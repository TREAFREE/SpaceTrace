import CryptoKit
import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceDomain

extension SQLiteEventJournalRepository:
    HistoricalCorrectedFindingIntegrityReconciliationRepository
{
    package func historicalCorrectedFindingIntegrityAuditRecord(
        id: HistoricalCorrectedFindingRecordID
    ) async throws -> HistoricalCorrectedFindingIntegrityAuditRecord? {
        try readHistoricalCorrectedFindingIntegrityAuditRecord(id: id)
    }

    package func commitCorrectedEvidenceInvalidation(
        _ command: HistoricalCorrectedFindingEvidenceInvalidationCommand
    ) async throws -> HistoricalCorrectedRetractionCommitOutcome {
        let requestDigest = historicalCorrectedRetractionRequestDigest(command)
        try execute(
            "BEGIN IMMEDIATE TRANSACTION",
            operation: "begin corrected finding retraction"
        )
        var responseLostAfterCommit = false
        do {
            if let existing = try readHistoricalCorrectedRetraction(
                requestID: command.requestID
            ) {
                guard existing.canonicalRequestDigest == requestDigest,
                      existing.record.findingID == command.findingID,
                      existing.expectedDraftDigest
                        == Data(command.expectedDraftSHA256.bytes) else {
                    throw SQLiteEventJournalError
                        .historicalCorrectedRetractionImmutableConflict
                }
                try execute(
                    "COMMIT TRANSACTION",
                    operation: "commit idempotent corrected finding retraction"
                )
                return .alreadyCommitted(existing.record)
            }

            guard let audit = try readHistoricalCorrectedFindingIntegrityAuditRecord(
                id: command.findingID
            ) else {
                throw SQLiteEventJournalError.historicalCorrectedRetractionTargetNotFound
            }
            guard audit.draftSHA256 == command.expectedDraftSHA256 else {
                throw SQLiteEventJournalError
                    .historicalCorrectedRetractionExpectedDigestMismatch
            }
            guard audit.retraction == nil else {
                throw SQLiteEventJournalError
                    .historicalCorrectedRetractionImmutableConflict
            }
            let target = try historicalCorrectedRetractionTarget(id: command.findingID)
                .correctedRetractionUnwrap()
            let committedAt = Self.correctionMilliseconds(now())
            guard committedAt <= target.expiresAtMilliseconds else {
                throw SQLiteEventJournalError.historicalCorrectedRetractionTargetExpired
            }
            try correctionExecuteNullable(
                """
                INSERT INTO historical_corrected_finding_retraction(
                    request_format_version,request_id,canonical_request_sha256,
                    retracted_corrected_finding_id,expected_draft_sha256,
                    reason_code,committed_at_ms,expires_at_ms
                ) VALUES(1,?,?,?,?,1,?,?)
                """,
                values: [
                    .blob(Data(command.requestID.bytes)),
                    .blob(requestDigest),
                    .integer(command.findingID.rawValue),
                    .blob(Data(command.expectedDraftSHA256.bytes)),
                    .integer(committedAt),
                    .integer(target.expiresAtMilliseconds),
                ]
            )
            if injectedFailurePoint == .beforeHistoricalCorrectedRetractionCommit {
                injectedFailurePoint = nil
                throw SQLiteEventJournalError.injectedFailure
            }
            let committed = try readHistoricalCorrectedRetraction(
                requestID: command.requestID
            ).correctedRetractionUnwrap()
            guard committed.canonicalRequestDigest == requestDigest,
                  committed.record.findingID == command.findingID,
                  committed.expectedDraftDigest
                    == Data(command.expectedDraftSHA256.bytes) else {
                throw SQLiteEventJournalError
                    .historicalCorrectedRetractionImmutableConflict
            }
            try execute(
                "COMMIT TRANSACTION",
                operation: "commit corrected finding retraction"
            )
            if injectedFailurePoint
                == .afterHistoricalCorrectedRetractionCommitBeforeReturningReceipt
            {
                injectedFailurePoint = nil
                responseLostAfterCommit = true
                throw SQLiteEventJournalError.injectedFailure
            }
            return .newlyCommitted(committed.record)
        } catch SQLiteEventJournalError.injectedFailure where responseLostAfterCommit {
            throw SQLiteEventJournalError.injectedFailure
        } catch {
            try rollback(after: error)
        }
    }

    private func readHistoricalCorrectedFindingIntegrityAuditRecord(
        id: HistoricalCorrectedFindingRecordID
    ) throws -> HistoricalCorrectedFindingIntegrityAuditRecord? {
        guard let target = try historicalCorrectedRetractionTarget(id: id) else {
            return nil
        }
        let rootProjectionID = try HistoricalProjectionRecordID(target.rootProjectionID)
        guard let terminal = try readHistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: rootProjectionID,
            validateTerminalResult: true
        ), terminal.predecessorCorrectingProjectionID?.rawValue
            == target.correctingProjectionID else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        let retraction = try readHistoricalCorrectedRetraction(findingID: id)?.record
        return try HistoricalCorrectedFindingIntegrityAuditRecord(
            findingID: id,
            projectionID: HistoricalCorrectingProjectionRecordID(
                target.correctingProjectionID
            ),
            draftSHA256: HistoricalEvidenceDigest(bytes: Array(target.draftDigest)),
            retraction: retraction
        )
    }

    private func historicalCorrectedRetractionTarget(
        id: HistoricalCorrectedFindingRecordID
    ) throws -> HistoricalCorrectedRetractionTarget? {
        let rows = try correctionRows(
            """
            SELECT finding.draft_sha256,finding.expires_at_ms,
                   projection.correcting_projection_id,work.root_projection_id
            FROM historical_corrected_finding finding
            JOIN historical_correcting_projection projection
              ON projection.correcting_projection_id=finding.correcting_projection_id
            JOIN historical_projection_correction_work work
              ON work.work_id=projection.work_id
            JOIN historical_projection_correction_checkpoint checkpoint
              ON checkpoint.correcting_projection_id=projection.correcting_projection_id
            WHERE finding.corrected_finding_id=?
              AND NOT EXISTS(
                  SELECT 1
                  FROM historical_projection_correction_work successor_work
                  JOIN historical_correcting_projection successor
                    ON successor.work_id=successor_work.work_id
                  JOIN historical_projection_correction_checkpoint successor_checkpoint
                    ON successor_checkpoint.correcting_projection_id=
                       successor.correcting_projection_id
                  WHERE successor_work.predecessor_correcting_projection_id=
                        projection.correcting_projection_id
              )
            """,
            integers: [id.rawValue]
        ) { statement in
            HistoricalCorrectedRetractionTarget(
                draftDigest: try correctionData(
                    statement,
                    0,
                    "corrected_retraction.draft_digest"
                ),
                expiresAtMilliseconds: sqlite3_column_int64(statement, 1),
                correctingProjectionID: sqlite3_column_int64(statement, 2),
                rootProjectionID: sqlite3_column_int64(statement, 3)
            )
        }
        guard rows.count <= 1 else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        guard let row = rows.first else { return nil }
        guard row.draftDigest.count == 32, row.expiresAtMilliseconds >= 0 else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        return row
    }

    private func readHistoricalCorrectedRetraction(
        requestID: HistoricalRetractionRequestID
    ) throws -> HistoricalStoredCorrectedRetraction? {
        try readHistoricalCorrectedRetraction(
            sql: """
            SELECT corrected_retraction_sequence,request_id,
                   canonical_request_sha256,retracted_corrected_finding_id,
                   expected_draft_sha256,reason_code,committed_at_ms,expires_at_ms
            FROM historical_corrected_finding_retraction WHERE request_id=?
            """,
            blobs: [Data(requestID.bytes)]
        )
    }

    private func readHistoricalCorrectedRetraction(
        findingID: HistoricalCorrectedFindingRecordID
    ) throws -> HistoricalStoredCorrectedRetraction? {
        try readHistoricalCorrectedRetraction(
            sql: """
            SELECT corrected_retraction_sequence,request_id,
                   canonical_request_sha256,retracted_corrected_finding_id,
                   expected_draft_sha256,reason_code,committed_at_ms,expires_at_ms
            FROM historical_corrected_finding_retraction
            WHERE retracted_corrected_finding_id=?
            """,
            integers: [findingID.rawValue]
        )
    }

    private func readHistoricalCorrectedRetraction(
        sql: String,
        integers: [Int64] = [],
        blobs: [Data] = []
    ) throws -> HistoricalStoredCorrectedRetraction? {
        let rows = try correctionRows(sql, integers: integers, blobs: blobs) { statement in
            let requestID = try HistoricalRetractionRequestID(
                bytes: Array(
                    correctionData(statement, 1, "corrected_retraction.request_id")
                )
            )
            let canonicalDigest = try correctionData(
                statement,
                2,
                "corrected_retraction.request_digest"
            )
            let expectedDigest = try correctionData(
                statement,
                4,
                "corrected_retraction.expected_digest"
            )
            guard canonicalDigest.count == 32,
                  expectedDigest.count == 32,
                  sqlite3_column_int64(statement, 5) == 1 else {
                throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
            }
            let record = try HistoricalCorrectedFindingRetractionRecord(
                recordID: HistoricalCorrectedRetractionRecordID(
                    sqlite3_column_int64(statement, 0)
                ),
                requestID: requestID,
                findingID: HistoricalCorrectedFindingRecordID(
                    sqlite3_column_int64(statement, 3)
                ),
                reason: .evidenceInvalidated,
                committedAt: ObservationInstant(
                    millisecondsSince1970: sqlite3_column_int64(statement, 6)
                ),
                expiresAt: ObservationInstant(
                    millisecondsSince1970: sqlite3_column_int64(statement, 7)
                )
            )
            return HistoricalStoredCorrectedRetraction(
                record: record,
                canonicalRequestDigest: canonicalDigest,
                expectedDraftDigest: expectedDigest
            )
        }
        guard rows.count <= 1 else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        return rows.first
    }

    private func historicalCorrectedRetractionRequestDigest(
        _ command: HistoricalCorrectedFindingEvidenceInvalidationCommand
    ) -> Data {
        var canonical = Data("SpaceTrace.HistoricalCorrectedFindingRetractionRequest.v1".utf8)
        canonical.append(0)
        canonical.append(contentsOf: command.requestID.bytes)
        correctionAppendBigEndian(UInt64(command.findingID.rawValue), to: &canonical)
        canonical.append(contentsOf: command.expectedDraftSHA256.bytes)
        canonical.append(1)
        return Data(SHA256.hash(data: canonical))
    }
}

private struct HistoricalCorrectedRetractionTarget {
    let draftDigest: Data
    let expiresAtMilliseconds: Int64
    let correctingProjectionID: Int64
    let rootProjectionID: Int64
}

private struct HistoricalStoredCorrectedRetraction {
    let record: HistoricalCorrectedFindingRetractionRecord
    let canonicalRequestDigest: Data
    let expectedDraftDigest: Data
}

private extension Optional {
    func correctedRetractionUnwrap() throws -> Wrapped {
        guard let self else {
            throw SQLiteEventJournalError.historicalCorrectedRetractionImmutableConflict
        }
        return self
    }
}
