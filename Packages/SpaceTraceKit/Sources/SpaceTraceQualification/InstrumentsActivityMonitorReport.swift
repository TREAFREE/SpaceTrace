import Foundation

public enum InstrumentsActivityMonitorAnalysisError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case inputIsNotDirectory
    case noSlices
    case missingCompanionFile(String)
    case malformedXML
    case unresolvedReference
    case columnCountMismatch
    case unexpectedSchema(String)
    case missingValue(String)
    case unusableCPUData(String)
    case counterRegression(String)
    case ledgerPrecedesLiveSeries(String)

    public var description: String {
        switch self {
        case .inputIsNotDirectory:
            "input_is_not_directory"
        case .noSlices:
            "no_slices"
        case let .missingCompanionFile(value):
            "missing_companion_file:\(value)"
        case .malformedXML:
            "malformed_xml"
        case .unresolvedReference:
            "unresolved_reference"
        case .columnCountMismatch:
            "column_count_mismatch"
        case let .unexpectedSchema(value):
            "unexpected_schema:\(value)"
        case let .missingValue(value):
            "missing_value:\(value)"
        case let .unusableCPUData(value):
            "unusable_cpu_data:\(value)"
        case let .counterRegression(value):
            "counter_regression:\(value)"
        case let .ledgerPrecedesLiveSeries(value):
            "ledger_precedes_live_series:\(value)"
        }
    }
}

public struct InstrumentsActivityMonitorSliceReport:
    Codable,
    Equatable,
    Sendable
{
    public let sliceID: String
    public let sampleCount: Int
    public let observedDurationNanoseconds: Int64
    public let cpuTimeNanoseconds: Int64
    public let meanCPUPercent: Double
    public let p95CPUPercent: Double
    public let maximumCPUPercent: Double
    public let idleWakeups: Int64
    public let diskBytesWritten: Int64
    public let diskBytesRead: Int64
    public let maximumPhysicalFootprintBytes: Int64
    public let appNapObserved: Bool
    public let preventingSleepObserved: Bool
    public let thermalStates: [String]
}

public struct InstrumentsActivityMonitorReport:
    Codable,
    Equatable,
    Sendable
{
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sliceCount: Int
    public let totalObservedDurationNanoseconds: Int64
    public let totalCPUTimeNanoseconds: Int64
    public let totalIdleWakeups: Int64
    public let totalDiskBytesWritten: Int64
    public let totalDiskBytesRead: Int64
    public let maximumPhysicalFootprintBytes: Int64
    public let minimumSliceMeanCPUPercent: Double
    public let maximumSliceMeanCPUPercent: Double
    public let minimumSliceP95CPUPercent: Double
    public let maximumSliceP95CPUPercent: Double
    public let maximumInstantaneousCPUPercent: Double
    public let appNapSliceCount: Int
    public let preventingSleepObserved: Bool
    public let thermalStates: [String]
    public let slices: [InstrumentsActivityMonitorSliceReport]
}

public struct InstrumentsActivityMonitorAnalyzer: Sendable {
    private let parser = XctraceTableParser()

    public init() {}

    public func analyze(
        directory: URL
    ) throws -> InstrumentsActivityMonitorReport {
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            throw InstrumentsActivityMonitorAnalysisError.inputIsNotDirectory
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let liveFiles = files.filter {
            $0.lastPathComponent.hasSuffix("-live.xml")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard liveFiles.isEmpty == false else {
            throw InstrumentsActivityMonitorAnalysisError.noSlices
        }

        let slices = try liveFiles.map { liveURL in
            let prefix = String(
                liveURL.lastPathComponent.dropLast("-live.xml".count)
            )
            let sliceID = prefix.hasPrefix("activity-monitor-")
                ? String(prefix.dropFirst("activity-monitor-".count))
                : prefix
            let ledgerURL = directory.appendingPathComponent(
                "\(prefix)-ledger.xml"
            )
            let thermalURL = directory.appendingPathComponent(
                "\(prefix)-thermal.xml"
            )
            guard FileManager.default.fileExists(atPath: ledgerURL.path) else {
                throw InstrumentsActivityMonitorAnalysisError
                    .missingCompanionFile("\(sliceID):ledger")
            }
            guard FileManager.default.fileExists(atPath: thermalURL.path) else {
                throw InstrumentsActivityMonitorAnalysisError
                    .missingCompanionFile("\(sliceID):thermal")
            }
            return try analyzeSlice(
                sliceID: sliceID,
                liveURL: liveURL,
                ledgerURL: ledgerURL,
                thermalURL: thermalURL
            )
        }
        let means = slices.map(\.meanCPUPercent)
        let p95Values = slices.map(\.p95CPUPercent)
        let thermalStates = Set(slices.flatMap(\.thermalStates)).sorted()
        return InstrumentsActivityMonitorReport(
            schemaVersion: InstrumentsActivityMonitorReport.currentSchemaVersion,
            sliceCount: slices.count,
            totalObservedDurationNanoseconds: slices.reduce(0) {
                $0 + $1.observedDurationNanoseconds
            },
            totalCPUTimeNanoseconds: slices.reduce(0) {
                $0 + $1.cpuTimeNanoseconds
            },
            totalIdleWakeups: slices.reduce(0) { $0 + $1.idleWakeups },
            totalDiskBytesWritten: slices.reduce(0) {
                $0 + $1.diskBytesWritten
            },
            totalDiskBytesRead: slices.reduce(0) { $0 + $1.diskBytesRead },
            maximumPhysicalFootprintBytes: slices.map {
                $0.maximumPhysicalFootprintBytes
            }.max() ?? 0,
            minimumSliceMeanCPUPercent: means.min() ?? 0,
            maximumSliceMeanCPUPercent: means.max() ?? 0,
            minimumSliceP95CPUPercent: p95Values.min() ?? 0,
            maximumSliceP95CPUPercent: p95Values.max() ?? 0,
            maximumInstantaneousCPUPercent: slices.map {
                $0.maximumCPUPercent
            }.max() ?? 0,
            appNapSliceCount: slices.filter(\.appNapObserved).count,
            preventingSleepObserved: slices.contains(
                where: \.preventingSleepObserved
            ),
            thermalStates: thermalStates,
            slices: slices
        )
    }

    private func analyzeSlice(
        sliceID: String,
        liveURL: URL,
        ledgerURL: URL,
        thermalURL: URL
    ) throws -> InstrumentsActivityMonitorSliceReport {
        let live = try parser.parse(liveURL)
        let ledger = try parser.parse(ledgerURL)
        let thermal = try parser.parse(thermalURL)
        guard live.schemaName == "activity-monitor-process-live" else {
            throw InstrumentsActivityMonitorAnalysisError.unexpectedSchema(
                sliceID
            )
        }
        guard ledger.schemaName == "activity-monitor-process-ledger" else {
            throw InstrumentsActivityMonitorAnalysisError.unexpectedSchema(
                sliceID
            )
        }
        guard thermal.schemaName == "device-thermal-state-intervals" else {
            throw InstrumentsActivityMonitorAnalysisError.unexpectedSchema(
                sliceID
            )
        }

        let cpuTotals = try live.rows.map {
            try int64("cpu-total", in: $0, sliceID: sliceID)
        }
        let wakeups = try live.rows.map {
            try int64("idle-wakeups", in: $0, sliceID: sliceID)
        }
        let writes = try live.rows.map {
            try int64("disk-bytes-written", in: $0, sliceID: sliceID)
        }
        let reads = try live.rows.map {
            try int64("disk-bytes-read", in: $0, sliceID: sliceID)
        }
        let memory = try live.rows.map {
            try int64(
                "memory-physical-footprint",
                in: $0,
                sliceID: sliceID
            )
        }
        let durations = try live.rows.map {
            try int64("duration", in: $0, sliceID: sliceID)
        }
        let cpuPercent = try live.rows.compactMap { row -> Double? in
            guard let cell = row["cpu-percent"] ?? nil else { return nil }
            guard let value = cell.doubleValue, value.isFinite, value >= 0 else {
                throw InstrumentsActivityMonitorAnalysisError
                    .unusableCPUData(sliceID)
            }
            return value
        }
        guard cpuPercent.isEmpty == false else {
            throw InstrumentsActivityMonitorAnalysisError.unusableCPUData(
                sliceID
            )
        }
        let appNap = try live.rows.map {
            try boolean("app-nap", in: $0, sliceID: sliceID)
        }
        let preventingSleep = try live.rows.map {
            try boolean("preventing-sleep", in: $0, sliceID: sliceID)
        }

        let cpuDelta = try delta(cpuTotals, metric: "cpu", sliceID: sliceID)
        let wakeupDelta = try delta(
            wakeups,
            metric: "wakeups",
            sliceID: sliceID
        )
        let writeDelta = try delta(
            writes,
            metric: "writes",
            sliceID: sliceID
        )
        let readDelta = try delta(reads, metric: "reads", sliceID: sliceID)
        try validateLedger(
            ledger,
            liveFinals: (
                cpu: cpuTotals.last ?? 0,
                wakeups: wakeups.last ?? 0,
                writes: writes.last ?? 0,
                reads: reads.last ?? 0
            ),
            sliceID: sliceID
        )
        let states = try Set(thermal.rows.map { row in
            guard let cell = row["thermal-state"] ?? nil else {
                throw InstrumentsActivityMonitorAnalysisError.missingValue(
                    "\(sliceID):thermal-state"
                )
            }
            let value = cell.displayValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty == false else {
                throw InstrumentsActivityMonitorAnalysisError.missingValue(
                    "\(sliceID):thermal-state"
                )
            }
            return value
        }).sorted()

        return InstrumentsActivityMonitorSliceReport(
            sliceID: sliceID,
            sampleCount: live.rows.count,
            observedDurationNanoseconds: try nonnegativeSum(
                durations,
                metric: "duration",
                sliceID: sliceID
            ),
            cpuTimeNanoseconds: cpuDelta,
            meanCPUPercent: cpuPercent.reduce(0, +) / Double(cpuPercent.count),
            p95CPUPercent: percentile95(cpuPercent),
            maximumCPUPercent: cpuPercent.max() ?? 0,
            idleWakeups: wakeupDelta,
            diskBytesWritten: writeDelta,
            diskBytesRead: readDelta,
            maximumPhysicalFootprintBytes: memory.max() ?? 0,
            appNapObserved: appNap.contains(true),
            preventingSleepObserved: preventingSleep.contains(true),
            thermalStates: states
        )
    }

    private func validateLedger(
        _ table: XctraceTable,
        liveFinals: (cpu: Int64, wakeups: Int64, writes: Int64, reads: Int64),
        sliceID: String
    ) throws {
        guard let row = table.rows.last else {
            throw InstrumentsActivityMonitorAnalysisError.missingValue(
                "\(sliceID):ledger"
            )
        }
        let values = (
            cpu: try int64("cpu-total", in: row, sliceID: sliceID),
            wakeups: try int64("idle-wakeups", in: row, sliceID: sliceID),
            writes: try int64("disk-bytes-written", in: row, sliceID: sliceID),
            reads: try int64("disk-bytes-read", in: row, sliceID: sliceID)
        )
        guard values.cpu >= liveFinals.cpu,
              values.wakeups >= liveFinals.wakeups,
              values.writes >= liveFinals.writes,
              values.reads >= liveFinals.reads else {
            throw InstrumentsActivityMonitorAnalysisError
                .ledgerPrecedesLiveSeries(sliceID)
        }
    }

    private func int64(
        _ key: String,
        in row: [String: XctraceCell?],
        sliceID: String
    ) throws -> Int64 {
        guard let cell = row[key] ?? nil,
              let value = cell.int64Value,
              value >= 0 else {
            throw InstrumentsActivityMonitorAnalysisError.missingValue(
                "\(sliceID):\(key)"
            )
        }
        return value
    }

    private func boolean(
        _ key: String,
        in row: [String: XctraceCell?],
        sliceID: String
    ) throws -> Bool {
        guard let cell = row[key] ?? nil,
              let value = cell.booleanValue else {
            throw InstrumentsActivityMonitorAnalysisError.missingValue(
                "\(sliceID):\(key)"
            )
        }
        return value
    }

    private func delta(
        _ values: [Int64],
        metric: String,
        sliceID: String
    ) throws -> Int64 {
        guard let first = values.first, let last = values.last else {
            throw InstrumentsActivityMonitorAnalysisError.missingValue(
                "\(sliceID):\(metric)"
            )
        }
        guard last >= first else {
            throw InstrumentsActivityMonitorAnalysisError.counterRegression(
                "\(sliceID):\(metric)"
            )
        }
        return last - first
    }

    private func nonnegativeSum(
        _ values: [Int64],
        metric: String,
        sliceID: String
    ) throws -> Int64 {
        var result: Int64 = 0
        for value in values {
            let (sum, overflow) = result.addingReportingOverflow(value)
            guard overflow == false else {
                throw InstrumentsActivityMonitorAnalysisError.counterRegression(
                    "\(sliceID):\(metric)"
                )
            }
            result = sum
        }
        return result
    }

    private func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return sorted[index]
    }
}
