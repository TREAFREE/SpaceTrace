import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceDomain

extension SQLiteEventJournalRepository {
    public func versionedEffectiveHistoricalFindings(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) async throws -> [VersionedEffectiveHistoricalFinding] {
        let roots = try historicalVersionedProjectionRoots(
            scopeID: scopeID,
            through: comparisonSequence
        )
        var values: [VersionedEffectiveHistoricalFinding] = []
        for root in roots {
            try Task.checkCancellation()
            let correctionAudit = try readHistoricalProjectionCorrectionAuditRecord(
                rootProjectionID: root,
                validateTerminalResult: true
            ).versionedQueryUnwrap(field: "versioned.root_projection")
            if let terminalID = correctionAudit.predecessorCorrectingProjectionID {
                let terminal = try historicalValidatedCorrectedProjectionAuditRecords(
                    rootProjectionID: root,
                    correctingProjectionID: terminalID
                )
                values.append(contentsOf: terminal.lazy.filter { $0.retraction == nil }.map(\.finding))
            } else {
                let original = try await historicalVersionedOriginalAuditRecords(
                    projectionID: root
                )
                values.append(contentsOf: original.lazy.filter { $0.retraction == nil }.map(\.finding))
            }
        }
        values.sort(by: historicalVersionedEffectiveOrder)
        return Array(values.prefix(limit.rawValue))
    }

    public func versionedHistoricalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) async throws -> [VersionedHistoricalFindingAuditRecord] {
        let values = try await historicalVersionedAuditRecords(
            scopeID: scopeID,
            through: comparisonSequence
        )
        return Array(values.prefix(limit.rawValue))
    }

    public func versionedEvidenceInvalidatedHistoricalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) async throws -> [VersionedHistoricalFindingAuditRecord] {
        let values = try await historicalVersionedAuditRecords(
            scopeID: scopeID,
            through: comparisonSequence
        ).filter { $0.retraction != nil }
        return Array(values.prefix(limit.rawValue))
    }

    private func historicalVersionedAuditRecords(
        scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence
    ) async throws -> [VersionedHistoricalFindingAuditRecord] {
        let roots = try historicalVersionedProjectionRoots(
            scopeID: scopeID,
            through: comparisonSequence
        )
        var values: [VersionedHistoricalFindingAuditRecord] = []
        for root in roots {
            try Task.checkCancellation()
            _ = try readHistoricalProjectionCorrectionAuditRecord(
                rootProjectionID: root,
                validateTerminalResult: true
            ).versionedQueryUnwrap(field: "versioned.root_projection")
            values.append(contentsOf: try await historicalVersionedOriginalAuditRecords(
                projectionID: root
            ))
            for correctingID in try historicalCorrectingProjectionIDs(
                rootProjectionID: root
            ) {
                values.append(
                    contentsOf: try historicalValidatedCorrectedProjectionAuditRecords(
                        rootProjectionID: root,
                        correctingProjectionID: correctingID
                    )
                )
            }
        }
        values.sort(by: historicalVersionedAuditOrder)
        return values
    }

    private func historicalVersionedProjectionRoots(
        scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence
    ) throws -> [HistoricalProjectionRecordID] {
        let rows = try correctionRows(
            """
            SELECT projection.projection_id
            FROM historical_finding_projection projection
            JOIN historical_projection_work work ON work.work_id=projection.work_id
            JOIN historical_projection_checkpoint checkpoint ON checkpoint.work_id=work.work_id
            JOIN historical_observation_frame_commit comparison
              ON comparison.sequence=work.comparison_sequence
            JOIN historical_observation_frame frame ON frame.frame_id=comparison.frame_id
            JOIN historical_observation_batch batch ON batch.batch_id=frame.batch_id
            JOIN historical_scope scope ON scope.scope_key=batch.scope_key
            WHERE work.comparison_sequence<=? AND scope.scope_id=?
            GROUP BY projection.projection_id
            ORDER BY work.comparison_sequence DESC,projection.projection_id
            """,
            integers: [comparisonSequence.rawValue],
            blobs: [Data(scopeID.rawValue.utf8)]
        ) { statement in
            try HistoricalProjectionRecordID(sqlite3_column_int64(statement, 0))
        }
        guard Set(rows).count == rows.count else {
            throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
        }
        return rows
    }

    private func historicalCorrectingProjectionIDs(
        rootProjectionID: HistoricalProjectionRecordID
    ) throws -> [HistoricalCorrectingProjectionRecordID] {
        try correctionRows(
            """
            SELECT projection.correcting_projection_id
            FROM historical_projection_correction_work work
            JOIN historical_correcting_projection projection ON projection.work_id=work.work_id
            JOIN historical_projection_correction_checkpoint checkpoint
              ON checkpoint.correcting_projection_id=projection.correcting_projection_id
            WHERE work.root_projection_id=?
            ORDER BY projection.correcting_projection_id
            """,
            integers: [rootProjectionID.rawValue]
        ) { statement in
            try HistoricalCorrectingProjectionRecordID(sqlite3_column_int64(statement, 0))
        }
    }

    private func historicalVersionedOriginalAuditRecords(
        projectionID: HistoricalProjectionRecordID
    ) async throws -> [VersionedHistoricalFindingAuditRecord] {
        let findingIDs = try correctionRows(
            "SELECT finding_id FROM historical_finding WHERE projection_id=? ORDER BY ordinal",
            integers: [projectionID.rawValue]
        ) { statement in
            try HistoricalFindingRecordID(sqlite3_column_int64(statement, 0))
        }
        var records: [VersionedHistoricalFindingAuditRecord] = []
        records.reserveCapacity(findingIDs.count)
        for findingID in findingIDs {
            try Task.checkCancellation()
            let record = try self.historicalFindingAuditRecord(id: findingID)
                .versionedQueryUnwrap(field: "versioned.original_finding")
            guard record.finding.projectionID == projectionID else {
                throw SQLiteEventJournalError.historicalCorrectionImmutableConflict
            }
            records.append(try VersionedHistoricalFindingAuditRecord(original: record))
        }
        return records
    }
}

private func historicalVersionedEffectiveOrder(
    _ lhs: VersionedEffectiveHistoricalFinding,
    _ rhs: VersionedEffectiveHistoricalFinding
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
        if lhs.projectionID != rhs.projectionID {
            return lhs.projectionID < rhs.projectionID
        }
        return lhs.recordID < rhs.recordID
    }
}

private func historicalVersionedAuditOrder(
    _ lhs: VersionedHistoricalFindingAuditRecord,
    _ rhs: VersionedHistoricalFindingAuditRecord
) -> Bool {
    if lhs.finding.comparisonSequence != rhs.finding.comparisonSequence {
        return lhs.finding.comparisonSequence > rhs.finding.comparisonSequence
    }
    if lhs.finding.projectionID != rhs.finding.projectionID {
        return lhs.finding.projectionID < rhs.finding.projectionID
    }
    return lhs.finding.recordID < rhs.finding.recordID
}

private extension Optional {
    func versionedQueryUnwrap(field: String) throws -> Wrapped {
        guard let self else {
            throw SQLiteEventJournalError.corruptStoredValue(field: field)
        }
        return self
    }
}
