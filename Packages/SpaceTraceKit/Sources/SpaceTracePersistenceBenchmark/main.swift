import Darwin
import Foundation
import SQLite3
import SpaceTraceApplication
@_spi(Benchmark) import SpaceTracePersistence

@main
enum SpaceTracePersistenceBenchmark {
    static func main() async throws {
        if CommandLine.arguments.contains("--mode") {
            try await runV11Prototype()
            return
        }
        let rowCount = try requestedRowCount()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTrace-history-benchmark-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("SpaceTrace.sqlite")

        let initialRepository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try await initialRepository.close()

        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let writeSamples = try seed(
            databaseURL: databaseURL,
            rowCount: rowCount,
            referenceDate: referenceDate
        )
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        let streamID = try EventStreamID("benchmark-stream")
        var querySamples: [Double] = []
        for _ in 0..<25 {
            let start = ContinuousClock.now
            let result = try await repository.topDirectoryGrowth(
                for: streamID,
                under: try DirtyRegionPath("/Benchmark"),
                from: referenceDate.addingTimeInterval(-7 * 86_400),
                through: referenceDate,
                limit: 100
            )
            guard result.count == 100 else { throw BenchmarkError.queryResult }
            querySamples.append(milliseconds(since: start))
        }
        let retentionStart = ContinuousClock.now
        let retention = try await repository.applyRetention(referenceDate: referenceDate)
        let retentionMilliseconds = milliseconds(since: retentionStart)
        try await repository.close()

        let checkpointMilliseconds = try checkpoint(databaseURL)
        let sizeBytes = try databaseSize(databaseURL)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let output = BenchmarkOutput(
            schemaVersion: SQLiteEventJournalRepository.currentSchemaVersion,
            rows: rowCount,
            writeBatchP95Milliseconds: percentile(writeSamples, 0.95),
            top100SevenDayP95Milliseconds: percentile(querySamples, 0.95),
            checkpointMilliseconds: checkpointMilliseconds,
            retentionMilliseconds: retentionMilliseconds,
            retainedPathRowsDeleted: retention.pathHistoryCount,
            databaseBytes: sizeBytes,
            peakResidentBytes: Int64(usage.ru_maxrss)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent(
                "SpaceTrace-history-benchmark-\(rowCount).json"
            ),
            options: .atomic
        )
    }

    private static func runV11Prototype() async throws {
        let arguments = CommandLine.arguments
        guard value(after: "--mode", in: arguments) == "v11-prototype",
              let sampleText = value(after: "--directory-samples", in: arguments),
              let directorySamples = Int(sampleText),
              directorySamples == 500_000 || directorySamples == 1_000_000,
              let scenarioText = value(after: "--scenario", in: arguments)
        else {
            throw BenchmarkError.arguments
        }
        let scenarios: [SQLiteHistoricalPrototypeScenario]
        if scenarioText == "matrix" {
            scenarios = SQLiteHistoricalPrototypeScenario.allCases
        } else if let scenario = SQLiteHistoricalPrototypeScenario(rawValue: scenarioText) {
            scenarios = [scenario]
        } else {
            throw BenchmarkError.arguments
        }

        var results: [SQLiteHistoricalPrototypeResult] = []
        for scenario in scenarios {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SpaceTrace-v11-\(directorySamples)-\(scenario.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("SpaceTrace.sqlite")
            let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
            try await repository.close()
            results.append(
                try SQLiteHistoricalFindingSchema.runPrototype(
                    databaseURL: databaseURL,
                    directorySamples: directorySamples,
                    scenario: scenario
                )
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent(
                "SpaceTrace-v11-prototype-\(directorySamples).json"
            ),
            options: .atomic
        )
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private static func requestedRowCount() throws -> Int {
        guard let value = CommandLine.arguments.dropFirst().first,
              let count = Int(value),
              count == 500_000 || count == 1_000_000 else {
            throw BenchmarkError.arguments
        }
        return count
    }

    private static func seed(
        databaseURL: URL,
        rowCount: Int,
        referenceDate: Date
    ) throws -> [Double] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw BenchmarkError.sqlite("open seed database") }
        defer { _ = sqlite3_close_v2(database) }
        guard sqlite3_exec(database, "PRAGMA synchronous=NORMAL", nil, nil, nil) == SQLITE_OK else {
            throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        let sql = """
            INSERT INTO directory_history_sample(
                stream_id,path,bucket_kind,bucket_start_ms,logical_bytes,
                logical_delta,allocated_bytes,descendant_count,coverage,scan_run_id
            ) VALUES('benchmark-stream',?1,'daily',?2,?3,?4,?3,10,'complete','benchmark')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database))) }
        defer { _ = sqlite3_finalize(statement) }
        let base = Int64(referenceDate.timeIntervalSince1970 * 1_000)
        var samples: [Double] = []
        for batchStart in stride(from: 0, to: rowCount, by: 500) {
            let started = ContinuousClock.now
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            for index in batchStart..<min(batchStart + 500, rowCount) {
                let day = index % 35
                let pathIndex = index / 35
                let path = String(format: "/Benchmark/p%07d", pathIndex)
                let bindResult = path.withCString {
                    sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient)
                }
                guard bindResult == SQLITE_OK else {
                    throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database)))
                }
                sqlite3_bind_int64(statement, 2, base - Int64(34 - day) * 86_400_000)
                sqlite3_bind_int64(statement, 3, Int64(pathIndex * 1_000 + day * 100))
                sqlite3_bind_int64(statement, 4, day == 0 ? 0 : 100)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database)))
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            samples.append(milliseconds(since: started))
        }
        return samples
    }

    private static func checkpoint(_ url: URL) throws -> Double {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw BenchmarkError.sqlite("open checkpoint database") }
        defer { _ = sqlite3_close_v2(database) }
        let start = ContinuousClock.now
        guard sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else {
            throw BenchmarkError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return milliseconds(since: start)
    }

    private static func databaseSize(_ url: URL) throws -> Int64 {
        try ["", "-wal", "-shm"].reduce(0) { result, suffix in
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { return result }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return result + ((attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * percentile).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }
}

private struct BenchmarkOutput: Encodable {
    let schemaVersion: Int
    let rows: Int
    let writeBatchP95Milliseconds: Double
    let top100SevenDayP95Milliseconds: Double
    let checkpointMilliseconds: Double
    let retentionMilliseconds: Double
    let retainedPathRowsDeleted: Int
    let databaseBytes: Int64
    let peakResidentBytes: Int64
}

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private enum BenchmarkError: Error {
    case arguments
    case sqlite(String)
    case queryResult
}
