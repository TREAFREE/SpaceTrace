import Foundation
import SpaceTraceApplication

@main
struct SpaceTraceSoakAnalyzerCommand {
    static func main() {
        do {
            let arguments = try Arguments.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            let records = try loadRecords(from: arguments.input)
            let policy = arguments.smokeDuration.map {
                StorageHistorySoakQualificationPolicy.smoke(
                    minimumDuration: $0
                )
            } ?? StorageHistorySoakQualificationPolicy()
            let report = StorageHistorySoakQualificationAnalyzer().analyze(
                records,
                policy: policy
            )
            let data = try makeReportData(report)
            if let output = arguments.output {
                try data.write(to: output, options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            let summary = report.passed
                ? "PASS: \(records.count) records\n"
                : "FAIL: \(report.issues.map(\.rawValue).joined(separator: ","))\n"
            FileHandle.standardError.write(Data(summary.utf8))
            exit(report.passed ? EXIT_SUCCESS : 2)
        } catch let error as CommandError {
            FileHandle.standardError.write(
                Data("error: \(error.message)\n\(Arguments.usage)\n".utf8)
            )
            exit(64)
        } catch {
            FileHandle.standardError.write(
                Data("error: qualification input could not be processed\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func loadRecords(
        from input: URL
    ) throws -> [StorageHistorySoakDiagnosticRecord] {
        let values = try input.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        let urls: [URL]
        if values.isDirectory == true {
            let candidates = try FileManager.default.contentsOfDirectory(
                at: input,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" }
            urls = candidates.sorted { first, second in
                rank(first.lastPathComponent) < rank(second.lastPathComponent)
            }
        } else {
            urls = [input]
        }
        guard urls.isEmpty == false else {
            throw CommandError("no JSONL diagnostic segments were found")
        }
        let decoder = JSONDecoder()
        var records: [StorageHistorySoakDiagnosticRecord] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            for line in data.split(separator: 0x0A) where line.isEmpty == false {
                records.append(
                    try decoder.decode(
                        StorageHistorySoakDiagnosticRecord.self,
                        from: Data(line)
                    )
                )
            }
        }
        guard records.isEmpty == false else {
            throw CommandError("diagnostic segments contained no records")
        }
        return records
    }

    private static func rank(_ name: String) -> Int {
        if name.contains("previous") { return 0 }
        if name.contains("current") { return 1 }
        return 2
    }

    private static func makeReportData(
        _ report: StorageHistorySoakQualificationReport
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}

private struct Arguments {
    let input: URL
    let output: URL?
    let smokeDuration: TimeInterval?

    static let usage = """
    usage: SpaceTraceSoakAnalyzer --input <file-or-directory> \
    [--output <report.json>] [--smoke <minimum-seconds>]
    """

    static func parse(_ arguments: [String]) throws -> Arguments {
        var input: URL?
        var output: URL?
        var smokeDuration: TimeInterval?
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                throw CommandError("missing value for \(flag)")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--input":
                input = URL(fileURLWithPath: value)
            case "--output":
                output = URL(fileURLWithPath: value)
            case "--smoke":
                guard let parsed = TimeInterval(value),
                      parsed >= 0,
                      parsed.isFinite else {
                    throw CommandError("--smoke requires non-negative seconds")
                }
                smokeDuration = parsed
            default:
                throw CommandError("unknown argument \(flag)")
            }
            index += 2
        }
        guard let input else {
            throw CommandError("--input is required")
        }
        return Arguments(
            input: input,
            output: output,
            smokeDuration: smokeDuration
        )
    }
}

private struct CommandError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
