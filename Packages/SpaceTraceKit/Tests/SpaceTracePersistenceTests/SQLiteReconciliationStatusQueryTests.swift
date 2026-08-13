import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite reconciliation status query", .serialized)
struct SQLiteReconciliationStatusQueryTests {
    @Test("Current and pending states survive repository reopen with typed revisions")
    func currentAndPendingSurviveReopen() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try statusRepository(for: fixture)
        try await installStatusBookmark(in: repository)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        let commit = try statusPublishedCommit(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        )
        let expectedSuccessSequence = try #require(
            commit.reconciliationRevisions.map(\.sequence).max()
        )

        let current = try await repository.durableReconciliationStatus(
            for: WatchedScopeID("scope-fixture")
        )
        guard case .current(let success) = current.state else {
            Issue.record("Expected current reconciliation status")
            return
        }
        #expect(success.sequence == expectedSuccessSequence)
        #expect(success.completedAt.millisecondsSince1970 == 2_000_000_200_000)

        try await repository.markDirty(
            streamID: prepared.streamID,
            regions: [prepared.workItem.region]
        )
        let pendingWork = try #require(
            try await repository.pendingDirtyWork(for: prepared.streamID, limit: 1).first
        )
        let pending = try await repository.durableReconciliationStatus(
            for: WatchedScopeID("scope-fixture")
        )
        guard case let .pending(lastSuccess, revision, pendingSince) = pending.state else {
            Issue.record("Expected pending reconciliation status")
            return
        }
        #expect(lastSuccess?.sequence == expectedSuccessSequence)
        #expect(revision == pendingWork.revision)
        #expect(pendingSince != nil)
        try await repository.close()

        let reopened = try statusRepository(for: fixture)
        let restored = try await reopened.durableReconciliationStatus(
            for: WatchedScopeID("scope-fixture")
        )
        #expect(restored == pending)
        try await reopened.close()
    }

    @Test(
        "Terminal incomplete scans remain distinct from pending cancellation",
        arguments: [
            CalibrationRunDisposition.partial,
            .failed,
            .cancelled,
        ]
    )
    func incompleteAttemptStatus(
        disposition: CalibrationRunDisposition
    ) async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try statusRepository(for: fixture)
        try await installStatusBookmark(in: repository)
        let baseline = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(baseline.request)
        let attempt = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000
        )
        try await repository.discardCalibration(
            attempt.runID,
            disposition: disposition,
            report: nil
        )

        let status = try await repository.durableReconciliationStatus(
            for: WatchedScopeID("scope-fixture")
        )
        switch (disposition, status.state) {
        case let (.partial, .partial(lastSuccess, revision, attemptedAt)):
            #expect(lastSuccess != nil)
            #expect(revision == attempt.workItem.revision)
            #expect(attemptedAt.millisecondsSince1970 == 2_000_000_200_000)
        case let (.failed, .failed(lastSuccess, revision, attemptedAt)):
            #expect(lastSuccess != nil)
            #expect(revision == attempt.workItem.revision)
            #expect(attemptedAt.millisecondsSince1970 == 2_000_000_200_000)
        case let (.cancelled, .pending(lastSuccess, revision, pendingSince)):
            #expect(lastSuccess != nil)
            #expect(revision == attempt.workItem.revision)
            #expect(pendingSince != nil)
        default:
            Issue.record(
                "Unexpected reconciliation status for \(disposition): \(String(reflecting: status.state))"
            )
        }
        try await repository.close()
    }

    @Test("History Off and re-enable before a fresh baseline are explicit durable states")
    func historyPolicyStates() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try statusRepository(for: fixture)
        try await installStatusBookmark(in: repository)
        let baseline = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(baseline.request)

        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        #expect(
            try await repository.durableReconciliationStatus(
                for: WatchedScopeID("scope-fixture")
            ).state == .historyDisabled
        )
        try await repository.close()

        let reopened = try statusRepository(for: fixture)
        #expect(
            try await reopened.durableReconciliationStatus(
                for: WatchedScopeID("scope-fixture")
            ).state == .historyDisabled
        )
        try await reopened.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 30)
        )
        #expect(
            try await reopened.durableReconciliationStatus(
                for: WatchedScopeID("scope-fixture")
            ).state == .baselineUnavailable
        )
        try await reopened.close()
    }

    @Test("A path-free aged requirement remains pending without inventing a revision")
    func pathFreePendingStatus() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try statusRepository(for: fixture)
        try await installStatusBookmark(in: repository)
        let baseline = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(baseline.request)
        try await repository.close()

        try fixture.execute(
            """
            INSERT INTO path_free_calibration_requirement(
                stream_id,scope_id,reasons,created_at_ms,updated_at_ms
            ) VALUES('historical-ledger-stream','scope-fixture',1,1234,5678);
            """
        )
        let reopened = try statusRepository(for: fixture)
        let status = try await reopened.durableReconciliationStatus(
            for: WatchedScopeID("scope-fixture")
        )
        guard case let .pending(lastSuccess, revision, pendingSince) = status.state else {
            Issue.record("Expected path-free pending status")
            return
        }
        #expect(lastSuccess != nil)
        #expect(revision == nil)
        #expect(pendingSince?.millisecondsSince1970 == 5_678)
        try await reopened.close()
    }
}

private func statusRepository(
    for fixture: HistoricalLedgerTestFixture
) throws -> SQLiteEventJournalRepository {
    try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: nil,
        now: { Date(timeIntervalSince1970: 2_000_000_200) },
        historicalStoreGenerationProvider: { Array(repeating: 0x51, count: 16) }
    )
}

private func installStatusBookmark(
    in repository: SQLiteEventJournalRepository
) async throws {
    try await repository.upsertWatchedScopeBookmark(
        WatchedScopeBookmark(
            scopeID: WatchedScopeID("scope-fixture"),
            bookmarkData: Data([0x51]),
            expectedRoot: DirtyRegionPath("/Fixtures"),
            expectedVolumeUUID: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!
        )
    )
}

private func statusPublishedCommit(
    _ outcome: HistoricalCalibrationFinalizationOutcome
) throws -> HistoricalCalibrationCommit {
    guard case .published(let commit) = outcome else {
        throw SQLiteReconciliationStatusTestError.expectedPublished
    }
    return commit
}

private enum SQLiteReconciliationStatusTestError: Error {
    case expectedPublished
}
