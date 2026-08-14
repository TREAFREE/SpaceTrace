import Foundation

enum SQLiteSensitiveArtifactKind: String, Sendable, CaseIterable {
    case activeMain
    case activeWAL
    case activeSHM
    case migrationBackup
    case onlineBackupSnapshot
    case quarantinedMain
    case quarantinedWAL
    case quarantinedSHM
    case quarantinedReadOnlyMain
    case quarantinedMigrationBackup
    case recoveryManifest
    case interruptedTemporary
    case unknownRecoveryArtifact
}

struct SQLiteSensitiveArtifactEntry: Sendable, Equatable {
    let kind: SQLiteSensitiveArtifactKind
    let createdAt: Date
    let earliestSensitiveExpiry: Date
    fileprivate let url: URL

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind
            && lhs.createdAt == rhs.createdAt
            && lhs.earliestSensitiveExpiry == rhs.earliestSensitiveExpiry
    }
}

/// Exhaustive inventory of app-owned SQLite artifacts that may contain paths
/// or immutable historical evidence. Public diagnostics consume only the
/// path-free kind and timestamps; URLs never escape this persistence module.
enum SQLiteSensitiveArtifactInventory {
    static let maximumArtifactCount = 1_024
    static let hardLifetime: TimeInterval = 7 * 86_400

    static func discover(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> [SQLiteSensitiveArtifactEntry] {
        let root = databaseURL.deletingLastPathComponent()
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: []
        )
        var entries: [SQLiteSensitiveArtifactEntry] = []
        for child in children {
            if let kind = rootKind(for: child.lastPathComponent, databaseName: databaseURL.lastPathComponent) {
                try append(child, kind: kind, to: &entries, fileManager: fileManager)
            } else if child.lastPathComponent == "Recovery" {
                try inventoryRecoveryRoot(child, entries: &entries, fileManager: fileManager)
            }
        }
        guard entries.count <= maximumArtifactCount else {
            throw SQLiteSensitiveArtifactInventoryError.artifactCountExceeded
        }
        return entries.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.createdAt < $1.createdAt
        }
    }

    static func scrubAfterSuccessfulStartup(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let entries = try discover(databaseURL: databaseURL, fileManager: fileManager)
        for entry in entries where activeKinds.contains(entry.kind) == false {
            try removeRegularArtifact(entry.url, fileManager: fileManager)
        }
        try removeEmptyRecoveryDirectories(
            databaseURL.deletingLastPathComponent().appendingPathComponent("Recovery"),
            fileManager: fileManager
        )
    }

    static func scrubExpired(
        databaseURL: URL,
        referenceDate: Date,
        fileManager: FileManager = .default
    ) throws {
        let entries = try discover(databaseURL: databaseURL, fileManager: fileManager)
        for entry in entries where activeKinds.contains(entry.kind) == false
            && entry.earliestSensitiveExpiry <= referenceDate {
            try removeRegularArtifact(entry.url, fileManager: fileManager)
        }
        try removeEmptyRecoveryDirectories(
            databaseURL.deletingLastPathComponent().appendingPathComponent("Recovery"),
            fileManager: fileManager
        )
    }

    private static let activeKinds: Set<SQLiteSensitiveArtifactKind> = [
        .activeMain, .activeWAL, .activeSHM,
    ]
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .creationDateKey, .contentModificationDateKey,
    ]

    private static func rootKind(
        for name: String,
        databaseName: String
    ) -> SQLiteSensitiveArtifactKind? {
        if name == databaseName { return .activeMain }
        if name == databaseName + "-wal" { return .activeWAL }
        if name == databaseName + "-shm" { return .activeSHM }
        if name.hasPrefix(databaseName + ".pre-migration-v"), name.hasSuffix(".sqlite") {
            return .migrationBackup
        }
        if name.hasPrefix(databaseName + ".online-backup-"), name.hasSuffix(".sqlite") {
            return .onlineBackupSnapshot
        }
        if name.hasPrefix(".SpaceTrace-migration-backup-"), name.hasSuffix(".tmp") {
            return .interruptedTemporary
        }
        return nil
    }

    private static func inventoryRecoveryRoot(
        _ root: URL,
        entries: inout [SQLiteSensitiveArtifactEntry],
        fileManager: FileManager
    ) throws {
        let rootValues = try root.resourceValues(forKeys: Set(resourceKeys))
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SQLiteSensitiveArtifactInventoryError.nonRegularArtifact
        }
        let incidents = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: []
        )
        for incident in incidents {
            let values = try incident.resourceValues(forKeys: Set(resourceKeys))
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                try append(
                    incident,
                    kind: .unknownRecoveryArtifact,
                    to: &entries,
                    fileManager: fileManager
                )
                continue
            }
            let artifacts = try fileManager.contentsOfDirectory(
                at: incident,
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
            let embeddedExpiry = try recoveryExpiry(
                artifacts.first { $0.lastPathComponent == "manifest.json" }
            )
            for artifact in artifacts {
                let kind: SQLiteSensitiveArtifactKind
                switch artifact.lastPathComponent {
                case "main.sqlite": kind = .quarantinedMain
                case "main.sqlite-wal": kind = .quarantinedWAL
                case "main.sqlite-shm": kind = .quarantinedSHM
                case "read-only-main.sqlite": kind = .quarantinedReadOnlyMain
                case "migration-backup.sqlite": kind = .quarantinedMigrationBackup
                case "manifest.json": kind = .recoveryManifest
                default: kind = .unknownRecoveryArtifact
                }
                try append(
                    artifact,
                    kind: kind,
                    embeddedExpiry: embeddedExpiry,
                    to: &entries,
                    fileManager: fileManager
                )
            }
        }
    }

    private static func append(
        _ url: URL,
        kind: SQLiteSensitiveArtifactKind,
        embeddedExpiry: Date? = nil,
        to entries: inout [SQLiteSensitiveArtifactEntry],
        fileManager _: FileManager
    ) throws {
        let values = try url.resourceValues(forKeys: Set(resourceKeys))
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SQLiteSensitiveArtifactInventoryError.nonRegularArtifact
        }
        let createdAt = values.creationDate ?? values.contentModificationDate ?? .distantPast
        let hardExpiry = createdAt.addingTimeInterval(hardLifetime)
        entries.append(
            SQLiteSensitiveArtifactEntry(
                kind: kind,
                createdAt: createdAt,
                earliestSensitiveExpiry: min(hardExpiry, embeddedExpiry ?? hardExpiry),
                url: url
            )
        )
        guard entries.count <= maximumArtifactCount else {
            throw SQLiteSensitiveArtifactInventoryError.artifactCountExceeded
        }
    }

    private static func recoveryExpiry(_ manifestURL: URL?) throws -> Date? {
        guard let manifestURL else { return nil }
        let values = try manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 65_536 else {
            throw SQLiteSensitiveArtifactInventoryError.nonRegularArtifact
        }
        let manifest = try JSONDecoder().decode(
            RecoveryExpiryManifest.self,
            from: Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        )
        let (fallbackExpiry, overflow) = manifest.createdAtMilliseconds.addingReportingOverflow(
            604_800_000
        )
        guard manifest.version == 1,
              manifest.createdAtMilliseconds >= 0,
              overflow == false else {
            throw SQLiteSensitiveArtifactInventoryError.invalidRecoveryManifest
        }
        let expiresAtMilliseconds = manifest.expiresAtMilliseconds ?? fallbackExpiry
        guard expiresAtMilliseconds >= manifest.createdAtMilliseconds,
              expiresAtMilliseconds - manifest.createdAtMilliseconds <= 604_800_000 else {
            throw SQLiteSensitiveArtifactInventoryError.invalidRecoveryManifest
        }
        return Date(
            timeIntervalSince1970: Double(expiresAtMilliseconds) / 1_000
        )
    }

    private static func removeRegularArtifact(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SQLiteSensitiveArtifactInventoryError.nonRegularArtifact
        }
        try fileManager.removeItem(at: url)
    }

    private static func removeEmptyRecoveryDirectories(
        _ recoveryRoot: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: recoveryRoot.path) else { return }
        let incidents = try fileManager.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for incident in incidents {
            let values = try incident.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if try fileManager.contentsOfDirectory(atPath: incident.path).isEmpty {
                try fileManager.removeItem(at: incident)
            }
        }
        if try fileManager.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty {
            try fileManager.removeItem(at: recoveryRoot)
        }
    }
}

enum SQLiteSensitiveArtifactInventoryError: Error, Sendable, Equatable {
    case artifactCountExceeded
    case invalidRecoveryManifest
    case nonRegularArtifact
}

private struct RecoveryExpiryManifest: Decodable {
    let version: Int
    let createdAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64?
}
