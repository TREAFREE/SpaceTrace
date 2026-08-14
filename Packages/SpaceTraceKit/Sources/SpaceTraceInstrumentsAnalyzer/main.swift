import Foundation
import SpaceTraceQualification

@main
struct SpaceTraceInstrumentsAnalyzerCommand {
    static func main() {
        do {
            let arguments = try Arguments.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            let report = try InstrumentsActivityMonitorAnalyzer().analyze(
                directory: arguments.input
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if let output = arguments.output {
                try data.write(to: output, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: output.path
                )
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            FileHandle.standardError.write(
                Data("PASS: \(report.sliceCount) Instruments slices\n".utf8)
            )
        } catch let error as CommandError {
            FileHandle.standardError.write(
                Data("error: \(error.message)\n\(Arguments.usage)\n".utf8)
            )
            exit(64)
        } catch let error as InstrumentsActivityMonitorAnalysisError {
            FileHandle.standardError.write(
                Data("error: \(error.description)\n".utf8)
            )
            exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(
                Data("error: Instruments evidence could not be processed\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}

private struct Arguments {
    let input: URL
    let output: URL?

    static let usage = """
    usage: SpaceTraceInstrumentsAnalyzer --input <instruments-directory> \
    [--output <report.json>]
    """

    static func parse(_ arguments: [String]) throws -> Arguments {
        var input: URL?
        var output: URL?
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
            default:
                throw CommandError("unknown argument \(flag)")
            }
            index += 2
        }
        guard let input else {
            throw CommandError("--input is required")
        }
        return Arguments(input: input, output: output)
    }
}

private struct CommandError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
