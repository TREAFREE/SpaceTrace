import Foundation
import SpaceTraceApplication
import SpaceTraceFileSystem
import SpaceTraceMonitoring
import SpaceTracePersistence
import SpaceTracePlatform

struct SpaceTraceCompositionRoot {
    let authorizationCoordinator: WatchedScopeAuthorizationCoordinator
    let baselineScanCoordinator: AuthorizedBaselineScanCoordinator
    let scanSchedulingMonitor: NativeScanSchedulingMonitor

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
        let baselineContextProvider = NativeAuthorizedBaselineScanContextProvider(
            catalog: catalog,
            runtime: runtime
        )
        let schedulingSnapshotProvider = FoundationScanSchedulingSnapshotProvider()
        let schedulingGate = AuthorizedBaselineScanSchedulingGate(
            initialSnapshot: schedulingSnapshotProvider.snapshot(systemActivity: .awake)
        )
        let baselineScanCoordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: baselineContextProvider,
            calibrationRunner: EventJournalAuthorizedBaselineCalibrationRunner(
                repository: repository,
                scanner: scanner
            ),
            snapshotRepository: repository,
            volumeCapacityProvider: FoundationStartupVolumeCapacityProvider(
                dataDirectoryURL: applicationSupportRoot
            ),
            scheduler: schedulingGate,
            buildMetadata: try AuthorizedBaselineBuildMetadata(
                appVersion: appVersion(),
                schemaVersion: SQLiteEventJournalRepository.currentSchemaVersion
            )
        )
        let schedulingMonitor = NativeScanSchedulingMonitor(
            receiver: schedulingGate,
            snapshotProvider: schedulingSnapshotProvider
        )
        schedulingMonitor.start()
        return Self(
            authorizationCoordinator: WatchedScopeAuthorizationCoordinator(
                catalog: catalog,
                lifecycle: lifecycle,
                cancelBaselineScan: {
                    await baselineScanCoordinator.cancel()
                }
            ),
            baselineScanCoordinator: baselineScanCoordinator,
            scanSchedulingMonitor: schedulingMonitor
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

    private static func appVersion(bundle: Bundle = .main) -> String {
        let shortVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        guard let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
              build.isEmpty == false else {
            return shortVersion
        }
        return "\(shortVersion) (\(build))"
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
