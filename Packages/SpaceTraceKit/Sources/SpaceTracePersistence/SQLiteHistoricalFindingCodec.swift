import CryptoKit
import Foundation
import SQLite3

enum SQLiteHistoricalFindingCodecError: Error, Sendable, Equatable {
    case invalidStoreGeneration
    case invalidNodeID
    case invalidMetricCode
    case byteLengthOutOfRange
    case embeddedNUL
    case invalidUTF8
    case frameNodeBudgetExceeded
    case frameByteBudgetExceeded
    case invalidEndpointShape
    case invalidAttributionShape
    case invalidReasonCode
    case invalidCorrectionVersion
    case invalidCorrectionCount
    case invalidSchemaDigest
    case sqlite
}

/// Strict wire codec for the schema-v11 historical ledger.
///
/// SQLite stores filesystem identities and explanatory text as raw UTF-8
/// BLOBs so canonically equivalent or case-distinct byte strings never merge.
/// Every decoding entry point validates before constructing a Swift value.
enum SQLiteHistoricalFindingCodec {
    static let storeGenerationByteCount = 16
    static let maximumIdentifierBytes = 4_096
    static let maximumDisplayNameBytes = 1_024
    static let maximumCanonicalPayloadBytes = 65_536
    static let maximumFrameNodeCount = 50_000
    static let maximumFrameDecodedEvidenceBytes = 16 * 1_024 * 1_024

    static func validateCorrectionRequestID(_ value: Data) throws -> Data {
        guard value.count == 16 else {
            throw SQLiteHistoricalFindingCodecError.byteLengthOutOfRange
        }
        return value
    }

    static func validateCorrectionDigest(_ value: Data) throws -> Data {
        guard value.count == 32 else {
            throw SQLiteHistoricalFindingCodecError.byteLengthOutOfRange
        }
        return value
    }

    static func encodeCorrectionPayload(_ value: String) throws -> Data {
        try encodeUTF8(
            value,
            field: "correction_payload",
            maximumBytes: maximumCanonicalPayloadBytes
        )
    }

    static func decodeCorrectionPayload(_ value: Data) throws -> String {
        try decodeUTF8(
            value,
            field: "correction_payload",
            maximumBytes: maximumCanonicalPayloadBytes
        )
    }

    static func validateCorrectionVersions(
        requestFormat: Int64,
        algorithm: Int64,
        rankingPolicy: Int64,
        inputFormat: Int64,
        resultFormat: Int64
    ) throws {
        guard requestFormat == 1,
              algorithm > 0,
              rankingPolicy > 0,
              inputFormat > 0,
              resultFormat == 1 else {
            throw SQLiteHistoricalFindingCodecError.invalidCorrectionVersion
        }
    }

    static func validateCorrectionCounts(
        findings: Int64,
        rankedPositive: Int64,
        reasons: Int64,
        truncatedPositive: Int64
    ) throws {
        guard (0...50_000).contains(findings),
              (0...100).contains(rankedPositive),
              rankedPositive <= findings,
              (0...38).contains(reasons),
              truncatedPositive >= 0 else {
            throw SQLiteHistoricalFindingCodecError.invalidCorrectionCount
        }
    }

    static func randomStoreGeneration() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        while true {
            let bytes = (0..<storeGenerationByteCount).map { _ in
                UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            }
            let generation = Data(bytes)
            if generation.contains(where: { $0 != 0 }) {
                return generation
            }
        }
    }

    static func validateStoreGeneration(_ generation: Data) throws {
        guard generation.count == storeGenerationByteCount,
              generation.contains(where: { $0 != 0 }) else {
            throw SQLiteHistoricalFindingCodecError.invalidStoreGeneration
        }
    }

    static func committedEndpointID(
        storeGeneration: Data,
        nodeID: Int64,
        metricCode: Int64
    ) throws -> String {
        try validateStoreGeneration(storeGeneration)
        guard nodeID > 0 else {
            throw SQLiteHistoricalFindingCodecError.invalidNodeID
        }
        guard metricCode == 1 || metricCode == 2 else {
            throw SQLiteHistoricalFindingCodecError.invalidMetricCode
        }
        let generation = storeGeneration.map { String(format: "%02x", $0) }.joined()
        let node = String(format: "%016llx", UInt64(nodeID))
        return "st11:\(generation):\(node):\(String(format: "%02lld", metricCode))"
    }

    static func encodeUTF8(
        _ value: String,
        field _: String,
        maximumBytes: Int
    ) throws -> Data {
        let data = Data(value.utf8)
        try validateUTF8Bytes(data, maximumBytes: maximumBytes)
        return data
    }

    static func decodeUTF8(
        _ data: Data,
        field _: String,
        maximumBytes: Int
    ) throws -> String {
        try validateUTF8Bytes(data, maximumBytes: maximumBytes)
        guard let value = String(data: data, encoding: .utf8) else {
            throw SQLiteHistoricalFindingCodecError.invalidUTF8
        }
        return value
    }

    static func validateFrameBudget(
        nodeCount: Int,
        decodedEvidenceBytes: Int
    ) throws {
        guard nodeCount >= 0, nodeCount <= maximumFrameNodeCount else {
            throw SQLiteHistoricalFindingCodecError.frameNodeBudgetExceeded
        }
        guard decodedEvidenceBytes >= 0,
              decodedEvidenceBytes <= maximumFrameDecodedEvidenceBytes else {
            throw SQLiteHistoricalFindingCodecError.frameByteBudgetExceeded
        }
    }

    static func validateEndpointShape(
        metricCode: Int64,
        stateCode: Int64,
        bytes: Int64?,
        coverageCode: Int64?,
        unknownReasonCode: Int64?
    ) throws {
        guard metricCode == 1 || metricCode == 2 else {
            throw SQLiteHistoricalFindingCodecError.invalidMetricCode
        }
        switch stateCode {
        case 1:
            guard let bytes, bytes >= 0,
                  coverageCode == 1 || coverageCode == 2,
                  unknownReasonCode == nil else {
                throw SQLiteHistoricalFindingCodecError.invalidEndpointShape
            }
        case 2:
            guard bytes == nil, coverageCode == nil, unknownReasonCode == nil else {
                throw SQLiteHistoricalFindingCodecError.invalidEndpointShape
            }
        case 3:
            guard bytes == nil, coverageCode == nil,
                  let unknownReasonCode, (1...6).contains(unknownReasonCode) else {
                throw SQLiteHistoricalFindingCodecError.invalidEndpointShape
            }
        default:
            throw SQLiteHistoricalFindingCodecError.invalidEndpointShape
        }
    }

    static func validateAttributionShape(
        decisionKind: Int64,
        categoryCode: Int64?,
        confidenceCode: Int64?,
        ruleVersion: Int64?
    ) throws {
        switch decisionKind {
        case 1:
            guard let categoryCode, (1...8).contains(categoryCode),
                  let confidenceCode, (1...3).contains(confidenceCode),
                  let ruleVersion, ruleVersion > 0 else {
                throw SQLiteHistoricalFindingCodecError.invalidAttributionShape
            }
        case 2, 3:
            guard categoryCode == nil, confidenceCode == nil, ruleVersion == nil else {
                throw SQLiteHistoricalFindingCodecError.invalidAttributionShape
            }
        default:
            throw SQLiteHistoricalFindingCodecError.invalidAttributionShape
        }
    }

    static func validateReasonCode(category: Int64, reasonCode: Int64) throws {
        let valid: Bool
        switch category {
        case 1: valid = (1...30).contains(reasonCode)
        case 2: valid = (31...34).contains(reasonCode)
        case 3: valid = (35...38).contains(reasonCode)
        default: valid = false
        }
        guard valid else {
            throw SQLiteHistoricalFindingCodecError.invalidReasonCode
        }
    }

    /// Hashes exact `sqlite_schema` object bytes. Compiler-generated
    /// `sqlite_%` objects are excluded; their defining UNIQUE clauses remain
    /// covered by their owning table SQL.
    static func schemaObjectDigest(database: OpaquePointer) throws -> Data {
        var statement: OpaquePointer?
        let sql = """
            SELECT type, name, tbl_name, sql
            FROM sqlite_schema
            WHERE type IN ('table', 'index', 'trigger')
              AND name NOT LIKE 'sqlite_%'
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        defer { sqlite3_finalize(statement) }

        var objects: [SchemaObject] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteHistoricalFindingCodecError.sqlite
            }
            objects.append(
                SchemaObject(
                    type: try readSchemaText(statement, column: 0),
                    name: try readSchemaText(statement, column: 1),
                    tableName: try readSchemaText(statement, column: 2),
                    sql: try readOptionalSchemaText(statement, column: 3)
                )
            )
        }

        objects.sort { lhs, rhs in
            for pair in [(lhs.type, rhs.type), (lhs.name, rhs.name), (lhs.tableName, rhs.tableName)] {
                if pair.0 != pair.1 {
                    return pair.0.lexicographicallyPrecedes(pair.1)
                }
            }
            return false
        }

        var canonical = Data()
        appendLengthPrefixed(Data("SpaceTrace.SQLite.schema-object-digest.v1".utf8), to: &canonical)
        for object in objects {
            appendLengthPrefixed(object.type, to: &canonical)
            appendLengthPrefixed(object.name, to: &canonical)
            appendLengthPrefixed(object.tableName, to: &canonical)
            if let sql = object.sql {
                canonical.append(0)
                appendLengthPrefixed(sql, to: &canonical)
            } else {
                canonical.append(0xFF)
            }
        }
        return Data(SHA256.hash(data: canonical))
    }

    static func validateInstalledV11(database: OpaquePointer) throws {
        let digest = try schemaObjectDigest(database: database)
        let expectedChecksum = digest.map { String(format: "%02x", $0) }.joined()
        let storedChecksum = try readSingleText(
            database,
            sql: "SELECT checksum FROM schema_migration WHERE version=11"
        )
        guard storedChecksum == expectedChecksum else {
            throw SQLiteHistoricalFindingCodecError.invalidSchemaDigest
        }

        let generation = try readSingleBlob(
            database,
            sql: "SELECT store_generation FROM historical_store_identity WHERE singleton=1 AND format_version=1"
        )
        try validateStoreGeneration(generation)
        guard try readSingleInteger(
            database,
            sql: "SELECT count(*) FROM historical_retention_policy WHERE singleton=1"
        ) == 1 else {
            throw SQLiteHistoricalFindingCodecError.invalidSchemaDigest
        }
    }

    static func validateInstalledV12(
        database: OpaquePointer,
        frozenSchemaDigest: Data
    ) throws {
        let digest = try schemaObjectDigest(database: database)
        let expectedChecksum = digest.map { String(format: "%02x", $0) }.joined()
        let storedChecksum = try readSingleText(
            database,
            sql: "SELECT checksum FROM schema_migration WHERE version=12"
        )
        guard storedChecksum == expectedChecksum else {
            throw SQLiteHistoricalFindingCodecError.invalidSchemaDigest
        }
        let sourceV11Checksum = try readSingleText(
            database,
            sql: "SELECT checksum FROM schema_migration WHERE version=11"
        )
        let frozenV11Checksum = SQLiteHistoricalFindingSchema.frozenSchemaDigest
            .map { String(format: "%02x", $0) }
            .joined()
        guard sourceV11Checksum != frozenV11Checksum || digest == frozenSchemaDigest else {
            throw SQLiteHistoricalFindingCodecError.invalidSchemaDigest
        }

        let generation = try readSingleBlob(
            database,
            sql: "SELECT store_generation FROM historical_store_identity WHERE singleton=1 AND format_version=1"
        )
        try validateStoreGeneration(generation)
        guard try readSingleInteger(
            database,
            sql: "SELECT count(*) FROM historical_retention_policy WHERE singleton=1"
        ) == 1 else {
            throw SQLiteHistoricalFindingCodecError.invalidSchemaDigest
        }
    }

    private static func validateUTF8Bytes(_ data: Data, maximumBytes: Int) throws {
        guard maximumBytes > 0, !data.isEmpty, data.count <= maximumBytes else {
            throw SQLiteHistoricalFindingCodecError.byteLengthOutOfRange
        }
        guard data.contains(0) == false else {
            throw SQLiteHistoricalFindingCodecError.embeddedNUL
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SQLiteHistoricalFindingCodecError.invalidUTF8
        }
    }

    private static func readSchemaText(
        _ statement: OpaquePointer,
        column: Int32
    ) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func readOptionalSchemaText(
        _ statement: OpaquePointer,
        column: Int32
    ) throws -> Data? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        return try readSchemaText(statement, column: column)
    }

    private static func appendLengthPrefixed(_ data: Data, to target: inout Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { target.append(contentsOf: $0) }
        target.append(data)
    }

    private static func readSingleText(
        _ database: OpaquePointer,
        sql: String
    ) throws -> String {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, 0) else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        guard sqlite3_step(statement) == SQLITE_DONE,
              let value = String(data: data, encoding: .utf8) else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        return value
    }

    private static func readSingleBlob(
        _ database: OpaquePointer,
        sql: String
    ) throws -> Data {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        return data
    }

    private static func readSingleInteger(
        _ database: OpaquePointer,
        sql: String
    ) throws -> Int64 {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        let value = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        return value
    }

    private static func prepare(
        _ database: OpaquePointer,
        sql: String
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteHistoricalFindingCodecError.sqlite
        }
        return statement
    }
}

private struct SchemaObject {
    let type: Data
    let name: Data
    let tableName: Data
    let sql: Data?
}
