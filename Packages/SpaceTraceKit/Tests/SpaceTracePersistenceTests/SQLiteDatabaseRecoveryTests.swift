import Foundation
import SQLite3
@testable import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite startup recovery", .serialized)
struct SQLiteDatabaseRecoveryTests {
    @Test("A failed migration preserves an atomic version-six backup")
    func failedMigrationPreservesBackup() async throws {
        let fixture = try RecoveryDatabaseFixture()
        try await fixture.makeVersionSixDatabase()
        #expect(throws: SQLiteEventJournalError.migrationFailed(fromVersion: 6, targetVersion: 7)) {
            _ = try SQLiteEventJournalRepository(
                databaseURL: fixture.databaseURL,
                failurePoint: .beforeMigrationCommit(version: 7)
            )
        }

        let backupURL = SQLiteMigrationBackup.backupURL(
            for: fixture.databaseURL,
            sourceVersion: 6
        )
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try schemaVersion(at: backupURL) == 6)
        #expect(try schemaVersion(at: fixture.databaseURL) == 6)
    }

    @Test("A successful migration removes its temporary recovery backup")
    func successfulMigrationRemovesBackup() async throws {
        let fixture = try RecoveryDatabaseFixture()
        try await fixture.makeVersionSixDatabase()
        let backupURL = SQLiteMigrationBackup.backupURL(
            for: fixture.databaseURL,
            sourceVersion: 6
        )

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        #expect(
            try schemaVersion(at: fixture.databaseURL)
                == Int32(SQLiteEventJournalRepository.currentSchemaVersion)
        )
        #expect(FileManager.default.fileExists(atPath: backupURL.path) == false)
    }

    @Test("Corrupt main database is isolated byte-for-byte without silent reset")
    func corruptMainIsIsolated() async throws {
        let fixture = try RecoveryDatabaseFixture()
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()
        var damaged = try Data(contentsOf: fixture.databaseURL)
        damaged.replaceSubrange(0..<16, with: Data(repeating: 0xA5, count: 16))
        try damaged.write(to: fixture.databaseURL)

        let result = SQLiteRepositoryBootstrap.open(
            databaseURL: fixture.databaseURL,
            now: Date(timeIntervalSince1970: 1_750_000_000),
            incidentID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            fileManager: .default
        )
        guard case let .recovery(session) = result else {
            Issue.record("Expected read-only recovery mode.")
            return
        }

        #expect(session.overview.reason == .databaseCorrupt)
        #expect(session.overview.source == .unavailable)
        #expect(session.overview.evidenceCompleteness == .unavailable)
        #expect(try Data(contentsOf: fixture.databaseURL) == damaged)
        let incident = try #require(session.overview.incidentDirectoryName)
        let isolated = fixture.directoryURL
            .appendingPathComponent("Recovery")
            .appendingPathComponent(incident)
            .appendingPathComponent("main.sqlite")
        #expect(try Data(contentsOf: isolated) == damaged)
    }

    @Test("Malformed WAL is isolated and the main database opens read-only")
    func malformedWALIsIsolated() async throws {
        let fixture = try RecoveryDatabaseFixture()
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()
        let walURL = URL(fileURLWithPath: fixture.databaseURL.path + "-wal")
        let damagedWAL = Data(repeating: 0xCC, count: 31)
        try damagedWAL.write(to: walURL)

        let result = SQLiteRepositoryBootstrap.open(
            databaseURL: fixture.databaseURL,
            now: Date(timeIntervalSince1970: 1_750_000_001),
            incidentID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            fileManager: .default
        )
        guard case let .recovery(session) = result else {
            Issue.record("Expected read-only recovery mode.")
            return
        }

        #expect(session.overview.reason == .databaseCorrupt)
        #expect(session.overview.source == .isolatedMainDatabase)
        #expect(session.overview.evidenceCompleteness == .incomplete)
        #expect(
            session.overview.schemaVersion
                == Int32(SQLiteEventJournalRepository.currentSchemaVersion)
        )
        #expect(session.verifyWriteRejectedForTesting())
        let incident = try #require(session.overview.incidentDirectoryName)
        let isolatedWAL = fixture.directoryURL
            .appendingPathComponent("Recovery")
            .appendingPathComponent(incident)
            .appendingPathComponent("main.sqlite-wal")
        #expect(try Data(contentsOf: isolatedWAL) == damagedWAL)
        session.close()
    }

    @Test("Migration failure boots from its read-only pre-migration backup")
    func migrationFailureUsesReadOnlyBackup() async throws {
        let fixture = try RecoveryDatabaseFixture()
        try await fixture.makeVersionSixDatabase()

        let result = SQLiteRepositoryBootstrap.open(
            databaseURL: fixture.databaseURL,
            now: Date(timeIntervalSince1970: 1_750_000_002),
            incidentID: UUID(uuidString: "cccccccc-dddd-eeee-ffff-000000000000")!,
            fileManager: .default,
            failurePoint: .beforeMigrationCommit(version: 7)
        )
        guard case let .recovery(session) = result else {
            Issue.record("Expected read-only recovery mode.")
            return
        }

        #expect(session.overview.reason == .migrationFailed)
        #expect(session.overview.source == .migrationBackup)
        #expect(session.overview.evidenceCompleteness == .complete)
        #expect(session.overview.schemaVersion == 6)
        #expect(session.verifyWriteRejectedForTesting())
        session.close()
    }

    @Test("Migration backups are ordered by numeric schema version")
    func migrationBackupsUseNumericOrdering() throws {
        let fixture = try RecoveryDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        for version: Int32 in [9, 10, 6] {
            try Data("fixture".utf8).write(
                to: SQLiteMigrationBackup.backupURL(
                    for: fixture.databaseURL,
                    sourceVersion: version
                )
            )
        }
        try Data("noncanonical".utf8).write(
            to: fixture.directoryURL.appendingPathComponent(
                "SpaceTrace.sqlite.pre-migration-v09.sqlite"
            )
        )
        #expect(
            SQLiteMigrationBackup.existingBackups(for: fixture.databaseURL)
                .map(\.lastPathComponent)
                == [
                    "SpaceTrace.sqlite.pre-migration-v10.sqlite",
                    "SpaceTrace.sqlite.pre-migration-v9.sqlite",
                    "SpaceTrace.sqlite.pre-migration-v6.sqlite",
                ]
        )
    }

    @Test("The sensitive artifact inventory covers every app-owned SQLite shape")
    func sensitiveArtifactInventoryIsExhaustive() async throws {
        let fixture = try RecoveryDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        for suffix in ["-wal", "-shm"] {
            try Data("active".utf8).write(
                to: URL(fileURLWithPath: fixture.databaseURL.path + suffix)
            )
        }
        try Data("backup".utf8).write(
            to: SQLiteMigrationBackup.backupURL(for: fixture.databaseURL, sourceVersion: 10)
        )
        try Data("online".utf8).write(
            to: fixture.directoryURL.appendingPathComponent(
                "SpaceTrace.sqlite.online-backup-fixture.sqlite"
            )
        )
        try Data("temporary".utf8).write(
            to: fixture.directoryURL.appendingPathComponent(
                ".SpaceTrace-migration-backup-fixture.tmp"
            )
        )

        let incident = fixture.directoryURL
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("2000000000000-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: incident, withIntermediateDirectories: true)
        for name in [
            "main.sqlite", "main.sqlite-wal", "main.sqlite-shm",
            "read-only-main.sqlite", "migration-backup.sqlite",
            "interrupted.part",
        ] {
            try Data(name.utf8).write(to: incident.appendingPathComponent(name))
        }
        let manifest = Data(
            #"{"version":1,"createdAtMilliseconds":2000000000000,"expiresAtMilliseconds":2000604800000}"#.utf8
        )
        try manifest.write(to: incident.appendingPathComponent("manifest.json"))

        let entries = try SQLiteSensitiveArtifactInventory.discover(
            databaseURL: fixture.databaseURL
        )
        #expect(Set(entries.map(\.kind)) == Set(SQLiteSensitiveArtifactKind.allCases))
        #expect(entries.allSatisfy { $0.earliestSensitiveExpiry > $0.createdAt })

        try SQLiteSensitiveArtifactInventory.scrubAfterSuccessfulStartup(
            databaseURL: fixture.databaseURL
        )
        let remaining = try SQLiteSensitiveArtifactInventory.discover(
            databaseURL: fixture.databaseURL
        )
        #expect(Set(remaining.map(\.kind)) == [.activeMain, .activeWAL, .activeSHM])
    }

    @Test("Expired recovery artifacts scrub without deleting the active database")
    func expiredArtifactScrubPreservesActiveDatabase() async throws {
        let fixture = try RecoveryDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()
        let backup = SQLiteMigrationBackup.backupURL(
            for: fixture.databaseURL,
            sourceVersion: 10
        )
        try Data("expired".utf8).write(to: backup)
        try SQLiteSensitiveArtifactInventory.scrubExpired(
            databaseURL: fixture.databaseURL,
            referenceDate: Date(timeIntervalSince1970: 4_000_000_000)
        )
        #expect(FileManager.default.fileExists(atPath: backup.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    @Test("A committed retention transaction resumes its checkpoint after reopen")
    func committedRetentionResumesCheckpointAfterReopen() async throws {
        let fixture = try RecoveryDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
        let interrupted = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL,
            failurePoint: .afterHistoricalRetentionCommitBeforeCheckpoint,
            now: { referenceDate }
        )
        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            try await interrupted.setHistoricalPathHistoryPolicy(
                HistoricalPathHistoryPolicy(retentionDays: 29)
            )
        }

        let reopened = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL,
            failurePoint: nil,
            now: { referenceDate }
        )
        #expect(
            try await reopened.historicalPathHistoryAvailability(
                for: ScopeID("checkpoint-reopen-scope")
            ) == .baselineUnavailable
        )
        #expect(
            try await reopened.historicalPathHistoryPolicy()
                == HistoricalPathHistoryPolicy(retentionDays: 29)
        )
        try await reopened.close()
        try await interrupted.close()
    }

    @Test("An external reader produces typed scrub-pending until it exits")
    func externalReaderKeepsCheckpointPending() async throws {
        let fixture = try RecoveryDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_100)
        let repository = try SQLiteEventJournalRepository(
            databaseURL: fixture.databaseURL,
            failurePoint: nil,
            now: { referenceDate }
        )
        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("busy-reader-scope")
            ) == .baselineUnavailable
        )

        var reader: OpaquePointer?
        let openResult = sqlite3_open_v2(
            fixture.databaseURL.path,
            &reader,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        let externalReader = try #require(reader)
        #expect(openResult == SQLITE_OK)
        #expect(sqlite3_exec(externalReader, "BEGIN", nil, nil, nil) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                externalReader,
                "SELECT count(*) FROM schema_migration",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )

        await #expect(throws: SQLiteEventJournalError.historicalScrubPending) {
            try await repository.setHistoricalPathHistoryPolicy(
                HistoricalPathHistoryPolicy(retentionDays: 28)
            )
        }
        await #expect(throws: SQLiteEventJournalError.historicalScrubPending) {
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("busy-reader-scope")
            )
        }
        #expect(sqlite3_exec(externalReader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close_v2(externalReader) == SQLITE_OK)
        reader = nil

        #expect(
            try await repository.historicalPathHistoryAvailability(
                for: ScopeID("busy-reader-scope")
            ) == .baselineUnavailable
        )
        try await repository.close()
    }
}

private struct RecoveryDatabaseFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("SpaceTrace.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func makeVersionSixDatabase() async throws {
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try await repository.close()
        try removeV11SchemaForLegacyMigrationFixture(at: databaseURL)
        try execute(
            at: databaseURL,
            sql: """
                DROP INDEX startup_volume_capacity_window;
                DROP TABLE startup_volume_capacity_sample;
                ALTER TABLE authorized_baseline_root DROP COLUMN volume_uuid;
                DELETE FROM schema_migration WHERE version >= 9;
                DROP TABLE directory_history_sample;
                DROP TABLE path_free_calibration_requirement;
                ALTER TABLE dirty_region DROP COLUMN updated_at_ms;
                DELETE FROM schema_migration WHERE version = 8;
                DROP INDEX node_current_expired_deleted;
                ALTER TABLE node_current DROP COLUMN deleted_at_ms;
                DELETE FROM schema_migration WHERE version = 7;
                PRAGMA user_version = 6;
                """
        )
    }
}

private func execute(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let database else { throw RecoveryTestError.sqlite("open read-write") }
    defer { _ = sqlite3_close_v2(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw RecoveryTestError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func schemaVersion(at url: URL) throws -> Int32 {
    var database: OpaquePointer?
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    let uri = components?.url?.absoluteString ?? url.absoluteString
    guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
          let database else { throw RecoveryTestError.sqlite("open read-only: \(url.lastPathComponent)") }
    defer { _ = sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw RecoveryTestError.sqlite("prepare user_version") }
    defer { _ = sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw RecoveryTestError.sqlite("step user_version") }
    return sqlite3_column_int(statement, 0)
}

private enum RecoveryTestError: Error {
    case sqlite(String)
}
