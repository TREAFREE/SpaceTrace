import Darwin
import Foundation
import SpaceTraceApplication

public enum AtomicDiagnosticExportWriterError: Error, Sendable, Equatable {
    case invalidStagingDirectory
    case invalidDestination
    case unsafeStagingEntry
    case stagedDataMismatch
}

/// Writes a bounded diagnostic export through a private, protected staging
/// file. Cancellation and ordinary failures before the atomic destination
/// commit cannot leave a partial user-visible export.
public actor AtomicDiagnosticExportWriter: DiagnosticExportWriting {
    public typealias BeforeDestinationCommit = @Sendable () async throws -> Void
    public typealias DestinationCommit = @Sendable (Data, URL) throws -> Void

    private let stagingDirectoryURL: URL
    private let fileManager: FileManager
    private let beforeDestinationCommit: BeforeDestinationCommit
    private let destinationCommit: DestinationCommit

    public init(
        stagingDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try Self.validateStagingDirectoryURL(stagingDirectoryURL)
        self.stagingDirectoryURL = stagingDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
        beforeDestinationCommit = {}
        destinationCommit = { data, destinationURL in
            try data.write(to: destinationURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        }
    }

    init(
        stagingDirectoryURL: URL,
        fileManager: FileManager = .default,
        beforeDestinationCommit: @escaping BeforeDestinationCommit = {},
        destinationCommit: @escaping DestinationCommit = { data, destinationURL in
            try data.write(to: destinationURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        }
    ) throws {
        try Self.validateStagingDirectoryURL(stagingDirectoryURL)
        self.stagingDirectoryURL = stagingDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
        self.beforeDestinationCommit = beforeDestinationCommit
        self.destinationCommit = destinationCommit
    }

    public func write(
        _ export: PreparedDiagnosticExport,
        to destinationURL: URL
    ) async throws -> DiagnosticExportWriteReceipt {
        let destination = try validatedDestination(destinationURL)
        try Task.checkCancellation()
        try prepareStagingDirectory()

        let partial = stagingDirectoryURL.appendingPathComponent(
            "\(export.preview.exportID.uuidString.lowercased()).partial",
            isDirectory: false
        )
        try removeOwnedPartialIfPresent(at: partial)
        guard fileManager.createFile(
            atPath: partial.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: partial) }

        let handle = try FileHandle(forWritingTo: partial)
        do {
            try handle.write(contentsOf: export.data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try protectFile(at: partial)

        try await beforeDestinationCommit()
        try Task.checkCancellation()
        let stagedData = try Data(
            contentsOf: partial,
            options: [.mappedIfSafe]
        )
        guard stagedData == export.data else {
            throw AtomicDiagnosticExportWriterError.stagedDataMismatch
        }

        let accessed = destination.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                destination.stopAccessingSecurityScopedResource()
            }
        }
        try destinationCommit(stagedData, destination)
        return DiagnosticExportWriteReceipt(
            destinationURL: destination,
            byteCount: stagedData.count
        )
    }

    public func recoverInterruptedExports() throws -> Int {
        try prepareStagingDirectory()
        let entries = try fileManager.contentsOfDirectory(
            at: stagingDirectoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )
        var removed = 0
        for entry in entries {
            guard Self.isOwnedPartialName(entry.lastPathComponent) else {
                continue
            }
            guard try Self.entryKind(at: entry) == .regularFile else {
                continue
            }
            try fileManager.removeItem(at: entry)
            removed += 1
        }
        return removed
    }

    private static func validateStagingDirectoryURL(_ url: URL) throws {
        guard url.isFileURL,
              url.path.first == "/",
              url.path != "/" else {
            throw AtomicDiagnosticExportWriterError.invalidStagingDirectory
        }
    }

    private func prepareStagingDirectory() throws {
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try stagingDirectoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw AtomicDiagnosticExportWriterError.invalidStagingDirectory
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stagingDirectoryURL.path
        )
    }

    private func validatedDestination(_ url: URL) throws -> URL {
        guard url.isFileURL,
              url.path.first == "/",
              url.lastPathComponent.isEmpty == false,
              url.path.utf8.contains(0) == false else {
            throw AtomicDiagnosticExportWriterError.invalidDestination
        }
        let standardized = url.standardizedFileURL
        let stagingPath = stagingDirectoryURL.resolvingSymlinksInPath().path
        let parent = standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let resolved = parent.appendingPathComponent(
            standardized.lastPathComponent,
            isDirectory: false
        )
        guard resolved.path != stagingPath,
              resolved.path.hasPrefix(stagingPath + "/") == false else {
            throw AtomicDiagnosticExportWriterError.invalidDestination
        }
        return standardized
    }

    private func removeOwnedPartialIfPresent(at url: URL) throws {
        switch try Self.entryKind(at: url) {
        case .missing:
            return
        case .regularFile:
            break
        case .directory, .other:
            throw AtomicDiagnosticExportWriterError.unsafeStagingEntry
        }
        try fileManager.removeItem(at: url)
    }

    private func protectFile(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func isOwnedPartialName(_ name: String) -> Bool {
        guard name.hasSuffix(".partial") else { return false }
        let rawID = String(name.dropLast(".partial".count))
        return UUID(uuidString: rawID) != nil
    }

    private enum EntryKind {
        case missing
        case regularFile
        case directory
        case other
    }

    /// Unlike `FileManager.fileExists`, `lstat` observes a broken symbolic
    /// link itself instead of treating it as a missing path. This keeps a
    /// hostile or stale staging link from redirecting a partial export.
    private static func entryKind(at url: URL) throws -> EntryKind {
        var information = stat()
        var capturedError: Int32 = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                capturedError = EINVAL
                return Int32(-1)
            }
            let result = lstat(path, &information)
            if result != 0 {
                capturedError = errno
            }
            return result
        }
        if result == 0 {
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                return .regularFile
            case S_IFDIR:
                return .directory
            default:
                return .other
            }
        }
        if capturedError == ENOENT {
            return .missing
        }
        throw POSIXError(POSIXErrorCode(rawValue: capturedError) ?? .EIO)
    }
}
