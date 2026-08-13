import Foundation
import SQLite3
import Testing
@_spi(Benchmark) @testable import SpaceTracePersistence

@Suite("SQLite v11-v13 historical-ledger migration", .serialized)
struct SQLiteHistoricalFindingMigrationTests {
    @Test("A fresh store installs the frozen v11 ledger inside the current schema")
    func freshStoreInstallsV11() async throws {
        let fixture = try MigrationDatabase()
        defer { fixture.remove() }

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        #expect(SQLiteEventJournalRepository.currentSchemaVersion == 13)
        #expect(try await repository.secureDeleteEnabledForTesting())
        try await repository.close()

        #expect(try fixture.int("PRAGMA user_version") == 13)
        #expect(try fixture.int("PRAGMA auto_vacuum") == 1)
        #expect(try fixture.int("SELECT path_history_days FROM historical_retention_policy WHERE singleton=1") == 30)
        #expect(try fixture.data("SELECT store_generation FROM historical_store_identity WHERE singleton=1")?.count == 16)
        #expect(try fixture.data("SELECT store_generation FROM historical_store_identity WHERE singleton=1") != Data(repeating: 0, count: 16))
        #expect(try fixture.text("PRAGMA integrity_check") == "ok")
        #expect(try fixture.rows("PRAGMA foreign_key_check").isEmpty)
        #expect(try fixture.historicalObjectNames() == SQLiteHistoricalFindingSchema.frozenObjectNames)
    }

    @Test("A populated v10 store migrates without manufacturing v11-v13 evidence")
    func populatedV10MigratesWithoutBackfill() async throws {
        let fixture = try MigrationDatabase()
        defer { fixture.remove() }
        try await fixture.makeVersionTenWithLegacyHistory()

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        #expect(try fixture.int("PRAGMA user_version") == 13)
        #expect(try fixture.int("SELECT count(*) FROM directory_history_sample") == 1)
        #expect(try fixture.int("SELECT count(*) FROM historical_observation_batch") == 0)
        #expect(try fixture.int("SELECT count(*) FROM historical_observation_node") == 0)
        #expect(try fixture.int("SELECT count(*) FROM historical_finding") == 0)
        #expect(try fixture.int("SELECT count(*) FROM historical_reconciliation_revision") == 0)
        #expect(try fixture.int("SELECT count(*) FROM node_current") == 0)
    }

    @Test("A v11 failure rolls back every ledger object and preserves the v10 backup")
    func failedV11MigrationRollsBack() async throws {
        let fixture = try MigrationDatabase()
        defer { fixture.remove() }
        try await fixture.makeVersionTenWithLegacyHistory()

        #expect(throws: SQLiteEventJournalError.migrationFailed(fromVersion: 10, targetVersion: 11)) {
            _ = try SQLiteEventJournalRepository(
                databaseURL: fixture.databaseURL,
                failurePoint: .beforeMigrationCommit(version: 11),
                historicalStoreGenerationProvider: {
                    Array(repeating: UInt8(0xA5), count: 16)
                }
            )
        }

        #expect(try fixture.int("PRAGMA user_version") == 10)
        #expect(try fixture.historicalObjectNames().isEmpty)
        #expect(try fixture.int("SELECT count(*) FROM directory_history_sample") == 1)
        let backupURL = SQLiteMigrationBackup.backupURL(
            for: fixture.databaseURL,
            sourceVersion: 10
        )
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try MigrationDatabase.int(at: backupURL, sql: "PRAGMA user_version") == 10)
    }

    @Test("Store generation is nonzero, immutable across reopen and online backup, and store-local")
    func storeGenerationLifecycle() async throws {
        let first = try MigrationDatabase()
        let second = try MigrationDatabase()
        defer {
            first.remove()
            second.remove()
        }

        let firstRepository = try SQLiteEventJournalRepository(databaseURL: first.databaseURL)
        try await firstRepository.close()
        let firstStoredGeneration = try first.data(
            "SELECT store_generation FROM historical_store_identity"
        )
        let firstGeneration = try #require(firstStoredGeneration)
        #expect(firstGeneration.count == 16)
        #expect(firstGeneration != Data(repeating: 0, count: 16))

        let reopened = try SQLiteEventJournalRepository(
            databaseURL: first.databaseURL,
            failurePoint: nil,
            historicalStoreGenerationProvider: {
                Issue.record("An existing store must not request a new generation.")
                return Array(repeating: UInt8(0xFF), count: 16)
            }
        )
        try await reopened.close()
        #expect(try first.data("SELECT store_generation FROM historical_store_identity") == firstGeneration)

        let backupURL = try first.createOnlineBackup(sourceVersion: 11)
        let backupRepository = try SQLiteEventJournalRepository(databaseURL: backupURL)
        try await backupRepository.close()
        #expect(try MigrationDatabase.data(at: backupURL, sql: "SELECT store_generation FROM historical_store_identity") == firstGeneration)

        let secondRepository = try SQLiteEventJournalRepository(databaseURL: second.databaseURL)
        try await secondRepository.close()
        let secondStoredGeneration = try second.data(
            "SELECT store_generation FROM historical_store_identity"
        )
        let secondGeneration = try #require(secondStoredGeneration)
        #expect(secondGeneration.count == 16)
        #expect(secondGeneration != Data(repeating: 0, count: 16))
        #expect(secondGeneration != firstGeneration)
    }

    @Test("Invalid injected generations fail closed without committing v11")
    func rejectsInvalidStoreGeneration() async throws {
        for invalid in [Data(), Data(repeating: 1, count: 15), Data(repeating: 0, count: 16), Data(repeating: 1, count: 17)] {
            let fixture = try MigrationDatabase()
            defer { fixture.remove() }
            try await fixture.makeVersionTenWithLegacyHistory()
            #expect(throws: SQLiteHistoricalFindingCodecError.invalidStoreGeneration) {
                _ = try SQLiteEventJournalRepository(
                    databaseURL: fixture.databaseURL,
                    failurePoint: nil,
                    historicalStoreGenerationProvider: { Array(invalid) }
                )
            }
            #expect(try fixture.int("PRAGMA user_version") == 10)
        }
    }

    @Test("Committed node and frame marker AUTOINCREMENT values are never reused")
    func autoIncrementValuesAreNotReused() async throws {
        let fixture = try MigrationDatabase()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        try fixture.execute("""
            PRAGMA foreign_keys=OFF;
            DROP TRIGGER historical_frame_commit_validate;
            DROP TRIGGER historical_node_validate_insert;
            INSERT INTO historical_observation_node(
                batch_id,subject_key,location_key,parent_node_id,observed_at_ms,
                direct_children_coverage,classification_decision_id
            ) VALUES(1,1,1,NULL,1,1,NULL);
            INSERT INTO historical_observation_frame_commit(
                frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,
                retention_anchor_ms,expires_at_ms
            ) VALUES(1,1,1,1,1,1,2592000001);
            """)
        let firstNode = try fixture.int("SELECT max(node_id) FROM historical_observation_node")
        let firstSequence = try fixture.int("SELECT max(sequence) FROM historical_observation_frame_commit")
        try fixture.execute("""
            DELETE FROM historical_observation_frame_commit;
            DELETE FROM historical_observation_node;
            INSERT INTO historical_observation_node(
                batch_id,subject_key,location_key,parent_node_id,observed_at_ms,
                direct_children_coverage,classification_decision_id
            ) VALUES(2,2,2,NULL,2,1,NULL);
            INSERT INTO historical_observation_frame_commit(
                frame_id,root_node_id,root_metric,endpoint_count,committed_at_ms,
                retention_anchor_ms,expires_at_ms
            ) VALUES(2,2,1,1,2,2,2592000002);
            """)
        #expect(try fixture.int("SELECT max(node_id) FROM historical_observation_node") > firstNode)
        #expect(try fixture.int("SELECT max(sequence) FROM historical_observation_frame_commit") > firstSequence)
    }

    @Test("Endpoint IDs use the frozen store, node and metric vector")
    func endpointIDVectors() throws {
        let generation = Data(0...15)
        #expect(try SQLiteHistoricalFindingCodec.committedEndpointID(
            storeGeneration: generation,
            nodeID: 1,
            metricCode: 1
        ) == "st11:000102030405060708090a0b0c0d0e0f:0000000000000001:01")
        #expect(try SQLiteHistoricalFindingCodec.committedEndpointID(
            storeGeneration: generation,
            nodeID: Int64.max,
            metricCode: 2
        ) == "st11:000102030405060708090a0b0c0d0e0f:7fffffffffffffff:02")
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidNodeID) {
            _ = try SQLiteHistoricalFindingCodec.committedEndpointID(storeGeneration: generation, nodeID: 0, metricCode: 1)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidMetricCode) {
            _ = try SQLiteHistoricalFindingCodec.committedEndpointID(storeGeneration: generation, nodeID: 1, metricCode: 3)
        }
    }

    @Test("History policy persists every raw value from zero through thirty")
    func historyPolicyRawRoundTrips() async throws {
        let fixture = try MigrationDatabase()
        defer { fixture.remove() }
        var repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()
        for days in 0...30 {
            try fixture.execute("UPDATE historical_retention_policy SET path_history_days=\(days), updated_at_ms=\(days) WHERE singleton=1")
            repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
            #expect(try await repository.secureDeleteEnabledForTesting())
            try await repository.close()
            #expect(try fixture.int("SELECT path_history_days FROM historical_retention_policy") == Int64(days))
        }
        #expect(throws: (any Error).self) {
            try fixture.execute("UPDATE historical_retention_policy SET path_history_days=31 WHERE singleton=1")
        }
        #expect(throws: (any Error).self) {
            try fixture.execute("UPDATE historical_retention_policy SET path_history_days=-1 WHERE singleton=1")
        }
    }

    @Test("UTF-8 codec is byte-preserving, bounded, and rejects NUL or malformed data")
    func strictUTF8Boundaries() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let upper = "A"
        let lower = "a"
        let encoded = try [composed, decomposed, upper, lower].map {
            try SQLiteHistoricalFindingCodec.encodeUTF8($0, field: "identity", maximumBytes: 4_096)
        }
        #expect(Set(encoded).count == 4)
        for (value, data) in zip([composed, decomposed, upper, lower], encoded) {
            #expect(try SQLiteHistoricalFindingCodec.decodeUTF8(data, field: "identity", maximumBytes: 4_096) == value)
        }

        for limit in [1_024, 4_096, 65_536] {
            let boundary = String(repeating: "x", count: limit)
            #expect(try SQLiteHistoricalFindingCodec.encodeUTF8(boundary, field: "boundary", maximumBytes: limit).count == limit)
            #expect(throws: SQLiteHistoricalFindingCodecError.byteLengthOutOfRange) {
                _ = try SQLiteHistoricalFindingCodec.encodeUTF8(boundary + "x", field: "boundary", maximumBytes: limit)
            }
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.embeddedNUL) {
            _ = try SQLiteHistoricalFindingCodec.encodeUTF8("a\0b", field: "identity", maximumBytes: 4_096)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidUTF8) {
            _ = try SQLiteHistoricalFindingCodec.decodeUTF8(Data([0xC3, 0x28]), field: "identity", maximumBytes: 4_096)
        }
    }

    @Test("Frame and integer wire budgets fail closed")
    func frameAndWireBudgets() throws {
        try SQLiteHistoricalFindingCodec.validateFrameBudget(nodeCount: 50_000, decodedEvidenceBytes: 16 * 1_024 * 1_024)
        #expect(throws: SQLiteHistoricalFindingCodecError.frameNodeBudgetExceeded) {
            try SQLiteHistoricalFindingCodec.validateFrameBudget(nodeCount: 50_001, decodedEvidenceBytes: 0)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.frameByteBudgetExceeded) {
            try SQLiteHistoricalFindingCodec.validateFrameBudget(nodeCount: 1, decodedEvidenceBytes: 16 * 1_024 * 1_024 + 1)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.frameNodeBudgetExceeded) {
            try SQLiteHistoricalFindingCodec.validateFrameBudget(nodeCount: -1, decodedEvidenceBytes: 0)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.frameByteBudgetExceeded) {
            try SQLiteHistoricalFindingCodec.validateFrameBudget(nodeCount: 0, decodedEvidenceBytes: -1)
        }

        for invalidMetric in [Int64.min, -1, 0, 3, Int64.max] {
            #expect(throws: SQLiteHistoricalFindingCodecError.invalidMetricCode) {
                try SQLiteHistoricalFindingCodec.validateEndpointShape(
                    metricCode: invalidMetric,
                    stateCode: 1,
                    bytes: 1,
                    coverageCode: 1,
                    unknownReasonCode: nil
                )
            }
        }
        for invalidState in [Int64.min, -1, 0, 4, Int64.max] {
            #expect(throws: SQLiteHistoricalFindingCodecError.invalidEndpointShape) {
                try SQLiteHistoricalFindingCodec.validateEndpointShape(
                    metricCode: 1,
                    stateCode: invalidState,
                    bytes: nil,
                    coverageCode: nil,
                    unknownReasonCode: nil
                )
            }
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidEndpointShape) {
            try SQLiteHistoricalFindingCodec.validateEndpointShape(metricCode: 1, stateCode: 1, bytes: 1, coverageCode: 3, unknownReasonCode: nil)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidEndpointShape) {
            try SQLiteHistoricalFindingCodec.validateEndpointShape(metricCode: 1, stateCode: 3, bytes: nil, coverageCode: nil, unknownReasonCode: 7)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidAttributionShape) {
            try SQLiteHistoricalFindingCodec.validateAttributionShape(decisionKind: 1, categoryCode: 9, confidenceCode: 1, ruleVersion: 1)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidAttributionShape) {
            try SQLiteHistoricalFindingCodec.validateAttributionShape(decisionKind: 2, categoryCode: 1, confidenceCode: nil, ruleVersion: nil)
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidReasonCode) {
            try SQLiteHistoricalFindingCodec.validateReasonCode(category: 2, reasonCode: 35)
        }
    }

    @Test("The complete schema object digest is frozen and recorded by migration")
    func canonicalSchemaDigest() async throws {
        let fixture = try MigrationDatabase()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()

        let database = try fixture.open(SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(database) }
        let digest = try SQLiteHistoricalFindingCodec.schemaObjectDigest(database: database)
        #expect(digest == SQLiteHistoricalCorrectedRetractionSchema.frozenSchemaDigest)
        #expect(digest.count == 32)
        #expect(try fixture.text("SELECT checksum FROM schema_migration WHERE version=11") == SQLiteHistoricalFindingSchema.frozenSchemaDigest.map { String(format: "%02x", $0) }.joined())
        #expect(try fixture.text("SELECT checksum FROM schema_migration WHERE version=12") == SQLiteHistoricalCorrectionSchema.frozenSchemaDigest.map { String(format: "%02x", $0) }.joined())
        #expect(try fixture.text("SELECT checksum FROM schema_migration WHERE version=13") == digest.map { String(format: "%02x", $0) }.joined())
    }

    @Test("Reopen rejects historical schema object drift before serving writes")
    func reopenRejectsSchemaDrift() async throws {
        let fixture = try MigrationDatabase()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        try await repository.close()
        try fixture.execute("DROP TRIGGER historical_rank_validate_projection")

        #expect(throws: SQLiteEventJournalError.databaseCorrupt) {
            _ = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        }
    }
}

/// Older-version fixtures bootstrap through today's schema, then remove the
/// v12 and v11 graphs. Centralizing that teardown prevents test fixtures from
/// teaching production migration to accept a lower `user_version` alongside
/// already-present v11 tables.
func removeV11SchemaForLegacyMigrationFixture(at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        throw MigrationDatabaseError.sqlite("open v11 fixture cleanup")
    }
    defer { sqlite3_close_v2(database) }
    try MigrationDatabase.executeForFixture(database, "PRAGMA foreign_keys=OFF")
    let removableObjects = SQLiteHistoricalFindingSchema.frozenObjectNames
        .union(SQLiteHistoricalCorrectionSchema.prototypeObjectNames)
        .union(SQLiteHistoricalCorrectedRetractionSchema.frozenObjectNames)
    let objects = try MigrationDatabase.rowsForFixture(
        database,
        "SELECT type,name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'"
    ).filter { row in
        row.count == 2 && removableObjects.contains(row[1])
    }.sorted { lhs, rhs in
        let priority = ["trigger": 1, "index": 2, "table": 3]
        let left = priority[lhs[0], default: 4]
        let right = priority[rhs[0], default: 4]
        return left == right ? lhs[1] < rhs[1] : left < right
    }
    for object in objects {
        let type = object[0]
        let name = object[1]
        let keyword = type == "trigger" ? "TRIGGER" : type == "index" ? "INDEX" : "TABLE"
        let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        try MigrationDatabase.executeForFixture(database, "DROP \(keyword) \(quoted)")
    }
    try MigrationDatabase.executeForFixture(
        database,
        "DELETE FROM schema_migration WHERE version IN (11,12,13)"
    )
}

private final class MigrationDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v11-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("SpaceTrace.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func makeVersionTenWithLegacyHistory() async throws {
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try await repository.close()
        let database = try open(SQLITE_OPEN_READWRITE)
        defer { sqlite3_close_v2(database) }
        try Self.execute(database, "PRAGMA foreign_keys=OFF")
        let removableObjects = SQLiteHistoricalFindingSchema.frozenObjectNames
            .union(SQLiteHistoricalCorrectionSchema.prototypeObjectNames)
            .union(SQLiteHistoricalCorrectedRetractionSchema.frozenObjectNames)
        let objects = try Self.rows(
            database,
            "SELECT type,name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'"
        ).filter { row in
            row.count == 2 && removableObjects.contains(row[1])
        }.sorted { lhs, rhs in
            let priority = ["trigger": 1, "index": 2, "table": 3]
            let left = priority[lhs[0], default: 4]
            let right = priority[rhs[0], default: 4]
            return left == right ? lhs[1] < rhs[1] : left < right
        }
        for row in objects {
            guard row.count == 2 else { continue }
            let type = row[0]
            let name = row[1]
            let keyword = type == "trigger" ? "TRIGGER" : type == "index" ? "INDEX" : "TABLE"
            try Self.execute(database, "DROP \(keyword) \(Self.quotedIdentifier(name))")
        }
        try Self.execute(
            database,
            """
            DELETE FROM schema_migration WHERE version IN (11,12,13);
            PRAGMA user_version=10;
            INSERT INTO directory_history_sample(
                stream_id,path,bucket_kind,bucket_start_ms,logical_bytes,
                logical_delta,allocated_bytes,descendant_count,coverage,scan_run_id
            ) VALUES('legacy-stream','/Fixtures/Legacy','daily',1,2,1,3,0,'complete','legacy-run');
            """
        )
    }

    func createOnlineBackup(sourceVersion: Int32) throws -> URL {
        let database = try open(SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(database) }
        return try SQLiteMigrationBackup.create(
            sourceDatabase: database,
            databaseURL: databaseURL,
            sourceVersion: sourceVersion
        )
    }

    func historicalObjectNames() throws -> Set<String> {
        let rows = try rows("SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'")
        return Set(rows.compactMap(\.first)).intersection(
            SQLiteHistoricalFindingSchema.frozenObjectNames
        )
    }

    func execute(_ sql: String) throws {
        let database = try open(SQLITE_OPEN_READWRITE)
        defer { sqlite3_close_v2(database) }
        try Self.execute(database, sql)
    }

    func int(_ sql: String) throws -> Int64 { try Self.int(at: databaseURL, sql: sql) }
    func data(_ sql: String) throws -> Data? { try Self.data(at: databaseURL, sql: sql) }
    func text(_ sql: String) throws -> String? {
        let database = try open(SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MigrationDatabaseError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }
    func rows(_ sql: String) throws -> [[String]] {
        let database = try open(SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(database) }
        return try Self.rows(database, sql)
    }

    func open(_ flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else { throw MigrationDatabaseError.sqlite("open") }
        return database
    }

    static func int(at url: URL, sql: String) throws -> Int64 {
        var database: OpaquePointer?
        let uri = immutableURI(for: url)
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let database else { throw MigrationDatabaseError.sqlite("open") }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MigrationDatabaseError.sqlite(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw MigrationDatabaseError.sqlite(String(cString: sqlite3_errmsg(database))) }
        return sqlite3_column_int64(statement, 0)
    }

    static func data(at url: URL, sql: String) throws -> Data? {
        var database: OpaquePointer?
        let uri = immutableURI(for: url)
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let database else { throw MigrationDatabaseError.sqlite("open") }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MigrationDatabaseError.sqlite(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    fileprivate static func executeForFixture(
        _ database: OpaquePointer,
        _ sql: String
    ) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw MigrationDatabaseError.sqlite(detail)
        }
    }

    fileprivate static func rowsForFixture(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MigrationDatabaseError.sqlite(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for column in 0..<sqlite3_column_count(statement) {
                row.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            }
            result.append(row)
        }
        return result
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        try executeForFixture(database, sql)
    }

    private static func rows(_ database: OpaquePointer, _ sql: String) throws -> [[String]] {
        try rowsForFixture(database, sql)
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func immutableURI(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

private enum MigrationDatabaseError: Error {
    case sqlite(String)
}
