import CryptoKit
import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceAttribution
import SpaceTraceDomain

extension SQLiteEventJournalRepository {
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
        try readHistoricalFrame(sequence: sequence)
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
        try execute("BEGIN IMMEDIATE TRANSACTION", operation: "begin calibration finalization")
        var responseLossAfterCommit = false
        do {
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

            let durableWork = try readExactHistoricalDirtyWork(
                streamID: streamID,
                path: workItem.region.path
            )
            guard durableWork?.revision == workItem.revision else {
                if let requestDigest {
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
                historicalOutcome = try persistHistoricalFrames(
                    request: historicalRequest,
                    requestDigest: requestDigest
                )
            }
            try markMissingDirectoriesDeleted(
                streamID: streamID,
                region: context.regionPath,
                runID: runID
            )
            try publishStagedDirectories(streamID: streamID, runID: runID)
            try recordDirectoryHistory(streamID: streamID, runID: runID, observedAt: now())
            guard try resolve(workItem, for: streamID) else {
                throw SQLiteEventJournalError.dirtyRevisionChangedDuringFinalization
            }
            try finishScanRun(runID, state: "completed", report: report)
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

private extension ObservationEndpointState {
    var isPresent: Bool {
        if case .present = self { return true }
        return false
    }
}

private extension SQLiteEventJournalRepository {
    func persistHistoricalFrames(
        request: HistoricalCalibrationFinalizationRequest,
        requestDigest: Data
    ) throws -> HistoricalCalibrationFinalizationOutcome {
        try validateCandidateAgainstStage(request)
        let priorSequences = try latestHistoricalSequences(
            scopeID: request.observation.scopeID
        )
        if priorSequences == nil,
           request.observation.nodes.contains(where: { node in
               if case .absent = node.state { return true }
               return false
           }) {
            throw SQLiteEventJournalError.historicalFirstBaselineCannotContainAbsence
        }
        if let priorSequences {
            try validateAbsenceEvidence(
                in: request.observation,
                priorLogicalSequence: priorSequences.logical
            )
        }

        let retentionAnchor = try request.observation.nodes
            .map(\.observedAt.millisecondsSince1970).min()
            .unwrap(field: "historical_retention_anchor")
        let expiresAt = try addingThirtyDays(retentionAnchor)
        guard expiresAt >= Self.historicalMilliseconds(now()) else {
            throw SQLiteEventJournalError.historicalCandidateExpired
        }
        let committedAt = Self.historicalMilliseconds(now())

        let scopeKey = try upsertHistoricalScope(request.observation.scopeID)
        let subjectKeys = try upsertHistoricalSubjects(
            request.observation.nodes,
            scopeKey: scopeKey
        )
        let locationKeys = try upsertHistoricalLocations(
            request.observation.nodes,
            scopeKey: scopeKey,
            pathSemanticsVersion: request.observation.pathSemanticsVersion
        )
        let decisionKeys = try upsertHistoricalDecisions(request.observation.nodes)
        try failHistoricalFinalizationIfRequested(.afterHistoricalDictionaries)

        let rootSubjectKey = try subjectKeys[request.observation.rootSubjectID]
            .unwrap(field: "historical_root_subject_key")
        let batchID = try insertHistoricalBatch(
            request: request,
            scopeKey: scopeKey,
            rootSubjectKey: rootSubjectKey,
            committedAt: committedAt
        )
        let logicalFrameID = try insertHistoricalFrame(batchID: batchID, metricCode: 1)
        let allocatedFrameID = try insertHistoricalFrame(batchID: batchID, metricCode: 2)
        try failHistoricalFinalizationIfRequested(.afterHistoricalBatch)

        let nodeIDs = try insertHistoricalNodes(
            request.observation.nodes,
            batchID: batchID,
            subjectKeys: subjectKeys,
            locationKeys: locationKeys,
            decisionKeys: decisionKeys
        )
        try failHistoricalFinalizationIfRequested(.afterHistoricalNodes)
        try insertHistoricalEndpoints(
            request.observation.nodes,
            nodeIDs: nodeIDs,
            frameID: logicalFrameID,
            metric: .logical
        )
        try failHistoricalFinalizationIfRequested(.afterHistoricalLogicalEndpoints)
        try insertHistoricalEndpoints(
            request.observation.nodes,
            nodeIDs: nodeIDs,
            frameID: allocatedFrameID,
            metric: .allocated
        )

        let rootNodeID = try nodeIDs[request.observation.rootSubjectID]
            .unwrap(field: "historical_root_node_id")
        let logicalSequence = try insertHistoricalFrameCommit(
            frameID: logicalFrameID,
            rootNodeID: rootNodeID,
            metricCode: 1,
            endpointCount: request.observation.nodes.count,
            committedAt: committedAt,
            retentionAnchor: retentionAnchor,
            expiresAt: expiresAt
        )
        try failHistoricalFinalizationIfRequested(.afterHistoricalLogicalMarker)
        let allocatedSequence = try insertHistoricalFrameCommit(
            frameID: allocatedFrameID,
            rootNodeID: rootNodeID,
            metricCode: 2,
            endpointCount: request.observation.nodes.count,
            committedAt: committedAt,
            retentionAnchor: retentionAnchor,
            expiresAt: expiresAt
        )

        let materialized = try HistoricalPairedObservationCommitMaterializer(
            candidate: request.observation
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
            request: request,
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
                    endpointCount: request.observation.nodes.count
                ),
                allocated: try HistoricalObservationFrameCommit(
                    sequence: allocatedSequence,
                    rootEndpointID: allocatedRootID,
                    endpointCount: request.observation.nodes.count
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
        for node in candidate.nodes {
            guard case .absent = node.state else { continue }
            guard let parentSubjectID = node.parentSubjectID,
                  let previousNode = prior?.nodes.first(where: {
                      $0.endpoint.subjectID == node.subjectID
                  }),
                  previousNode.endpoint.state.isPresent,
                  let currentParent = candidate.nodes.first(where: {
                      $0.subjectID == parentSubjectID
                  }),
                  currentParent.directChildrenCoverage == .complete,
                  case let .present(_, _, parentCoverage) = currentParent.state,
                  parentCoverage == .complete else {
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
        let sql = "SELECT l.sequence,a.sequence FROM historical_observation_batch b JOIN historical_observation_frame lf ON lf.batch_id=b.batch_id AND lf.metric=1 JOIN historical_observation_frame af ON af.batch_id=b.batch_id AND af.metric=2 JOIN historical_observation_frame_commit l ON l.frame_id=lf.frame_id JOIN historical_observation_frame_commit a ON a.frame_id=af.frame_id JOIN historical_scope s ON s.scope_key=b.scope_key WHERE s.scope_id=? ORDER BY l.sequence DESC LIMIT 1"
        var statement: OpaquePointer?
        let database = try databaseHandle()
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw historicalSQLiteError("prepare latest frames") }
        defer { sqlite3_finalize(statement) }
        try bindHistoricalBlob(scope, statement, 1)
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

private enum HistoricalSQLValue {
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
