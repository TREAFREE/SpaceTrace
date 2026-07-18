import AppKit
import OSLog
import SpaceTraceMonitoring

@MainActor
final class SpaceTraceAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.TREAFREE.SpaceTrace",
        category: "lifecycle"
    )
    private var compositionRoot: SpaceTraceCompositionRoot?
    private var startupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        do {
            let compositionRoot = try SpaceTraceCompositionRoot.make()
            self.compositionRoot = compositionRoot
            startupTask = Task { @concurrent [weak self, lifecycle = compositionRoot.lifecycle] in
                do {
                    _ = try await lifecycle.start()
                } catch is CancellationError {
                    return
                } catch NativeMonitoringApplicationLifecycleError.startCancelled {
                    return
                } catch {
                    await self?.recordStartupFailure()
                }
            }
        } catch {
            logger.error("Application composition failed with private diagnostic context.")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard let lifecycle = compositionRoot?.lifecycle else {
            return .terminateNow
        }
        guard shutdownTask == nil else {
            return .terminateLater
        }

        startupTask?.cancel()
        shutdownTask = Task { @concurrent in
            await lifecycle.stop()
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func recordStartupFailure() {
        logger.error("Monitoring startup failed with private diagnostic context.")
    }
}
