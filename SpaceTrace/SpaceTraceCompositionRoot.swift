import Foundation
import SpaceTraceApplication
import SpaceTraceFileSystem
import SpaceTraceMonitoring
import SpaceTracePersistence
import SpaceTracePlatform

struct SpaceTraceCompositionRoot {
    let authorizationCoordinator: WatchedScopeAuthorizationCoordinator

    static func make(fileManager: FileManager = .default) throws -> Self {
        let applicationSupportRoot = try applicationSupportDirectory(using: fileManager)
        let databaseURL = applicationSupportRoot
            .appendingPathComponent("SpaceTrace.sqlite", isDirectory: false)
        let repository = try SQLiteEventJournalRepository(databaseURL: databaseURL)
        try protectDatabaseFiles(at: databaseURL, using: fileManager)

        let catalog = SecurityScopedWatchedScopeCatalog(
            repository: repository,
            accessMode: .required
        )
        let scanner = FoundationMetadataCalibrationScanner(
            excludedPaths: [try DirtyRegionPath(applicationSupportRoot.path)]
        )
        let runtime = NativeVolumeMonitoringRuntime(
            catalog: catalog,
            repository: repository,
            scanner: scanner
        )
        let lifecycle = NativeMonitoringApplicationLifecycle(
            catalog: catalog,
            runtime: runtime
        )
        return Self(
            authorizationCoordinator: WatchedScopeAuthorizationCoordinator(
                catalog: catalog,
                lifecycle: lifecycle
            )
        )
    }

    private static func applicationSupportDirectory(
        using fileManager: FileManager
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("SpaceTrace", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private static func protectDatabaseFiles(
        at databaseURL: URL,
        using fileManager: FileManager
    ) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }
}
