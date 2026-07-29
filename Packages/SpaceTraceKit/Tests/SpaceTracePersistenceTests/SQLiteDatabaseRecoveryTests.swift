import Foundation
import SQLite3
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
        #expect(session.overview.schemaVersion == 6)
        #expect(session.verifyWriteRejectedForTesting())
        session.close()
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
