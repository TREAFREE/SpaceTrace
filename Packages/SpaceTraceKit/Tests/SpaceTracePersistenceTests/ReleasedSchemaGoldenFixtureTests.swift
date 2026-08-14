import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import SpaceTracePersistence

@Suite("Released-schema golden fixtures", .serialized)
struct ReleasedSchemaGoldenFixtureTests {
    @Test("Frozen legacy bytes and generated v10-v13 fixtures migrate to current schema")
    func fixturesMigrateForward() async throws {
        let root = try releasedFixtureRoot()
        for fixture in legacyFixtures {
            let sourceURL = root.appendingPathComponent("v\(fixture.version)/SpaceTrace.sqlite")
            #expect(try digest(sourceURL) == fixture.sha256)
            #expect(try readVersion(sourceURL) == fixture.version)
            try await assertMigratesToCurrent(sourceURL)
        }

        let manifest = try loadManifest(root: root)
        #expect(manifest.formatVersion == 2)
        #expect(manifest.fixtures.map(\.schemaVersion) == [10, 11, 12, 13])
        for fixture in manifest.fixtures {
            let sourceURL = root.appendingPathComponent(fixture.relativePath)
            #expect(try digest(sourceURL) == fixture.sha256)
            #expect(try readVersion(sourceURL) == fixture.schemaVersion)
            try await assertMigratesToCurrent(sourceURL)
        }
    }

    @Test("Manifest v2 freezes exact types, paths, generator bytes and logical regeneration")
    func manifestAndGeneratorsAreCanonical() throws {
        let root = try releasedFixtureRoot()
        let manifestURL = root.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["formatVersion", "fixtures"])
        #expect(try #require(object["formatVersion"]) is NSNumber)
        #expect((object["formatVersion"] as? NSNumber)?.intValue == 2)
        let entries = try #require(object["fixtures"] as? [[String: Any]])
        #expect(entries.count == 4)

        let manifest = try JSONDecoder().decode(GoldenManifest.self, from: data)
        for (entry, raw) in zip(manifest.fixtures, entries) {
            #expect(Set(raw.keys) == GoldenFixture.expectedKeys)
            #expect(try #require(raw["schemaVersion"]) is NSNumber)
            #expect(try #require(raw["generatorVersion"]) is NSNumber)
            for key in GoldenFixture.stringKeys {
                #expect(try #require(raw[key]) is String)
            }
            #expect(entry.relativePath == "v\(entry.schemaVersion)/SpaceTrace.sqlite")
            #expect(
                entry.generatorPath
                    == "Scripts/Fixtures/generate-released-schema-v\(entry.schemaVersion)-fixture.sh"
            )
            #expect(entry.generatorVersion == 1)
            for value in [
                entry.sha256, entry.generatorSHA256,
                entry.semanticSHA256, entry.schemaObjectSHA256,
            ] {
                #expect(value.count == 64)
                #expect(value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) })
            }

            let generatorURL = repositoryRoot().appendingPathComponent(entry.generatorPath)
            #expect(try digest(generatorURL) == entry.generatorSHA256)
        }

        let verifier = repositoryRoot().appendingPathComponent(
            "Scripts/verify-released-schema-fixtures.sh"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [verifier.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("A populated v10 fixture migrates atomically to empty v11/v12 evidence")
    func versionTenMigratesToEleven() async throws {
        let copy = try fixtureCopy(version: 10)
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        #expect(try scalar(copy.database, "SELECT count(*) FROM node_current") == 2)

        let repository = try SQLiteEventJournalRepository(databaseURL: copy.database)
        try await repository.close()
        #expect(try readVersion(copy.database) == 13)
        #expect(try scalar(copy.database, "SELECT count(*) FROM node_current") == 2)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_observation_node") == 0)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_reconciliation_revision") == 0)
        #expect(try scalar(copy.database, "PRAGMA foreign_key_check") == 0)
    }

    @Test("A populated v11 fixture migrates without rewriting its ledger")
    func versionElevenMigrates() async throws {
        let copy = try fixtureCopy(version: 11)
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        let before = try scalar(copy.database, "SELECT count(*) FROM historical_observation_node")
        let repository = try SQLiteEventJournalRepository(databaseURL: copy.database)
        try await repository.close()
        #expect(try readVersion(copy.database) == 13)
        #expect(before == 2)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_observation_node") == before)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_observation_frame_commit") == 2)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_reconciliation_revision") == 0)
    }

    @Test("A populated v12 fixture reopens without rewriting either immutable lane")
    func versionTwelveReopens() async throws {
        let copy = try fixtureCopy(version: 12)
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        let nodes = try scalar(copy.database, "SELECT count(*) FROM historical_observation_node")
        let revisions = try scalar(copy.database, "SELECT count(*) FROM historical_reconciliation_revision")
        let corrections = try scalar(copy.database, "SELECT count(*) FROM historical_projection_correction_checkpoint")
        let repository = try SQLiteEventJournalRepository(databaseURL: copy.database)
        try await repository.close()
        #expect(try readVersion(copy.database) == 13)
        #expect(nodes == 4)
        #expect(revisions == 4)
        #expect(corrections == 1)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_observation_node") == nodes)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_reconciliation_revision") == revisions)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_projection_correction_checkpoint") == corrections)
    }

    @Test("A populated v13 fixture reopens without fabricating a corrected invalidation")
    func versionThirteenReopens() async throws {
        let copy = try fixtureCopy(version: 13)
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        let nodes = try scalar(copy.database, "SELECT count(*) FROM historical_observation_node")
        let corrections = try scalar(
            copy.database,
            "SELECT count(*) FROM historical_projection_correction_checkpoint"
        )
        let repository = try SQLiteEventJournalRepository(databaseURL: copy.database)
        try await repository.close()
        #expect(try readVersion(copy.database) == 13)
        #expect(try scalar(copy.database, "SELECT count(*) FROM historical_observation_node") == nodes)
        #expect(
            try scalar(
                copy.database,
                "SELECT count(*) FROM historical_projection_correction_checkpoint"
            ) == corrections
        )
        #expect(
            try scalar(
                copy.database,
                "SELECT count(*) FROM historical_corrected_finding_retraction"
            ) == 0
        )
    }

    @Test("An injected v11 migration failure leaves the v10 main and backup readable")
    func versionElevenMigrationRollsBack() throws {
        let copy = try fixtureCopy(version: 10)
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        #expect(throws: SQLiteEventJournalError.migrationFailed(fromVersion: 10, targetVersion: 11)) {
            _ = try SQLiteEventJournalRepository(
                databaseURL: copy.database,
                failurePoint: .beforeMigrationCommit(version: 11)
            )
        }
        #expect(try readVersion(copy.database) == 10)
        #expect(try scalar(copy.database, "SELECT count(*) FROM node_current") == 2)
        let backup = SQLiteMigrationBackup.backupURL(for: copy.database, sourceVersion: 10)
        #expect(try readVersion(backup) == 10)
    }

    @Test("Missing v11 indexes and triggers fail before writes")
    func schemaObjectDriftFailsClosed() throws {
        for sql in [
            "DROP INDEX historical_metric_endpoint_frame",
            "DROP TRIGGER historical_frame_commit_validate",
        ] {
            let copy = try fixtureCopy(version: 11)
            defer { try? FileManager.default.removeItem(at: copy.directory) }
            try execute(copy.database, sql)
            #expect(throws: SQLiteEventJournalError.databaseCorrupt) {
                _ = try SQLiteEventJournalRepository(databaseURL: copy.database)
            }
        }
    }

    @Test("Foreign-key ledger corruption fails before writes")
    func logicalLedgerCorruptionFailsClosed() throws {
        let copy = try fixtureCopy(version: 11)
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        try execute(
            copy.database,
            "PRAGMA foreign_keys=OFF; DELETE FROM historical_scope WHERE scope_key=1"
        )
        #expect(throws: SQLiteEventJournalError.databaseCorrupt) {
            _ = try SQLiteEventJournalRepository(databaseURL: copy.database)
        }
    }

    @Test("Unsupported v14 is rejected without persistent mutation")
    func unsupportedFutureSchemaDoesNotMutate() throws {
        let copy = try fixtureCopy(version: 12)
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        try execute(copy.database, "PRAGMA journal_mode=DELETE; PRAGMA user_version=14")
        let before = try Data(contentsOf: copy.database)
        #expect(throws: SQLiteEventJournalError.unsupportedSchemaVersion(14)) {
            _ = try SQLiteEventJournalRepository(databaseURL: copy.database)
        }
        #expect(try Data(contentsOf: copy.database) == before)
        #expect(FileManager.default.fileExists(atPath: copy.database.path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: copy.database.path + "-shm") == false)
    }
}

private struct GoldenManifest: Decodable {
    let formatVersion: Int
    let fixtures: [GoldenFixture]
}

private struct GoldenFixture: Decodable {
    static let expectedKeys: Set<String> = [
        "schemaVersion", "relativePath", "sha256", "generatorPath",
        "generatorSHA256", "generatorVersion", "seed", "semanticSHA256",
        "schemaObjectSHA256",
    ]
    static let stringKeys: [String] = [
        "relativePath", "sha256", "generatorPath", "generatorSHA256", "seed",
        "semanticSHA256", "schemaObjectSHA256",
    ]

    let schemaVersion: Int32
    let relativePath: String
    let sha256: String
    let generatorPath: String
    let generatorSHA256: String
    let generatorVersion: Int
    let seed: String
    let semanticSHA256: String
    let schemaObjectSHA256: String
}

private let legacyFixtures: [(version: Int32, sha256: String)] = [
    (6, "5a5bbe6cdf57ac6c5e4398a771b6505e29e4775b4f321fd5ed1097ff30bae528"),
    (7, "beccfcbf1bf40ad2f3f89997d58f61aeacb7b0126ed9a4c813b9448a3cdfb95c"),
    (8, "8d2d9468362f685e8e485ae291d007c0b70aaf06d691dd8ff2f50c2de506eeb5"),
    (9, "fdc8a4452202260b6bbefd47c122c60e98ad7a959f184646a06ed067817c7108"),
]

private func repositoryRoot() -> URL {
    var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while current.path != "/" {
        if FileManager.default.fileExists(
            atPath: current.appendingPathComponent("SpaceTrace.xcodeproj").path
        ) { return current }
        current.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
}

private func releasedFixtureRoot() throws -> URL {
    try #require(
        Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Fixtures/ReleasedSchemas"
        )
    ).deletingLastPathComponent()
}

private func loadManifest(root: URL) throws -> GoldenManifest {
    try JSONDecoder().decode(
        GoldenManifest.self,
        from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
    )
}

private func fixtureCopy(version: Int32) throws -> (directory: URL, database: URL) {
    let root = try releasedFixtureRoot()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SpaceTrace-golden-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = directory.appendingPathComponent("SpaceTrace.sqlite")
    try FileManager.default.copyItem(
        at: root.appendingPathComponent("v\(version)/SpaceTrace.sqlite"),
        to: database
    )
    return (directory, database)
}

private func assertMigratesToCurrent(_ sourceURL: URL) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SpaceTrace-golden-migration-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let copyURL = directory.appendingPathComponent("SpaceTrace.sqlite")
    try FileManager.default.copyItem(at: sourceURL, to: copyURL)
    let repository = try SQLiteEventJournalRepository(databaseURL: copyURL)
    try await repository.close()
    #expect(try readVersion(copyURL) == SQLiteEventJournalRepository.currentSchemaVersion)
}

private func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).hex
}

private func execute(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let database else { throw GoldenFixtureError.sqlite }
    defer { _ = sqlite3_close_v2(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw GoldenFixtureError.sqlite
    }
}

private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
    var database: OpaquePointer?
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    let uri = components?.url?.absoluteString ?? url.absoluteString
    guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
          let database else { throw GoldenFixtureError.sqlite }
    defer { _ = sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw GoldenFixtureError.sqlite }
    defer { _ = sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int64(statement, 0)
}

private func readVersion(_ url: URL) throws -> Int32 {
    Int32(try scalar(url, "PRAGMA user_version"))
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private enum GoldenFixtureError: Error { case sqlite }
