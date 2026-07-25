import Foundation
import SpaceTraceApplication
import SpaceTraceFileSystem
import SpaceTraceMonitoring
import SpaceTracePersistence
import SpaceTracePlatform

struct SpaceTraceCompositionRoot {
    let authorizationCoordinator: WatchedScopeAuthorizationCoordinator
    let baselineScanCoordinator: AuthorizedBaselineScanCoordinator
    let storageHistoryQuery: StorageHistoryOverviewQuery
    let startupVolume24HourStatusQuery: StartupVolume24HourStatusQuery
    let storageHistoryBackgroundCoordinator: StorageHistoryBackgroundCoordinator
    let storageHistoryLifecycleMonitor: NativeStorageHistoryLifecycleMonitor
    let scanSchedulingMonitor: NativeScanSchedulingMonitor

    enum Startup {
        case operational(SpaceTraceCompositionRoot)
        case recovery(SQLiteReadOnlyRecoverySession)
    }

    static func bootstrap(fileManager: FileManager = .default) throws -> Startup {
        let applicationSupportRoot = try applicationSupportDirectory(using: fileManager)
        let databaseURL = applicationSupportRoot
            .appendingPathComponent("SpaceTrace.sqlite", isDirectory: false)
        switch SQLiteRepositoryBootstrap.open(databaseURL: databaseURL) {
        case let .operational(repository):
            return .operational(try make(
                repository: repository,
                applicationSupportRoot: applicationSupportRoot,
                databaseURL: databaseURL,
                fileManager: fileManager
            ))
        case let .recovery(session):
            return .recovery(session)
        }
    }

    private static func make(
        repository: SQLiteEventJournalRepository,
        applicationSupportRoot: URL,
        databaseURL: URL,
        fileManager: FileManager
    ) throws -> Self {
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
        let volumeCapacityProvider = FoundationStartupVolumeCapacityProvider(
            dataDirectoryURL: applicationSupportRoot
        )
        let baselineScanCoordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: baselineContextProvider,
            calibrationRunner: EventJournalAuthorizedBaselineCalibrationRunner(
                repository: repository,
                scanner: scanner
            ),
            snapshotRepository: repository,
            volumeCapacityProvider: volumeCapacityProvider,
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
        let capacityRecorder = StartupVolumeCapacityRecorder(
            provider: volumeCapacityProvider,
            repository: repository
        )
        let storageHistoryBackgroundCoordinator =
            StorageHistoryBackgroundCoordinator(
                recorder: capacityRecorder,
                retention: repository
            )
        let storageHistoryLifecycleMonitor =
            try NativeStorageHistoryLifecycleMonitor(
                receiver: storageHistoryBackgroundCoordinator
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
            storageHistoryQuery: StorageHistoryOverviewQuery(
                directoryRepository: repository,
                volumeRepository: repository
            ),
            startupVolume24HourStatusQuery: StartupVolume24HourStatusQuery(
                repository: repository
            ),
            storageHistoryBackgroundCoordinator:
                storageHistoryBackgroundCoordinator,
            storageHistoryLifecycleMonitor: storageHistoryLifecycleMonitor,
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
