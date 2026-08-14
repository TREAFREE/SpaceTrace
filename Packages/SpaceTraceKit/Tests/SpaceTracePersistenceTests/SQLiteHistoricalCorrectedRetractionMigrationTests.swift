import Foundation
import SQLite3
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite v13 corrected-finding retraction migration", .serialized)
struct SQLiteHistoricalCorrectedRetractionMigrationTests {
    @Test("The additive v13 DDL matches its frozen full-schema digest")
    func additiveSchemaDigestIsFrozen() throws {
        let fixture = try CorrectedRetractionMigrationDatabase.copyReleased(version: 12)
        defer { fixture.remove() }
        let digest = try fixture.installV13AndReadSchemaDigest()
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(
            digest == SQLiteHistoricalCorrectedRetractionSchema.frozenSchemaDigest,
            "actual v13 schema digest: \(digestHex)"
        )
    }

    @Test("A fresh store installs an empty frozen v13 invalidation lane")
    func freshStoreInstallsV13() async throws {
        let fixture = try CorrectedRetractionMigrationDatabase()
        defer { fixture.remove() }

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        #expect(SQLiteEventJournalRepository.currentSchemaVersion == 13)
        try await repository.close()

        #expect(try fixture.integer("PRAGMA user_version") == 13)
        #expect(
            try fixture.integer(
                "SELECT count(*) FROM historical_corrected_finding_retraction"
            ) == 0
        )
        #expect(try fixture.text("PRAGMA integrity_check") == "ok")
        #expect(try fixture.rows("PRAGMA foreign_key_check").isEmpty)
        #expect(
            try fixture.schemaDigest()
                == SQLiteHistoricalCorrectedRetractionSchema.frozenSchemaDigest
        )
    }

    @Test("A released v12 store migrates additively without inventing invalidations")
    func releasedV12MigratesWithoutFabrication() async throws {
        let fixture = try CorrectedRetractionMigrationDatabase.copyReleased(version: 12)
        defer { fixture.remove() }
        let before = try fixture.v12SemanticSnapshot()

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        #expect(try fixture.integer("PRAGMA user_version") == 13)
        #expect(try fixture.v12SemanticSnapshot() == before)
        #expect(
            try fixture.integer(
                "SELECT count(*) FROM historical_corrected_finding_retraction"
            ) == 0
        )
    }

    @Test("v13 drops legacy incomplete attempts that cannot prove current-cycle ordering")
    func migrationDropsLegacyIncompleteAttempts() async throws {
        let fixture = try CorrectedRetractionMigrationDatabase.copyReleased(version: 12)
        defer { fixture.remove() }
        try fixture.execute(
            """
            INSERT INTO scan_run(
                id,stream_id,region_path,dirty_revision_be,state,
                coverage,entries_seen,directories_staged,started_at_ms,finished_at_ms
            ) VALUES(
                'legacy-partial','legacy-stream','/Legacy',
                X'0000000000000001','partial','partial',1,1,1,2
            );
            """
        )
        #expect(try fixture.integer("SELECT count(*) FROM scan_run WHERE state='partial'") == 1)

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        #expect(try fixture.integer("SELECT count(*) FROM scan_run WHERE state='partial'") == 0)
        #expect(try fixture.integer("PRAGMA user_version") == 13)
    }

    @Test(
        "Every injected v13 boundary restores v12 and retains its atomic backup",
        arguments: [
            SQLiteEventJournalTestFailurePoint.afterV13SchemaInstall,
            .afterV13MigrationRecord,
            .beforeMigrationCommit(version: 13),
        ]
    )
    func failureRollsBackToV12(
        failurePoint: SQLiteEventJournalTestFailurePoint
    ) throws {
        let fixture = try CorrectedRetractionMigrationDatabase.copyReleased(version: 12)
        defer { fixture.remove() }
        let before = try fixture.v12SemanticSnapshot()

        #expect(throws: SQLiteEventJournalError.migrationFailed(fromVersion: 12, targetVersion: 13)) {
            _ = try SQLiteEventJournalRepository(
                databaseURL: fixture.databaseURL,
                failurePoint: failurePoint
            )
        }

        #expect(try fixture.integer("PRAGMA user_version") == 12)
        #expect(try fixture.v12SemanticSnapshot() == before)
        #expect(
            try fixture.objectExists("historical_corrected_finding_retraction") == false
        )
        let backup = SQLiteMigrationBackup.backupURL(
            for: fixture.databaseURL,
            sourceVersion: 12
        )
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(
            try CorrectedRetractionMigrationDatabase.integer(
                at: backup,
                sql: "PRAGMA user_version"
            ) == 12
        )
    }
}

private final class CorrectedRetractionMigrationDatabase {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v13-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("SpaceTrace.sqlite")
    }

    private init(directory: URL, databaseURL: URL) {
        self.directory = directory
        self.databaseURL = databaseURL
    }

    static func copyReleased(version: Int) throws -> CorrectedRetractionMigrationDatabase {
        let source = try #require(
            Bundle.module.url(
                forResource: "SpaceTrace",
                withExtension: "sqlite",
                subdirectory: "Fixtures/ReleasedSchemas/v\(version)"
            )
        )
        let fixture = try CorrectedRetractionMigrationDatabase()
        try FileManager.default.copyItem(at: source, to: fixture.databaseURL)
        return fixture
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        let backup = SQLiteMigrationBackup.backupURL(for: databaseURL, sourceVersion: 12)
        try? FileManager.default.removeItem(at: backup)
    }

    func integer(_ sql: String) throws -> Int64 {
        try withDatabase { try Self.integer(database: $0, sql: sql) }
    }

    static func integer(at url: URL, sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw CorrectedRetractionMigrationTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        return try integer(database: database, sql: sql)
    }

    func text(_ sql: String) throws -> String {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CorrectedRetractionMigrationTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else {
                throw CorrectedRetractionMigrationTestError.sqlite
            }
            return String(cString: value)
        }
    }

    func rows(_ sql: String) throws -> [[String]] {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CorrectedRetractionMigrationTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            var values: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map(String.init(cString:)) ?? "NULL"
                })
            }
            return values
        }
    }

    func objectExists(_ name: String) throws -> Bool {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT 1 FROM sqlite_schema WHERE name=?",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw CorrectedRetractionMigrationTestError.sqlite
            }
            defer { sqlite3_finalize(statement) }
            guard name.withCString({
                sqlite3_bind_text(
                    statement,
                    1,
                    $0,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }) == SQLITE_OK else {
                throw CorrectedRetractionMigrationTestError.sqlite
            }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func schemaDigest() throws -> Data {
        try withDatabase { try SQLiteHistoricalFindingCodec.schemaObjectDigest(database: $0) }
    }

    func installV13AndReadSchemaDigest() throws -> Data {
        try withDatabase { database in
            try SQLiteHistoricalCorrectedRetractionSchema.installFrozenV13(on: database)
            return try SQLiteHistoricalFindingCodec.schemaObjectDigest(database: database)
        }
    }

    func execute(_ sql: String) throws {
        try withDatabase { database in
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                if let errorMessage { sqlite3_free(errorMessage) }
                throw CorrectedRetractionMigrationTestError.sqlite
            }
        }
    }

    func v12SemanticSnapshot() throws -> [[String]] {
        try rows(
            """
            SELECT 'migration',version,checksum FROM schema_migration WHERE version<=12
            UNION ALL
            SELECT 'correction',correcting_projection_id,canonical_result_sha256
            FROM historical_correcting_projection
            UNION ALL
            SELECT 'finding',corrected_finding_id,draft_sha256
            FROM historical_corrected_finding
            ORDER BY 1,2
            """
        )
    }

    private static func integer(database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CorrectedRetractionMigrationTestError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CorrectedRetractionMigrationTestError.sqlite
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw CorrectedRetractionMigrationTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        return try body(database)
    }
}

private enum CorrectedRetractionMigrationTestError: Error { case sqlite }
