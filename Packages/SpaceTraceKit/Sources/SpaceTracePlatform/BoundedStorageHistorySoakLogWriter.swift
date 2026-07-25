import Foundation
import SpaceTraceApplication

public enum BoundedStorageHistorySoakLogWriterError: Error, Equatable {
    case invalidConfiguration
    case recordExceedsSegmentBudget
}

/// A two-segment JSONL writer for explicitly enabled local qualification runs.
/// The dedicated directory and files are private to the current user.
public actor BoundedStorageHistorySoakLogWriter:
    StorageHistorySoakLogWriting
{
    private let directoryURL: URL
    private let maximumSegmentBytes: Int64
    private let retentionDuration: TimeInterval
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder

    public init(
        directoryURL: URL,
        maximumTotalBytes: Int64 = 10 * 1_024 * 1_024,
        retentionDuration: TimeInterval = 7 * 86_400,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard maximumTotalBytes >= 2,
              retentionDuration > 0,
              retentionDuration.isFinite else {
            throw BoundedStorageHistorySoakLogWriterError
                .invalidConfiguration
        }
        self.directoryURL = directoryURL
        maximumSegmentBytes = maximumTotalBytes / 2
        self.retentionDuration = retentionDuration
        self.fileManager = fileManager
        self.now = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func append(
        _ record: StorageHistorySoakDiagnosticRecord
    ) throws {
        var line = try encoder.encode(record)
        line.append(0x0A)
        guard line.count <= maximumSegmentBytes else {
            throw BoundedStorageHistorySoakLogWriterError
                .recordExceedsSegmentBudget
        }

        try prepareDirectory()
        try removeExpiredSegments()
        let current = directoryURL.appendingPathComponent(
            "qualification-current.jsonl",
            isDirectory: false
        )
        let previous = directoryURL.appendingPathComponent(
            "qualification-previous.jsonl",
            isDirectory: false
        )
        if try fileSize(at: current) + Int64(line.count)
            > maximumSegmentBytes {
            if fileManager.fileExists(atPath: previous.path) {
                try fileManager.removeItem(at: previous)
            }
            if fileManager.fileExists(atPath: current.path) {
                try fileManager.moveItem(at: current, to: previous)
                try protectFile(at: previous)
            }
        }
        if fileManager.fileExists(atPath: current.path) == false {
            guard fileManager.createFile(
                atPath: current.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        try protectFile(at: current)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func removeExpiredSegments() throws {
        let cutoff = now().addingTimeInterval(-retentionDuration)
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "jsonl" {
            let values = try url.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            if let modified = values.contentModificationDate,
               modified < cutoff {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func protectFile(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
