import AppKit
import OSLog
import SpaceTraceApplication
import SpaceTraceMonitoring

@MainActor
final class SpaceTraceAppDelegate: NSObject, NSApplicationDelegate {
    let authorizationModel = DirectoryAuthorizationViewModel()
    let baselineScanModel = BaselineScanViewModel()

    private let logger = Logger(
        subsystem: "com.TREAFREE.SpaceTrace",
        category: "lifecycle"
    )
    private var compositionRoot: SpaceTraceCompositionRoot?
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
            let compositionRoot = try SpaceTraceCompositionRoot.make()
            self.compositionRoot = compositionRoot
            authorizationModel.connect(compositionRoot.authorizationCoordinator)
            baselineScanModel.connect(compositionRoot.baselineScanCoordinator)
            startupTask = Task { [weak self] in
                await self?.authorizationModel.start()
            }
        } catch {
            authorizationModel.handleCompositionFailure()
            baselineScanModel.handleCompositionFailure()
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
        guard let coordinator = compositionRoot?.authorizationCoordinator else {
            return .terminateNow
        }
        guard shutdownTask == nil else {
            return .terminateLater
        }

        startupTask?.cancel()
        shutdownTask = Task { @concurrent in
            await coordinator.stop()
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

}
