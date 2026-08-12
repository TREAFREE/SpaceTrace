import CryptoKit
import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceDomain

extension SQLiteEventJournalRepository: HistoricalProjectionCorrectionRepository {
    package func historicalProjectionCorrectionStoredRequest(
        requestID: HistoricalProjectionCorrectionRequestID
    ) throws -> HistoricalProjectionCorrectionStoredRequest? {
        try performHistoricalStartupMaintenanceIfNeeded()
        guard let workID = try correctionOptionalInt(
            "SELECT work_id FROM historical_projection_correction_work WHERE request_id=?",
            blobs: [Data(requestID.bytes)]
        ) else {
            return nil
        }
        let row = try correctionRows(
            """
            SELECT w.root_projection_id,w.algorithm_version,w.ranking_policy_version,
                   w.correction_input_format_version,w.correction_input_sha256,
                   i.canonical_input
            FROM historical_projection_correction_work w
            JOIN historical_correction_input i
              ON i.algorithm_version=w.algorithm_version
             AND i.ranking_policy_version=w.ranking_policy_version
             AND i.input_format_version=w.correction_input_format_version
             AND i.input_sha256=w.correction_input_sha256
            WHERE w.work_id=?
            """,
            integers: [workID]
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                Int(sqlite3_column_int64(statement, 1)),
                Int(sqlite3_column_int64(statement, 2)),
                Int(sqlite3_column_int64(statement, 3)),
                try correctionData(statement, 4, "correction.input_digest"),
                try correctionData(statement, 5, "correction.input")
            )
        }.first.correctionUnwrap(field: "historical_correction_stored_request")
        let rootProjectionID = try HistoricalProjectionRecordID(row.0)
        let rootWork = try historicalRootProjectionWork(rootProjectionID)
        let baseline = try correctionReadFrame(sequence: rootWork.baselineSequence)
            .correctionUnwrap(field: "historical_correction_baseline")
        let comparison = try correctionReadFrame(sequence: rootWork.comparisonSequence)
            .correctionUnwrap(field: "historical_correction_comparison")
        let semanticIdentity = try HistoricalProjectionSemanticIdentity(
            algorithmVersion: HistoricalFindingAlgorithmVersion(row.1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(row.2),
            correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(row.3),
            correctionInputDigest: HistoricalProjectionCorrectionDigest(bytes: Array(row.4))
        )
        let result = try historicalProjectionCorrectionRegistry.generate(
            semanticIdentity: semanticIdentity,
            canonicalInput: row.5,
            baseline: baseline,
            comparison: comparison,
            positiveLimit: rootWork.positiveLimit
        )
        let stored = try historicalStoredCorrectionCommand(
            workID: workID,
            expectedResult: result,
            rootProjectionID: rootProjectionID
        )
        let command = stored.command
        let audit = try HistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: command.rootProjectionID,
            predecessorCorrectingProjectionID: command.predecessorCorrectingProjectionID,
            predecessor: command.predecessor,
            positiveLimit: rootWork.positiveLimit
        )
        return HistoricalProjectionCorrectionStoredRequest(
            audit: audit,
            semanticIdentity: semanticIdentity,
            canonicalInput: row.5
        )
    }

    package func historicalProjectionCorrectionAuditRecord(
        rootProjectionID: HistoricalProjectionRecordID
    ) throws -> HistoricalProjectionCorrectionAuditRecord? {
        try performHistoricalStartupMaintenanceIfNeeded()
        return try readHistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: rootProjectionID,
            validateTerminalResult: true
        )
    }

    package func commitHistoricalProjectionCorrection(
        _ command: HistoricalProjectionCorrectionCommand
    ) throws -> HistoricalProjectionCorrectionCommitOutcome {
        _ = try HistoricalProjectionCorrectionRequest(
            requestID: command.requestID,
            predecessor: command.predecessor,
            replacement: command.replacement
        )
        let expectedDigest = try historicalProjectionCorrectionResultDigest(
            command.expectedResult
        )
        guard expectedDigest == command.replacement.resultDigest else {
            throw SQLiteEventJournalError.historicalCorrectionResultMismatch
        }
        let requestDigest = try historicalCorrectionRequestDigest(command)

        try execute(
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin historical projection correction"
        )
        var responseLossAfterCommit = false
        do {
            if let existingWorkID = try correctionOptionalInt(
                "SELECT work_id FROM historical_projection_correction_work WHERE request_id=?",
                blobs: [Data(command.requestID.bytes)]
            ) {
                let correctingProjectionID = try validateStoredHistoricalCorrection(
                    workID: existingWorkID,
                    command: command,
                    requestDigest: requestDigest
                )
                try execute(
                    "COMMIT TRANSACTION",
                    operation: "commit idempotent historical projection correction"
                )
                return .alreadyCommitted(
                    try HistoricalCorrectingProjectionRecordID(correctingProjectionID)
                )
            }

            guard let audit = try readHistoricalProjectionCorrectionAuditRecord(
                rootProjectionID: command.rootProjectionID,
                validateTerminalResult: true
            ) else {
                throw SQLiteEventJournalError.historicalCorrectionTargetNotFound
            }
            guard audit.rootProjectionID == command.rootProjectionID,
                  audit.predecessorCorrectingProjectionID
                    == command.predecessorCorrectingProjectionID,
                  audit.predecessor == command.predecessor else {
                throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
            }

            let baseline = try correctionReadFrame(
                sequence: command.predecessor.baselineSequence
            ).correctionUnwrap(field: "historical_correction_baseline")
            let comparison = try correctionReadFrame(
                sequence: command.predecessor.comparisonSequence
            ).correctionUnwrap(field: "historical_correction_comparison")
            let regenerated = try historicalProjectionCorrectionRegistry.generate(
                semanticIdentity: command.replacement.semanticIdentity,
                canonicalInput: command.canonicalInput,
                baseline: baseline,
                comparison: comparison,
                positiveLimit: audit.positiveLimit
            )
            guard regenerated == command.expectedResult,
                  try historicalProjectionCorrectionResultDigest(regenerated)
                    == command.replacement.resultDigest else {
                throw SQLiteEventJournalError.historicalCorrectionResultMismatch
            }

            try insertOrValidateHistoricalCorrectionInput(command)
            let committedAt = Self.correctionMilliseconds(now())
            let workID = try insertHistoricalCorrectionWork(
                command,
                requestDigest: requestDigest,
                createdAt: committedAt
            )
            let correctingProjectionID = try insertHistoricalCorrectingProjection(
                workID: workID,
                rootProjectionID: command.rootProjectionID,
                result: regenerated,
                resultDigest: Data(command.replacement.resultDigest.bytes),
                committedAt: committedAt
            )
            if injectedFailurePoint == .beforeHistoricalCorrectionCheckpoint {
                injectedFailurePoint = nil
                throw SQLiteEventJournalError.injectedFailure
            }
            try correctionExecute(
                "INSERT INTO historical_projection_correction_checkpoint(work_id,correcting_projection_id,committed_at_ms) VALUES(?,?,?)",
                integers: [workID, correctingProjectionID, committedAt]
            )
            _ = try validateStoredHistoricalCorrection(
                workID: workID,
                command: command,
                requestDigest: requestDigest
            )
            try execute(
                "COMMIT TRANSACTION",
                operation: "commit historical projection correction"
            )
            if injectedFailurePoint == .afterHistoricalCorrectionCommitBeforeReturningReceipt {
                injectedFailurePoint = nil
                responseLossAfterCommit = true
            }
            if responseLossAfterCommit {
                throw SQLiteEventJournalError.injectedFailure
            }
            return .newlyCommitted(
                try HistoricalCorrectingProjectionRecordID(correctingProjectionID)
            )
        } catch SQLiteEventJournalError.injectedFailure where responseLossAfterCommit {
            throw SQLiteEventJournalError.injectedFailure
        } catch {
            try rollback(after: error)
        }
    }
}

extension SQLiteEventJournalRepository {
    private func readHistoricalProjectionCorrectionAuditRecord(
        rootProjectionID: HistoricalProjectionRecordID,
        validateTerminalResult: Bool
    ) throws -> HistoricalProjectionCorrectionAuditRecord? {
        let rootRows = try correctionRows(
            """
            SELECT p.canonical_result_sha256,w.baseline_sequence,w.comparison_sequence,
                   w.algorithm_version,w.ranking_policy_version,w.positive_limit,
                   s.scope_id,bf.metric
            FROM historical_finding_projection p
            JOIN historical_projection_work w ON w.work_id=p.work_id
            JOIN historical_projection_checkpoint pc ON pc.work_id=w.work_id
            JOIN historical_observation_frame_commit bc ON bc.sequence=w.baseline_sequence
            JOIN historical_observation_frame bf ON bf.frame_id=bc.frame_id
            JOIN historical_observation_batch bb ON bb.batch_id=bf.batch_id
            JOIN historical_scope s ON s.scope_key=bb.scope_key
            JOIN scan_run br ON br.id=bb.scan_run_id
            JOIN historical_observation_frame_commit cc ON cc.sequence=w.comparison_sequence
            JOIN historical_observation_frame cf ON cf.frame_id=cc.frame_id
            JOIN historical_observation_batch cb ON cb.batch_id=cf.batch_id
            JOIN scan_run cr ON cr.id=cb.scan_run_id
            WHERE p.projection_id=? AND bf.metric=cf.metric
              AND bb.scope_key=cb.scope_key
              AND br.state='completed' AND br.coverage='complete'
              AND cr.state='completed' AND cr.coverage='complete'
            """,
            integers: [rootProjectionID.rawValue]
        ) { statement in
            HistoricalCorrectionRootRow(
                digest: try correctionData(statement, 0, "correction.root_digest"),
                baselineSequence: sqlite3_column_int64(statement, 1),
                comparisonSequence: sqlite3_column_int64(statement, 2),
                algorithmVersion: Int(sqlite3_column_int64(statement, 3)),
                rankingPolicyVersion: Int(sqlite3_column_int64(statement, 4)),
                positiveLimit: Int(sqlite3_column_int64(statement, 5)),
                scopeBytes: try correctionData(statement, 6, "correction.scope_id"),
                metricCode: sqlite3_column_int64(statement, 7)
            )
        }
        guard rootRows.count <= 1 else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        guard let root = rootRows.first else { return nil }
        guard root.digest.count == 32,
              (1...100).contains(root.positiveLimit) else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        try correctionValidateRootProjection(id: rootProjectionID.rawValue)

        let pendingCount = try correctionSingleInt(
            """
            SELECT count(*)
            FROM historical_projection_correction_work w
            LEFT JOIN historical_projection_correction_checkpoint c ON c.work_id=w.work_id
            WHERE w.root_projection_id=? AND c.work_id IS NULL
            """,
            integers: [rootProjectionID.rawValue]
        )
        guard pendingCount == 0 else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }

        let terminalRows = try correctionRows(
            """
            SELECT p.correcting_projection_id,p.canonical_result_sha256,
                   w.algorithm_version,w.ranking_policy_version,
                   w.correction_input_format_version,w.correction_input_sha256,
                   i.canonical_input,w.work_id
            FROM historical_projection_correction_work w
            JOIN historical_correcting_projection p ON p.work_id=w.work_id
            JOIN historical_projection_correction_checkpoint c
              ON c.correcting_projection_id=p.correcting_projection_id
            JOIN historical_correction_input i
              ON i.algorithm_version=w.algorithm_version
             AND i.ranking_policy_version=w.ranking_policy_version
             AND i.input_format_version=w.correction_input_format_version
             AND i.input_sha256=w.correction_input_sha256
            WHERE w.root_projection_id=?
              AND NOT EXISTS(
                SELECT 1 FROM historical_projection_correction_work successor
                JOIN historical_correcting_projection successor_projection
                  ON successor_projection.work_id=successor.work_id
                JOIN historical_projection_correction_checkpoint successor_checkpoint
                  ON successor_checkpoint.correcting_projection_id=
                     successor_projection.correcting_projection_id
                WHERE successor.predecessor_correcting_projection_id=
                      p.correcting_projection_id
              )
            """,
            integers: [rootProjectionID.rawValue]
        ) { statement in
            HistoricalCorrectionTerminalRow(
                correctingProjectionID: sqlite3_column_int64(statement, 0),
                digest: try correctionData(statement, 1, "correction.result_digest"),
                algorithmVersion: Int(sqlite3_column_int64(statement, 2)),
                rankingPolicyVersion: Int(sqlite3_column_int64(statement, 3)),
                inputFormatVersion: Int(sqlite3_column_int64(statement, 4)),
                inputDigest: try correctionData(statement, 5, "correction.input_digest"),
                canonicalInput: try correctionData(statement, 6, "correction.input"),
                workID: sqlite3_column_int64(statement, 7)
            )
        }
        guard terminalRows.count <= 1 else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }

        let semanticIdentity: HistoricalProjectionSemanticIdentity
        let predecessorDigest: Data
        let predecessorCorrectingProjectionID: HistoricalCorrectingProjectionRecordID?
        if let terminal = terminalRows.first {
            guard terminal.digest.count == 32,
                  terminal.inputDigest.count == 32 else {
                throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
            }
            let inputDigest = try HistoricalProjectionCorrectionDigest(
                bytes: Array(terminal.inputDigest)
            )
            semanticIdentity = try HistoricalProjectionSemanticIdentity(
                algorithmVersion: HistoricalFindingAlgorithmVersion(
                    terminal.algorithmVersion
                ),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(
                    terminal.rankingPolicyVersion
                ),
                correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(
                    terminal.inputFormatVersion
                ),
                correctionInputDigest: inputDigest
            )
            predecessorDigest = terminal.digest
            predecessorCorrectingProjectionID = try HistoricalCorrectingProjectionRecordID(
                terminal.correctingProjectionID
            )
            if validateTerminalResult {
                let baseline = try correctionReadFrame(
                    sequence: ObservationCommitSequence(root.baselineSequence)
                ).correctionUnwrap(field: "historical_correction_baseline")
                let comparison = try correctionReadFrame(
                    sequence: ObservationCommitSequence(root.comparisonSequence)
                ).correctionUnwrap(field: "historical_correction_comparison")
                let result = try historicalProjectionCorrectionRegistry.generate(
                    semanticIdentity: semanticIdentity,
                    canonicalInput: terminal.canonicalInput,
                    baseline: baseline,
                    comparison: comparison,
                    positiveLimit: root.positiveLimit
                )
                let command = try historicalStoredCorrectionCommand(
                    workID: terminal.workID,
                    expectedResult: result,
                    rootProjectionID: rootProjectionID
                )
                _ = try validateStoredHistoricalCorrection(
                    workID: terminal.workID,
                    command: command.command,
                    requestDigest: command.requestDigest
                )
            }
        } else {
            semanticIdentity = try HistoricalProjectionSemanticIdentity(
                algorithmVersion: HistoricalFindingAlgorithmVersion(root.algorithmVersion),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(
                    root.rankingPolicyVersion
                ),
                correctionInputFormatVersion: nil,
                correctionInputDigest: nil
            )
            predecessorDigest = root.digest
            predecessorCorrectingProjectionID = nil
        }

        let scopeID = try ScopeID(
            SQLiteHistoricalFindingCodec.decodeUTF8(
                root.scopeBytes,
                field: "correction.scope_id",
                maximumBytes: 4_096
            )
        )
        let reference = try HistoricalProjectionCorrectionReference(
            projectionID: rootProjectionID,
            projectionDigest: HistoricalProjectionCorrectionDigest(
                bytes: Array(predecessorDigest)
            ),
            baselineSequence: ObservationCommitSequence(root.baselineSequence),
            comparisonSequence: ObservationCommitSequence(root.comparisonSequence),
            scopeID: scopeID,
            metric: try historicalCorrectionMetric(root.metricCode),
            semanticIdentity: semanticIdentity
        )
        return try HistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: rootProjectionID,
            predecessorCorrectingProjectionID: predecessorCorrectingProjectionID,
            predecessor: reference,
            positiveLimit: root.positiveLimit
        )
    }

    private func insertOrValidateHistoricalCorrectionInput(
        _ command: HistoricalProjectionCorrectionCommand
    ) throws {
        guard let format = command.replacement.semanticIdentity.correctionInputFormatVersion,
              let digest = command.replacement.semanticIdentity.correctionInputDigest else {
            throw SQLiteEventJournalError.historicalCorrectionResultMismatch
        }
        try correctionExecuteNullable(
            """
            INSERT OR IGNORE INTO historical_correction_input(
                algorithm_version,ranking_policy_version,input_format_version,
                input_sha256,canonical_input
            ) VALUES(?,?,?,?,?)
            """,
            values: [
                .integer(Int64(command.replacement.semanticIdentity.algorithmVersion.rawValue)),
                .integer(Int64(command.replacement.semanticIdentity.rankingPolicyVersion.rawValue)),
                .integer(Int64(format.rawValue)),
                .blob(Data(digest.bytes)),
                .blob(command.canonicalInput),
            ]
        )
        let stored = try correctionRows(
            """
            SELECT canonical_input FROM historical_correction_input
            WHERE algorithm_version=? AND ranking_policy_version=?
              AND input_format_version=? AND input_sha256=?
            """,
            integers: [
                Int64(command.replacement.semanticIdentity.algorithmVersion.rawValue),
                Int64(command.replacement.semanticIdentity.rankingPolicyVersion.rawValue),
                Int64(format.rawValue),
            ],
            blobs: [Data(digest.bytes)]
        ) { statement in
            try correctionData(statement, 0, "correction.canonical_input")
        }
        guard stored == [command.canonicalInput] else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
    }

    private func insertHistoricalCorrectionWork(
        _ command: HistoricalProjectionCorrectionCommand,
        requestDigest: Data,
        createdAt: Int64
    ) throws -> Int64 {
        guard let format = command.replacement.semanticIdentity.correctionInputFormatVersion,
              let inputDigest = command.replacement.semanticIdentity.correctionInputDigest else {
            throw SQLiteEventJournalError.historicalCorrectionResultMismatch
        }
        try correctionExecuteNullable(
            """
            INSERT INTO historical_projection_correction_work(
                request_id,request_format_version,canonical_request_sha256,
                root_projection_id,predecessor_correcting_projection_id,
                expected_predecessor_sha256,algorithm_version,ranking_policy_version,
                correction_input_format_version,correction_input_sha256,created_at_ms
            ) VALUES(?,1,?,?,?,?,?,?,?,?,?)
            """,
            values: [
                .blob(Data(command.requestID.bytes)),
                .blob(requestDigest),
                .integer(command.rootProjectionID.rawValue),
                command.predecessorCorrectingProjectionID.map {
                    .integer($0.rawValue)
                } ?? .null,
                .blob(Data(command.predecessor.projectionDigest.bytes)),
                .integer(Int64(command.replacement.semanticIdentity.algorithmVersion.rawValue)),
                .integer(Int64(command.replacement.semanticIdentity.rankingPolicyVersion.rawValue)),
                .integer(Int64(format.rawValue)),
                .blob(Data(inputDigest.bytes)),
                .integer(createdAt),
            ]
        )
        return sqlite3_last_insert_rowid(try databaseHandle())
    }

    private func insertHistoricalCorrectingProjection(
        workID: Int64,
        rootProjectionID: HistoricalProjectionRecordID,
        result: HistoricalFindingGenerationResult,
        resultDigest: Data,
        committedAt: Int64
    ) throws -> Int64 {
        let rootWork = try historicalRootProjectionWork(rootProjectionID)
        let expiresAt = try correctionSingleInt(
            """
            SELECT min(b.expires_at_ms,c.expires_at_ms)
            FROM historical_projection_work w
            JOIN historical_observation_frame_commit b ON b.sequence=w.baseline_sequence
            JOIN historical_observation_frame_commit c ON c.sequence=w.comparison_sequence
            WHERE w.work_id=?
            """,
            integers: [rootWork.recordID.rawValue]
        )
        let reasonCount = result.suppressionSummary.findingSuppressions.count
            + result.suppressionSummary.rankingExclusions.count
            + result.suppressionSummary.collapses.count
        try correctionExecuteNullable(
            """
            INSERT INTO historical_correcting_projection(
                work_id,result_format_version,canonical_result_sha256,finding_count,
                ranked_positive_count,reason_count,truncated_positive_count,
                committed_at_ms,expires_at_ms
            ) VALUES(?,1,?,?,?,?,?,?,?)
            """,
            values: [
                .integer(workID),
                .blob(resultDigest),
                .integer(Int64(result.batch.findings.count)),
                .integer(Int64(result.batch.rankedPositiveFindingKeys.count)),
                .integer(Int64(reasonCount)),
                .integer(Int64(result.suppressionSummary.truncatedPositiveCount)),
                .integer(committedAt),
                .integer(expiresAt),
            ]
        )
        let projectionID = sqlite3_last_insert_rowid(try databaseHandle())
        let rows = try correctionExpectedRows(work: rootWork, result: result)
        let rowByKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.draft.key, $0) })
        let orderedDrafts = try correctionTopologicalDrafts(result.batch.findings)
        var findingIDByKey: [HistoricalFindingKey: Int64] = [:]
        for draft in orderedDrafts {
            let row = try rowByKey[draft.key].correctionUnwrap(
                field: "corrected_finding_row"
            )
            let ancestorID: Int64?
            switch draft.movementContext {
            case .none:
                ancestorID = nil
            case .inheritedFromAncestor(let key):
                ancestorID = try findingIDByKey[key].correctionUnwrap(
                    field: "corrected_movement_ancestor"
                )
            }
            try correctionExecuteNullable(
                """
                INSERT INTO historical_corrected_finding(
                    correcting_projection_id,ordinal,finding_key_sha256,draft_sha256,
                    baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,
                    kind,inclusive_delta_bytes,ranking_contribution_bytes,
                    movement_ancestor_corrected_finding_id,expires_at_ms
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                values: [
                    .integer(projectionID), .integer(Int64(row.ordinal)),
                    .blob(row.findingKeyDigest), .blob(row.draftDigest),
                    .integer(row.baselineNodeID), .integer(row.metricCode),
                    .integer(row.comparisonNodeID), .integer(row.metricCode),
                    .integer(row.kindCode), .integer(row.inclusiveDeltaBytes),
                    row.rankingContributionBytes.map(HistoricalSQLValue.integer) ?? .null,
                    ancestorID.map(HistoricalSQLValue.integer) ?? .null,
                    .integer(row.expiresAtMilliseconds),
                ]
            )
            findingIDByKey[draft.key] = sqlite3_last_insert_rowid(try databaseHandle())
        }
        for (offset, key) in result.batch.rankedPositiveFindingKeys.enumerated() {
            try correctionExecute(
                "INSERT INTO historical_corrected_positive_rank(correcting_projection_id,rank,corrected_finding_id) VALUES(?,?,?)",
                integers: [
                    projectionID,
                    Int64(offset + 1),
                    try findingIDByKey[key].correctionUnwrap(
                        field: "corrected_rank_finding"
                    ),
                ]
            )
        }
        try insertHistoricalCorrectedReasons(
            result.suppressionSummary.findingSuppressions,
            category: 1,
            projectionID: projectionID
        )
        try insertHistoricalCorrectedReasons(
            result.suppressionSummary.rankingExclusions,
            category: 2,
            projectionID: projectionID
        )
        try insertHistoricalCorrectedReasons(
            result.suppressionSummary.collapses,
            category: 3,
            projectionID: projectionID
        )
        return projectionID
    }

    private func insertHistoricalCorrectedReasons(
        _ values: [HistoricalFindingReasonCount],
        category: Int64,
        projectionID: Int64
    ) throws {
        for value in values {
            try correctionExecute(
                "INSERT INTO historical_corrected_reason_count(correcting_projection_id,category,reason_code,count) VALUES(?,?,?,?)",
                integers: [
                    projectionID,
                    category,
                    try correctionReasonCode(value.reason),
                    Int64(value.count),
                ]
            )
        }
    }

    private func validateStoredHistoricalCorrection(
        workID: Int64,
        command: HistoricalProjectionCorrectionCommand,
        requestDigest: Data
    ) throws -> Int64 {
        let rows = try correctionRows(
            """
            SELECT w.request_id,w.canonical_request_sha256,w.root_projection_id,
                   w.predecessor_correcting_projection_id,w.expected_predecessor_sha256,
                   w.algorithm_version,w.ranking_policy_version,
                   w.correction_input_format_version,w.correction_input_sha256,
                   i.canonical_input,p.correcting_projection_id,p.canonical_result_sha256,
                   p.finding_count,p.ranked_positive_count,p.reason_count,
                   p.truncated_positive_count,p.committed_at_ms,p.expires_at_ms,
                   c.committed_at_ms
            FROM historical_projection_correction_work w
            JOIN historical_correction_input i
              ON i.algorithm_version=w.algorithm_version
             AND i.ranking_policy_version=w.ranking_policy_version
             AND i.input_format_version=w.correction_input_format_version
             AND i.input_sha256=w.correction_input_sha256
            JOIN historical_correcting_projection p ON p.work_id=w.work_id
            JOIN historical_projection_correction_checkpoint c
              ON c.work_id=w.work_id AND c.correcting_projection_id=p.correcting_projection_id
            WHERE w.work_id=?
            """,
            integers: [workID]
        ) { statement in
            HistoricalStoredCorrectionRow(
                requestID: try correctionData(statement, 0, "correction.request_id"),
                requestDigest: try correctionData(statement, 1, "correction.request_digest"),
                rootProjectionID: sqlite3_column_int64(statement, 2),
                predecessorID: try historicalOptionalInteger(statement, 3),
                predecessorDigest: try correctionData(statement, 4, "correction.predecessor_digest"),
                algorithmVersion: Int(sqlite3_column_int64(statement, 5)),
                rankingPolicyVersion: Int(sqlite3_column_int64(statement, 6)),
                inputFormatVersion: Int(sqlite3_column_int64(statement, 7)),
                inputDigest: try correctionData(statement, 8, "correction.input_digest"),
                canonicalInput: try correctionData(statement, 9, "correction.input"),
                correctingProjectionID: sqlite3_column_int64(statement, 10),
                resultDigest: try correctionData(statement, 11, "correction.result_digest"),
                findingCount: Int(sqlite3_column_int64(statement, 12)),
                rankCount: Int(sqlite3_column_int64(statement, 13)),
                reasonCount: Int(sqlite3_column_int64(statement, 14)),
                truncatedCount: Int(sqlite3_column_int64(statement, 15)),
                committedAt: sqlite3_column_int64(statement, 16),
                expiresAt: sqlite3_column_int64(statement, 17),
                checkpointAt: sqlite3_column_int64(statement, 18)
            )
        }
        guard rows.count == 1, let stored = rows.first,
              stored.requestID == Data(command.requestID.bytes),
              stored.requestDigest == requestDigest,
              stored.rootProjectionID == command.rootProjectionID.rawValue,
              stored.predecessorID == command.predecessorCorrectingProjectionID?.rawValue,
              stored.predecessorDigest == Data(command.predecessor.projectionDigest.bytes),
              stored.algorithmVersion
                == command.replacement.semanticIdentity.algorithmVersion.rawValue,
              stored.rankingPolicyVersion
                == command.replacement.semanticIdentity.rankingPolicyVersion.rawValue,
              stored.inputFormatVersion
                == command.replacement.semanticIdentity.correctionInputFormatVersion?.rawValue,
              stored.inputDigest
                == command.replacement.semanticIdentity.correctionInputDigest.map({
                    Data($0.bytes)
                }),
              stored.canonicalInput == command.canonicalInput,
              stored.resultDigest == Data(command.replacement.resultDigest.bytes),
              stored.findingCount == command.expectedResult.batch.findings.count,
              stored.rankCount
                == command.expectedResult.batch.rankedPositiveFindingKeys.count,
              stored.reasonCount == historicalCorrectionReasonRowCount(
                command.expectedResult
              ),
              stored.truncatedCount
                == command.expectedResult.suppressionSummary.truncatedPositiveCount,
              stored.committedAt == stored.checkpointAt,
              stored.expiresAt >= 0 else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }

        let rootWork = try historicalRootProjectionWork(command.rootProjectionID)
        let expected = try correctionExpectedRows(
            work: rootWork,
            result: command.expectedResult
        )
        let storedFindings = try correctionRows(
            """
            SELECT corrected_finding_id,ordinal,finding_key_sha256,draft_sha256,
                   baseline_node_id,baseline_metric,comparison_node_id,comparison_metric,
                   kind,inclusive_delta_bytes,ranking_contribution_bytes,
                   movement_ancestor_corrected_finding_id,expires_at_ms
            FROM historical_corrected_finding
            WHERE correcting_projection_id=? ORDER BY ordinal
            """,
            integers: [stored.correctingProjectionID]
        ) { statement in
            HistoricalStoredCorrectedFindingRow(
                id: sqlite3_column_int64(statement, 0),
                ordinal: Int(sqlite3_column_int64(statement, 1)),
                keyDigest: try correctionData(statement, 2, "corrected.key_digest"),
                draftDigest: try correctionData(statement, 3, "corrected.draft_digest"),
                baselineNodeID: sqlite3_column_int64(statement, 4),
                baselineMetric: sqlite3_column_int64(statement, 5),
                comparisonNodeID: sqlite3_column_int64(statement, 6),
                comparisonMetric: sqlite3_column_int64(statement, 7),
                kind: sqlite3_column_int64(statement, 8),
                inclusiveDelta: sqlite3_column_int64(statement, 9),
                rankingContribution: try historicalOptionalInteger(statement, 10),
                movementAncestorID: try historicalOptionalInteger(statement, 11),
                expiresAt: sqlite3_column_int64(statement, 12)
            )
        }
        guard storedFindings.count == expected.count else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        let idByKey = Dictionary(
            uniqueKeysWithValues: zip(expected, storedFindings).map { ($0.0.draft.key, $0.1.id) }
        )
        for (expectedRow, storedRow) in zip(expected, storedFindings) {
            let expectedAncestorID = expectedRow.movementAncestorKey.flatMap { idByKey[$0] }
            guard storedRow.ordinal == expectedRow.ordinal,
                  storedRow.keyDigest == expectedRow.findingKeyDigest,
                  storedRow.draftDigest == expectedRow.draftDigest,
                  storedRow.baselineNodeID == expectedRow.baselineNodeID,
                  storedRow.baselineMetric == expectedRow.metricCode,
                  storedRow.comparisonNodeID == expectedRow.comparisonNodeID,
                  storedRow.comparisonMetric == expectedRow.metricCode,
                  storedRow.kind == expectedRow.kindCode,
                  storedRow.inclusiveDelta == expectedRow.inclusiveDeltaBytes,
                  storedRow.rankingContribution == expectedRow.rankingContributionBytes,
                  storedRow.movementAncestorID == expectedAncestorID,
                  storedRow.expiresAt == expectedRow.expiresAtMilliseconds else {
                throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
            }
        }

        let ranks = try correctionRows(
            "SELECT rank,corrected_finding_id FROM historical_corrected_positive_rank WHERE correcting_projection_id=? ORDER BY rank",
            integers: [stored.correctingProjectionID]
        ) { statement in
            (Int(sqlite3_column_int64(statement, 0)), sqlite3_column_int64(statement, 1))
        }
        let expectedRanks = try command.expectedResult.batch.rankedPositiveFindingKeys
            .enumerated().map { offset, key in
                (
                    offset + 1,
                    try idByKey[key].correctionUnwrap(field: "corrected_rank_key")
                )
            }
        guard ranks.elementsEqual(expectedRanks, by: { $0.0 == $1.0 && $0.1 == $1.1 }) else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }

        let reasons = try correctionRows(
            "SELECT category,reason_code,count FROM historical_corrected_reason_count WHERE correcting_projection_id=? ORDER BY category,reason_code",
            integers: [stored.correctingProjectionID]
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1),
                sqlite3_column_int64(statement, 2)
            )
        }
        let expectedReasons = try historicalCorrectionReasonRows(command.expectedResult)
        guard reasons.elementsEqual(expectedReasons, by: {
            $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
        }) else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        return stored.correctingProjectionID
    }

    private func historicalStoredCorrectionCommand(
        workID: Int64,
        expectedResult: HistoricalFindingGenerationResult,
        rootProjectionID: HistoricalProjectionRecordID
    ) throws -> (command: HistoricalProjectionCorrectionCommand, requestDigest: Data) {
        let row = try correctionRows(
            """
            SELECT w.request_id,w.canonical_request_sha256,
                   w.predecessor_correcting_projection_id,w.expected_predecessor_sha256,
                   w.algorithm_version,w.ranking_policy_version,
                   w.correction_input_format_version,w.correction_input_sha256,i.canonical_input
            FROM historical_projection_correction_work w
            JOIN historical_correction_input i
              ON i.algorithm_version=w.algorithm_version
             AND i.ranking_policy_version=w.ranking_policy_version
             AND i.input_format_version=w.correction_input_format_version
             AND i.input_sha256=w.correction_input_sha256
            WHERE w.work_id=?
            """,
            integers: [workID]
        ) { statement in
            (
                try correctionData(statement, 0, "correction.request_id"),
                try correctionData(statement, 1, "correction.request_digest"),
                try historicalOptionalInteger(statement, 2),
                try correctionData(statement, 3, "correction.predecessor_digest"),
                Int(sqlite3_column_int64(statement, 4)),
                Int(sqlite3_column_int64(statement, 5)),
                Int(sqlite3_column_int64(statement, 6)),
                try correctionData(statement, 7, "correction.input_digest"),
                try correctionData(statement, 8, "correction.input")
            )
        }.first.correctionUnwrap(field: "historical_correction_work")
        let rootWork = try historicalRootProjectionWork(rootProjectionID)
        let baseline = try correctionReadFrame(sequence: rootWork.baselineSequence)
            .correctionUnwrap(field: "historical_correction_baseline")
        let predecessorSemantic: HistoricalProjectionSemanticIdentity
        if let predecessorID = row.2 {
            let predecessor = try correctionRows(
                """
                SELECT pw.algorithm_version,pw.ranking_policy_version,
                       pw.correction_input_format_version,pw.correction_input_sha256
                FROM historical_correcting_projection p
                JOIN historical_projection_correction_work pw ON pw.work_id=p.work_id
                WHERE p.correcting_projection_id=?
                """,
                integers: [predecessorID]
            ) { statement in
                (
                    Int(sqlite3_column_int64(statement, 0)),
                    Int(sqlite3_column_int64(statement, 1)),
                    Int(sqlite3_column_int64(statement, 2)),
                    try correctionData(statement, 3, "correction.predecessor_input")
                )
            }.first.correctionUnwrap(field: "historical_correction_predecessor")
            predecessorSemantic = try HistoricalProjectionSemanticIdentity(
                algorithmVersion: HistoricalFindingAlgorithmVersion(predecessor.0),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(predecessor.1),
                correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(
                    predecessor.2
                ),
                correctionInputDigest: HistoricalProjectionCorrectionDigest(
                    bytes: Array(predecessor.3)
                )
            )
        } else {
            predecessorSemantic = try HistoricalProjectionSemanticIdentity(
                algorithmVersion: rootWork.algorithmVersion,
                rankingPolicyVersion: rootWork.rankingPolicyVersion,
                correctionInputFormatVersion: nil,
                correctionInputDigest: nil
            )
        }
        guard let baselineRoot = baseline.nodes.first(where: {
            $0.endpoint.subjectID == baseline.rootSubjectID
        }) else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        let scope = baselineRoot.endpoint.scopeID
        let metric = baselineRoot.endpoint.metric
        let reference = try HistoricalProjectionCorrectionReference(
            projectionID: rootProjectionID,
            projectionDigest: HistoricalProjectionCorrectionDigest(bytes: Array(row.3)),
            baselineSequence: rootWork.baselineSequence,
            comparisonSequence: rootWork.comparisonSequence,
            scopeID: scope,
            metric: metric,
            semanticIdentity: predecessorSemantic
        )
        let semantic = try HistoricalProjectionSemanticIdentity(
            algorithmVersion: HistoricalFindingAlgorithmVersion(row.4),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(row.5),
            correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(row.6),
            correctionInputDigest: HistoricalProjectionCorrectionDigest(bytes: Array(row.7))
        )
        let replacement = try HistoricalProjectionReplacement(
            baselineSequence: rootWork.baselineSequence,
            comparisonSequence: rootWork.comparisonSequence,
            scopeID: scope,
            metric: metric,
            semanticIdentity: semantic,
            resultDigest: try historicalProjectionCorrectionResultDigest(expectedResult),
            findingCount: expectedResult.batch.findings.count
        )
        let audit = try HistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: rootProjectionID,
            predecessorCorrectingProjectionID: try row.2.map {
                try HistoricalCorrectingProjectionRecordID($0)
            },
            predecessor: reference,
            positiveLimit: rootWork.positiveLimit
        )
        let command = HistoricalProjectionCorrectionCommand(
            rehydratingStoredRequestID: try HistoricalProjectionCorrectionRequestID(
                bytes: Array(row.0)
            ),
            audit: audit,
            replacement: replacement,
            canonicalInput: row.8,
            expectedResult: expectedResult
        )
        return (command, row.1)
    }

    private func historicalRootProjectionWork(
        _ rootProjectionID: HistoricalProjectionRecordID
    ) throws -> HistoricalProjectionWork {
        let workID = try correctionOptionalInt(
            "SELECT work_id FROM historical_finding_projection WHERE projection_id=?",
            integers: [rootProjectionID.rawValue]
        ).correctionUnwrap(field: "historical_correction_root_work")
        return try correctionReadProjectionWork(id: HistoricalProjectionWorkID(workID))
            .correctionUnwrap(field: "historical_correction_root_work")
    }

    private func historicalCorrectionRequestDigest(
        _ command: HistoricalProjectionCorrectionCommand
    ) throws -> Data {
        var data = Data("SpaceTrace.HistoricalProjectionCorrectionRequest.v1".utf8)
        data.append(0)
        data.append(contentsOf: command.requestID.bytes)
        correctionAppendBigEndian(UInt64(command.rootProjectionID.rawValue), to: &data)
        correctionAppendBigEndian(
            UInt64(command.predecessorCorrectingProjectionID?.rawValue ?? 0),
            to: &data
        )
        data.append(contentsOf: command.predecessor.projectionDigest.bytes)
        correctionAppendBigEndian(
            UInt64(command.predecessor.baselineSequence.rawValue),
            to: &data
        )
        correctionAppendBigEndian(
            UInt64(command.predecessor.comparisonSequence.rawValue),
            to: &data
        )
        historicalCorrectionAppend(Data(command.predecessor.scopeID.rawValue.utf8), to: &data)
        data.append(command.replacement.metric == .logical ? 1 : 2)
        correctionAppendBigEndian(
            UInt64(command.replacement.semanticIdentity.algorithmVersion.rawValue),
            to: &data
        )
        correctionAppendBigEndian(
            UInt64(command.replacement.semanticIdentity.rankingPolicyVersion.rawValue),
            to: &data
        )
        guard let inputFormatVersion =
                command.replacement.semanticIdentity.correctionInputFormatVersion,
              let inputDigest = command.replacement.semanticIdentity.correctionInputDigest else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        correctionAppendBigEndian(
            UInt64(inputFormatVersion.rawValue),
            to: &data
        )
        data.append(contentsOf: inputDigest.bytes)
        historicalCorrectionAppend(command.canonicalInput, to: &data)
        data.append(contentsOf: command.replacement.resultDigest.bytes)
        return Data(SHA256.hash(data: data))
    }

    private func historicalCorrectionAppend(_ value: Data, to data: inout Data) {
        correctionAppendBigEndian(UInt64(value.count), to: &data)
        data.append(value)
    }

    private func historicalCorrectionMetric(_ code: Int64) throws -> StorageMetric {
        switch code {
        case 1: return .logical
        case 2: return .allocated
        default:
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
    }

    private func historicalCorrectionReasonRowCount(
        _ result: HistoricalFindingGenerationResult
    ) -> Int {
        result.suppressionSummary.findingSuppressions.count
            + result.suppressionSummary.rankingExclusions.count
            + result.suppressionSummary.collapses.count
    }

    private func historicalCorrectionReasonRows(
        _ result: HistoricalFindingGenerationResult
    ) throws -> [(Int64, Int64, Int64)] {
        var rows: [(Int64, Int64, Int64)] = []
        for (category, counts) in [
            (Int64(1), result.suppressionSummary.findingSuppressions),
            (Int64(2), result.suppressionSummary.rankingExclusions),
            (Int64(3), result.suppressionSummary.collapses),
        ] {
            for value in counts {
                rows.append((category, try correctionReasonCode(value.reason), Int64(value.count)))
            }
        }
        return rows.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
    }
}

private struct HistoricalCorrectionRootRow {
    let digest: Data
    let baselineSequence: Int64
    let comparisonSequence: Int64
    let algorithmVersion: Int
    let rankingPolicyVersion: Int
    let positiveLimit: Int
    let scopeBytes: Data
    let metricCode: Int64
}

private struct HistoricalCorrectionTerminalRow {
    let correctingProjectionID: Int64
    let digest: Data
    let algorithmVersion: Int
    let rankingPolicyVersion: Int
    let inputFormatVersion: Int
    let inputDigest: Data
    let canonicalInput: Data
    let workID: Int64
}

private struct HistoricalStoredCorrectionRow {
    let requestID: Data
    let requestDigest: Data
    let rootProjectionID: Int64
    let predecessorID: Int64?
    let predecessorDigest: Data
    let algorithmVersion: Int
    let rankingPolicyVersion: Int
    let inputFormatVersion: Int
    let inputDigest: Data
    let canonicalInput: Data
    let correctingProjectionID: Int64
    let resultDigest: Data
    let findingCount: Int
    let rankCount: Int
    let reasonCount: Int
    let truncatedCount: Int
    let committedAt: Int64
    let expiresAt: Int64
    let checkpointAt: Int64
}

private struct HistoricalStoredCorrectedFindingRow {
    let id: Int64
    let ordinal: Int
    let keyDigest: Data
    let draftDigest: Data
    let baselineNodeID: Int64
    let baselineMetric: Int64
    let comparisonNodeID: Int64
    let comparisonMetric: Int64
    let kind: Int64
    let inclusiveDelta: Int64
    let rankingContribution: Int64?
    let movementAncestorID: Int64?
    let expiresAt: Int64
}

private extension Optional {
    func correctionUnwrap(field: String) throws -> Wrapped {
        guard let self else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        return self
    }
}
