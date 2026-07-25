import AppKit
import OSLog
import SpaceTraceApplication
import SpaceTraceDomain
import SpaceTraceMonitoring
import SpaceTracePersistence
import SpaceTracePlatform

@MainActor
final class SpaceTraceAppDelegate: NSObject, NSApplicationDelegate {
    let authorizationModel = DirectoryAuthorizationViewModel()
    let baselineScanModel = BaselineScanViewModel()
    let directoryHistoryModel = DirectoryHistoryViewModel()
    let databaseRecoveryModel = DatabaseRecoveryViewModel()
    let menuBarStatusModel = MenuBarStatusViewModel()

    private let logger = Logger(
        subsystem: "com.TREAFREE.SpaceTrace",
        category: "lifecycle"
    )
    private var compositionRoot: SpaceTraceCompositionRoot?
    private var recoverySession: SQLiteReadOnlyRecoverySession?
    private var startupTask: Task<Void, Never>?
    private var storageHistoryStartupTask: Task<Void, Never>?
    private var storageHistoryObservationTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
#if DEBUG
        if authorizationModel.loadUITestScenarioIfConfigured() {
            directoryHistoryModel.connect(UITestStorageHistoryLoader())
            menuBarStatusModel.loadUITestFixture()
            return
        }
#endif
        do {
            switch try SpaceTraceCompositionRoot.bootstrap() {
            case let .operational(compositionRoot):
                self.compositionRoot = compositionRoot
                authorizationModel.connect(compositionRoot.authorizationCoordinator)
                baselineScanModel.connect(compositionRoot.baselineScanCoordinator)
                directoryHistoryModel.connect(compositionRoot.storageHistoryQuery)
                menuBarStatusModel.connect(
                    compositionRoot.startupVolume24HourStatusQuery
                )
                startupTask = Task { [weak self] in
                    await self?.authorizationModel.start()
                }
                storageHistoryObservationTask = Task { [weak self] in
                    await self?.menuBarStatusModel.monitor(
                        background:
                            compositionRoot.storageHistoryBackgroundCoordinator
                    )
                }
                storageHistoryStartupTask = Task {
                    await compositionRoot.storageHistoryBackgroundCoordinator
                        .start()
                    guard Task.isCancelled == false else { return }
                    compositionRoot.storageHistoryLifecycleMonitor.start()
                }
            case let .recovery(session):
                recoverySession = session
                databaseRecoveryModel.activate(session.overview)
                authorizationModel.handleCompositionFailure()
                baselineScanModel.handleCompositionFailure()
                directoryHistoryModel.handleCompositionFailure()
                menuBarStatusModel.handleCompositionFailure()
            }
        } catch {
            authorizationModel.handleCompositionFailure()
            baselineScanModel.handleCompositionFailure()
            directoryHistoryModel.handleCompositionFailure()
            menuBarStatusModel.handleCompositionFailure()
            logger.error("Application composition failed with private diagnostic context.")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        Task { [weak self] in
            await self?.authorizationModel.refreshIfNeeded()
            await self?.menuBarStatusModel.refresh()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard let compositionRoot else {
            recoverySession?.close()
            return .terminateNow
        }
        guard shutdownTask == nil else {
            return .terminateLater
        }

        startupTask?.cancel()
        storageHistoryStartupTask?.cancel()
        storageHistoryObservationTask?.cancel()
        compositionRoot.storageHistoryLifecycleMonitor.stop()
        compositionRoot.scanSchedulingMonitor.stop()
        let authorizationCoordinator = compositionRoot.authorizationCoordinator
        let baselineScanCoordinator = compositionRoot.baselineScanCoordinator
        let storageHistoryBackgroundCoordinator =
            compositionRoot.storageHistoryBackgroundCoordinator
        shutdownTask = Task { @concurrent in
            await baselineScanCoordinator.cancel()
            await storageHistoryBackgroundCoordinator.stop()
            await authorizationCoordinator.stop()
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

#if DEBUG
private struct UITestStorageHistoryLoader: StorageHistoryOverviewLoading {
    nonisolated func loadOverview(
        contexts: [AuthorizedBaselineScanContext],
        window: DirectoryHistoryWindow,
        through end: Date,
        growthLimit: Int
    ) throws -> StorageHistoryOverview {
        _ = contexts
        _ = growthLimit
        let start = end.addingTimeInterval(-window.duration)
        let volumeUUID = UUID(
            uuidString: "88888888-8888-8888-8888-888888888888"
        )
        let startingAvailable = try ByteCount(100 * 1_073_741_824)
        let endingAvailable = try ByteCount(98 * 1_073_741_824)
        let points = [
            StartupVolumeHistoryPoint(
                bucketStart: start,
                sampledAt: start,
                sequence: 1,
                volumeUUID: volumeUUID,
                totalBytes: try ByteCount(256 * 1_073_741_824),
                availableBytes: startingAvailable,
                availableForImportantUsageBytes: nil,
                coverage: .complete
            ),
            StartupVolumeHistoryPoint(
                bucketStart: end,
                sampledAt: end,
                sequence: 2,
                volumeUUID: volumeUUID,
                totalBytes: try ByteCount(256 * 1_073_741_824),
                availableBytes: endingAvailable,
                availableForImportantUsageBytes: nil,
                coverage: .partial
            ),
        ]
        let directories = DirectoryHistoryOverview(
            window: window,
            start: start,
            end: end,
            bucket: window.bucket,
            series: [],
            growthSources: [],
            coverage: .unavailable
        )
        return StorageHistoryOverview(
            window: window,
            start: start,
            end: end,
            bucket: window.bucket,
            volume: StartupVolumeHistorySeries(
                points: points,
                coverage: .partial,
                identityDiscontinuity: false
            ),
            directories: directories,
            reconciliation: StorageReconciliationSummary(
                firstObservedAt: start,
                lastObservedAt: end,
                startingAvailableBytes: startingAvailable,
                endingAvailableBytes: endingAvailable,
                diskSpaceLoss: try ByteCount(2 * 1_073_741_824),
                observedDirectoryAllocatedGrowth: nil,
                explainedDiskSpaceLoss: nil,
                unattributedDiskSpaceLoss: nil,
                comparableScopeCount: 0,
                excludedNestedScopeCount: 0,
                excludedExternalScopeCount: 0,
                unknownVolumeScopeCount: 0,
                coverage: .partial
            )
        )
    }
}
#endif
