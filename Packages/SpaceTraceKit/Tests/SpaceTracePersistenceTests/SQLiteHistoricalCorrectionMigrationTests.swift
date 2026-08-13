import Foundation
import SQLite3
import Testing
@_spi(Benchmark) @testable import SpaceTracePersistence

@Suite("SQLite v12 correction-ledger migration", .serialized)
struct SQLiteHistoricalCorrectionMigrationTests {
    @Test("A fresh store preserves the frozen v12 graph inside current v13")
    func freshStoreInstallsV12() async throws {
        let fixture = try CorrectionMigrationDatabase()
        defer { fixture.remove() }

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        #expect(SQLiteEventJournalRepository.currentSchemaVersion == 13)
        try await repository.close()

        #expect(try fixture.integer("PRAGMA user_version") == 13)
        #expect(try fixture.integer("SELECT count(*) FROM historical_reconciliation_revision") == 0)
        #expect(try fixture.integer("SELECT count(*) FROM historical_projection_correction_checkpoint") == 0)
        #expect(try fixture.text("PRAGMA integrity_check") == "ok")
        #expect(try fixture.rows("PRAGMA foreign_key_check").isEmpty)
        let digest = try fixture.schemaDigest()
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(
            digest == SQLiteHistoricalCorrectedRetractionSchema.frozenSchemaDigest,
            "actual schema digest: \(digestHex)"
        )
    }

    @Test("A populated v11 store preserves every legacy value and invents no revision chain")
    func populatedV11MigratesWithoutFabrication() async throws {
        let fixture = try CorrectionMigrationDatabase.copyReleased(version: 11)
        defer { fixture.remove() }
        let before = try fixture.v11SemanticSnapshot()

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        #expect(try fixture.integer("PRAGMA user_version") == 13)
        #expect(try fixture.v11SemanticSnapshot() == before)
        #expect(try fixture.integer("SELECT count(*) FROM historical_reconciliation_revision") == 0)
        #expect(try fixture.integer("SELECT count(*) FROM historical_correction_input") == 0)
        #expect(try fixture.integer("SELECT count(*) FROM historical_projection_correction_work") == 0)
    }

    @Test(
        "Every injected v12 boundary restores v11 and retains its atomic backup",
        arguments: [
            SQLiteEventJournalTestFailurePoint.afterV12SchemaInstall,
            .afterV12MigrationRecord,
            .beforeMigrationCommit(version: 12),
        ]
    )
    func failureRollsBackToV11(
        failurePoint: SQLiteEventJournalTestFailurePoint
    ) async throws {
        let fixture = try CorrectionMigrationDatabase.copyReleased(version: 11)
        defer { fixture.remove() }
        let before = try fixture.v11SemanticSnapshot()

        #expect(throws: SQLiteEventJournalError.migrationFailed(fromVersion: 11, targetVersion: 12)) {
            _ = try SQLiteEventJournalRepository(
                databaseURL: fixture.databaseURL,
                failurePoint: failurePoint
            )
        }

        #expect(try fixture.integer("PRAGMA user_version") == 11)
        #expect(try fixture.v11SemanticSnapshot() == before)
        #expect(try fixture.objectExists("historical_reconciliation_revision") == false)
        let backup = SQLiteMigrationBackup.backupURL(
            for: fixture.databaseURL,
            sourceVersion: 11
        )
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try CorrectionMigrationDatabase.integer(at: backup, sql: "PRAGMA user_version") == 11)
    }

    @Test("Correction wire values reject malformed lengths, NUL, and oversized payloads")
    func correctionCodecBounds() throws {
        #expect(try SQLiteHistoricalFindingCodec.validateCorrectionRequestID(Data(repeating: 1, count: 16)).count == 16)
        #expect(throws: SQLiteHistoricalFindingCodecError.byteLengthOutOfRange) {
            _ = try SQLiteHistoricalFindingCodec.validateCorrectionRequestID(Data(repeating: 1, count: 15))
        }
        #expect(try SQLiteHistoricalFindingCodec.validateCorrectionDigest(Data(repeating: 2, count: 32)).count == 32)
        #expect(throws: SQLiteHistoricalFindingCodecError.byteLengthOutOfRange) {
            _ = try SQLiteHistoricalFindingCodec.validateCorrectionDigest(Data(repeating: 2, count: 33))
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.embeddedNUL) {
            _ = try SQLiteHistoricalFindingCodec.encodeCorrectionPayload("safe\0unsafe")
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.byteLengthOutOfRange) {
            _ = try SQLiteHistoricalFindingCodec.encodeCorrectionPayload(
                String(repeating: "x", count: 65_537)
            )
        }
    }
}

private final class CorrectionMigrationDatabase {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v12-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("SpaceTrace.sqlite")
    }

    private init(directory: URL, databaseURL: URL) {
        self.directory = directory
        self.databaseURL = databaseURL
    }

    static func copyReleased(version: Int) throws -> CorrectionMigrationDatabase {
        let source = try #require(
            Bundle.module.url(
                forResource: "SpaceTrace",
                withExtension: "sqlite",
                subdirectory: "Fixtures/ReleasedSchemas/v\(version)"
            )
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v12-migrated-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("SpaceTrace.sqlite")
        try FileManager.default.copyItem(at: source, to: destination)
        return CorrectionMigrationDatabase(directory: directory, databaseURL: destination)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        let backup = SQLiteMigrationBackup.backupURL(for: databaseURL, sourceVersion: 11)
        try? FileManager.default.removeItem(at: backup)
    }

    func integer(_ sql: String) throws -> Int64 {
        try withDatabase { try Self.integer(database: $0, sql: sql) }
    }

    static func integer(at url: URL, sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw CorrectionMigrationTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        return try integer(database: database, sql: sql)
    }

    func text(_ sql: String) throws -> String {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CorrectionMigrationTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else {
                throw CorrectionMigrationTestError.sqlite
            }
            return String(cString: value)
        }
    }

    func rows(_ sql: String) throws -> [[String]] {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CorrectionMigrationTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            var rows: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map(String.init(cString:)) ?? "NULL"
                })
            }
            return rows
        }
    }

    func objectExists(_ name: String) throws -> Bool {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_schema WHERE name=?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CorrectionMigrationTestError.sqlite }
            defer { sqlite3_finalize(statement) }
            let result = name.withCString {
                sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw CorrectionMigrationTestError.sqlite }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func schemaDigest() throws -> Data {
        try withDatabase { try SQLiteHistoricalFindingCodec.schemaObjectDigest(database: $0) }
    }

    func v11SemanticSnapshot() throws -> [[String]] {
        try rows("""
            SELECT 'node',node_id,batch_id,subject_key,location_key,coalesce(parent_node_id,-1),observed_at_ms,direct_children_coverage,classification_decision_id
            FROM historical_observation_node
            UNION ALL
            SELECT 'endpoint',node_id,metric,frame_id,state_kind,coalesce(bytes,-1),coalesce(measurement_coverage,-1),coalesce(unknown_reason_code,-1),0
            FROM historical_metric_endpoint
            UNION ALL
            SELECT 'finding',finding_id,projection_id,ordinal,baseline_node_id,comparison_node_id,kind,inclusive_delta_bytes,coalesce(ranking_contribution_bytes,-1)
            FROM historical_finding
            ORDER BY 1,2,3
            """)
    }

    private static func integer(database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CorrectionMigrationTestError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CorrectionMigrationTestError.sqlite }
        return sqlite3_column_int64(statement, 0)
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw CorrectionMigrationTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        return try body(database)
    }
}

private enum CorrectionMigrationTestError: Error { case sqlite }
