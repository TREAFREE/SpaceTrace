import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import SpaceTracePersistence

@Suite("Released-schema golden fixtures", .serialized)
struct ReleasedSchemaGoldenFixtureTests {
    @Test("Every checked-in fixture retains its reviewed bytes and migrates forward")
    func fixturesMigrateForward() async throws {
        let manifestURL = try #require(
            Bundle.module.url(
                forResource: "manifest",
                withExtension: "json",
                subdirectory: "Fixtures/ReleasedSchemas"
            )
        )
        let manifest = try JSONDecoder().decode(
            GoldenManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        #expect(manifest.formatVersion == 1)
        #expect(manifest.fixtures.map(\.schemaVersion) == [6, 7, 8, 9])

        for fixture in manifest.fixtures {
            let sourceURL = manifestURL.deletingLastPathComponent()
                .appendingPathComponent(fixture.relativePath)
            let bytes = try Data(contentsOf: sourceURL)
            #expect(SHA256.hash(data: bytes).hex == fixture.sha256)
            #expect(try readVersion(sourceURL) == fixture.schemaVersion)

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SpaceTrace-golden-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copyURL = directory.appendingPathComponent("SpaceTrace.sqlite")
            try FileManager.default.copyItem(at: sourceURL, to: copyURL)
            defer { try? FileManager.default.removeItem(at: directory) }

            let repository = try SQLiteEventJournalRepository(databaseURL: copyURL)
            try await repository.close()
            #expect(try readVersion(copyURL) == SQLiteEventJournalRepository.currentSchemaVersion)
        }
    }
}

private struct GoldenManifest: Decodable {
    let formatVersion: Int
    let fixtures: [GoldenFixture]
}

private struct GoldenFixture: Decodable {
    let schemaVersion: Int32
    let relativePath: String
    let sha256: String
}

private func readVersion(_ url: URL) throws -> Int32 {
    var database: OpaquePointer?
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    let uri = components?.url?.absoluteString ?? url.absoluteString
    guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
          let database else { throw GoldenFixtureError.sqlite }
    defer { _ = sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw GoldenFixtureError.sqlite }
    defer { _ = sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw GoldenFixtureError.sqlite }
    return sqlite3_column_int(statement, 0)
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private enum GoldenFixtureError: Error { case sqlite }
