import Foundation
import SQLite3
import Testing
@_spi(Benchmark) @testable import SpaceTracePersistence

@Suite("SQLite v12 correction codec", .serialized)
struct SQLiteHistoricalCorrectionCodecTests {
    @Test("Correction scalar payloads have exact byte and UTF-8 bounds")
    func scalarBounds() throws {
        #expect(try SQLiteHistoricalFindingCodec.validateCorrectionRequestID(Data(repeating: 1, count: 16)).count == 16)
        #expect(try SQLiteHistoricalFindingCodec.validateCorrectionDigest(Data(repeating: 2, count: 32)).count == 32)
        let encoded = try SQLiteHistoricalFindingCodec.encodeCorrectionPayload("{\"fixture\":\"v12\"}")
        #expect(try SQLiteHistoricalFindingCodec.decodeCorrectionPayload(encoded) == "{\"fixture\":\"v12\"}")
        for invalidCount in [0, 15, 17] {
            #expect(throws: SQLiteHistoricalFindingCodecError.byteLengthOutOfRange) {
                _ = try SQLiteHistoricalFindingCodec.validateCorrectionRequestID(
                    Data(repeating: 1, count: invalidCount)
                )
            }
        }
        for invalidCount in [0, 31, 33] {
            #expect(throws: SQLiteHistoricalFindingCodecError.byteLengthOutOfRange) {
                _ = try SQLiteHistoricalFindingCodec.validateCorrectionDigest(
                    Data(repeating: 2, count: invalidCount)
                )
            }
        }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidUTF8) {
            _ = try SQLiteHistoricalFindingCodec.decodeCorrectionPayload(Data([0xC3, 0x28]))
        }
    }

    @Test("Correction versions and aggregate counts are closed and bounded")
    func versionAndCountBounds() throws {
        try SQLiteHistoricalFindingCodec.validateCorrectionVersions(
            requestFormat: 1,
            algorithm: 2,
            rankingPolicy: 1,
            inputFormat: 1,
            resultFormat: 1
        )
        try SQLiteHistoricalFindingCodec.validateCorrectionCounts(
            findings: 50_000,
            rankedPositive: 100,
            reasons: 38,
            truncatedPositive: 0
        )
        for versions in [
            (0, 1, 1, 1, 1),
            (1, 0, 1, 1, 1),
            (1, 1, 0, 1, 1),
            (1, 1, 1, 0, 1),
            (1, 1, 1, 1, 2),
        ] {
            #expect(throws: SQLiteHistoricalFindingCodecError.invalidCorrectionVersion) {
                try SQLiteHistoricalFindingCodec.validateCorrectionVersions(
                    requestFormat: Int64(versions.0),
                    algorithm: Int64(versions.1),
                    rankingPolicy: Int64(versions.2),
                    inputFormat: Int64(versions.3),
                    resultFormat: Int64(versions.4)
                )
            }
        }
        for counts in [
            (-1, 0, 0, 0),
            (50_001, 0, 0, 0),
            (1, 2, 0, 0),
            (101, 101, 0, 0),
            (1, 0, 39, 0),
            (1, 0, 0, -1),
        ] {
            #expect(throws: SQLiteHistoricalFindingCodecError.invalidCorrectionCount) {
                try SQLiteHistoricalFindingCodec.validateCorrectionCounts(
                    findings: Int64(counts.0),
                    rankedPositive: Int64(counts.1),
                    reasons: Int64(counts.2),
                    truncatedPositive: Int64(counts.3)
                )
            }
        }
    }

    @Test("The installed-schema validator rejects a missing v12 trigger")
    func installedSchemaDrift() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-v12-codec-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("SpaceTrace.sqlite")
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try await repository.close()

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw CorrectionCodecTestError.sqlite }
        defer { sqlite3_close_v2(database) }
        try SQLiteHistoricalCorrectionRepository.validateInstalledSchema(database: database)
        guard sqlite3_exec(
            database,
            "DROP TRIGGER historical_correction_checkpoint_validate_insert",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw CorrectionCodecTestError.sqlite }
        #expect(throws: SQLiteHistoricalFindingCodecError.invalidSchemaDigest) {
            try SQLiteHistoricalCorrectionRepository.validateInstalledSchema(database: database)
        }
    }
}

private enum CorrectionCodecTestError: Error { case sqlite }
