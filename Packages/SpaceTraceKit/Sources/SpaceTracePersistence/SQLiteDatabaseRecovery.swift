import Foundation
import SQLite3
import Synchronization
import Darwin

public enum SQLiteRecoveryReason: String, Sendable, Equatable, Codable {
    case migrationFailed
    case databaseCorrupt
    case diskFull
    case unsupportedSchema
    case startupFailure
}

public enum SQLiteRecoverySource: String, Sendable, Equatable, Codable {
    case migrationBackup
    case isolatedMainDatabase
    case unavailable
}

public struct SQLiteReadOnlyRecoveryOverview: Sendable, Equatable {
    public let reason: SQLiteRecoveryReason
    public let source: SQLiteRecoverySource
    public let schemaVersion: Int32?
    public let isReadable: Bool
    public let incidentDirectoryName: String?

    public init(
        reason: SQLiteRecoveryReason,
        source: SQLiteRecoverySource,
        schemaVersion: Int32?,
        isReadable: Bool,
        incidentDirectoryName: String?
    ) {
        self.reason = reason
        self.source = source
        self.schemaVersion = schemaVersion
        self.isReadable = isReadable
        self.incidentDirectoryName = incidentDirectoryName
    }
}

public enum SQLiteRepositoryBootstrapResult: Sendable {
    case operational(SQLiteEventJournalRepository)
    case recovery(SQLiteReadOnlyRecoverySession)
}

public enum SQLiteRepositoryBootstrap {
    public static func open(databaseURL: URL) -> SQLiteRepositoryBootstrapResult {
        open(
            databaseURL: databaseURL,
            now: Date(),
            incidentID: UUID(),
            fileManager: .default,
            failurePoint: nil
        )
    }

    static func open(
        databaseURL: URL,
        now: Date,
        incidentID: UUID,
        fileManager: FileManager,
        failurePoint: SQLiteEventJournalTestFailurePoint? = nil
    ) -> SQLiteRepositoryBootstrapResult {
        do {
            return .operational(
                try SQLiteEventJournalRepository(
                    databaseURL: databaseURL,
                    failurePoint: failurePoint
                )
            )
        } catch {
            let reason = SQLiteRecoveryReason(error: error)
            let isolated = try? SQLiteRecoveryIsolation.create(
                databaseURL: databaseURL,
                reason: reason,
                now: now,
                incidentID: incidentID,
                fileManager: fileManager
            )
            return .recovery(
                SQLiteReadOnlyRecoverySession(
                    reason: reason,
                    isolated: isolated
                )
            )
        }
    }
}

public final class SQLiteReadOnlyRecoverySession: @unchecked Sendable {
    public let overview: SQLiteReadOnlyRecoveryOverview
    private let connection: Mutex<OpaquePointer?>

    fileprivate init(
        reason: SQLiteRecoveryReason,
        isolated: SQLiteRecoveryIsolation?
    ) {
        let candidates: [(URL, SQLiteRecoverySource)] = [
            isolated?.migrationBackupURL.map { ($0, .migrationBackup) },
            isolated?.readOnlyMainURL.map { ($0, .isolatedMainDatabase) },
        ].compactMap { $0 }

        var selectedDatabase: OpaquePointer?
        var selectedSource = SQLiteRecoverySource.unavailable
        var selectedVersion: Int32?

        for (url, source) in candidates {
            var database: OpaquePointer?
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            let immutableURI = components?.url?.absoluteString ?? url.absoluteString
            let result = sqlite3_open_v2(
                immutableURI,
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI,
                nil
            )
            guard result == SQLITE_OK, let database else {
                if let database { _ = sqlite3_close_v2(database) }
                continue
            }
            guard Self.enableQueryOnly(database),
                  let version = Self.readSchemaVersion(database) else {
                _ = sqlite3_close_v2(database)
                continue
            }
            selectedDatabase = database
            selectedSource = source
            selectedVersion = version
            break
        }

        connection = Mutex(selectedDatabase)
        overview = SQLiteReadOnlyRecoveryOverview(
            reason: reason,
            source: selectedSource,
            schemaVersion: selectedVersion,
            isReadable: selectedDatabase != nil,
            incidentDirectoryName: isolated?.directoryURL.lastPathComponent
        )
    }

    deinit {
        connection.withLock { database in
            if let database { _ = sqlite3_close_v2(database) }
            database = nil
        }
    }

    public func close() {
        connection.withLock { database in
            if let database { _ = sqlite3_close_v2(database) }
            database = nil
        }
    }

    func verifyWriteRejectedForTesting() -> Bool {
        connection.withLock { database in
            guard let database else { return true }
            return sqlite3_exec(
                database,
                "CREATE TABLE recovery_write_must_fail(id INTEGER)",
                nil,
                nil,
                nil
            ) & 0xFF == SQLITE_READONLY
        }
    }

    private static func enableQueryOnly(_ database: OpaquePointer) -> Bool {
        sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK
    }

    private static func readSchemaVersion(_ database: OpaquePointer) -> Int32? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA user_version",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { _ = sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0)
    }
}

struct SQLiteMigrationBackup {
    static func create(
        sourceDatabase: OpaquePointer,
        databaseURL: URL,
        sourceVersion: Int32,
        fileManager: FileManager = .default
    ) throws -> URL {
        let backupURL = backupURL(for: databaseURL, sourceVersion: sourceVersion)
        let temporaryURL = databaseURL.deletingLastPathComponent().appendingPathComponent(
            ".SpaceTrace-migration-backup-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        var destination: OpaquePointer?
        let openResult = sqlite3_open_v2(
            temporaryURL.path,
            &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let destination else {
            if let destination { _ = sqlite3_close_v2(destination) }
            throw mappedError(
                operation: "open migration backup",
                code: openResult,
                database: destination
            )
        }

        var operationError: (any Error)?
        if sqlite3_exec(destination, "PRAGMA synchronous = FULL", nil, nil, nil) != SQLITE_OK {
            operationError = mappedError(
                operation: "configure migration backup",
                code: sqlite3_errcode(destination),
                database: destination
            )
        } else if let backup = sqlite3_backup_init(destination, "main", sourceDatabase, "main") {
            let stepResult = sqlite3_backup_step(backup, -1)
            let finishResult = sqlite3_backup_finish(backup)
            if stepResult != SQLITE_DONE {
                operationError = mappedError(
                    operation: "copy migration backup",
                    code: stepResult,
                    database: destination
                )
            } else if finishResult != SQLITE_OK {
                operationError = mappedError(
                    operation: "finish migration backup",
                    code: finishResult,
                    database: destination
                )
            }
        } else {
            operationError = mappedError(
                operation: "initialize migration backup",
                code: sqlite3_errcode(destination),
                database: destination
            )
        }

        let closeResult = sqlite3_close_v2(destination)
        if operationError == nil, closeResult != SQLITE_OK {
            operationError = SQLiteEventJournalError.sqliteFailure(
                operation: "close migration backup",
                code: closeResult,
                message: "SQLite could not close the migration backup."
            )
        }
        if let operationError { throw operationError }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        try atomicReplace(temporaryURL: temporaryURL, destinationURL: backupURL)
        return backupURL
    }

    static func backupURL(for databaseURL: URL, sourceVersion: Int32) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(
            "\(databaseURL.lastPathComponent).pre-migration-v\(sourceVersion).sqlite",
            isDirectory: false
        )
    }

    static func existingBackups(
        for databaseURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let directory = databaseURL.deletingLastPathComponent()
        let prefix = databaseURL.lastPathComponent + ".pre-migration-v"
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }

    private static func atomicReplace(
        temporaryURL: URL,
        destinationURL: URL
    ) throws {
        let result = temporaryURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func mappedError(
        operation: String,
        code: Int32,
        database: OpaquePointer?
    ) -> SQLiteEventJournalError {
        let primaryCode = code & 0xFF
        if primaryCode == SQLITE_FULL {
            return .diskFull(operation: operation)
        }
        if primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB {
            return .databaseCorrupt
        }
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite did not provide a database handle."
        return .sqliteFailure(operation: operation, code: code, message: message)
    }
}

struct SQLiteArtifactValidator {
    static func validateBeforeOpen(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        let mainHeader = try prefix(of: databaseURL, byteCount: 100)
        guard mainHeader.count >= 100,
              mainHeader.prefix(16) == Data("SQLite format 3\0".utf8) else {
            throw SQLiteEventJournalError.databaseCorrupt
        }

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        guard fileManager.fileExists(atPath: walURL.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: walURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        // SQLite may leave an empty WAL placeholder after a clean shutdown.
        guard byteCount != 0 else { return }
        guard byteCount >= 32 else {
            throw SQLiteEventJournalError.databaseCorrupt
        }
        let header = try prefix(of: walURL, byteCount: 32)
        guard header.count == 32 else {
            throw SQLiteEventJournalError.databaseCorrupt
        }
        let magic = readUInt32BigEndian(header, offset: 0)
        let encodedPageSize = readUInt32BigEndian(header, offset: 8)
        let pageSize = encodedPageSize == 1 ? 65_536 : Int(encodedPageSize)
        guard magic == 0x377F_0682 || magic == 0x377F_0683,
              pageSize >= 512,
              pageSize <= 65_536,
              pageSize.nonzeroBitCount == 1,
              (byteCount - 32).isMultiple(of: pageSize + 24) else {
            throw SQLiteEventJournalError.databaseCorrupt
        }
    }

    private static func prefix(of url: URL, byteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: byteCount) ?? Data()
    }

    private static func readUInt32BigEndian(_ data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

fileprivate struct SQLiteRecoveryIsolation {
    let directoryURL: URL
    let migrationBackupURL: URL?
    let readOnlyMainURL: URL?

    static func create(
        databaseURL: URL,
        reason: SQLiteRecoveryReason,
        now: Date,
        incidentID: UUID,
        fileManager: FileManager
    ) throws -> Self {
        let recoveryRoot = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
        try fileManager.createDirectory(
            at: recoveryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let directoryURL = recoveryRoot.appendingPathComponent(
            "\(milliseconds)-\(incidentID.uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var artifactNames: [String] = []
        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let destinationURL = directoryURL.appendingPathComponent("main.sqlite\(suffix)")
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
            artifactNames.append(destinationURL.lastPathComponent)
        }

        let readOnlyMainURL: URL?
        if fileManager.fileExists(atPath: databaseURL.path) {
            let candidate = directoryURL.appendingPathComponent("read-only-main.sqlite")
            try fileManager.copyItem(at: databaseURL, to: candidate)
            try fileManager.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: candidate.path
            )
            readOnlyMainURL = candidate
            artifactNames.append(candidate.lastPathComponent)
        } else {
            readOnlyMainURL = nil
        }

        let sourceBackup = SQLiteMigrationBackup.existingBackups(
            for: databaseURL,
            fileManager: fileManager
        ).first
        let migrationBackupURL: URL?
        if let sourceBackup {
            let destination = directoryURL.appendingPathComponent("migration-backup.sqlite")
            try fileManager.copyItem(at: sourceBackup, to: destination)
            try fileManager.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: destination.path
            )
            migrationBackupURL = destination
            artifactNames.append(destination.lastPathComponent)
        } else {
            migrationBackupURL = nil
        }

        let manifest = SQLiteRecoveryManifest(
            version: 1,
            reason: reason,
            createdAtMilliseconds: milliseconds,
            artifacts: artifactNames.sorted()
        )
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
        return Self(
            directoryURL: directoryURL,
            migrationBackupURL: migrationBackupURL,
            readOnlyMainURL: readOnlyMainURL
        )
    }
}

private struct SQLiteRecoveryManifest: Codable {
    let version: Int
    let reason: SQLiteRecoveryReason
    let createdAtMilliseconds: Int64
    let artifacts: [String]
}

private extension SQLiteRecoveryReason {
    init(error: any Error) {
        guard let error = error as? SQLiteEventJournalError else {
            self = .startupFailure
            return
        }
        switch error {
        case .migrationFailed:
            self = .migrationFailed
        case .databaseCorrupt:
            self = .databaseCorrupt
        case .diskFull:
            self = .diskFull
        case .unsupportedSchemaVersion:
            self = .unsupportedSchema
        default:
            self = .startupFailure
        }
    }
}
