import AppKit
import OSLog
import SpaceTraceApplication
import SpaceTraceMonitoring
import SpaceTracePersistence
import SpaceTracePlatform

@MainActor
final class SpaceTraceAppDelegate: NSObject, NSApplicationDelegate {
    let authorizationModel = DirectoryAuthorizationViewModel()
    let baselineScanModel = BaselineScanViewModel()
    let directoryHistoryModel = DirectoryHistoryViewModel()
    let databaseRecoveryModel = DatabaseRecoveryViewModel()

    private let logger = Logger(
        subsystem: "com.TREAFREE.SpaceTrace",
        category: "lifecycle"
    )
    private var compositionRoot: SpaceTraceCompositionRoot?
    private var recoverySession: SQLiteReadOnlyRecoverySession?
    private var startupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
#if DEBUG
        if authorizationModel.loadUITestScenarioIfConfigured() {
            return
        }
#endif
        do {
            switch try SpaceTraceCompositionRoot.bootstrap() {
            case let .operational(compositionRoot):
                self.compositionRoot = compositionRoot
                authorizationModel.connect(compositionRoot.authorizationCoordinator)
                baselineScanModel.connect(compositionRoot.baselineScanCoordinator)
                directoryHistoryModel.connect(compositionRoot.directoryHistoryQuery)
                startupTask = Task { [weak self] in
                    await self?.authorizationModel.start()
                }
            case let .recovery(session):
                recoverySession = session
                databaseRecoveryModel.activate(session.overview)
                authorizationModel.handleCompositionFailure()
                baselineScanModel.handleCompositionFailure()
                directoryHistoryModel.handleCompositionFailure()
            }
        } catch {
            authorizationModel.handleCompositionFailure()
            baselineScanModel.handleCompositionFailure()
            directoryHistoryModel.handleCompositionFailure()
            logger.error("Application composition failed with private diagnostic context.")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        Task { [weak self] in
            await self?.authorizationModel.refreshIfNeeded()
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
        compositionRoot.scanSchedulingMonitor.stop()
        let authorizationCoordinator = compositionRoot.authorizationCoordinator
        let baselineScanCoordinator = compositionRoot.baselineScanCoordinator
        shutdownTask = Task { @concurrent in
            await baselineScanCoordinator.cancel()
            await authorizationCoordinator.stop()
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

}
