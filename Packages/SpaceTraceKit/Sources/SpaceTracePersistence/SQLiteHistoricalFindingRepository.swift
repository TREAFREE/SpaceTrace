import CryptoKit
import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceAttribution
import SpaceTraceDomain

extension SQLiteEventJournalRepository {
    public func historicalPathHistoryPolicy() throws -> HistoricalPathHistoryPolicy {
        try HistoricalPathHistoryPolicy(retentionDays: readHistoricalRetentionDays())
    }

    public func setHistoricalPathHistoryPolicy(
        _ policy: HistoricalPathHistoryPolicy
    ) throws {
        _ = try setHistoricalPathHistoryPolicyAndScrub(
            days: policy.retentionDays,
            referenceDate: now()
        )
    }

    public func historicalPathHistoryAvailability(
        for scopeID: ScopeID
    ) throws -> HistoricalPathHistoryAvailability {
        try performHistoricalStartupMaintenanceIfNeeded()
        guard try readHistoricalRetentionDays() > 0 else { return .historyDisabled }
        let scope = Data(scopeID.rawValue.utf8)
        let available = try historicalOptionalInt(
            """
            SELECT 1
            FROM historical_observation_baseline_checkpoint checkpoint
            JOIN historical_observation_frame_commit commit_row
              ON commit_row.sequence=checkpoint.frame_sequence
            JOIN historical_observation_frame frame ON frame.frame_id=commit_row.frame_id
            JOIN historical_observation_batch batch ON batch.batch_id=frame.batch_id
            JOIN historical_scope scope ON scope.scope_key=batch.scope_key
            WHERE scope.scope_id=?
              AND commit_row.committed_at_ms >= (
                  SELECT updated_at_ms FROM historical_retention_policy WHERE singleton=1
              )
            LIMIT 1
            """,
            blobs: [scope]
        )
        return available == nil ? .baselineUnavailable : .available
    }

    public func nextHistoricalProjectionWork() throws -> HistoricalProjectionWork? {
        try performHistoricalStartupMaintenanceIfNeeded()
        return try readNextHistoricalProjectionWork()
    }

    public func commitHistoricalProjection(
        _ result: HistoricalFindingGenerationResult,
        for work: HistoricalProjectionWork
    ) throws -> HistoricalProjectionCommitOutcome {
        let resultDigest = try canonicalHistoricalProjectionDigest(result)
        try execute(
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin historical projection"
        )
        var responseLossAfterCommit = false
        do {
            let existingProjectionID = try historicalOptionalInt(
                "SELECT projection_id FROM historical_finding_projection WHERE work_id=?",
                integers: [work.recordID.rawValue]
            )
            let storedWork = try readHistoricalProjectionWork(id: work.recordID)
                .unwrap(field: "historical_projection_work")
            guard storedWork == work else {
                throw existingProjectionID == nil
                    ? SQLiteEventJournalError.historicalProjectionWorkMismatch
                    : SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            let baseline = try readHistoricalFrame(sequence: work.baselineSequence)
                .unwrap(field: "historical_projection_baseline")
            let comparison = try readHistoricalFrame(sequence: work.comparisonSequence)
                .unwrap(field: "historical_projection_comparison")
            let regenerated = try HistoricalFindingGenerator().generate(
                baseline: baseline,
                comparison: comparison,
                positiveLimit: work.positiveLimit
            )
            guard regenerated == result else {
                throw existingProjectionID == nil
                    ? SQLiteEventJournalError.historicalProjectionResultMismatch
                    : SQLiteEventJournalError.historicalProjectionImmutableConflict
            }

            if let projectionID = existingProjectionID {
                try validateStoredHistoricalProjection(
                    projectionID: projectionID,
                    work: work,
                    result: regenerated,
                    resultDigest: resultDigest
                )
                try execute(
                    "COMMIT TRANSACTION",
                    operation: "commit idempotent historical projection"
                )
                return .alreadyCommitted(
                    try HistoricalProjectionRecordID(projectionID)
                )
            }

            let projectionID = try insertHistoricalProjection(
                work: work,
                result: regenerated,
                resultDigest: resultDigest
            )
            try validateStoredHistoricalProjection(
                projectionID: projectionID,
                work: work,
                result: regenerated,
                resultDigest: resultDigest
            )
            try execute(
                "COMMIT TRANSACTION",
                operation: "commit historical projection"
            )
            if injectedFailurePoint == .afterHistoricalProjectionCommitBeforeReturningReceipt {
                injectedFailurePoint = nil
                responseLossAfterCommit = true
            }
            if responseLossAfterCommit {
                throw SQLiteEventJournalError.injectedFailure
            }
            return .newlyCommitted(try HistoricalProjectionRecordID(projectionID))
        } catch SQLiteEventJournalError.injectedFailure where responseLossAfterCommit {
            throw SQLiteEventJournalError.injectedFailure
        } catch {
            try rollback(after: error)
        }
    }

    public func historicalFindingAuditRecord(
        id: HistoricalFindingRecordID
    ) throws -> HistoricalFindingAuditRecord? {
        try performHistoricalStartupMaintenanceIfNeeded()
        guard let finding = try rehydratedHistoricalFinding(id: id) else {
            return nil
        }
        let storedRetraction = try readHistoricalStoredRetraction(findingID: id)
        if let storedRetraction,
           storedRetraction.expectedDraftDigest != finding.draftDigest {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }
        return try HistoricalFindingAuditRecord(
            finding: finding.effective,
            draftSHA256: try HistoricalEvidenceDigest(bytes: Array(finding.draftDigest)),
            retraction: storedRetraction?.record
        )
    }

    public func historicalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) throws -> [HistoricalFindingAuditRecord] {
        try historicalFindingAuditRecords(
            for: scopeID,
            through: comparisonSequence,
            limit: limit,
            evidenceInvalidatedOnly: false
        )
    }

    public func evidenceInvalidatedHistoricalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) throws -> [HistoricalFindingAuditRecord] {
        try historicalFindingAuditRecords(
            for: scopeID,
            through: comparisonSequence,
            limit: limit,
            evidenceInvalidatedOnly: true
        )
    }

    private func historicalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit,
        evidenceInvalidatedOnly: Bool
    ) throws -> [HistoricalFindingAuditRecord] {
        try performHistoricalStartupMaintenanceIfNeeded()
        let scopeBytes = try SQLiteHistoricalFindingCodec.encodeUTF8(
            scopeID.rawValue,
            field: "scope_id",
            maximumBytes: 4_096
        )
        let retractionJoin = evidenceInvalidatedOnly
            ? "JOIN historical_finding_retraction AS x ON x.retracted_finding_id=f.finding_id"
            : ""
        let candidates = try historicalRows(
            """
            SELECT f.finding_id,f.projection_id,w.comparison_sequence,r.rank
            FROM historical_finding AS f
            JOIN historical_finding_projection AS p ON p.projection_id=f.projection_id
            JOIN historical_projection_work AS w ON w.work_id=p.work_id
            JOIN historical_observation_node AS bn ON bn.node_id=f.baseline_node_id
            JOIN historical_observation_batch AS b ON b.batch_id=bn.batch_id
            JOIN historical_scope AS s ON s.scope_key=b.scope_key
            LEFT JOIN historical_finding_positive_rank AS r ON r.finding_id=f.finding_id
            \(retractionJoin)
            LEFT JOIN historical_observation_node AS cn ON cn.node_id=f.comparison_node_id
            LEFT JOIN frozen_attribution_decision AS bd ON bd.decision_id=bn.classification_decision_id
            LEFT JOIN frozen_attribution_decision AS cd ON cd.decision_id=cn.classification_decision_id
            WHERE w.comparison_sequence<=?1 AND s.scope_id=?3
            ORDER BY w.comparison_sequence DESC,
                CASE WHEN r.rank IS NULL THEN 1 ELSE 0 END ASC,
                r.rank ASC,
                f.baseline_node_id ASC,f.baseline_metric ASC,
                f.comparison_node_id ASC,f.comparison_metric ASC,
                f.kind ASC,
                COALESCE(bd.catalog_version,0) ASC,
                COALESCE(cd.catalog_version,0) ASC,
                f.finding_id ASC
            LIMIT ?2
            """,
            integers: [comparisonSequence.rawValue, Int64(limit.rawValue)],
            blobs: [scopeBytes]
        ) { statement in
            HistoricalEffectiveFindingCandidate(
                findingID: sqlite3_column_int64(statement, 0),
                projectionID: sqlite3_column_int64(statement, 1),
                comparisonSequence: sqlite3_column_int64(statement, 2),
                positiveRank: try historicalOptionalInteger(statement, 3).map(Int.init)
            )
        }

        var projectionCache: [Int64: [Int64: HistoricalRehydratedFinding]] = [:]
        var result: [HistoricalFindingAuditRecord] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            if projectionCache[candidate.projectionID] == nil {
                projectionCache[candidate.projectionID] = try rehydratedHistoricalProjection(
                    id: candidate.projectionID
                )
            }
            let projection = try projectionCache[candidate.projectionID]
                .unwrap(field: "historical_audit_projection")
            let finding = try projection[candidate.findingID]
                .unwrap(field: "historical_audit_finding")
            guard finding.effective.comparisonSequence.rawValue
                    == candidate.comparisonSequence,
                  finding.effective.positiveRank == candidate.positiveRank else {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            let recordID = try HistoricalFindingRecordID(candidate.findingID)
            let storedRetraction = try readHistoricalStoredRetraction(findingID: recordID)
            if evidenceInvalidatedOnly, storedRetraction == nil {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            if let storedRetraction,
               storedRetraction.expectedDraftDigest != finding.draftDigest {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            result.append(try HistoricalFindingAuditRecord(
                finding: finding.effective,
                draftSHA256: HistoricalEvidenceDigest(bytes: Array(finding.draftDigest)),
                retraction: storedRetraction?.record
            ))
        }
        return result
    }

    public func effectiveHistoricalFindings(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) throws -> [EffectiveHistoricalFinding] {
        try performHistoricalStartupMaintenanceIfNeeded()
        let scopeBytes = try SQLiteHistoricalFindingCodec.encodeUTF8(
            scopeID.rawValue,
            field: "scope_id",
            maximumBytes: 4_096
        )
        let candidates = try historicalRows(
            """
            SELECT f.finding_id,f.projection_id,w.comparison_sequence,r.rank
            FROM historical_finding AS f
            JOIN historical_finding_projection AS p ON p.projection_id=f.projection_id
            JOIN historical_projection_work AS w ON w.work_id=p.work_id
            JOIN historical_observation_node AS bn ON bn.node_id=f.baseline_node_id
            JOIN historical_observation_batch AS b ON b.batch_id=bn.batch_id
            JOIN historical_scope AS s ON s.scope_key=b.scope_key
            LEFT JOIN historical_finding_positive_rank AS r ON r.finding_id=f.finding_id
            LEFT JOIN historical_finding_retraction AS x ON x.retracted_finding_id=f.finding_id
            LEFT JOIN historical_observation_node AS cn ON cn.node_id=f.comparison_node_id
            LEFT JOIN frozen_attribution_decision AS bd ON bd.decision_id=bn.classification_decision_id
            LEFT JOIN frozen_attribution_decision AS cd ON cd.decision_id=cn.classification_decision_id
            WHERE w.comparison_sequence<=?1 AND s.scope_id=?3 AND x.retraction_sequence IS NULL
            ORDER BY w.comparison_sequence DESC,
                CASE WHEN r.rank IS NULL THEN 1 ELSE 0 END ASC,
                r.rank ASC,
                f.baseline_node_id ASC,f.baseline_metric ASC,
                f.comparison_node_id ASC,f.comparison_metric ASC,
                f.kind ASC,
                COALESCE(bd.catalog_version,0) ASC,
                COALESCE(cd.catalog_version,0) ASC,
                f.finding_id ASC
            LIMIT ?2
            """,
            integers: [comparisonSequence.rawValue, Int64(limit.rawValue)],
            blobs: [scopeBytes]
        ) { statement in
            HistoricalEffectiveFindingCandidate(
                findingID: sqlite3_column_int64(statement, 0),
                projectionID: sqlite3_column_int64(statement, 1),
                comparisonSequence: sqlite3_column_int64(statement, 2),
                positiveRank: try historicalOptionalInteger(statement, 3).map(Int.init)
            )
        }

        var projectionCache: [Int64: [Int64: HistoricalRehydratedFinding]] = [:]
        var result: [EffectiveHistoricalFinding] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            if projectionCache[candidate.projectionID] == nil {
                projectionCache[candidate.projectionID] = try rehydratedHistoricalProjection(
                    id: candidate.projectionID
                )
            }
            let projection = try projectionCache[candidate.projectionID]
                .unwrap(field: "historical_effective_projection")
            let finding = try projection[candidate.findingID]
                .unwrap(field: "historical_effective_finding")
            guard finding.effective.comparisonSequence.rawValue == candidate.comparisonSequence,
                  finding.effective.positiveRank == candidate.positiveRank else {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            result.append(finding.effective)
        }
        guard result.elementsEqual(result.sorted(by: historicalEffectiveFindingOrder)) else {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }
        return result
    }

    package func commitEvidenceInvalidation(
        _ command: HistoricalFindingEvidenceInvalidationCommand
    ) throws -> HistoricalRetractionCommitOutcome {
        let requestDigest = canonicalHistoricalRetractionDigest(command)
        try execute(
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin historical finding retraction"
        )
        var responseLossAfterCommit = false
        do {
            if let existing = try readHistoricalRetraction(requestID: command.requestID) {
                guard existing.record.findingID == command.findingID,
                      existing.expectedDraftDigest == Data(command.expectedDraftSHA256.bytes),
                      existing.canonicalRequestDigest == requestDigest else {
                    throw SQLiteEventJournalError.historicalRetractionImmutableConflict
                }
                try execute(
                    "COMMIT TRANSACTION",
                    operation: "commit idempotent historical finding retraction"
                )
                return .alreadyCommitted(existing.record)
            }

            let storedDigest = try historicalRows(
                "SELECT draft_sha256 FROM historical_finding WHERE finding_id=?",
                integers: [command.findingID.rawValue]
            ) { statement in
                try historicalData(statement, 0, "historical_finding.draft_sha256")
            }.first
            guard let storedDigest else {
                throw SQLiteEventJournalError.historicalRetractionTargetNotFound
            }
            guard storedDigest == Data(command.expectedDraftSHA256.bytes) else {
                throw SQLiteEventJournalError.historicalRetractionExpectedDigestMismatch
            }
            guard try historicalOptionalInt(
                "SELECT retraction_sequence FROM historical_finding_retraction WHERE retracted_finding_id=?",
                integers: [command.findingID.rawValue]
            ) == nil else {
                throw SQLiteEventJournalError.historicalRetractionImmutableConflict
            }

            try historicalExecuteNullable(
                "INSERT INTO historical_finding_retraction(request_format_version,request_id,canonical_request_sha256,retracted_finding_id,expected_draft_sha256,reason_code,committed_at_ms) VALUES(1,?,?,?,?,1,CAST((julianday('now')-2440587.5)*86400000 AS INTEGER))",
                values: [
                    .blob(Data(command.requestID.bytes)),
                    .blob(requestDigest),
                    .integer(command.findingID.rawValue),
                    .blob(storedDigest),
                ]
            )
            let committed = try readHistoricalRetraction(requestID: command.requestID)
                .unwrap(field: "historical_finding_retraction")
            guard committed.record.findingID == command.findingID,
                  committed.expectedDraftDigest == storedDigest,
                  committed.canonicalRequestDigest == requestDigest else {
                throw SQLiteEventJournalError.historicalRetractionImmutableConflict
            }
            if injectedFailurePoint == .beforeHistoricalRetractionCommit {
                injectedFailurePoint = nil
                throw SQLiteEventJournalError.injectedFailure
            }
            try execute(
                "COMMIT TRANSACTION",
                operation: "commit historical finding retraction"
            )
            if injectedFailurePoint == .afterHistoricalRetractionCommitBeforeReturningReceipt {
                injectedFailurePoint = nil
                responseLossAfterCommit = true
            }
            if responseLossAfterCommit {
                throw SQLiteEventJournalError.injectedFailure
            }
            return .newlyCommitted(committed.record)
        } catch SQLiteEventJournalError.injectedFailure where responseLossAfterCommit {
            throw SQLiteEventJournalError.injectedFailure
        } catch {
            try rollback(after: error)
        }
    }

    public func finalizeCalibrationWithHistoricalFrames(
        _ request: HistoricalCalibrationFinalizationRequest
    ) throws -> HistoricalCalibrationFinalizationOutcome {
        let result = try finalizeCalibrationPrimitive(
            runID: request.runID,
            report: request.report,
            workItem: request.workItem,
            streamID: request.streamID,
            historicalRequest: request
        )
        guard let outcome = result.historicalOutcome else {
            throw SQLiteEventJournalError.corruptStoredValue(
                field: "historical_finalization_outcome"
            )
        }
        return outcome
    }

    public func historicalObservationFrame(
        sequence: ObservationCommitSequence
    ) throws -> HistoricalFindingObservationFrame? {
        try performHistoricalStartupMaintenanceIfNeeded()
        return try readHistoricalFrame(sequence: sequence)
    }

    func finalizeCalibrationPrimitive(
        runID: CalibrationRunID,
        report: CalibrationReport,
        workItem: DirtyRegionWorkItem,
        streamID: EventStreamID,
        historicalRequest: HistoricalCalibrationFinalizationRequest?
    ) throws -> HistoricalCalibrationPrimitiveResult {
        guard report.coverage == .complete else {
            throw SQLiteEventJournalError.incompleteReportCannotFinalize
        }

        let requestDigest = try historicalRequest.map(canonicalHistoricalRequestDigest)
        let disabledRequestDigest = historicalRequest.map(canonicalDisabledHistoricalRequestDigest)
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin calibration finalization")
        var responseLossAfterCommit = false
        do {
            if let historicalRequest,
               let disabledRequestDigest,
               try validateDisabledReceiptIfPresent(
                   request: historicalRequest,
                   expectedDigest: disabledRequestDigest
               ) {
                try execute(
                    "COMMIT TRANSACTION",
                    operation: "commit idempotent disabled historical finalization"
                )
                return HistoricalCalibrationPrimitiveResult(
                    legacyPublished: true,
                    historicalOutcome: .historyDisabled
                )
            }
            let context = try readScanRun(runID)
            if let historicalRequest,
               let requestDigest,
               context.state != "running" {
                let outcome = try readTerminalHistoricalOutcome(
                    request: historicalRequest,
                    expectedDigest: requestDigest,
                    context: context
                )
                try execute(
                    "COMMIT TRANSACTION",
                    operation: "commit idempotent historical finalization"
                )
                return HistoricalCalibrationPrimitiveResult(
                    legacyPublished: outcome.isPublished,
                    historicalOutcome: outcome
                )
            }

            guard context.state == "running" else {
                throw SQLiteEventJournalError.scanRunNotRunning(runID.rawValue)
            }
            guard context.streamID == streamID,
                  context.regionPath == workItem.region.path,
                  context.revision == workItem.revision else {
                throw SQLiteEventJournalError.scanRunContextMismatch(runID.rawValue)
            }
            let summary = try stagedSummary(runID: runID, root: context.regionPath)
            guard summary.count == report.directoriesStaged,
                  summary.containsRoot,
                  summary.partialCount == 0 else {
                throw SQLiteEventJournalError.stagedDirectoryCountMismatch(
                    expected: report.directoriesStaged,
                    actual: summary.count
                )
            }

            let retentionDays = try readHistoricalRetentionDays()
            let durableWork = try readExactHistoricalDirtyWork(
                streamID: streamID,
                path: workItem.region.path
            )
            guard durableWork?.revision == workItem.revision else {
                if retentionDays > 0, let requestDigest {
                    try insertSupersededReceipt(
                        runID: runID,
                        digest: requestDigest
                    )
                }
                try finishScanRun(runID, state: "superseded", report: report)
                try deleteStagedRows(runID)
                try execute("COMMIT TRANSACTION", operation: "commit superseded scan")
                return HistoricalCalibrationPrimitiveResult(
                    legacyPublished: false,
                    historicalOutcome: historicalRequest == nil ? nil : .superseded
                )
            }
            guard durableWork == workItem else {
                throw SQLiteEventJournalError.scanRunContextMismatch(runID.rawValue)
            }

            var historicalOutcome: HistoricalCalibrationFinalizationOutcome?
            if let historicalRequest, let requestDigest {
                if retentionDays == 0 {
                    try insertDisabledReceipt(
                        request: historicalRequest,
                        digest: canonicalDisabledHistoricalRequestDigest(historicalRequest)
                    )
                    historicalOutcome = .historyDisabled
                } else {
                    historicalOutcome = try persistHistoricalFrames(
                        request: historicalRequest,
                        requestDigest: requestDigest
                    )
                }
            }
            try markMissingDirectoriesDeleted(
                streamID: streamID,
                region: context.regionPath,
                runID: runID
            )
            try publishStagedDirectories(streamID: streamID, runID: runID)
            if retentionDays > 0 {
                try recordDirectoryHistory(streamID: streamID, runID: runID, observedAt: now())
            }
            guard try resolve(workItem, for: streamID) else {
                throw SQLiteEventJournalError.dirtyRevisionChangedDuringFinalization
            }
            try finishScanRun(runID, state: "completed", report: report)
            if let historicalRequest,
               case let .published(commit)? = historicalOutcome {
                let revisions = try appendReconciliationRevisions(
                    for: historicalRequest
                )
                historicalOutcome = .published(
                    HistoricalCalibrationCommit(
                        disposition: commit.disposition,
                        logical: commit.logical,
                        allocated: commit.allocated,
                        reconciliationRevisions: revisions
                    )
                )
                try failHistoricalFinalizationIfRequested(
                    .afterHistoricalReconciliationRevisions
                )
            }
            try deleteStagedRows(runID)
            try execute("COMMIT TRANSACTION", operation: "commit calibration finalization")
            if historicalRequest != nil,
               injectedFailurePoint == .afterCalibrationCommitBeforeReturningReceipt {
                injectedFailurePoint = nil
                responseLossAfterCommit = true
            }
            if responseLossAfterCommit {
                throw SQLiteEventJournalError.injectedFailure
            }
            return HistoricalCalibrationPrimitiveResult(
                legacyPublished: true,
                historicalOutcome: historicalOutcome
            )
        } catch SQLiteEventJournalError.injectedFailure where responseLossAfterCommit {
            throw SQLiteEventJournalError.injectedFailure
        } catch {
            try rollback(after: error)
        }
    }
}

extension SQLiteEventJournalRepository:
    HistoricalFindingPersistenceRepository,
    HistoricalFindingIntegrityReconciliationRepository
{}

struct HistoricalCalibrationPrimitiveResult {
    let legacyPublished: Bool
    let historicalOutcome: HistoricalCalibrationFinalizationOutcome?
}

private extension HistoricalCalibrationFinalizationOutcome {
    var isPublished: Bool {
        if case .published = self { return true }
        return false
    }
}

private extension SQLiteEventJournalRepository {
    func persistHistoricalFrames(
        request: HistoricalCalibrationFinalizationRequest,
        requestDigest: Data
    ) throws -> HistoricalCalibrationFinalizationOutcome {
        let priorSequences = try latestHistoricalSequences(
            scopeID: request.observation.scopeID
        )
        let reconciledObservation: HistoricalPairedObservationCandidate
        if let priorSequences {
            let previousLogicalFrame = try readHistoricalFrame(
                sequence: priorSequences.logical
            ).unwrap(field: "historical_previous_logical_frame")
            reconciledObservation = try HistoricalCalibrationAbsenceReconciler()
                .reconcile(
                    current: request.observation,
                    previousLogicalFrame: previousLogicalFrame
                )
        } else {
            reconciledObservation = request.observation
        }
        let persistedRequest = try HistoricalCalibrationFinalizationRequest(
            runID: request.runID,
            report: request.report,
            workItem: request.workItem,
            streamID: request.streamID,
            observation: reconciledObservation
        )
        try validateCandidateAgainstStage(persistedRequest)
        if priorSequences == nil,
           persistedRequest.observation.nodes.contains(where: { node in
               if case .absent = node.state { return true }
               return false
           }) {
            throw SQLiteEventJournalError.historicalFirstBaselineCannotContainAbsence
        }
        if let priorSequences {
            try validateAbsenceEvidence(
                in: persistedRequest.observation,
                priorLogicalSequence: priorSequences.logical
            )
        }

        let retentionAnchor = try persistedRequest.observation.nodes
            .map(\.observedAt.millisecondsSince1970).min()
            .unwrap(field: "historical_retention_anchor")
        let expiresAt = try addingThirtyDays(retentionAnchor)
        guard expiresAt >= Self.historicalMilliseconds(now()) else {
            throw SQLiteEventJournalError.historicalCandidateExpired
        }
        let committedAt = Self.historicalMilliseconds(now())

        let scopeKey = try upsertHistoricalScope(persistedRequest.observation.scopeID)
        let subjectKeys = try upsertHistoricalSubjects(
            persistedRequest.observation.nodes,
            scopeKey: scopeKey
        )
        let locationKeys = try upsertHistoricalLocations(
            persistedRequest.observation.nodes,
            scopeKey: scopeKey,
            pathSemanticsVersion: persistedRequest.observation.pathSemanticsVersion
        )
        let decisionKeys = try upsertHistoricalDecisions(persistedRequest.observation.nodes)
        try failHistoricalFinalizationIfRequested(.afterHistoricalDictionaries)

        let rootSubjectKey = try subjectKeys[persistedRequest.observation.rootSubjectID]
            .unwrap(field: "historical_root_subject_key")
        let batchID = try insertHistoricalBatch(
            request: persistedRequest,
            scopeKey: scopeKey,
            rootSubjectKey: rootSubjectKey,
            committedAt: committedAt
        )
        let logicalFrameID = try insertHistoricalFrame(batchID: batchID, metricCode: 1)
        let allocatedFrameID = try insertHistoricalFrame(batchID: batchID, metricCode: 2)
        try failHistoricalFinalizationIfRequested(.afterHistoricalBatch)

        let nodeIDs = try insertHistoricalNodes(
            persistedRequest.observation.nodes,
            batchID: batchID,
            subjectKeys: subjectKeys,
            locationKeys: locationKeys,
            decisionKeys: decisionKeys
        )
        try failHistoricalFinalizationIfRequested(.afterHistoricalNodes)
        try insertHistoricalEndpoints(
            persistedRequest.observation.nodes,
            nodeIDs: nodeIDs,
            frameID: logicalFrameID,
            metric: .logical
        )
        try failHistoricalFinalizationIfRequested(.afterHistoricalLogicalEndpoints)
        try insertHistoricalEndpoints(
            persistedRequest.observation.nodes,
            nodeIDs: nodeIDs,
            frameID: allocatedFrameID,
            metric: .allocated
        )

        let rootNodeID = try nodeIDs[persistedRequest.observation.rootSubjectID]
            .unwrap(field: "historical_root_node_id")
        let logicalSequence = try insertHistoricalFrameCommit(
            frameID: logicalFrameID,
            rootNodeID: rootNodeID,
            metricCode: 1,
            endpointCount: persistedRequest.observation.nodes.count,
            committedAt: committedAt,
            retentionAnchor: retentionAnchor,
            expiresAt: expiresAt
        )
        try failHistoricalFinalizationIfRequested(.afterHistoricalLogicalMarker)
        let allocatedSequence = try insertHistoricalFrameCommit(
            frameID: allocatedFrameID,
            rootNodeID: rootNodeID,
            metricCode: 2,
            endpointCount: persistedRequest.observation.nodes.count,
            committedAt: committedAt,
            retentionAnchor: retentionAnchor,
            expiresAt: expiresAt
        )

        let materialized = try HistoricalPairedObservationCommitMaterializer(
            candidate: persistedRequest.observation
        ).materialize(
            storeGeneration: try historicalStoreGeneration(),
            nodeIDs: nodeIDs,
            logicalSequence: logicalSequence,
            allocatedSequence: allocatedSequence
        )
        guard try readHistoricalFrame(sequence: logicalSequence) == materialized.logical,
              try readHistoricalFrame(sequence: allocatedSequence) == materialized.allocated else {
            throw SQLiteEventJournalError.corruptStoredValue(
                field: "historical_frame_rehydration"
            )
        }

        try insertPublishedReceipt(
            request: persistedRequest,
            digest: requestDigest,
            logicalSequence: logicalSequence,
            allocatedSequence: allocatedSequence,
            committedAt: committedAt,
            retentionAnchor: retentionAnchor,
            expiresAt: expiresAt
        )
        try failHistoricalFinalizationIfRequested(.beforeHistoricalProjectionWork)
        if let priorSequences {
            try insertHistoricalProjectionWork(
                baseline: priorSequences,
                comparison: (logicalSequence, allocatedSequence),
                committedAt: committedAt
            )
        } else {
            try insertHistoricalBaselineCheckpoints(
                logicalSequence: logicalSequence,
                allocatedSequence: allocatedSequence,
                committedAt: committedAt
            )
        }

        let logicalRootID = materialized.logical.rootEndpointID
        let allocatedRootID = materialized.allocated.rootEndpointID
        return .published(
            HistoricalCalibrationCommit(
                disposition: .newlyCommitted,
                logical: try HistoricalObservationFrameCommit(
                    sequence: logicalSequence,
                    rootEndpointID: logicalRootID,
                    endpointCount: persistedRequest.observation.nodes.count
                ),
                allocated: try HistoricalObservationFrameCommit(
                    sequence: allocatedSequence,
                    rootEndpointID: allocatedRootID,
                    endpointCount: persistedRequest.observation.nodes.count
                )
            )
        )
    }
}

private extension SQLiteEventJournalRepository {
    func readExactHistoricalDirtyWork(
        streamID: EventStreamID,
        path: DirtyRegionPath
    ) throws -> DirtyRegionWorkItem? {
        let sql = "SELECT reasons,maximum_cursor_be,revision_be FROM dirty_region WHERE stream_id=? AND path=?"
        let database = try databaseHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw historicalSQLiteError("prepare dirty-work proof") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, streamID.rawValue, -1, historicalSQLiteTransient)
        sqlite3_bind_text(statement, 2, path.rawValue, -1, historicalSQLiteTransient)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw historicalSQLiteError("read dirty-work proof")
        }
        let reasons = DirtyRegionReason(
            rawValue: UInt64(bitPattern: sqlite3_column_int64(statement, 0))
        )
        let cursor: EventJournalCursor?
        if sqlite3_column_type(statement, 1) == SQLITE_NULL {
            cursor = nil
        } else {
            let data = try historicalData(statement, 1, "dirty.maximum_cursor")
            guard data.count == 8 else {
                throw SQLiteEventJournalError.corruptStoredValue(
                    field: "dirty.maximum_cursor"
                )
            }
            cursor = EventJournalCursor(
                data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            )
        }
        let revisionData = try historicalData(statement, 2, "dirty.revision")
        guard revisionData.count == 8 else {
            throw SQLiteEventJournalError.corruptStoredValue(field: "dirty.revision")
        }
        let revision = revisionData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        do {
            return DirtyRegionWorkItem(
                region: try DirtyRegion(
                    path: path,
                    reasons: reasons,
                    maximumCursor: cursor
                ),
                revision: try DirtyRegionRevision(revision)
            )
        } catch {
            throw SQLiteEventJournalError.corruptStoredValue(field: "dirty_region")
        }
    }

    func validateCandidateAgainstStage(
        _ request: HistoricalCalibrationFinalizationRequest
    ) throws {
        guard request.observation.rootPath.utf8.elementsEqual(
            request.workItem.region.path.rawValue.utf8
        ) else {
            throw SQLiteEventJournalError.historicalCandidateStageMismatch
        }
        let staged = try readHistoricalStagedAggregates(runID: request.runID)
        let present = request.observation.nodes.compactMap {
            node -> (String, Int64, Int64, String)? in
            guard case let .present(logical, allocated, coverage) = node.state else {
                return nil
            }
            return (node.path, logical.value, allocated.value, coverage.rawValue)
        }
        guard staged.count == present.count else {
            throw SQLiteEventJournalError.historicalCandidateStageMismatch
        }
        for (path, logical, allocated, coverage) in present {
            guard staged.contains(where: { row in
                row.path.utf8.elementsEqual(path.utf8)
                    && row.logical == logical
                    && row.allocated == allocated
                    && row.coverage == coverage
            }) else {
                throw SQLiteEventJournalError.historicalCandidateStageMismatch
            }
        }
        for node in request.observation.nodes {
            switch node.state {
            case .absent, .unknown:
                guard staged.contains(where: { $0.path.utf8.elementsEqual(node.path.utf8) }) == false else {
                    throw SQLiteEventJournalError.historicalCandidateStageMismatch
                }
            case .present:
                break
            }
        }
    }

    func validateAbsenceEvidence(
        in candidate: HistoricalPairedObservationCandidate,
        priorLogicalSequence: ObservationCommitSequence
    ) throws {
        let prior = try readHistoricalFrame(sequence: priorLogicalSequence)
        let previousBySubject = Dictionary(
            uniqueKeysWithValues: (prior?.nodes ?? []).map {
                ($0.endpoint.subjectID, $0)
            }
        )
        for node in candidate.nodes {
            guard case .absent = node.state else { continue }
            guard let parentSubjectID = node.parentSubjectID,
                  let previousNode = previousBySubject[node.subjectID],
                  let previousParent = previousBySubject[parentSubjectID],
                  previousNode.parentSubjectID == parentSubjectID,
                  case .present(_, .complete) = previousNode.endpoint.state,
                  let currentParent = candidate.nodes.first(where: {
                      $0.subjectID == parentSubjectID
                  }),
                  currentParent.directChildrenCoverage == .complete,
                  case let .present(_, _, parentCoverage) = currentParent.state,
                  parentCoverage == .complete,
                  previousParent.endpoint.locationID == currentParent.locationID,
                  previousParent.path.utf8.elementsEqual(currentParent.path.utf8),
                  previousNode.endpoint.identityBasis == node.identityBasis,
                  previousNode.endpoint.locationID == node.locationID,
                  previousNode.path.utf8.elementsEqual(node.path.utf8),
                  previousNode.displayName.utf8.elementsEqual(node.displayName.utf8),
                  previousNode.stableIdentityEvidence == node.stableIdentityEvidence else {
                throw SQLiteEventJournalError.historicalAbsenceEvidenceMissing
            }
        }
    }

    func readHistoricalStagedAggregates(
        runID: CalibrationRunID
    ) throws -> [(path: String, logical: Int64, allocated: Int64, coverage: String)] {
        let sql = "SELECT path,logical_bytes,allocated_bytes,coverage FROM scan_node_stage WHERE scan_run_id=? ORDER BY path"
        return try historicalRows(sql, text: runID.rawValue) { statement in
            guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER else {
                throw SQLiteEventJournalError.historicalCandidateStageMismatch
            }
            return (
                try historicalText(statement, 0, "scan_node_stage.path"),
                sqlite3_column_int64(statement, 1),
                sqlite3_column_int64(statement, 2),
                try historicalText(statement, 3, "scan_node_stage.coverage")
            )
        }
    }
}

private extension SQLiteEventJournalRepository {
    /// Appends one compact v12 row per completely measured directory. The row
    /// is the shared authority for its hourly and daily public revision IDs.
    /// This runs only after the dirty compare-and-delete succeeds and the scan
    /// is terminal, but before staged evidence is removed and before COMMIT.
    func appendReconciliationRevisions(
        for request: HistoricalCalibrationFinalizationRequest
    ) throws -> [ReconciliationRevision] {
        let rows = try reconciliationSourceRows(runID: request.runID)
        let expectedPresentCount = request.observation.nodes.reduce(into: 0) { count, node in
            if case .present = node.state { count += 1 }
        }
        guard rows.count == expectedPresentCount else {
            throw SQLiteEventJournalError.corruptStoredValue(
                field: "reconciliation_source_count"
            )
        }

        for row in rows {
            let hourlyPredecessor = try terminalReconciliationPredecessor(
                nodeID: row.nodeID,
                bucket: .hourly
            )
            let dailyPredecessor = try terminalReconciliationPredecessor(
                nodeID: row.nodeID,
                bucket: .daily
            )
            let digest = reconciliationPayloadDigest(
                row: row,
                runID: request.runID,
                dirtyRevision: request.workItem.revision
            )
            try historicalExecuteNullable(
                "INSERT INTO historical_reconciliation_revision(node_id,hourly_predecessor_node_id,daily_predecessor_node_id,descendant_count,payload_sha256) VALUES(?,?,?,?,?)",
                values: [
                    .integer(row.nodeID),
                    hourlyPredecessor.map(HistoricalSQLValue.integer) ?? .null,
                    dailyPredecessor.map(HistoricalSQLValue.integer) ?? .null,
                    .integer(row.descendantCount),
                    .blob(digest),
                ]
            )
        }
        return try readReconciliationRevisions(runID: request.runID)
    }

    func readReconciliationRevisions(
        runID: CalibrationRunID
    ) throws -> [ReconciliationRevision] {
        let context = try readScanRun(runID)
        let rows = try historicalRows(
            """
            SELECT n.node_id,s.subject_id,l.location_id,n.observed_at_ms,
                   logical.bytes,allocated.bytes,r.descendant_count,
                   scope.scope_id,b.stream_id_utf8,
                   r.hourly_predecessor_node_id,r.daily_predecessor_node_id,
                   r.payload_sha256
            FROM historical_observation_batch b
            JOIN historical_scope scope ON scope.scope_key=b.scope_key
            JOIN historical_observation_node n ON n.batch_id=b.batch_id
            JOIN historical_subject s ON s.subject_key=n.subject_key
            JOIN historical_location l ON l.location_key=n.location_key
            JOIN historical_metric_endpoint logical
              ON logical.node_id=n.node_id AND logical.metric=1
            JOIN historical_metric_endpoint allocated
              ON allocated.node_id=n.node_id AND allocated.metric=2
            JOIN historical_reconciliation_revision r ON r.node_id=n.node_id
            WHERE b.scan_run_id=?
            ORDER BY n.node_id
            """,
            text: runID.rawValue
        ) { statement in
            try ReconciliationStoredRow(
                nodeID: sqlite3_column_int64(statement, 0),
                subjectID: SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 1, "reconciliation.subject_id"),
                    field: "reconciliation.subject_id",
                    maximumBytes: 4_096
                ),
                locationID: SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 2, "reconciliation.location_id"),
                    field: "reconciliation.location_id",
                    maximumBytes: 4_096
                ),
                observedAt: sqlite3_column_int64(statement, 3),
                logicalBytes: sqlite3_column_int64(statement, 4),
                allocatedBytes: sqlite3_column_int64(statement, 5),
                descendantCount: sqlite3_column_int64(statement, 6),
                scopeID: SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 7, "reconciliation.scope_id"),
                    field: "reconciliation.scope_id",
                    maximumBytes: 4_096
                ),
                streamID: SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 8, "reconciliation.stream_id"),
                    field: "reconciliation.stream_id",
                    maximumBytes: 4_096
                ),
                hourlyPredecessorNodeID: try historicalOptionalInteger(statement, 9),
                dailyPredecessorNodeID: try historicalOptionalInteger(statement, 10),
                payloadDigest: try historicalData(statement, 11, "reconciliation.payload")
            )
        }

        var result: [ReconciliationRevision] = []
        result.reserveCapacity(rows.count * 2)
        for row in rows {
            guard row.streamID.utf8.elementsEqual(context.streamID.rawValue.utf8),
                  reconciliationPayloadDigest(
                    row: row.source,
                    runID: runID,
                    dirtyRevision: context.revision
                  ) == row.payloadDigest else {
                throw SQLiteEventJournalError.corruptStoredValue(
                    field: "reconciliation_payload"
                )
            }
            for bucket in [DirectoryHistoryBucket.hourly, .daily] {
                let duration = bucket.durationMilliseconds
                let bucketStart = row.observedAt - row.observedAt % duration
                let key = try ReconciliationRevisionKey(
                    scopeID: WatchedScopeID(row.scopeID),
                    streamID: EventStreamID(row.streamID),
                    subjectID: SubjectID(row.subjectID),
                    locationID: ObservationLocationID(row.locationID),
                    bucket: bucket,
                    bucketStart: ObservationInstant(millisecondsSince1970: bucketStart)
                )
                let publicID = try SQLiteHistoricalCorrectionSchema.materializedRevisionID(
                    nodeID: row.nodeID,
                    bucketCode: bucket == .hourly ? 1 : 2
                )
                let predecessorNodeID = bucket == .hourly
                    ? row.hourlyPredecessorNodeID
                    : row.dailyPredecessorNodeID
                let predecessor: ReconciliationRevisionReference? = try predecessorNodeID.map {
                    let predecessorID = try SQLiteHistoricalCorrectionSchema.materializedRevisionID(
                        nodeID: $0,
                        bucketCode: bucket == .hourly ? 1 : 2
                    )
                    return ReconciliationRevisionReference(
                        id: try ReconciliationRevisionID(predecessorID),
                        sequence: try ReconciliationRevisionSequence(predecessorID),
                        key: key
                    )
                }
                result.append(
                    try ReconciliationRevision(
                        id: ReconciliationRevisionID(publicID),
                        sequence: ReconciliationRevisionSequence(publicID),
                        key: key,
                        predecessor: predecessor,
                        scanRunID: runID,
                        dirtyRevision: context.revision,
                        observedAt: ObservationInstant(
                            millisecondsSince1970: row.observedAt
                        ),
                        logicalBytes: ByteCount(row.logicalBytes),
                        allocatedBytes: ByteCount(row.allocatedBytes),
                        descendantCount: row.descendantCount,
                        payloadDigest: ReconciliationRevisionDigest(
                            bytes: Array(row.payloadDigest)
                        )
                    )
                )
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    func reconciliationSourceRows(
        runID: CalibrationRunID
    ) throws -> [ReconciliationSourceRow] {
        try historicalRows(
            """
            SELECT n.node_id,s.subject_id,l.location_id,n.observed_at_ms,
                   logical.bytes,allocated.bytes,staged.descendant_count,
                   scope.scope_id,b.stream_id_utf8
            FROM historical_observation_batch b
            JOIN historical_scope scope ON scope.scope_key=b.scope_key
            JOIN historical_observation_node n ON n.batch_id=b.batch_id
            JOIN historical_subject s ON s.subject_key=n.subject_key
            JOIN historical_location l ON l.location_key=n.location_key
            JOIN historical_metric_endpoint logical
              ON logical.node_id=n.node_id AND logical.metric=1
            JOIN historical_metric_endpoint allocated
              ON allocated.node_id=n.node_id AND allocated.metric=2
            JOIN scan_node_stage staged
              ON staged.scan_run_id=b.scan_run_id
             AND CAST(staged.path AS BLOB)=l.path_utf8
            WHERE b.scan_run_id=?
              AND logical.state_kind=1 AND logical.measurement_coverage=1
              AND allocated.state_kind=1 AND allocated.measurement_coverage=1
              AND staged.coverage='complete'
            ORDER BY n.node_id
            """,
            text: runID.rawValue
        ) { statement in
            ReconciliationSourceRow(
                nodeID: sqlite3_column_int64(statement, 0),
                subjectID: try SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 1, "reconciliation.subject_id"),
                    field: "reconciliation.subject_id",
                    maximumBytes: 4_096
                ),
                locationID: try SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 2, "reconciliation.location_id"),
                    field: "reconciliation.location_id",
                    maximumBytes: 4_096
                ),
                observedAt: sqlite3_column_int64(statement, 3),
                logicalBytes: sqlite3_column_int64(statement, 4),
                allocatedBytes: sqlite3_column_int64(statement, 5),
                descendantCount: sqlite3_column_int64(statement, 6),
                scopeID: try SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 7, "reconciliation.scope_id"),
                    field: "reconciliation.scope_id",
                    maximumBytes: 4_096
                ),
                streamID: try SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 8, "reconciliation.stream_id"),
                    field: "reconciliation.stream_id",
                    maximumBytes: 4_096
                )
            )
        }
    }

    func terminalReconciliationPredecessor(
        nodeID: Int64,
        bucket: DirectoryHistoryBucket
    ) throws -> Int64? {
        let predecessorColumn = bucket == .hourly
            ? "hourly_predecessor_node_id"
            : "daily_predecessor_node_id"
        let duration = bucket.durationMilliseconds
        return try historicalOptionalInt(
            """
            SELECT prior.node_id
            FROM historical_observation_node new_node
            JOIN historical_observation_batch new_batch
              ON new_batch.batch_id=new_node.batch_id
            JOIN historical_reconciliation_revision prior
            JOIN historical_observation_node prior_node
              ON prior_node.node_id=prior.node_id
            JOIN historical_observation_batch prior_batch
              ON prior_batch.batch_id=prior_node.batch_id
            WHERE new_node.node_id=?
              AND prior.node_id<new_node.node_id
              AND prior_batch.scope_key=new_batch.scope_key
              AND prior_batch.stream_id_utf8=new_batch.stream_id_utf8
              AND prior_node.subject_key=new_node.subject_key
              AND prior_node.location_key=new_node.location_key
              AND prior_node.observed_at_ms/?=new_node.observed_at_ms/?
              AND NOT EXISTS(
                  SELECT 1 FROM historical_reconciliation_revision successor
                  WHERE successor.\(predecessorColumn)=prior.node_id
              )
            ORDER BY prior.node_id DESC
            LIMIT 1
            """,
            integers: [nodeID, duration, duration]
        )
    }

    func reconciliationPayloadDigest(
        row: ReconciliationSourceRow,
        runID: CalibrationRunID,
        dirtyRevision: DirtyRegionRevision
    ) -> Data {
        var payload = Data("SpaceTrace.ReconciliationNodeRevision.v1".utf8)
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(data)
        }
        func append(_ value: Int64) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        }
        append(row.nodeID)
        append(Data(row.scopeID.utf8))
        append(Data(row.streamID.utf8))
        append(Data(row.subjectID.utf8))
        append(Data(row.locationID.utf8))
        append(Data(runID.rawValue.utf8))
        append(Int64(bitPattern: dirtyRevision.rawValue))
        append(row.observedAt)
        append(row.logicalBytes)
        append(row.allocatedBytes)
        append(row.descendantCount)
        return Data(SHA256.hash(data: payload))
    }
}

private extension SQLiteEventJournalRepository {
    func upsertHistoricalScope(_ scopeID: ScopeID) throws -> Int64 {
        let bytes = try SQLiteHistoricalFindingCodec.encodeUTF8(
            scopeID.rawValue,
            field: "scope_id",
            maximumBytes: 4_096
        )
        try historicalExecute(
            "INSERT OR IGNORE INTO historical_scope(scope_id) VALUES(?)",
            blobs: [bytes]
        )
        return try historicalSingleInt(
            "SELECT scope_key FROM historical_scope WHERE scope_id=?",
            blobs: [bytes]
        )
    }

    func upsertHistoricalSubjects(
        _ nodes: [HistoricalPairedObservationNodeCandidate],
        scopeKey: Int64
    ) throws -> [SubjectID: Int64] {
        var result: [SubjectID: Int64] = [:]
        for node in nodes {
            let bytes = try SQLiteHistoricalFindingCodec.encodeUTF8(
                node.subjectID.rawValue,
                field: "subject_id",
                maximumBytes: 4_096
            )
            let basis = node.identityBasis == .stableFileSystemObject ? 1 : 2
            try historicalExecute(
                "INSERT OR IGNORE INTO historical_subject(scope_key,identity_basis,subject_id) VALUES(?,?,?)",
                integers: [scopeKey, Int64(basis)],
                blobs: [bytes]
            )
            let key = try historicalSingleInt(
                "SELECT subject_key FROM historical_subject WHERE scope_key=? AND identity_basis=? AND subject_id=?",
                integers: [scopeKey, Int64(basis)],
                blobs: [bytes]
            )
            result[node.subjectID] = key
        }
        return result
    }

    func upsertHistoricalLocations(
        _ nodes: [HistoricalPairedObservationNodeCandidate],
        scopeKey: Int64,
        pathSemanticsVersion: ObservationSemanticsVersion
    ) throws -> [SubjectID: Int64] {
        var result: [SubjectID: Int64] = [:]
        for node in nodes {
            let location = try SQLiteHistoricalFindingCodec.encodeUTF8(
                node.locationID.rawValue,
                field: "location_id",
                maximumBytes: 4_096
            )
            let path = try SQLiteHistoricalFindingCodec.encodeUTF8(
                node.path,
                field: "path",
                maximumBytes: 4_096
            )
            let display = try SQLiteHistoricalFindingCodec.encodeUTF8(
                node.displayName,
                field: "display_name",
                maximumBytes: 1_024
            )
            try historicalExecute(
                "INSERT OR IGNORE INTO historical_location(scope_key,path_semantics_version,location_id,path_utf8,display_name_utf8) VALUES(?,?,?,?,?)",
                integers: [scopeKey, Int64(pathSemanticsVersion.rawValue)],
                blobs: [location, path, display]
            )
            let key = try historicalSingleInt(
                "SELECT location_key FROM historical_location WHERE scope_key=? AND path_semantics_version=? AND location_id=? AND path_utf8=? AND display_name_utf8=?",
                integers: [scopeKey, Int64(pathSemanticsVersion.rawValue)],
                blobs: [location, path, display]
            )
            result[node.subjectID] = key
        }
        return result
    }

    func upsertHistoricalDecisions(
        _ nodes: [HistoricalPairedObservationNodeCandidate]
    ) throws -> [SubjectID: Int64] {
        var result: [SubjectID: Int64] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for node in nodes {
            guard let decision = node.classification else { continue }
            let payload = try encoder.encode(decision)
            let digest = Data(SHA256.hash(data: payload))
            if let existing = try historicalOptionalInt(
                "SELECT decision_id FROM frozen_attribution_decision WHERE canonical_sha256=? AND canonical_payload=?",
                blobs: [digest, payload]
            ) {
                result[node.subjectID] = existing
                continue
            }
            let shape = try historicalAttributionShape(decision)
            try historicalInsertDecision(
                decision: decision,
                payload: payload,
                digest: digest,
                shape: shape
            )
            let key = sqlite3_last_insert_rowid(try databaseHandle())
            if case let .ambiguous(ruleIDs) = shape {
                for (ordinal, ruleID) in ruleIDs.enumerated() {
                    try historicalExecute(
                        "INSERT INTO frozen_attribution_competitor(decision_id,ordinal,rule_id) VALUES(?,?,?)",
                        integers: [key, Int64(ordinal)],
                        blobs: [Data(ruleID.utf8)]
                    )
                }
            }
            result[node.subjectID] = key
        }
        return result
    }

    func historicalInsertDecision(
        decision: VersionedAttributionDecision,
        payload: Data,
        digest: Data,
        shape: HistoricalAttributionShape
    ) throws {
        let sql = "INSERT INTO frozen_attribution_decision(format_version,canonical_payload,canonical_sha256,catalog_version,decision_kind,category_code,confidence_code,rule_id,rule_version,evidence_code) VALUES(1,?,?,?,?,?,?,?,?,?)"
        var statement: OpaquePointer?
        let database = try databaseHandle()
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw historicalSQLiteError("prepare attribution") }
        defer { sqlite3_finalize(statement) }
        try bindHistoricalBlob(payload, statement, 1)
        try bindHistoricalBlob(digest, statement, 2)
        sqlite3_bind_int64(statement, 3, Int64(decision.catalogVersion.rawValue))
        switch shape {
        case let .classified(category, confidence, ruleID, ruleVersion, evidenceCode):
            sqlite3_bind_int(statement, 4, 1)
            sqlite3_bind_int(statement, 5, category)
            sqlite3_bind_int(statement, 6, confidence)
            try bindHistoricalBlob(Data(ruleID.utf8), statement, 7)
            sqlite3_bind_int64(statement, 8, Int64(ruleVersion))
            try bindHistoricalBlob(Data(evidenceCode.utf8), statement, 9)
        case .noMatch:
            sqlite3_bind_int(statement, 4, 2)
            for index in 5...9 { sqlite3_bind_null(statement, Int32(index)) }
        case .ambiguous:
            sqlite3_bind_int(statement, 4, 3)
            for index in 5...9 { sqlite3_bind_null(statement, Int32(index)) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw historicalSQLiteError("insert attribution")
        }
    }

    func historicalAttributionShape(
        _ decision: VersionedAttributionDecision
    ) throws -> HistoricalAttributionShape {
        switch decision.result {
        case let .classified(value):
            return .classified(
                category: historicalCategoryCode(value.category),
                confidence: historicalConfidenceCode(value.confidence),
                ruleID: value.ruleID.rawValue,
                ruleVersion: value.ruleVersion.rawValue,
                evidenceCode: value.evidenceCode.rawValue
            )
        case .unknown(.noMatchingRule):
            return .noMatch
        case let .unknown(.ambiguous(ruleIDs)):
            return .ambiguous(ruleIDs.map(\.rawValue))
        }
    }

    func insertHistoricalBatch(
        request: HistoricalCalibrationFinalizationRequest,
        scopeKey: Int64,
        rootSubjectKey: Int64,
        committedAt: Int64
    ) throws -> Int64 {
        try historicalExecuteNullable(
            "INSERT INTO historical_observation_batch(scan_run_id,stream_id_utf8,scope_key,root_subject_key,volume_id,mount_generation_id,coverage_epoch_id,path_semantics_version,measurement_semantics_version,created_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?)",
            values: [
                .text(request.runID.rawValue),
                .blob(Data(request.streamID.rawValue.utf8)),
                .integer(scopeKey),
                .integer(rootSubjectKey),
                .blob(Data(request.observation.volumeID.rawValue.utf8)),
                .blob(Data(request.observation.mountGenerationID.rawValue.utf8)),
                .blob(Data(request.observation.coverageEpochID.rawValue.utf8)),
                .integer(Int64(request.observation.pathSemanticsVersion.rawValue)),
                .integer(Int64(request.observation.measurementSemanticsVersion.rawValue)),
                .integer(committedAt),
            ]
        )
        return sqlite3_last_insert_rowid(try databaseHandle())
    }

    func insertHistoricalFrame(batchID: Int64, metricCode: Int64) throws -> Int64 {
        try historicalExecute(
            "INSERT INTO historical_observation_frame(batch_id,metric) VALUES(?,?)",
            integers: [batchID, metricCode]
        )
        return sqlite3_last_insert_rowid(try databaseHandle())
    }

    func insertHistoricalNodes(
        _ nodes: [HistoricalPairedObservationNodeCandidate],
        batchID: Int64,
        subjectKeys: [SubjectID: Int64],
        locationKeys: [SubjectID: Int64],
        decisionKeys: [SubjectID: Int64]
    ) throws -> [SubjectID: Int64] {
        var nodeIDs: [SubjectID: Int64] = [:]
        let ordered = nodes.sorted { lhs, rhs in
            let lhsDepth = historicalPathDepth(lhs.path)
            let rhsDepth = historicalPathDepth(rhs.path)
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.subjectID.rawValue.utf8.lexicographicallyPrecedes(
                rhs.subjectID.rawValue.utf8
            )
        }
        for node in ordered {
            let parentNodeID = try node.parentSubjectID.map { parent in
                try nodeIDs[parent].unwrap(field: "historical_parent_node")
            }
            try historicalExecuteNullable(
                "INSERT INTO historical_observation_node(batch_id,subject_key,location_key,parent_node_id,observed_at_ms,direct_children_coverage,classification_decision_id) VALUES(?,?,?,?,?,?,?)",
                values: [
                    .integer(batchID),
                    .integer(try subjectKeys[node.subjectID].unwrap(field: "subject_key")),
                    .integer(try locationKeys[node.subjectID].unwrap(field: "location_key")),
                    parentNodeID.map(HistoricalSQLValue.integer) ?? .null,
                    .integer(node.observedAt.millisecondsSince1970),
                    .integer(Int64(historicalCoverageCode(node.directChildrenCoverage))),
                    decisionKeys[node.subjectID].map(HistoricalSQLValue.integer) ?? .null,
                ]
            )
            let nodeID = sqlite3_last_insert_rowid(try databaseHandle())
            nodeIDs[node.subjectID] = nodeID
            if let stable = node.stableIdentityEvidence {
                try insertHistoricalStableIdentity(stable, nodeID: nodeID)
            }
        }
        return nodeIDs
    }

    func insertHistoricalStableIdentity(
        _ stable: HistoricalFindingStableIdentityEvidence,
        nodeID: Int64
    ) throws {
        let linkStatus: Int64 = switch stable.linkStatus {
        case .unique: 1
        case .ambiguous: 2
        case .unknown: 3
        }
        switch stable.reuseGuard {
        case let .generationToken(token):
            try historicalExecuteNullable(
                "INSERT INTO historical_endpoint_stable_identity VALUES(?,1,?,NULL,NULL,1,?)",
                values: [.integer(nodeID), .blob(Data(token.utf8)), .integer(linkStatus)]
            )
        case let .birthTime(time):
            try historicalExecuteNullable(
                "INSERT INTO historical_endpoint_stable_identity VALUES(?,2,NULL,?,?,1,?)",
                values: [
                    .integer(nodeID), .integer(time.secondsSince1970),
                    .integer(Int64(time.nanoseconds)), .integer(linkStatus),
                ]
            )
        }
    }

    func insertHistoricalEndpoints(
        _ nodes: [HistoricalPairedObservationNodeCandidate],
        nodeIDs: [SubjectID: Int64],
        frameID: Int64,
        metric: StorageMetric
    ) throws {
        let metricCode: Int64 = metric == .logical ? 1 : 2
        for node in nodes {
            let state: [HistoricalSQLValue]
            switch node.state {
            case let .present(logical, allocated, coverage):
                let bytes = metric == .logical ? logical.value : allocated.value
                state = [
                    .integer(1), .integer(bytes),
                    .integer(Int64(historicalCoverageCode(coverage))), .null,
                ]
            case .absent:
                state = [.integer(2), .null, .null, .null]
            case let .unknown(reason):
                state = [.integer(3), .null, .null, .integer(Int64(historicalUnknownCode(reason)))]
            }
            try historicalExecuteNullable(
                "INSERT INTO historical_metric_endpoint(node_id,metric,frame_id,state_kind,bytes,measurement_coverage,unknown_reason_code) VALUES(?,?,?,?,?,?,?)",
                values: [
                    .integer(try nodeIDs[node.subjectID].unwrap(field: "node_id")),
                    .integer(metricCode), .integer(frameID),
                ] + state
            )
        }
    }

    func insertHistoricalFrameCommit(
        frameID: Int64,
        rootNodeID: Int64,
        metricCode: Int64,
        endpointCount: Int,
        committedAt: Int64,
        retentionAnchor: Int64,
        expiresAt: Int64
    ) throws -> ObservationCommitSequence {
        try historicalExecute(
            "INSERT INTO historical_observation_frame_commit(frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(?,?,?,?,?,?,?)",
            integers: [
                frameID, rootNodeID, metricCode, Int64(endpointCount),
                committedAt, retentionAnchor, expiresAt,
            ]
        )
        return try ObservationCommitSequence(
            sqlite3_last_insert_rowid(try databaseHandle())
        )
    }

    func insertPublishedReceipt(
        request: HistoricalCalibrationFinalizationRequest,
        digest: Data,
        logicalSequence: ObservationCommitSequence,
        allocatedSequence: ObservationCommitSequence,
        committedAt: Int64,
        retentionAnchor: Int64,
        expiresAt: Int64
    ) throws {
        try historicalExecuteNullable(
            "INSERT INTO historical_calibration_receipt(scan_run_id,request_format_version,canonical_request_sha256,outcome,logical_sequence,allocated_sequence,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(?,1,?,1,?,?,?,?,?)",
            values: [
                .text(request.runID.rawValue), .blob(digest),
                .integer(logicalSequence.rawValue), .integer(allocatedSequence.rawValue),
                .integer(committedAt), .integer(retentionAnchor), .integer(expiresAt),
            ]
        )
    }

    func insertSupersededReceipt(runID: CalibrationRunID, digest: Data) throws {
        let committedAt = Self.historicalMilliseconds(now())
        let expiresAt = try addingSevenDays(committedAt)
        try historicalExecuteNullable(
            "INSERT INTO historical_calibration_receipt(scan_run_id,request_format_version,canonical_request_sha256,outcome,logical_sequence,allocated_sequence,committed_at_ms,retention_anchor_ms,expires_at_ms) VALUES(?,1,?,2,NULL,NULL,?,?,?)",
            values: [
                .text(runID.rawValue), .blob(digest), .integer(committedAt),
                .integer(committedAt), .integer(expiresAt),
            ]
        )
    }

    func insertDisabledReceipt(
        request: HistoricalCalibrationFinalizationRequest,
        digest: Data
    ) throws {
        if try validateDisabledReceiptIfPresent(
            request: request,
            expectedDigest: digest
        ) {
            return
        }
        let committedAt = Self.historicalMilliseconds(now())
        let expiresAt = try addingSevenDays(committedAt)
        try historicalExecuteNullable(
            "INSERT INTO historical_disabled_calibration_receipt(receipt_id,request_format_version,canonical_request_sha256,committed_at_ms,expires_at_ms) VALUES(?,1,?,?,?)",
            values: [
                .blob(Data(request.disabledReceiptIDBytes)),
                .blob(digest),
                .integer(committedAt),
                .integer(expiresAt),
            ]
        )
    }

    func insertHistoricalBaselineCheckpoints(
        logicalSequence: ObservationCommitSequence,
        allocatedSequence: ObservationCommitSequence,
        committedAt: Int64
    ) throws {
        for sequence in [logicalSequence, allocatedSequence] {
            try historicalExecute(
                "INSERT INTO historical_observation_baseline_checkpoint(frame_sequence,checkpoint_kind,committed_at_ms) VALUES(?,1,?)",
                integers: [sequence.rawValue, committedAt]
            )
        }
    }

    func insertHistoricalProjectionWork(
        baseline: (logical: ObservationCommitSequence, allocated: ObservationCommitSequence),
        comparison: (ObservationCommitSequence, ObservationCommitSequence),
        committedAt: Int64
    ) throws {
        for pair in [
            (baseline.logical, comparison.0),
            (baseline.allocated, comparison.1),
        ] {
            try historicalExecute(
                "INSERT INTO historical_projection_work(baseline_sequence,comparison_sequence,algorithm_version,ranking_policy_version,positive_limit,created_at_ms) VALUES(?,?,1,1,10,?)",
                integers: [pair.0.rawValue, pair.1.rawValue, committedAt]
            )
        }
    }
}

private extension SQLiteEventJournalRepository {
    func validateDisabledReceiptIfPresent(
        request: HistoricalCalibrationFinalizationRequest,
        expectedDigest: Data
    ) throws -> Bool {
        var storedDigest: Data?
        _ = try historicalRows(
            "SELECT canonical_request_sha256 FROM historical_disabled_calibration_receipt WHERE receipt_id=?",
            blobs: [Data(request.disabledReceiptIDBytes)]
        ) { statement in
            storedDigest = try historicalData(statement, 0, "disabled_receipt.digest")
        }
        guard let storedDigest else { return false }
        guard storedDigest == expectedDigest else {
            throw SQLiteEventJournalError.historicalImmutableRequestConflict
        }
        return true
    }

    func readTerminalHistoricalOutcome(
        request: HistoricalCalibrationFinalizationRequest,
        expectedDigest: Data,
        context: ScanRunContext
    ) throws -> HistoricalCalibrationFinalizationOutcome {
        let sql = "SELECT canonical_request_sha256,outcome,logical_sequence,allocated_sequence FROM historical_calibration_receipt WHERE scan_run_id=?"
        var statement: OpaquePointer?
        let database = try databaseHandle()
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw historicalSQLiteError("prepare receipt") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, request.runID.rawValue, -1, historicalSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteEventJournalError.scanRunNotRunning(request.runID.rawValue)
        }
        let storedDigest = try historicalData(statement, 0, "receipt.digest")
        guard storedDigest == expectedDigest else {
            throw SQLiteEventJournalError.historicalImmutableRequestConflict
        }
        guard context.streamID == request.streamID,
              context.regionPath == request.workItem.region.path,
              context.revision == request.workItem.revision else {
            throw SQLiteEventJournalError.scanRunContextMismatch(request.runID.rawValue)
        }
        switch sqlite3_column_int(statement, 1) {
        case 2:
            return .superseded
        case 1:
            let logical = try ObservationCommitSequence(sqlite3_column_int64(statement, 2))
            let allocated = try ObservationCommitSequence(sqlite3_column_int64(statement, 3))
            let logicalFrame = try readHistoricalFrame(sequence: logical)
            let allocatedFrame = try readHistoricalFrame(sequence: allocated)
            return .published(
                HistoricalCalibrationCommit(
                    disposition: .alreadyCommitted,
                    logical: try HistoricalObservationFrameCommit(
                        sequence: logical,
                        rootEndpointID: try logicalFrame.unwrap(field: "logical_frame").rootEndpointID,
                        endpointCount: try logicalFrame.unwrap(field: "logical_frame").nodes.count
                    ),
                    allocated: try HistoricalObservationFrameCommit(
                        sequence: allocated,
                        rootEndpointID: try allocatedFrame.unwrap(field: "allocated_frame").rootEndpointID,
                        endpointCount: try allocatedFrame.unwrap(field: "allocated_frame").nodes.count
                    ),
                    reconciliationRevisions: try readReconciliationRevisions(
                        runID: request.runID
                    )
                )
            )
        default:
            throw SQLiteEventJournalError.corruptStoredValue(field: "receipt.outcome")
        }
    }

    func latestHistoricalSequences(
        scopeID: ScopeID
    ) throws -> (logical: ObservationCommitSequence, allocated: ObservationCommitSequence)? {
        let scope = Data(scopeID.rawValue.utf8)
        let retentionDays = try readHistoricalRetentionDays()
        let currentMilliseconds = max(0, Self.historicalMilliseconds(now()))
        let retentionDuration = Int64(retentionDays) * 86_400_000
        let sql = "SELECT l.sequence,a.sequence FROM historical_observation_batch b JOIN historical_observation_frame lf ON lf.batch_id=b.batch_id AND lf.metric=1 JOIN historical_observation_frame af ON af.batch_id=b.batch_id AND af.metric=2 JOIN historical_observation_frame_commit l ON l.frame_id=lf.frame_id JOIN historical_observation_frame_commit a ON a.frame_id=af.frame_id JOIN historical_scope s ON s.scope_key=b.scope_key WHERE s.scope_id=?1 AND l.expires_at_ms>=?2 AND a.expires_at_ms>=?2 AND l.retention_anchor_ms+?3>=?2 AND a.retention_anchor_ms+?3>=?2 ORDER BY l.sequence DESC LIMIT 1"
        var statement: OpaquePointer?
        let database = try databaseHandle()
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw historicalSQLiteError("prepare latest frames") }
        defer { sqlite3_finalize(statement) }
        try bindHistoricalBlob(scope, statement, 1)
        guard sqlite3_bind_int64(statement, 2, currentMilliseconds) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, retentionDuration) == SQLITE_OK else {
            throw historicalSQLiteError("bind latest frame retention window")
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw historicalSQLiteError("read latest frames") }
        return (
            try ObservationCommitSequence(sqlite3_column_int64(statement, 0)),
            try ObservationCommitSequence(sqlite3_column_int64(statement, 1))
        )
    }

    func readHistoricalFrame(
        sequence: ObservationCommitSequence
    ) throws -> HistoricalFindingObservationFrame? {
        let headerSQL = "SELECT b.root_subject_key,b.scope_key,b.volume_id,b.mount_generation_id,b.coverage_epoch_id,b.path_semantics_version,b.measurement_semantics_version,f.metric,b.batch_id FROM historical_observation_frame_commit c JOIN historical_observation_frame f ON f.frame_id=c.frame_id JOIN historical_observation_batch b ON b.batch_id=f.batch_id WHERE c.sequence=?"
        var header: HistoricalFrameHeader?
        _ = try historicalRows(headerSQL, integers: [sequence.rawValue]) { statement in
            header = HistoricalFrameHeader(
                rootSubjectKey: sqlite3_column_int64(statement, 0),
                scopeKey: sqlite3_column_int64(statement, 1),
                volumeID: try historicalData(statement, 2, "batch.volume_id"),
                mountID: try historicalData(statement, 3, "batch.mount_generation_id"),
                epochID: try historicalData(statement, 4, "batch.coverage_epoch_id"),
                pathSemantics: sqlite3_column_int64(statement, 5),
                measurementSemantics: sqlite3_column_int64(statement, 6),
                metric: sqlite3_column_int(statement, 7),
                batchID: sqlite3_column_int64(statement, 8)
            )
            return ()
        }
        guard let header else { return nil }
        let generation = try historicalStoreGeneration()
        let scopeRaw = try historicalDictionaryString(
            "SELECT scope_id FROM historical_scope WHERE scope_key=?",
            integer: header.scopeKey,
            field: "scope_id"
        )
        let metric: StorageMetric = header.metric == 1 ? .logical : .allocated
        let nodeSQL = "SELECT n.node_id,s.subject_id,s.identity_basis,p.subject_id,pn.node_id,l.location_id,l.path_utf8,l.display_name_utf8,n.observed_at_ms,n.direct_children_coverage,n.classification_decision_id,e.state_kind,e.bytes,e.measurement_coverage,e.unknown_reason_code,stable.guard_kind,stable.generation_token_utf8,stable.birth_seconds,stable.birth_nanoseconds,stable.link_status FROM historical_observation_node n JOIN historical_subject s ON s.subject_key=n.subject_key LEFT JOIN historical_observation_node pn ON pn.node_id=n.parent_node_id LEFT JOIN historical_subject p ON p.subject_key=pn.subject_key JOIN historical_location l ON l.location_key=n.location_key JOIN historical_metric_endpoint e ON e.node_id=n.node_id AND e.metric=? LEFT JOIN historical_endpoint_stable_identity stable ON stable.node_id=n.node_id WHERE n.batch_id=? ORDER BY n.node_id"
        let nodes: [HistoricalFindingNode] = try historicalRows(
            nodeSQL,
            integers: [Int64(header.metric), header.batchID]
        ) { statement in
            let nodeID = sqlite3_column_int64(statement, 0)
            let subject = try SubjectID(
                SQLiteHistoricalFindingCodec.decodeUTF8(
                    try historicalData(statement, 1, "subject_id"),
                    field: "subject_id",
                    maximumBytes: 4_096
                )
            )
            let parent = try historicalOptionalData(statement, 3).map {
                try SubjectID(SQLiteHistoricalFindingCodec.decodeUTF8(
                    $0, field: "parent_subject_id", maximumBytes: 4_096
                ))
            }
            let endpointID = try ObservationEndpointID(
                SQLiteHistoricalFindingCodec.committedEndpointID(
                    storeGeneration: Data(generation.bytes),
                    nodeID: nodeID,
                    metricCode: Int64(header.metric)
                )
            )
            let state = try historicalEndpointState(
                statement: statement,
                stateColumn: 11,
                bytesColumn: 12,
                coverageColumn: 13,
                reasonColumn: 14,
                parentSubjectID: parent,
                parentNodeID: sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 4),
                generation: generation,
                metric: metric
            )
            let endpoint = try ObservationEndpoint(
                id: endpointID,
                scopeID: ScopeID(scopeRaw),
                volumeID: ObservationVolumeID(try historicalUTF8(header.volumeID, "volume_id", 4_096)),
                mountGenerationID: ObservationMountGenerationID(try historicalUTF8(header.mountID, "mount_id", 4_096)),
                coverageEpochID: ObservationCoverageEpochID(try historicalUTF8(header.epochID, "epoch_id", 4_096)),
                subjectID: subject,
                identityBasis: sqlite3_column_int(statement, 2) == 1 ? .stableFileSystemObject : .normalizedPath,
                locationID: ObservationLocationID(try historicalUTF8(try historicalData(statement, 5, "location_id"), "location_id", 4_096)),
                metric: metric,
                pathSemanticsVersion: ObservationSemanticsVersion(Int(header.pathSemantics)),
                measurementSemanticsVersion: ObservationSemanticsVersion(Int(header.measurementSemantics)),
                sequence: sequence,
                observedAt: ObservationInstant(millisecondsSince1970: sqlite3_column_int64(statement, 8)),
                state: state
            )
            return try HistoricalFindingNode(
                endpoint: endpoint,
                parentSubjectID: parent,
                path: try historicalUTF8(try historicalData(statement, 6, "path"), "path", 4_096),
                displayName: try historicalUTF8(try historicalData(statement, 7, "display"), "display", 1_024),
                directChildrenCoverage: try historicalCoverage(sqlite3_column_int(statement, 9)),
                classification: try historicalDecision(statement, column: 10),
                stableIdentityEvidence: try historicalStableIdentity(statement, firstColumn: 15)
            )
        }
        let rootSubject = try historicalDictionaryString(
            "SELECT subject_id FROM historical_subject WHERE subject_key=?",
            integer: header.rootSubjectKey,
            field: "root_subject"
        )
        let root = try nodes.first(where: { $0.endpoint.subjectID.rawValue.utf8.elementsEqual(rootSubject.utf8) })
            .unwrap(field: "root_node")
        return try HistoricalFindingObservationFrame(
            rootSubjectID: root.endpoint.subjectID,
            rootPath: root.path,
            nodes: nodes
        )
    }
}

// MARK: - Canonical request and compact SQLite helpers

private extension SQLiteEventJournalRepository {
    func historicalEndpointState(
        statement: OpaquePointer,
        stateColumn: Int32,
        bytesColumn: Int32,
        coverageColumn: Int32,
        reasonColumn: Int32,
        parentSubjectID: SubjectID?,
        parentNodeID: Int64?,
        generation: HistoricalStoreGeneration,
        metric: StorageMetric
    ) throws -> ObservationEndpointState {
        switch sqlite3_column_int(statement, stateColumn) {
        case 1:
            guard sqlite3_column_type(statement, bytesColumn) == SQLITE_INTEGER else {
                throw SQLiteEventJournalError.corruptStoredValue(field: "endpoint.bytes")
            }
            return .present(
                bytes: try ByteCount(sqlite3_column_int64(statement, bytesColumn)),
                coverage: try historicalCoverage(sqlite3_column_int(statement, coverageColumn))
            )
        case 2:
            guard let parentSubjectID, let parentNodeID else {
                throw SQLiteEventJournalError.corruptStoredValue(field: "endpoint.absence_parent")
            }
            return .absent(
                ParentAbsenceReference(
                    parentEndpointID: try ObservationEndpointID(
                        SQLiteHistoricalFindingCodec.committedEndpointID(
                            storeGeneration: Data(generation.bytes),
                            nodeID: parentNodeID,
                            metricCode: metric == .logical ? 1 : 2
                        )
                    ),
                    parentSubjectID: parentSubjectID
                )
            )
        case 3:
            return .unknown(
                try historicalUnknownReason(sqlite3_column_int(statement, reasonColumn))
            )
        default:
            throw SQLiteEventJournalError.corruptStoredValue(field: "endpoint.state")
        }
    }

    func historicalDecision(
        _ statement: OpaquePointer,
        column: Int32
    ) throws -> VersionedAttributionDecision? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw SQLiteEventJournalError.corruptStoredValue(field: "classification_decision_id")
        }
        let decisionID = sqlite3_column_int64(statement, column)
        var payload: Data?
        var digest: Data?
        _ = try historicalRows(
            "SELECT canonical_payload,canonical_sha256 FROM frozen_attribution_decision WHERE decision_id=?",
            integers: [decisionID]
        ) { row in
            payload = try historicalData(row, 0, "classification.payload")
            digest = try historicalData(row, 1, "classification.digest")
        }
        let exactPayload = try payload.unwrap(field: "classification.payload")
        guard Data(SHA256.hash(data: exactPayload)) == digest else {
            throw SQLiteEventJournalError.corruptStoredValue(field: "classification.digest")
        }
        do {
            return try JSONDecoder().decode(
                VersionedAttributionDecision.self,
                from: exactPayload
            )
        } catch {
            throw SQLiteEventJournalError.corruptStoredValue(field: "classification.payload")
        }
    }

    func historicalStableIdentity(
        _ statement: OpaquePointer,
        firstColumn: Int32
    ) throws -> HistoricalFindingStableIdentityEvidence? {
        if sqlite3_column_type(statement, firstColumn) == SQLITE_NULL { return nil }
        let reuseGuard: HistoricalFindingIdentityReuseGuard
        switch sqlite3_column_int(statement, firstColumn) {
        case 1:
            reuseGuard = .generationToken(
                try historicalUTF8(
                    try historicalData(statement, firstColumn + 1, "stable.generation"),
                    "stable.generation",
                    4_096
                )
            )
        case 2:
            reuseGuard = .birthTime(
                try HistoricalFindingBirthTime(
                    secondsSince1970: sqlite3_column_int64(statement, firstColumn + 2),
                    nanoseconds: sqlite3_column_int(statement, firstColumn + 3)
                )
            )
        default:
            throw SQLiteEventJournalError.corruptStoredValue(field: "stable.guard_kind")
        }
        let linkStatus: HistoricalFindingLinkStatus = switch sqlite3_column_int(
            statement,
            firstColumn + 4
        ) {
        case 1: .unique
        case 2: .ambiguous
        case 3: .unknown
        default:
            throw SQLiteEventJournalError.corruptStoredValue(field: "stable.link_status")
        }
        return try HistoricalFindingStableIdentityEvidence(
            reuseGuard: reuseGuard,
            nodeKind: .directory,
            linkStatus: linkStatus
        )
    }

    func canonicalHistoricalRequestDigest(
        _ request: HistoricalCalibrationFinalizationRequest
    ) throws -> Data {
        var bytes = Data("SpaceTrace.HistoricalCalibrationRequest.v1".utf8)
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        func appendInt(_ value: Int64) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
        }
        append(Data(request.runID.rawValue.utf8))
        append(Data(request.streamID.rawValue.utf8))
        append(Data(request.workItem.region.path.rawValue.utf8))
        appendInt(Int64(bitPattern: request.workItem.revision.rawValue))
        appendInt(Int64(bitPattern: request.workItem.region.reasons.rawValue))
        if let cursor = request.workItem.region.maximumCursor {
            append(Data([1]))
            appendInt(Int64(bitPattern: cursor.rawValue))
        } else {
            append(Data([0]))
        }
        append(Data(request.report.coverage == .complete ? "complete".utf8 : "partial".utf8))
        appendInt(request.report.entriesVisited)
        appendInt(request.report.directoriesStaged)
        append(Data(request.observation.scopeID.rawValue.utf8))
        append(Data(request.observation.volumeID.rawValue.utf8))
        append(Data(request.observation.mountGenerationID.rawValue.utf8))
        append(Data(request.observation.coverageEpochID.rawValue.utf8))
        append(Data(request.observation.rootSubjectID.rawValue.utf8))
        append(Data(request.observation.rootPath.utf8))
        appendInt(Int64(request.observation.pathSemanticsVersion.rawValue))
        appendInt(Int64(request.observation.measurementSemanticsVersion.rawValue))
        appendInt(Int64(request.observation.nodes.count))
        for node in request.observation.nodes {
            append(Data(node.subjectID.rawValue.utf8))
            if let parent = node.parentSubjectID {
                append(Data([1]))
                append(Data(parent.rawValue.utf8))
            } else {
                append(Data([0]))
            }
            append(Data(node.identityBasis.rawValue.utf8))
            append(Data(node.locationID.rawValue.utf8))
            append(Data(node.path.utf8))
            append(Data(node.displayName.utf8))
            appendInt(node.observedAt.millisecondsSince1970)
            append(Data(node.directChildrenCoverage.rawValue.utf8))
            switch node.state {
            case let .present(logical, allocated, coverage):
                append(Data("present:\(coverage.rawValue)".utf8))
                appendInt(logical.value)
                appendInt(allocated.value)
            case .absent:
                append(Data("absent".utf8))
            case let .unknown(reason):
                append(Data("unknown:\(reason.rawValue)".utf8))
            }
            if let decision = node.classification {
                append(Data([1]))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                append(try encoder.encode(decision))
            } else {
                append(Data([0]))
            }
            if let stable = node.stableIdentityEvidence {
                append(Data([1]))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                append(try encoder.encode(stable))
            } else {
                append(Data([0]))
            }
        }
        return Data(SHA256.hash(data: bytes))
    }

    /// History Off retains only bounded, path-free idempotency evidence. Its
    /// digest intentionally excludes run/stream/path/candidate and every
    /// unconstrained string. The receipt key already identifies the run; the
    /// remaining scalar fields detect materially different retries without
    /// retaining a path-derived hash.
    func canonicalDisabledHistoricalRequestDigest(
        _ request: HistoricalCalibrationFinalizationRequest
    ) -> Data {
        var bytes = Data("SpaceTrace.HistoricalCalibrationDisabledRequest.v1".utf8)
        func append(_ value: UInt64) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        }
        append(1)
        append(0)
        append(request.workItem.revision.rawValue)
        append(request.workItem.region.reasons.rawValue)
        if let cursor = request.workItem.region.maximumCursor {
            append(1)
            append(cursor.rawValue)
        } else {
            append(0)
        }
        append(request.report.coverage == .complete ? 1 : 2)
        append(UInt64(bitPattern: request.report.entriesVisited))
        append(UInt64(bitPattern: request.report.directoriesStaged))
        return Data(SHA256.hash(data: bytes))
    }

    func readNextHistoricalProjectionWork() throws -> HistoricalProjectionWork? {
        let sql = "SELECT w.work_id,w.baseline_sequence,w.comparison_sequence,w.algorithm_version,w.ranking_policy_version,w.positive_limit FROM historical_projection_work w LEFT JOIN historical_projection_checkpoint c ON c.work_id=w.work_id WHERE c.work_id IS NULL ORDER BY w.comparison_sequence,w.work_id LIMIT 1"
        let rows = try historicalRows(sql) { statement in
            try makeHistoricalProjectionWork(statement)
        }
        return rows.first
    }

    func readHistoricalProjectionWork(
        id: HistoricalProjectionWorkID
    ) throws -> HistoricalProjectionWork? {
        let sql = "SELECT work_id,baseline_sequence,comparison_sequence,algorithm_version,ranking_policy_version,positive_limit FROM historical_projection_work WHERE work_id=?"
        return try historicalRows(sql, integers: [id.rawValue]) { statement in
            try makeHistoricalProjectionWork(statement)
        }.first
    }

    func makeHistoricalProjectionWork(
        _ statement: OpaquePointer
    ) throws -> HistoricalProjectionWork {
        do {
            return try HistoricalProjectionWork(
                recordID: HistoricalProjectionWorkID(sqlite3_column_int64(statement, 0)),
                baselineSequence: ObservationCommitSequence(sqlite3_column_int64(statement, 1)),
                comparisonSequence: ObservationCommitSequence(sqlite3_column_int64(statement, 2)),
                algorithmVersion: HistoricalFindingAlgorithmVersion(
                    Int(sqlite3_column_int(statement, 3))
                ),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(
                    Int(sqlite3_column_int(statement, 4))
                ),
                positiveLimit: Int(sqlite3_column_int64(statement, 5))
            )
        } catch {
            throw SQLiteEventJournalError.corruptStoredValue(
                field: "historical_projection_work"
            )
        }
    }

    func canonicalHistoricalProjectionDigest(
        _ result: HistoricalFindingGenerationResult
    ) throws -> Data {
        try canonicalHistoricalDigest(
            result,
            domain: "SpaceTrace.HistoricalFindingGenerationResult.v1"
        )
    }

    func canonicalHistoricalRetractionDigest(
        _ command: HistoricalFindingEvidenceInvalidationCommand
    ) -> Data {
        canonicalHistoricalRetractionDigestFields(
            requestID: command.requestID,
            findingID: command.findingID,
            expectedDraftDigest: Data(command.expectedDraftSHA256.bytes)
        )
    }

    func rehydratedHistoricalFinding(
        id: HistoricalFindingRecordID
    ) throws -> HistoricalRehydratedFinding? {
        guard let projectionID = try historicalOptionalInt(
            "SELECT projection_id FROM historical_finding WHERE finding_id=?",
            integers: [id.rawValue]
        ) else {
            return nil
        }
        return try rehydratedHistoricalProjection(id: projectionID)[id.rawValue]
            .unwrap(field: "historical_finding")
    }

    func rehydratedHistoricalProjection(
        id projectionID: Int64
    ) throws -> [Int64: HistoricalRehydratedFinding] {
        let workID = try historicalOptionalInt(
            "SELECT work_id FROM historical_finding_projection WHERE projection_id=?",
            integers: [projectionID]
        ).unwrap(field: "historical_finding_projection")
        let work = try readHistoricalProjectionWork(
            id: HistoricalProjectionWorkID(workID)
        ).unwrap(field: "historical_projection_work")
        let baseline = try readHistoricalFrame(sequence: work.baselineSequence)
            .unwrap(field: "historical_projection_baseline")
        let comparison = try readHistoricalFrame(sequence: work.comparisonSequence)
            .unwrap(field: "historical_projection_comparison")
        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison,
            positiveLimit: work.positiveLimit
        )
        try validateStoredHistoricalProjection(
            projectionID: projectionID,
            work: work,
            result: result,
            resultDigest: try canonicalHistoricalProjectionDigest(result)
        )
        let rows = try historicalRows(
            "SELECT finding_id,ordinal,draft_sha256 FROM historical_finding WHERE projection_id=? ORDER BY ordinal",
            integers: [projectionID]
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                Int(sqlite3_column_int64(statement, 1)),
                try historicalData(statement, 2, "finding.draft_digest")
            )
        }
        let ranks = try historicalRows(
            "SELECT finding_id,rank FROM historical_finding_positive_rank WHERE projection_id=?",
            integers: [projectionID]
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                Int(sqlite3_column_int64(statement, 1))
            )
        }
        let rankByFindingID = Dictionary(uniqueKeysWithValues: ranks)
        guard rows.count == result.batch.findings.count else {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }
        var rehydrated: [Int64: HistoricalRehydratedFinding] = [:]
        for row in rows {
            guard result.batch.findings.indices.contains(row.1) else {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            let draft = result.batch.findings[row.1]
            let draftDigest = try canonicalHistoricalDigest(
                draft,
                domain: "SpaceTrace.HistoricalFindingDraft.v1"
            )
            guard row.2 == draftDigest else {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            let effective = try EffectiveHistoricalFinding(
                recordID: HistoricalFindingRecordID(row.0),
                projectionID: HistoricalProjectionRecordID(projectionID),
                comparisonSequence: work.comparisonSequence,
                positiveRank: rankByFindingID[row.0],
                draft: draft
            )
            guard rehydrated.updateValue(
                HistoricalRehydratedFinding(
                    effective: effective,
                    draftDigest: row.2
                ),
                forKey: row.0
            ) == nil else {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
        }
        return rehydrated
    }

    func readHistoricalStoredRetraction(
        findingID: HistoricalFindingRecordID
    ) throws -> HistoricalStoredRetraction? {
        try readHistoricalRetraction(
            sql: "SELECT retraction_sequence,request_format_version,request_id,canonical_request_sha256,retracted_finding_id,expected_draft_sha256,reason_code,committed_at_ms FROM historical_finding_retraction WHERE retracted_finding_id=?",
            integers: [findingID.rawValue],
            blobs: []
        )
    }

    func readHistoricalRetraction(
        requestID: HistoricalRetractionRequestID
    ) throws -> HistoricalStoredRetraction? {
        try readHistoricalRetraction(
            sql: "SELECT retraction_sequence,request_format_version,request_id,canonical_request_sha256,retracted_finding_id,expected_draft_sha256,reason_code,committed_at_ms FROM historical_finding_retraction WHERE request_id=?",
            integers: [],
            blobs: [Data(requestID.bytes)]
        )
    }

    func readHistoricalRetraction(
        sql: String,
        integers: [Int64],
        blobs: [Data]
    ) throws -> HistoricalStoredRetraction? {
        let rows = try historicalRows(sql, integers: integers, blobs: blobs) { statement in
            guard sqlite3_column_int64(statement, 1) == 1,
                  sqlite3_column_int64(statement, 6) == 1,
                  sqlite3_column_int64(statement, 7) >= 0 else {
                throw SQLiteEventJournalError.corruptStoredValue(
                    field: "historical_finding_retraction"
                )
            }
            let request = try HistoricalRetractionRequestID(
                bytes: Array(try historicalData(statement, 2, "retraction.request_id"))
            )
            let canonicalDigest = try historicalData(
                statement,
                3,
                "retraction.canonical_request_sha256"
            )
            let expectedDigest = try historicalData(
                statement,
                5,
                "retraction.expected_draft_sha256"
            )
            let findingID = try HistoricalFindingRecordID(
                sqlite3_column_int64(statement, 4)
            )
            let commandDigest = canonicalHistoricalRetractionDigestFields(
                requestID: request,
                findingID: findingID,
                expectedDraftDigest: expectedDigest
            )
            guard canonicalDigest.count == 32,
                  expectedDigest.count == 32,
                  canonicalDigest == commandDigest else {
                throw SQLiteEventJournalError.corruptStoredValue(
                    field: "historical_finding_retraction"
                )
            }
            return HistoricalStoredRetraction(
                record: HistoricalFindingRetractionRecord(
                    recordID: try HistoricalRetractionRecordID(
                        sqlite3_column_int64(statement, 0)
                    ),
                    requestID: request,
                    findingID: findingID,
                    reason: .evidenceInvalidated,
                    committedAt: try ObservationInstant(
                        millisecondsSince1970: sqlite3_column_int64(statement, 7)
                    )
                ),
                canonicalRequestDigest: canonicalDigest,
                expectedDraftDigest: expectedDigest
            )
        }
        guard rows.count <= 1 else {
            throw SQLiteEventJournalError.corruptStoredValue(
                field: "historical_finding_retraction"
            )
        }
        return rows.first
    }

    func canonicalHistoricalRetractionDigestFields(
        requestID: HistoricalRetractionRequestID,
        findingID: HistoricalFindingRecordID,
        expectedDraftDigest: Data
    ) -> Data {
        var canonical = Data("SpaceTrace.HistoricalFindingRetractionRequest".utf8)
        canonical.append(0)
        appendHistoricalBigEndian(UInt32(1), to: &canonical)
        canonical.append(contentsOf: requestID.bytes)
        appendHistoricalBigEndian(UInt64(findingID.rawValue), to: &canonical)
        canonical.append(expectedDraftDigest)
        let reason = Data("evidence_invalidated".utf8)
        appendHistoricalBigEndian(UInt64(reason.count), to: &canonical)
        canonical.append(reason)
        return Data(SHA256.hash(data: canonical))
    }

    func appendHistoricalBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    func insertHistoricalProjection(
        work: HistoricalProjectionWork,
        result: HistoricalFindingGenerationResult,
        resultDigest: Data
    ) throws -> Int64 {
        let committedAt = Self.historicalMilliseconds(now())
        try historicalExecuteNullable(
            "INSERT INTO historical_finding_projection(work_id,format_version,canonical_result_sha256,truncated_positive_count,committed_at_ms) VALUES(?,1,?,?,?)",
            values: [
                .integer(work.recordID.rawValue),
                .blob(resultDigest),
                .integer(Int64(result.suppressionSummary.truncatedPositiveCount)),
                .integer(committedAt),
            ]
        )
        let projectionID = sqlite3_last_insert_rowid(try databaseHandle())
        let expectedRows = try historicalProjectionExpectedRows(
            work: work,
            result: result
        )
        let rowByKey = Dictionary(uniqueKeysWithValues: expectedRows.map { ($0.draft.key, $0) })
        let orderedDrafts = try historicalTopologicalDrafts(result.batch.findings)
        var findingIDByKey: [HistoricalFindingKey: Int64] = [:]

        for draft in orderedDrafts {
            let row = try rowByKey[draft.key].unwrap(field: "historical_finding_row")
            if try historicalOptionalInt(
                "SELECT finding_id FROM historical_finding WHERE finding_key_sha256=?",
                blobs: [row.findingKeyDigest]
            ) != nil {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
            let movementAncestorID: Int64?
            switch draft.movementContext {
            case .none:
                movementAncestorID = nil
            case .inheritedFromAncestor(let ancestorKey):
                movementAncestorID = try findingIDByKey[ancestorKey].unwrap(
                    field: "historical_movement_ancestor"
                )
            }
            try historicalExecuteNullable(
                "INSERT INTO historical_finding(projection_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_finding_id,expires_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                values: [
                    .integer(projectionID),
                    .integer(Int64(row.ordinal)),
                    .blob(row.findingKeyDigest),
                    .blob(row.draftDigest),
                    .integer(row.baselineNodeID),
                    .integer(row.metricCode),
                    .integer(row.comparisonNodeID),
                    .integer(row.metricCode),
                    .integer(row.kindCode),
                    .integer(row.inclusiveDeltaBytes),
                    row.rankingContributionBytes.map(HistoricalSQLValue.integer) ?? .null,
                    movementAncestorID.map(HistoricalSQLValue.integer) ?? .null,
                    .integer(row.expiresAtMilliseconds),
                ]
            )
            findingIDByKey[draft.key] = sqlite3_last_insert_rowid(try databaseHandle())
        }

        for (offset, key) in result.batch.rankedPositiveFindingKeys.enumerated() {
            let findingID = try findingIDByKey[key].unwrap(field: "historical_rank_finding")
            try historicalExecute(
                "INSERT INTO historical_finding_positive_rank(projection_id,rank,finding_id) VALUES(?,?,?)",
                integers: [projectionID, Int64(offset + 1), findingID]
            )
        }
        try insertHistoricalReasonCounts(
            result.suppressionSummary.findingSuppressions,
            category: 1,
            projectionID: projectionID
        )
        try insertHistoricalReasonCounts(
            result.suppressionSummary.rankingExclusions,
            category: 2,
            projectionID: projectionID
        )
        try insertHistoricalReasonCounts(
            result.suppressionSummary.collapses,
            category: 3,
            projectionID: projectionID
        )

        if injectedFailurePoint == .beforeHistoricalProjectionCheckpoint {
            injectedFailurePoint = nil
            throw SQLiteEventJournalError.injectedFailure
        }
        try historicalExecute(
            "INSERT INTO historical_projection_checkpoint(work_id,committed_at_ms) VALUES(?,?)",
            integers: [work.recordID.rawValue, committedAt]
        )
        return projectionID
    }

    func insertHistoricalReasonCounts(
        _ counts: [HistoricalFindingReasonCount],
        category: Int64,
        projectionID: Int64
    ) throws {
        for value in counts {
            try historicalExecute(
                "INSERT INTO historical_finding_reason_count(projection_id,category,reason_code,count) VALUES(?,?,?,?)",
                integers: [
                    projectionID,
                    category,
                    try historicalReasonCode(value.reason),
                    Int64(value.count),
                ]
            )
        }
    }

    func historicalProjectionExpectedRows(
        work: HistoricalProjectionWork,
        result: HistoricalFindingGenerationResult
    ) throws -> [HistoricalProjectionExpectedFindingRow] {
        let expiresAt = try historicalSingleInt(
            "SELECT min(b.expires_at_ms,c.expires_at_ms) FROM historical_projection_work w JOIN historical_observation_frame_commit b ON b.sequence=w.baseline_sequence JOIN historical_observation_frame_commit c ON c.sequence=w.comparison_sequence WHERE w.work_id=?",
            integers: [work.recordID.rawValue]
        )
        return try result.batch.findings.enumerated().map { ordinal, draft in
            let metricCode = try historicalMetricCode(draft.evidence.metric)
            let baselineNodeID = try historicalNodeID(
                endpointID: draft.evidence.baselineEndpointID,
                sequence: work.baselineSequence,
                metricCode: metricCode
            )
            let comparisonNodeID = try historicalNodeID(
                endpointID: draft.evidence.comparisonEndpointID,
                sequence: work.comparisonSequence,
                metricCode: metricCode
            )
            let findingKeyDigest: Data
            if injectedFailurePoint == .forceHistoricalFindingKeyDigestCollision {
                findingKeyDigest = Data(repeating: 0xA5, count: 32)
            } else {
                findingKeyDigest = try canonicalHistoricalDigest(
                    draft.key,
                    domain: "SpaceTrace.HistoricalFindingKey.v1"
                )
            }
            return HistoricalProjectionExpectedFindingRow(
                ordinal: ordinal,
                findingKeyDigest: findingKeyDigest,
                draftDigest: try canonicalHistoricalDigest(
                    draft,
                    domain: "SpaceTrace.HistoricalFindingDraft.v1"
                ),
                baselineNodeID: baselineNodeID,
                comparisonNodeID: comparisonNodeID,
                metricCode: metricCode,
                kindCode: historicalFindingKindCode(draft.kind),
                inclusiveDeltaBytes: draft.inclusiveDelta.bytes,
                rankingContributionBytes: draft.rankingContribution?.bytes,
                movementAncestorKey: draft.movementContext?.ancestorKey,
                expiresAtMilliseconds: expiresAt,
                draft: draft
            )
        }
    }

    func validateStoredHistoricalProjection(
        projectionID: Int64,
        work: HistoricalProjectionWork,
        result: HistoricalFindingGenerationResult,
        resultDigest: Data
    ) throws {
        let headers = try historicalRows(
            "SELECT work_id,format_version,canonical_result_sha256,truncated_positive_count FROM historical_finding_projection WHERE projection_id=?",
            integers: [projectionID]
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1),
                try historicalData(statement, 2, "projection.digest"),
                sqlite3_column_int64(statement, 3)
            )
        }
        guard let header = headers.first,
              headers.count == 1,
              header.0 == work.recordID.rawValue,
              header.1 == 1,
              header.2 == resultDigest,
              header.3 == Int64(result.suppressionSummary.truncatedPositiveCount)
        else {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }
        guard try historicalSingleInt(
            "SELECT count(*) FROM historical_projection_checkpoint WHERE work_id=?",
            integers: [work.recordID.rawValue]
        ) == 1 else {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }

        let expectedRows = try historicalProjectionExpectedRows(
            work: work,
            result: result
        )
        let actualRows = try historicalRows(
            "SELECT finding_id,ordinal,finding_key_sha256,draft_sha256,baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,kind,inclusive_delta_bytes,ranking_contribution_bytes,movement_ancestor_finding_id,expires_at_ms FROM historical_finding WHERE projection_id=? ORDER BY ordinal",
            integers: [projectionID]
        ) { statement in
            HistoricalProjectionStoredFindingRow(
                findingID: sqlite3_column_int64(statement, 0),
                ordinal: Int(sqlite3_column_int64(statement, 1)),
                findingKeyDigest: try historicalData(statement, 2, "finding.key_digest"),
                draftDigest: try historicalData(statement, 3, "finding.draft_digest"),
                baselineNodeID: sqlite3_column_int64(statement, 4),
                baselineMetricCode: sqlite3_column_int64(statement, 5),
                comparisonNodeID: sqlite3_column_int64(statement, 6),
                comparisonMetricCode: sqlite3_column_int64(statement, 7),
                kindCode: sqlite3_column_int64(statement, 8),
                inclusiveDeltaBytes: sqlite3_column_int64(statement, 9),
                rankingContributionBytes: try historicalOptionalInteger(statement, 10),
                movementAncestorFindingID: try historicalOptionalInteger(statement, 11),
                expiresAtMilliseconds: sqlite3_column_int64(statement, 12)
            )
        }
        guard actualRows.count == expectedRows.count else {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }
        var actualIDByKeyDigest: [Data: Int64] = [:]
        for row in actualRows {
            guard actualIDByKeyDigest.updateValue(
                row.findingID,
                forKey: row.findingKeyDigest
            ) == nil else {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
        }
        let expectedByKey = Dictionary(uniqueKeysWithValues: expectedRows.map {
            ($0.draft.key, $0)
        })
        for (expected, actual) in zip(expectedRows, actualRows) {
            let expectedAncestorID: Int64?
            if let ancestorKey = expected.movementAncestorKey {
                let ancestor = try expectedByKey[ancestorKey].unwrap(
                    field: "historical_expected_ancestor"
                )
                expectedAncestorID = try actualIDByKeyDigest[ancestor.findingKeyDigest].unwrap(
                    field: "historical_stored_ancestor"
                )
            } else {
                expectedAncestorID = nil
            }
            guard actual.matches(expected, movementAncestorFindingID: expectedAncestorID) else {
                throw SQLiteEventJournalError.historicalProjectionImmutableConflict
            }
        }

        let expectedRanks = try result.batch.rankedPositiveFindingKeys.enumerated().map {
            offset, key -> HistoricalProjectionStoredRank in
            let expected = try expectedByKey[key].unwrap(field: "historical_expected_rank")
            return HistoricalProjectionStoredRank(
                rank: offset + 1,
                findingID: try actualIDByKeyDigest[expected.findingKeyDigest].unwrap(
                    field: "historical_stored_rank"
                )
            )
        }
        let actualRanks = try historicalRows(
            "SELECT rank,finding_id FROM historical_finding_positive_rank WHERE projection_id=? ORDER BY rank",
            integers: [projectionID]
        ) { statement in
            HistoricalProjectionStoredRank(
                rank: Int(sqlite3_column_int64(statement, 0)),
                findingID: sqlite3_column_int64(statement, 1)
            )
        }
        guard actualRanks == expectedRanks else {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }

        let expectedReasons = try historicalExpectedReasonRows(
            result.suppressionSummary,
            projectionID: projectionID
        )
        let actualReasons = try historicalRows(
            "SELECT projection_id,category,reason_code,count FROM historical_finding_reason_count WHERE projection_id=? ORDER BY category,reason_code",
            integers: [projectionID]
        ) { statement in
            HistoricalProjectionStoredReason(
                projectionID: sqlite3_column_int64(statement, 0),
                category: sqlite3_column_int64(statement, 1),
                reasonCode: sqlite3_column_int64(statement, 2),
                count: sqlite3_column_int64(statement, 3)
            )
        }
        guard actualReasons == expectedReasons else {
            throw SQLiteEventJournalError.historicalProjectionImmutableConflict
        }
    }

    func historicalExpectedReasonRows(
        _ summary: HistoricalFindingSuppressionSummary,
        projectionID: Int64
    ) throws -> [HistoricalProjectionStoredReason] {
        var rows: [HistoricalProjectionStoredReason] = []
        for (category, counts) in [
            (Int64(1), summary.findingSuppressions),
            (Int64(2), summary.rankingExclusions),
            (Int64(3), summary.collapses),
        ] {
            for value in counts {
                rows.append(
                    HistoricalProjectionStoredReason(
                        projectionID: projectionID,
                        category: category,
                        reasonCode: try historicalReasonCode(value.reason),
                        count: Int64(value.count)
                    )
                )
            }
        }
        return rows.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.reasonCode < $1.reasonCode
        }
    }

    func historicalTopologicalDrafts(
        _ drafts: [HistoricalFindingDraft]
    ) throws -> [HistoricalFindingDraft] {
        let draftByKey = Dictionary(uniqueKeysWithValues: drafts.map { ($0.key, $0) })
        var stateByKey: [HistoricalFindingKey: HistoricalProjectionVisitState] = [:]
        var result: [HistoricalFindingDraft] = []
        result.reserveCapacity(drafts.count)

        for startingDraft in drafts {
            if stateByKey[startingDraft.key] == .visited { continue }
            var chain: [HistoricalFindingDraft] = []
            var current = startingDraft
            while true {
                switch stateByKey[current.key] {
                case .visited:
                    break
                case .visiting:
                    throw SQLiteEventJournalError.historicalProjectionResultMismatch
                case .none:
                    stateByKey[current.key] = .visiting
                    chain.append(current)
                    guard let ancestorKey = current.movementContext?.ancestorKey else {
                        break
                    }
                    guard let ancestor = draftByKey[ancestorKey] else {
                        throw SQLiteEventJournalError.historicalProjectionResultMismatch
                    }
                    current = ancestor
                    continue
                }
                break
            }
            while let draft = chain.popLast() {
                stateByKey[draft.key] = .visited
                result.append(draft)
            }
        }
        guard result.count == drafts.count else {
            throw SQLiteEventJournalError.historicalProjectionResultMismatch
        }
        return result
    }

    func historicalNodeID(
        endpointID: ObservationEndpointID,
        sequence: ObservationCommitSequence,
        metricCode: Int64
    ) throws -> Int64 {
        let components = endpointID.rawValue.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        let generation = try historicalStoreGeneration().bytes.map {
            String(format: "%02x", $0)
        }.joined()
        guard components.count == 4,
              components[0] == "st11",
              components[1] == Substring(generation),
              components[3] == Substring(String(format: "%02lld", metricCode)),
              components[2].count == 16,
              let unsignedNodeID = UInt64(components[2], radix: 16),
              unsignedNodeID <= UInt64(Int64.max),
              unsignedNodeID > 0 else {
            throw SQLiteEventJournalError.historicalProjectionResultMismatch
        }
        let nodeID = Int64(unsignedNodeID)
        guard try historicalSingleInt(
            "SELECT count(*) FROM historical_metric_endpoint e JOIN historical_observation_node n ON n.node_id=e.node_id JOIN historical_observation_frame f ON f.batch_id=n.batch_id AND f.metric=e.metric JOIN historical_observation_frame_commit c ON c.frame_id=f.frame_id WHERE e.node_id=? AND e.metric=? AND c.sequence=?",
            integers: [nodeID, metricCode, sequence.rawValue]
        ) == 1 else {
            throw SQLiteEventJournalError.historicalProjectionResultMismatch
        }
        return nodeID
    }

    func canonicalHistoricalDigest<Value: Encodable>(
        _ value: Value,
        domain: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(value)
        var canonical = Data(domain.utf8)
        canonical.append(0)
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
        canonical.append(payload)
        return Data(SHA256.hash(data: canonical))
    }

    func historicalMetricCode(_ metric: StorageMetric) throws -> Int64 {
        switch metric {
        case .logical: 1
        case .allocated: 2
        case .volumeAvailable:
            throw SQLiteEventJournalError.historicalProjectionResultMismatch
        }
    }

    func historicalFindingKindCode(_ kind: HistoricalFindingKind) -> Int64 {
        switch kind {
        case .appearance: 1
        case .decrease: 2
        case .disappearance: 3
        case .growth: 4
        case .move: 5
        }
    }

    func historicalReasonCode(_ reason: HistoricalFindingReason) throws -> Int64 {
        guard let index = historicalFindingReasonWireOrder.firstIndex(of: reason) else {
            throw SQLiteEventJournalError.historicalProjectionResultMismatch
        }
        return Int64(index + 1)
    }

    func historicalStoreGeneration() throws -> HistoricalStoreGeneration {
        let data = try historicalSingleData(
            "SELECT store_generation FROM historical_store_identity WHERE singleton=1"
        )
        return try HistoricalStoreGeneration(bytes: Array(data))
    }

    static func historicalMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    func addingThirtyDays(_ value: Int64) throws -> Int64 {
        let (result, overflow) = value.addingReportingOverflow(2_592_000_000)
        guard overflow == false else { throw SQLiteEventJournalError.historicalCandidateExpired }
        return result
    }

    func addingSevenDays(_ value: Int64) throws -> Int64 {
        let (result, overflow) = value.addingReportingOverflow(604_800_000)
        guard overflow == false else { throw SQLiteEventJournalError.historicalCandidateExpired }
        return result
    }

    func historicalExecute(
        _ sql: String,
        integers: [Int64] = [],
        texts: [String] = [],
        blobs: [Data] = []
    ) throws {
        var values = integers.map(HistoricalSQLValue.integer)
            + texts.map(HistoricalSQLValue.text)
            + blobs.map(HistoricalSQLValue.blob)
        try historicalExecuteNullable(sql, values: values)
        values.removeAll(keepingCapacity: false)
    }

    func historicalExecuteNullable(
        _ sql: String,
        values: [HistoricalSQLValue]
    ) throws {
        let database = try databaseHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw historicalSQLiteError("prepare historical write") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .integer(value): sqlite3_bind_int64(statement, index, value)
            case let .text(value): sqlite3_bind_text(statement, index, value, -1, historicalSQLiteTransient)
            case let .blob(value): try bindHistoricalBlob(value, statement, index)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw historicalSQLiteError("execute historical write")
        }
    }

    func historicalSingleInt(
        _ sql: String,
        integers: [Int64] = [],
        blobs: [Data] = []
    ) throws -> Int64 {
        try historicalOptionalInt(sql, integers: integers, blobs: blobs)
            .unwrap(field: "historical_integer")
    }

    func historicalOptionalInt(
        _ sql: String,
        integers: [Int64] = [],
        blobs: [Data] = []
    ) throws -> Int64? {
        var result: Int64?
        _ = try historicalRows(sql, integers: integers, blobs: blobs) { statement in
            result = sqlite3_column_int64(statement, 0)
            return ()
        }
        return result
    }

    func historicalSingleData(_ sql: String) throws -> Data {
        var result: Data?
        _ = try historicalRows(sql) { statement in
            result = try historicalData(statement, 0, "historical_blob")
            return ()
        }
        return try result.unwrap(field: "historical_blob")
    }

    func historicalRows<Result>(
        _ sql: String,
        integers: [Int64] = [],
        text: String? = nil,
        blobs: [Data] = [],
        map: (OpaquePointer) throws -> Result
    ) throws -> [Result] {
        let database = try databaseHandle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw historicalSQLiteError("prepare historical query") }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for integer in integers { sqlite3_bind_int64(statement, index, integer); index += 1 }
        if let text { sqlite3_bind_text(statement, index, text, -1, historicalSQLiteTransient); index += 1 }
        for blob in blobs { try bindHistoricalBlob(blob, statement, index); index += 1 }
        var result: [Result] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw historicalSQLiteError("read historical query") }
            result.append(try map(statement))
        }
    }

    func historicalDictionaryString(
        _ sql: String,
        integer: Int64,
        field: String
    ) throws -> String {
        let rows = try historicalRows(sql, integers: [integer]) { statement in
            try historicalUTF8(try historicalData(statement, 0, field), field, 4_096)
        }
        return try rows.first.unwrap(field: field)
    }

    func historicalSQLiteError(_ operation: String) -> SQLiteEventJournalError {
        let database = try? databaseHandle()
        let code = database.map(sqlite3_errcode) ?? SQLITE_ERROR
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable"
        if code & 0xff == SQLITE_FULL { return .diskFull(operation: operation) }
        return .sqliteFailure(operation: operation, code: code, message: message)
    }
}

enum HistoricalSQLValue {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null
}

private enum HistoricalAttributionShape {
    case classified(category: Int32, confidence: Int32, ruleID: String, ruleVersion: Int, evidenceCode: String)
    case noMatch
    case ambiguous([String])
}

private struct HistoricalFrameHeader {
    let rootSubjectKey: Int64
    let scopeKey: Int64
    let volumeID: Data
    let mountID: Data
    let epochID: Data
    let pathSemantics: Int64
    let measurementSemantics: Int64
    let metric: Int32
    let batchID: Int64
}

private struct ReconciliationSourceRow {
    let nodeID: Int64
    let subjectID: String
    let locationID: String
    let observedAt: Int64
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let descendantCount: Int64
    let scopeID: String
    let streamID: String
}

private struct ReconciliationStoredRow {
    let nodeID: Int64
    let subjectID: String
    let locationID: String
    let observedAt: Int64
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let descendantCount: Int64
    let scopeID: String
    let streamID: String
    let hourlyPredecessorNodeID: Int64?
    let dailyPredecessorNodeID: Int64?
    let payloadDigest: Data

    var source: ReconciliationSourceRow {
        ReconciliationSourceRow(
            nodeID: nodeID,
            subjectID: subjectID,
            locationID: locationID,
            observedAt: observedAt,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            descendantCount: descendantCount,
            scopeID: scopeID,
            streamID: streamID
        )
    }
}

struct HistoricalProjectionExpectedFindingRow {
    let ordinal: Int
    let findingKeyDigest: Data
    let draftDigest: Data
    let baselineNodeID: Int64
    let comparisonNodeID: Int64
    let metricCode: Int64
    let kindCode: Int64
    let inclusiveDeltaBytes: Int64
    let rankingContributionBytes: Int64?
    let movementAncestorKey: HistoricalFindingKey?
    let expiresAtMilliseconds: Int64
    let draft: HistoricalFindingDraft
}

private struct HistoricalProjectionStoredFindingRow {
    let findingID: Int64
    let ordinal: Int
    let findingKeyDigest: Data
    let draftDigest: Data
    let baselineNodeID: Int64
    let baselineMetricCode: Int64
    let comparisonNodeID: Int64
    let comparisonMetricCode: Int64
    let kindCode: Int64
    let inclusiveDeltaBytes: Int64
    let rankingContributionBytes: Int64?
    let movementAncestorFindingID: Int64?
    let expiresAtMilliseconds: Int64

    func matches(
        _ expected: HistoricalProjectionExpectedFindingRow,
        movementAncestorFindingID expectedAncestorID: Int64?
    ) -> Bool {
        ordinal == expected.ordinal
            && findingKeyDigest == expected.findingKeyDigest
            && draftDigest == expected.draftDigest
            && baselineNodeID == expected.baselineNodeID
            && baselineMetricCode == expected.metricCode
            && comparisonNodeID == expected.comparisonNodeID
            && comparisonMetricCode == expected.metricCode
            && kindCode == expected.kindCode
            && inclusiveDeltaBytes == expected.inclusiveDeltaBytes
            && rankingContributionBytes == expected.rankingContributionBytes
            && movementAncestorFindingID == expectedAncestorID
            && expiresAtMilliseconds == expected.expiresAtMilliseconds
    }
}

private struct HistoricalProjectionStoredRank: Equatable {
    let rank: Int
    let findingID: Int64
}

private struct HistoricalProjectionStoredReason: Equatable {
    let projectionID: Int64
    let category: Int64
    let reasonCode: Int64
    let count: Int64
}

private struct HistoricalEffectiveFindingCandidate {
    let findingID: Int64
    let projectionID: Int64
    let comparisonSequence: Int64
    let positiveRank: Int?
}

private struct HistoricalRehydratedFinding {
    let effective: EffectiveHistoricalFinding
    let draftDigest: Data
}

private struct HistoricalStoredRetraction {
    let record: HistoricalFindingRetractionRecord
    let canonicalRequestDigest: Data
    let expectedDraftDigest: Data
}

private func historicalEffectiveFindingOrder(
    _ lhs: EffectiveHistoricalFinding,
    _ rhs: EffectiveHistoricalFinding
) -> Bool {
    if lhs.comparisonSequence != rhs.comparisonSequence {
        return lhs.comparisonSequence > rhs.comparisonSequence
    }
    switch (lhs.positiveRank, rhs.positiveRank) {
    case let (.some(left), .some(right)) where left != right:
        return left < right
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    default:
        break
    }
    if lhs.draft.key != rhs.draft.key {
        return lhs.draft.key < rhs.draft.key
    }
    return lhs.recordID < rhs.recordID
}

private enum HistoricalProjectionVisitState {
    case visiting
    case visited
}

private let historicalFindingReasonWireOrder: [HistoricalFindingReason] = [
    .frameRootSubjectMismatch,
    .frameScopeMismatch,
    .frameVolumeMismatch,
    .frameMountGenerationMismatch,
    .frameCoverageEpochMismatch,
    .frameMetricMismatch,
    .framePathSemanticsMismatch,
    .frameMeasurementSemanticsMismatch,
    .frameNonIncreasingSequence,
    .missingBaselineEndpoint,
    .missingComparisonEndpoint,
    .endpointScopeMismatch,
    .endpointVolumeMismatch,
    .endpointMountGenerationMismatch,
    .endpointCoverageEpochMismatch,
    .endpointSubjectMismatch,
    .endpointIdentityBasisMismatch,
    .endpointMetricMismatch,
    .endpointPathSemanticsMismatch,
    .endpointMeasurementSemanticsMismatch,
    .endpointNonIncreasingSequence,
    .endpointIncompleteCoverage,
    .endpointUnavailable,
    .endpointLocationChangedWithoutStableIdentity,
    .endpointLocationChangedWithoutTwoPresentEndpoints,
    .stableIdentityEvidenceMissing,
    .stableIdentityReuseGuardMismatch,
    .stableIdentityNodeKindMismatch,
    .stableIdentityLinkSetNotUnique,
    .moveParentEvidenceIncomplete,
    .rankingIncompleteDirectChildren,
    .rankingIncompleteChildMeasurement,
    .rankingKindIneligible,
    .rankingNonPositiveContribution,
    .collapsedImplicitDescendantMove,
    .collapsedInheritedMoveFacet,
    .coveredByAncestorAppearance,
    .coveredByAncestorDisappearance,
]

private extension HistoricalFindingMovementContext {
    var ancestorKey: HistoricalFindingKey {
        switch self {
        case .inheritedFromAncestor(let ancestorKey): ancestorKey
        }
    }
}

private let historicalSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindHistoricalBlob(
    _ data: Data,
    _ statement: OpaquePointer,
    _ index: Int32
) throws {
    let result = data.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), historicalSQLiteTransient)
    }
    guard result == SQLITE_OK else {
        throw SQLiteEventJournalError.sqliteFailure(
            operation: "bind historical blob",
            code: result,
            message: "SQLite rejected a bounded historical blob."
        )
    }
}

private func historicalData(
    _ statement: OpaquePointer,
    _ column: Int32,
    _ field: String
) throws -> Data {
    guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
        throw SQLiteEventJournalError.corruptStoredValue(field: field)
    }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
        throw SQLiteEventJournalError.corruptStoredValue(field: field)
    }
    return Data(bytes: pointer, count: count)
}

private func historicalOptionalData(
    _ statement: OpaquePointer,
    _ column: Int32
) throws -> Data? {
    if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
    return try historicalData(statement, column, "historical_optional_blob")
}

func historicalOptionalInteger(
    _ statement: OpaquePointer,
    _ column: Int32
) throws -> Int64? {
    if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
    guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
        throw SQLiteEventJournalError.corruptStoredValue(field: "historical_optional_integer")
    }
    return sqlite3_column_int64(statement, column)
}

// Narrow cross-file adapters used by the schema-v12 correction lane. The
// underlying v11 helpers remain file-private so the rest of Persistence does
// not acquire a second general-purpose SQLite API.
extension SQLiteEventJournalRepository {
    func correctionReadFrame(
        sequence: ObservationCommitSequence
    ) throws -> HistoricalFindingObservationFrame? {
        try readHistoricalFrame(sequence: sequence)
    }

    func correctionReadProjectionWork(
        id: HistoricalProjectionWorkID
    ) throws -> HistoricalProjectionWork? {
        try readHistoricalProjectionWork(id: id)
    }

    func correctionValidateRootProjection(id: Int64) throws {
        _ = try rehydratedHistoricalProjection(id: id)
    }

    func correctionExpectedRows(
        work: HistoricalProjectionWork,
        result: HistoricalFindingGenerationResult
    ) throws -> [HistoricalProjectionExpectedFindingRow] {
        try historicalProjectionExpectedRows(work: work, result: result)
    }

    func correctionTopologicalDrafts(
        _ drafts: [HistoricalFindingDraft]
    ) throws -> [HistoricalFindingDraft] {
        try historicalTopologicalDrafts(drafts)
    }

    func correctionReasonCode(_ reason: HistoricalFindingReason) throws -> Int64 {
        try historicalReasonCode(reason)
    }

    static func correctionMilliseconds(_ date: Date) -> Int64 {
        historicalMilliseconds(date)
    }

    func correctionExecute(
        _ sql: String,
        integers: [Int64] = [],
        blobs: [Data] = []
    ) throws {
        try historicalExecute(sql, integers: integers, blobs: blobs)
    }

    func correctionExecuteNullable(
        _ sql: String,
        values: [HistoricalSQLValue]
    ) throws {
        try historicalExecuteNullable(sql, values: values)
    }

    func correctionSingleInt(
        _ sql: String,
        integers: [Int64] = [],
        blobs: [Data] = []
    ) throws -> Int64 {
        try historicalSingleInt(sql, integers: integers, blobs: blobs)
    }

    func correctionOptionalInt(
        _ sql: String,
        integers: [Int64] = [],
        blobs: [Data] = []
    ) throws -> Int64? {
        try historicalOptionalInt(sql, integers: integers, blobs: blobs)
    }

    func correctionRows<Result>(
        _ sql: String,
        integers: [Int64] = [],
        blobs: [Data] = [],
        map: (OpaquePointer) throws -> Result
    ) throws -> [Result] {
        try historicalRows(sql, integers: integers, blobs: blobs, map: map)
    }

    func correctionAppendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        appendHistoricalBigEndian(value, to: &data)
    }
}

func correctionData(
    _ statement: OpaquePointer,
    _ column: Int32,
    _ field: String
) throws -> Data {
    try historicalData(statement, column, field)
}

private func historicalText(
    _ statement: OpaquePointer,
    _ column: Int32,
    _ field: String
) throws -> String {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
          let pointer = sqlite3_column_text(statement, column) else {
        throw SQLiteEventJournalError.corruptStoredValue(field: field)
    }
    return String(
        decoding: UnsafeBufferPointer(
            start: pointer,
            count: Int(sqlite3_column_bytes(statement, column))
        ),
        as: UTF8.self
    )
}

private func historicalUTF8(_ data: Data, _ field: String, _ maximum: Int) throws -> String {
    try SQLiteHistoricalFindingCodec.decodeUTF8(data, field: field, maximumBytes: maximum)
}

private func historicalCoverageCode(_ coverage: ObservationCoverage) -> Int32 {
    switch coverage {
    case .complete: 1
    case .partial: 2
    case .unknown: 3
    }
}

private func historicalCoverage(_ code: Int32) throws -> ObservationCoverage {
    switch code {
    case 1: .complete
    case 2: .partial
    case 3: .unknown
    default: throw SQLiteEventJournalError.corruptStoredValue(field: "coverage")
    }
}

private func historicalUnknownCode(_ reason: ObservationUnavailabilityReason) -> Int32 {
    switch reason {
    case .permissionDenied: 1
    case .volumeUnavailable: 2
    case .continuityGap: 3
    case .incompleteEnumeration: 4
    case .identityUnavailable: 5
    case .endpointMissing: 6
    }
}

private func historicalUnknownReason(_ code: Int32) throws -> ObservationUnavailabilityReason {
    switch code {
    case 1: .permissionDenied
    case 2: .volumeUnavailable
    case 3: .continuityGap
    case 4: .incompleteEnumeration
    case 5: .identityUnavailable
    case 6: .endpointMissing
    default: throw SQLiteEventJournalError.corruptStoredValue(field: "unknown_reason")
    }
}

private func historicalCategoryCode(_ category: StorageAttributionCategory) -> Int32 {
    switch category {
    case .developerTools: 1
    case .virtualization: 2
    case .aiModelsAndCaches: 3
    case .creativeCachesAndRenderData: 4
    case .games: 5
    case .logsAndCaches: 6
    case .cloudLocalData: 7
    case .snapshotFactors: 8
    }
}

private func historicalConfidenceCode(_ confidence: AttributionConfidence) -> Int32 {
    switch confidence {
    case .high: 1
    case .medium: 2
    case .low: 3
    case .unknown: 0
    }
}

private func historicalPathDepth(_ path: String) -> Int {
    path.utf8.reduce(into: 0) { count, byte in if byte == 47 { count += 1 } }
}

private extension Optional {
    func unwrap(field: String) throws -> Wrapped {
        guard let self else { throw SQLiteEventJournalError.corruptStoredValue(field: field) }
        return self
    }
}
