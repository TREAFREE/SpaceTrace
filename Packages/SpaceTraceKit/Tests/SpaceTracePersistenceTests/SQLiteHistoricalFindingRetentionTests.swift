import Foundation
import SQLite3
@testable import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite historical ledger retention and History Off", .serialized)
struct SQLiteHistoricalFindingRetentionTests {
    @Test("The persisted 0...30 day policy survives reopen")
    func policyPersistsAcrossReopen() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        var repository = try retentionRepository(for: fixture)

        #expect(
            try await repository.historicalPathHistoryPolicy()
                == HistoricalPathHistoryPolicy(retentionDays: 30)
        )
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("scope-fixture")
            ) == .historyDisabled
        )
        try await repository.applyStorageHistoryRetention(
            referenceDate: Date(timeIntervalSince1970: 2_000_000_020)
        )
        #expect(
            try await repository.historicalPathHistoryPolicy()
                == HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        try await repository.close()

        repository = try retentionRepository(for: fixture)
        #expect(
            try await repository.historicalPathHistoryPolicy()
                == HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("scope-fixture")
            ) == .historyDisabled
        )
        try await repository.close()
    }

    @Test("History Off publishes current truth without writing either history format")
    func historyOffSuppressesLegacyAndPairedHistory() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )

        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        let first = try await repository.finalizeCalibrationWithHistoricalFrames(
            prepared.request
        )
        #expect(first == .historyDisabled)
        #expect(try fixture.count("historical_disabled_calibration_receipt") == 1)
        #expect(try fixture.count("historical_calibration_receipt") == 0)
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.count("directory_history_sample") == 0)
        #expect(try fixture.count("node_current") == 2)
        #expect(try fixture.count("dirty_region") == 0)

        let retry = try await repository.finalizeCalibrationWithHistoricalFrames(
            prepared.request
        )
        #expect(retry == .historyDisabled)
        #expect(try fixture.count("historical_disabled_calibration_receipt") == 1)
        #expect(try fixture.count("node_current") == 2)
        try await repository.close()
    }

    @Test("Re-enabling history requires a fresh committed baseline")
    func availabilityRequiresFreshPostEnableBaseline() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
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
        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("scope-fixture")
            ) == .baselineUnavailable
        )

        let baseline = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000
        )
        guard case .published = try await repository
            .finalizeCalibrationWithHistoricalFrames(baseline.request) else {
            Issue.record("Expected a fresh historical baseline after re-enabling history.")
            return
        }
        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("scope-fixture")
            ) == .available
        )
        try await repository.close()
    }

    @Test("The observation-anchored hard boundary retains 30 days and expires at 30 days plus 1 ms")
    func exactThirtyDayBoundary() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        let observedAt: Int64 = 2_000_000_000_000
        let baseline = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: observedAt
        )
        guard case .published = try await repository
            .finalizeCalibrationWithHistoricalFrames(baseline.request) else {
            Issue.record("Expected a committed baseline.")
            return
        }

        _ = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(observedAt + 2_592_000_000) / 1_000
            )
        )
        #expect(try fixture.count("historical_observation_batch") == 1)

        _ = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(observedAt + 2_592_000_001) / 1_000
            )
        )
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)
        try await repository.close()
    }

    @Test("The first historical read performs overdue startup retention")
    func firstHistoricalReadRunsStartupRetention() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let observedAt: Int64 = 2_000_000_000_000
        var repository = try retentionRepository(for: fixture)
        let baseline = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: observedAt
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(baseline.request)
        try await repository.close()

        repository = try retentionRepository(
            for: fixture,
            nowSeconds: Double(observedAt + 2_592_000_001) / 1_000
        )
        #expect(try fixture.count("historical_observation_batch") == 1)
        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("scope-fixture")
            ) == .baselineUnavailable
        )
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)
        try await repository.close()
    }

    @Test("A shorter persisted policy uses the earlier effective expiry")
    func shorterPolicyWinsOverHardExpiry() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        let observedAt: Int64 = 2_000_000_000_000
        let baseline = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: observedAt
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(baseline.request)
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 1)
        )

        _ = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(observedAt + 86_400_000) / 1_000
            )
        )
        #expect(try fixture.count("historical_observation_batch") == 1)
        _ = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(observedAt + 86_400_001) / 1_000
            )
        )
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(
            try await repository.historicalPathHistoryPolicy()
                == HistoricalPathHistoryPolicy(retentionDays: 1)
        )
        try await repository.close()
    }

    @Test("Legacy finalization obeys History Off without losing current truth")
    func legacyFinalizationObeysHistoryOff() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)

        #expect(
            try await repository.finalizeCalibration(
                prepared.runID,
                report: prepared.report,
                workItem: prepared.workItem,
                streamID: prepared.streamID
            )
        )
        #expect(try fixture.count("node_current") == 2)
        #expect(try fixture.count("directory_history_sample") == 0)
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.count("historical_disabled_calibration_receipt") == 0)
        try await repository.close()
    }

    @Test("History Off preserves operational continuity and path-free capacity truth")
    func historyOffPreservesOperationalState() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        let scopeID = try WatchedScopeID("scope-operational")
        let streamID = try EventStreamID("stream-operational")
        let root = try DirtyRegionPath("/Volumes/Operational")
        let volumeUUID = try #require(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        )
        let bookmark = try WatchedScopeBookmark(
            scopeID: scopeID,
            bookmarkData: Data(repeating: 0x45, count: 32),
            expectedRoot: root,
            expectedVolumeUUID: volumeUUID
        )
        try await repository.upsertWatchedScopeBookmark(bookmark)
        _ = try await repository.activateScopeMount(
            scopeID: scopeID,
            evidence: VolumeMountEvidence(mountPath: root, volumeUUID: volumeUUID),
            proposedGenerationID: MountGenerationID("generation-operational")
        )
        try await repository.markDirty(
            streamID: streamID,
            regions: [
                try DirtyRegion(
                    path: root,
                    reasons: [.requiresCalibration],
                    maximumCursor: nil
                ),
            ]
        )
        try await repository.recordStartupVolumeCapacity(
            StartupVolumeCapacitySnapshot(
                observedAt: Date(timeIntervalSince1970: 2_000_000_000),
                volumeUUID: volumeUUID,
                totalBytes: ByteCount(10_000),
                availableBytes: ByteCount(4_000),
                availableForImportantUsageBytes: nil
            ),
            source: .lifecycle
        )

        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        #expect(try await repository.watchedScopeBookmarks() == [bookmark])
        #expect(try await repository.scopeMountGeneration(for: scopeID) != nil)
        #expect(try await repository.dirtyRegions(for: streamID).count == 1)
        #expect(
            try await repository.recentStartupVolumeCapacityHistory(limit: 10).count == 1
        )
        try await repository.close()
    }

    @Test("Disabled receipts ignore strings but reject changed scalar evidence")
    func disabledReceiptPrivacyAndConflictMatrix() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        #expect(
            try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
                == .historyDisabled
        )
        let receiptTimes = try fixture.rows(
            "SELECT committed_at_ms,expires_at_ms FROM historical_disabled_calibration_receipt"
        )
        #expect(receiptTimes.count == 1)
        #expect(Int64(receiptTimes[0][1])! - Int64(receiptTimes[0][0])! == 604_800_000)

        let changedPath = try DirtyRegionPath("/Ignored/Entirely/Different")
        let ignoredWork = DirtyRegionWorkItem(
            region: try DirtyRegion(
                path: changedPath,
                reasons: prepared.workItem.region.reasons,
                maximumCursor: prepared.workItem.region.maximumCursor
            ),
            revision: prepared.workItem.revision
        )
        let ignoredStrings = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: ignoredWork,
            streamID: EventStreamID("ignored-stream"),
            observation: prepared.request.observation
        )
        #expect(
            try await repository.finalizeCalibrationWithHistoricalFrames(ignoredStrings)
                == .historyDisabled
        )

        let changedRevision = try HistoricalCalibrationFinalizationRequest(
            runID: prepared.runID,
            report: prepared.report,
            workItem: DirtyRegionWorkItem(
                region: prepared.workItem.region,
                revision: DirtyRegionRevision(prepared.workItem.revision.rawValue + 1)
            ),
            streamID: prepared.streamID,
            observation: prepared.request.observation
        )
        await #expect(throws: SQLiteEventJournalError.historicalImmutableRequestConflict) {
            _ = try await repository.finalizeCalibrationWithHistoricalFrames(changedRevision)
        }
        try await repository.close()
    }

    @Test("A disabled receipt survives after its path-bearing scan run is released")
    func disabledReceiptOutlivesPathBearingScanRun() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        var repository = try retentionRepository(for: fixture)
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        let first = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
        let second = try await prepareHistoricalLedgerRun(
            repository: repository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            child: .omitted,
            observedAtMilliseconds: 2_000_000_100_000
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(second.request)
        _ = try await repository.applyRetention(
            referenceDate: Date(timeIntervalSince1970: 2_000_000_020)
        )
        #expect(
            try fixture.int(
                "SELECT count(*) FROM scan_run WHERE id='\(first.runID.rawValue)'"
            ) == 0
        )
        #expect(try fixture.count("historical_disabled_calibration_receipt") == 2)
        try await repository.close()

        repository = try retentionRepository(for: fixture)
        #expect(
            try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
                == .historyDisabled
        )
        try await repository.close()
    }

    @Test(
        "Graph retention removes projections and retractions without violating foreign keys"
    )
    func graphRetentionDeletesEveryDependentTier() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        let comparison = try await commitProjectionWithRetraction(repository: repository)

        let report = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(2_000_000_100_000 + 2_592_000_001) / 1_000
            )
        )
        #expect(report.historicalBatchCount == 2)
        #expect(report.rebasedComparisonCount == 0)
        for table in [
            "historical_finding_retraction",
            "historical_finding_positive_rank",
            "historical_finding_reason_count",
            "historical_finding",
            "historical_projection_checkpoint",
            "historical_finding_projection",
            "historical_projection_work",
            "historical_observation_frame_commit",
            "historical_metric_endpoint",
            "historical_observation_node",
            "historical_observation_frame",
            "historical_observation_batch",
        ] {
            #expect(try fixture.count(table) == 0, "Expected \(table) to be empty")
        }
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)
        #expect(
            try await repository.effectiveHistoricalFindings(
                for: ScopeID("scope-fixture"),
                through: comparison,
                limit: HistoricalFindingQueryLimit(1_000)
            ).isEmpty
        )
        try await repository.close()
    }

    @Test("A retained comparison is rebased when its predecessor expires")
    func retainedComparisonIsRebased() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        let baselineTime: Int64 = 2_000_000_000_000
        let comparisonTime = baselineTime + 20 * 86_400_000
        let baseline = try await prepareHistoricalLedgerRun(
            repository: repository,
            observedAtMilliseconds: baselineTime
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(baseline.request)
        let comparison = try await prepareHistoricalLedgerRun(
            repository: repository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            child: .present(logical: 50, allocated: 40),
            observedAtMilliseconds: comparisonTime
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(comparison.request)
        #expect(try fixture.count("historical_projection_work") == 2)

        let report = try await repository.applyRetention(
            referenceDate: Date(
                timeIntervalSince1970: Double(baselineTime + 2_592_000_001) / 1_000
            )
        )
        #expect(report.historicalBatchCount == 1)
        #expect(report.rebasedComparisonCount == 2)
        #expect(try fixture.count("historical_observation_batch") == 1)
        #expect(try fixture.count("historical_projection_work") == 0)
        #expect(
            try fixture.int(
                "SELECT count(*) FROM historical_observation_baseline_checkpoint WHERE checkpoint_kind=2"
            ) == 2
        )
        #expect(
            try fixture.int(
                "SELECT occurrence_count FROM historical_path_free_gap WHERE reason_code=2"
            ) == 2
        )
        #expect(try await repository.nextHistoricalProjectionWork() == nil)
        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("scope-fixture")
            ) == .available
        )
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)
        try await repository.close()
    }

    @Test(
        "Every injected graph-retention failure rolls policy and evidence back",
        arguments: [
            SQLiteEventJournalTestFailurePoint.afterExpiredDeletedNodesBeforeBaselines,
            .afterHistoricalRetentionFindingsBeforeFrames,
            .afterHistoricalRetentionFramesBeforeDictionaries,
        ]
    )
    func graphRetentionFailureRollsBack(
        failurePoint: SQLiteEventJournalTestFailurePoint
    ) async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        var repository = try retentionRepository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        try await repository.close()

        repository = try retentionRepository(for: fixture, failurePoint: failurePoint)
        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            try await repository.setHistoricalPathHistoryPolicy(
                HistoricalPathHistoryPolicy(retentionDays: 0)
            )
        }
        #expect(try fixture.count("historical_observation_batch") == 1)
        #expect(try fixture.count("historical_calibration_receipt") == 1)
        #expect(try fixture.count("directory_history_sample") == 4)
        #expect(try fixture.int("SELECT path_history_days FROM historical_retention_policy") == 30)
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)
        try await repository.close()
    }

    @Test("A real SQLITE_FULL during graph scrub rolls every row and policy change back")
    func realSQLiteFullRollsBackGraphScrub() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        var repository = try retentionRepository(for: fixture)
        let prepared = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(prepared.request)
        try await repository.close()
        try vacuumRetentionFixture(fixture.databaseURL)

        repository = try retentionRepository(
            for: fixture,
            failurePoint: .forceHistoricalRetentionSQLiteFull
        )
        try await repository.constrainDatabaseGrowthForTesting()
        do {
            try await repository.setHistoricalPathHistoryPolicy(
                HistoricalPathHistoryPolicy(retentionDays: 0)
            )
            Issue.record("Expected the real SQLite page cap to reject retention padding.")
        } catch let error as SQLiteEventJournalError {
            guard case .diskFull = error else { throw error }
        }
        #expect(try fixture.int("SELECT path_history_days FROM historical_retention_policy") == 30)
        #expect(try fixture.count("historical_observation_batch") == 1)
        #expect(try fixture.count("historical_calibration_receipt") == 1)
        #expect(
            try fixture.int(
                "SELECT count(*) FROM sqlite_schema WHERE name='spacetrace_retention_full_probe'"
            ) == 0
        )
        #expect(try fixture.int("SELECT count(*) FROM pragma_foreign_key_check") == 0)

        try await repository.allowDatabaseGrowthForTesting()
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        #expect(try fixture.count("historical_observation_batch") == 0)
        #expect(try fixture.int("SELECT path_history_days FROM historical_retention_policy") == 0)
        try await repository.close()
    }

    @Test("History Off physically removes released historical child identity bytes")
    func historyOffPhysicallyScrubsReleasedBytes() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try retentionRepository(for: fixture)
        let first = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
        try await repository.setHistoricalPathHistoryPolicy(
            HistoricalPathHistoryPolicy(retentionDays: 0)
        )
        let second = try await prepareHistoricalLedgerRun(
            repository: repository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            child: .omitted,
            observedAtMilliseconds: 2_000_000_100_000
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(second.request)
        _ = try await repository.applyRetention(
            referenceDate: Date(timeIntervalSince1970: 2_000_000_020)
        )
        #expect(
            try fixture.int(
                "SELECT count(*) FROM node_current WHERE path='/Fixtures/Child'"
            ) == 0
        )
        try await repository.close()

        let sensitiveValues = ["/Fixtures/Child", "location-child"]
        for url in activeSQLiteArtifacts(in: fixture.directoryURL) {
            let bytes = try Data(contentsOf: url)
            for value in sensitiveValues {
                #expect(
                    bytes.range(of: Data(value.utf8)) == nil,
                    "Found released historical identity bytes in \(url.lastPathComponent)"
                )
            }
        }
    }
}

private func retentionRepository(
    for fixture: HistoricalLedgerTestFixture,
    failurePoint: SQLiteEventJournalTestFailurePoint? = nil,
    nowSeconds: Double = 2_000_000_010
) throws -> SQLiteEventJournalRepository {
    try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: failurePoint,
        now: { Date(timeIntervalSince1970: nowSeconds) },
        historicalStoreGenerationProvider: { Array(repeating: 0x11, count: 16) }
    )
}

private func commitProjectionWithRetraction(
    repository: SQLiteEventJournalRepository
) async throws -> ObservationCommitSequence {
    let first = try await prepareHistoricalLedgerRun(repository: repository)
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
    let second = try await prepareHistoricalLedgerRun(
        repository: repository,
        logicalRootBytes: 120,
        allocatedRootBytes: 96,
        child: .present(logical: 50, allocated: 40),
        observedAtMilliseconds: 2_000_000_100_000
    )
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(second.request)
    let work = try #require(try await repository.nextHistoricalProjectionWork())
    let baseline = try #require(
        try await repository.historicalObservationFrame(sequence: work.baselineSequence)
    )
    let comparison = try #require(
        try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
    )
    let result = try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison,
        positiveLimit: work.positiveLimit
    )
    _ = try await repository.commitHistoricalProjection(result, for: work)
    let finding = try #require(
        try await repository.effectiveHistoricalFindings(
            for: ScopeID("scope-fixture"),
            through: work.comparisonSequence,
            limit: HistoricalFindingQueryLimit(1_000)
        ).first
    )
    let audit = try #require(
        try await repository.historicalFindingAuditRecord(id: finding.recordID)
    )
    let command = try HistoricalFindingIntegrityReconciliationAuthorizer
        .authorizeEvidenceInvalidation(
            requestID: HistoricalRetractionRequestID(bytes: Array(repeating: 0x71, count: 16)),
            failure: .ledgerIntegrityViolation,
            storedAuditRecord: audit
        )
    _ = try await repository.commitEvidenceInvalidation(command)
    return work.comparisonSequence
}

private func vacuumRetentionFixture(_ databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        throw RetentionFixtureError.sqlite("open")
    }
    defer { sqlite3_close_v2(database) }
    guard sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;", nil, nil, nil)
        == SQLITE_OK else {
        throw RetentionFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func activeSQLiteArtifacts(in directoryURL: URL) -> [URL] {
    ["SpaceTrace.sqlite", "SpaceTrace.sqlite-wal", "SpaceTrace.sqlite-shm"]
        .map { directoryURL.appendingPathComponent($0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
}

private enum RetentionFixtureError: Error {
    case sqlite(String)
}
