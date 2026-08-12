import Foundation
import SQLite3
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite reconciliation revision publication", .serialized)
struct SQLiteReconciliationRevisionTests {
    @Test("A complete calibration atomically publishes both revision buckets")
    func completeCalibrationPublishesRevisions() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        let outcome = try await repository.finalizeCalibrationWithHistoricalFrames(
            prepared.request
        )
        let commit = try publishedCommit(outcome)
        let rootSubject = try SubjectID("root")
        let childSubject = try SubjectID("child")

        #expect(commit.reconciliationRevisions.count == 4)
        #expect(commit.reconciliationRevisions.contains { $0.key.bucket == .hourly })
        #expect(commit.reconciliationRevisions.contains { $0.key.bucket == .daily })
        #expect(commit.reconciliationRevisions.allSatisfy { $0.predecessorID == nil })
        #expect(commit.reconciliationRevisions.map(\.id).sorted() == commit.reconciliationRevisions.map(\.id))
        #expect(try fixture.count("historical_reconciliation_revision") == 2)
        #expect(try fixture.count("historical_observation_frame_commit") == 2)
        #expect(try fixture.count("directory_history_sample") == 4)
        #expect(try fixture.count("node_current") == 2)
        #expect(try fixture.int("SELECT count(*) FROM scan_run WHERE state='completed'") == 1)
        #expect(
            commit.reconciliationRevisions.first(where: {
                $0.key.subjectID == rootSubject && $0.key.bucket == .daily
            })?.descendantCount == 1
        )
        #expect(
            commit.reconciliationRevisions.first(where: {
                $0.key.subjectID == childSubject && $0.key.bucket == .daily
            })?.descendantCount == 0
        )
        try await repository.close()
    }

    @Test("A later complete scan in the same buckets appends one linear successor per key")
    func sameBucketSuccessorsAndClockRollback() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(for: fixture)
        let firstPrepared = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000
        )
        let first = try publishedCommit(
            try await repository.finalizeCalibrationWithHistoricalFrames(firstPrepared.request)
        )

        let secondPrepared = try await prepareHistoricalLedgerRun(
            repository: repository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            child: .present(logical: 50, allocated: 40),
            observedAtMilliseconds: 2_000_000_050_000
        )
        let second = try publishedCommit(
            try await repository.finalizeCalibrationWithHistoricalFrames(secondPrepared.request)
        )

        #expect(try fixture.count("historical_reconciliation_revision") == 4)
        #expect(second.reconciliationRevisions.count == first.reconciliationRevisions.count)
        let firstByKey = Dictionary(uniqueKeysWithValues: first.reconciliationRevisions.map {
            ($0.key, $0)
        })
        for successor in second.reconciliationRevisions {
            let predecessor = try #require(firstByKey[successor.key])
            #expect(successor.predecessorID == predecessor.id)
            #expect(successor.sequence > predecessor.sequence)
            #expect(successor.observedAt < predecessor.observedAt)
        }
        #expect(try fixture.int("SELECT count(*) FROM historical_reconciliation_revision WHERE hourly_predecessor_node_id IS NOT NULL") == 2)
        #expect(try fixture.int("SELECT count(*) FROM historical_reconciliation_revision WHERE daily_predecessor_node_id IS NOT NULL") == 2)
        try await repository.close()
    }

    @Test("A same-bucket chain expires atomically at its original boundary")
    func chainUsesSharedExpiry() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(for: fixture)
        let firstObserved: Int64 = 2_000_000_100_000
        let first = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: firstObserved
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
        let successor = try await prepareHistoricalLedgerRun(
            repository: repository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            child: .present(logical: 50, allocated: 40),
            observedAtMilliseconds: firstObserved + 50_000
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(successor.request)
        #expect(try fixture.count("historical_reconciliation_revision") == 4)

        _ = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(firstObserved + 2_592_000_001) / 1_000
            )
        )

        #expect(try fixture.count("historical_reconciliation_revision") == 0)
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)
        try await repository.close()
    }

    @Test("A dirty revision race publishes neither frames nor revisions")
    func dirtyRevisionRaceSuppressesPublication() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        try await repository.markDirty(
            streamID: prepared.streamID,
            regions: [prepared.workItem.region]
        )

        #expect(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
                == .superseded
        )
        #expect(try fixture.count("historical_reconciliation_revision") == 0)
        #expect(try fixture.count("historical_observation_frame_commit") == 0)
        #expect(try fixture.count("node_current") == 0)
        #expect(try fixture.count("dirty_region") == 1)
        try await repository.close()
    }

    @Test("ACK loss retry returns the exact prior revision identities without duplication")
    func acknowledgmentLossIsIdempotent() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(
            for: fixture,
            failurePoint: .afterCalibrationCommitBeforeReturningReceipt
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        }
        let retry = try publishedCommit(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        )

        #expect(retry.disposition == .alreadyCommitted)
        #expect(retry.reconciliationRevisions.count == 4)
        #expect(try fixture.count("historical_reconciliation_revision") == 2)
        #expect(try fixture.count("historical_calibration_receipt") == 1)
        try await repository.close()
    }

    @Test("Failure after revision insertion rolls the entire publication back")
    func injectedFailureRollsBackEverything() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(
            for: fixture,
            failurePoint: .afterHistoricalReconciliationRevisions
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        }
        #expect(try fixture.count("historical_reconciliation_revision") == 0)
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.count("historical_calibration_receipt") == 0)
        #expect(try fixture.count("directory_history_sample") == 0)
        #expect(try fixture.count("node_current") == 0)
        #expect(try fixture.count("dirty_region") == 1)
        #expect(try fixture.int("SELECT count(*) FROM scan_run WHERE state='running'") == 1)
        try await repository.close()
    }

    @Test("History Off and discarded runs never append reconciliation authority")
    func unavailableRunsAppendNoRevisions() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(for: fixture)
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        let disabled = try await prepareHistoricalLedgerRun(repository: repository)
        #expect(
            try await repository.finalizeCalibrationWithHistoricalFrames(disabled.request)
                == .historyDisabled
        )

        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 30)
        )
        let discarded = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000
        )
        try await repository.discardCalibration(
            discarded.runID,
            disposition: .partial,
            report: nil
        )

        #expect(try fixture.count("historical_reconciliation_revision") == 0)
        #expect(try fixture.count("historical_observation_batch") == 0)
        try await repository.close()
    }

    @Test(
        "Every non-complete terminal disposition appends no revisions",
        arguments: [
            CalibrationRunDisposition.partial,
            .cancelled,
            .failed,
        ]
    )
    func discardedDispositionAppendsNoRevision(
        disposition: CalibrationRunDisposition
    ) async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        try await repository.discardCalibration(
            prepared.runID,
            disposition: disposition,
            report: nil
        )

        #expect(try fixture.count("historical_reconciliation_revision") == 0)
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.count("node_current") == 0)
        #expect(try fixture.count("dirty_region") == 1)
        try await repository.close()
    }

    @Test("Already-expired evidence cannot publish a revision or current truth")
    func expiredEvidenceAppendsNoRevision() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try revisionRepository(
            for: fixture,
            nowSeconds: 2_002_592_000.001
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        await #expect(throws: SQLiteEventJournalError.historicalCandidateExpired) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        }
        #expect(try fixture.count("historical_reconciliation_revision") == 0)
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.count("node_current") == 0)
        #expect(try fixture.count("dirty_region") == 1)
        try await repository.close()
    }

    @Test("History Off deletes a released correction graph in dependency order")
    func historyOffDeletesReleasedCorrectionGraph() async throws {
        let fixture = try ReleasedV12CorrectionFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        #expect(try fixture.count("historical_correcting_projection") == 1)
        #expect(try fixture.count("historical_reconciliation_revision") == 4)

        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )

        for table in [
            "historical_projection_correction_checkpoint",
            "historical_corrected_positive_rank",
            "historical_corrected_reason_count",
            "historical_corrected_finding",
            "historical_correcting_projection",
            "historical_projection_correction_work",
            "historical_correction_input",
            "historical_reconciliation_revision",
            "historical_observation_batch",
        ] {
            #expect(try fixture.count(table) == 0)
        }
        #expect(try fixture.scalar("PRAGMA foreign_key_check") == nil)
        try await repository.close()
    }
}

private func revisionRepository(
    for fixture: HistoricalLedgerTestFixture,
    failurePoint: SQLiteEventJournalTestFailurePoint? = nil,
    nowSeconds: Double = 2_000_000_200
) throws -> SQLiteEventJournalRepository {
    try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: failurePoint,
        now: { Date(timeIntervalSince1970: nowSeconds) },
        historicalStoreGenerationProvider: { Array(repeating: 0x31, count: 16) }
    )
}

private func publishedCommit(
    _ outcome: HistoricalCalibrationFinalizationOutcome
) throws -> HistoricalCalibrationCommit {
    guard case let .published(commit) = outcome else {
        throw ReconciliationRevisionTestError.expectedPublished
    }
    return commit
}

private enum ReconciliationRevisionTestError: Error {
    case expectedPublished
}

private struct ReleasedV12CorrectionFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        let source = try #require(
            Bundle.module.url(
                forResource: "SpaceTrace",
                withExtension: "sqlite",
                subdirectory: "Fixtures/ReleasedSchemas/v12"
            )
        )
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v12-retention-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        databaseURL = directoryURL.appendingPathComponent("SpaceTrace.sqlite")
        try FileManager.default.copyItem(at: source, to: databaseURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func count(_ table: String) throws -> Int64 {
        try #require(try scalar("SELECT count(*) FROM \(table)"))
    }

    func scalar(_ sql: String) throws -> Int64? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw ReconciliationRevisionTestError.expectedPublished
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ReconciliationRevisionTestError.expectedPublished
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }
}
