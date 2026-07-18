import SpaceTraceApplication

public protocol VolumeMonitoringRuntime: Sendable {
    func run() async throws
}

extension NativeVolumeMonitoringRuntime: VolumeMonitoringRuntime {}

/// Process-lifetime owner for bookmark restoration and the one long-lived
/// native monitoring task. Window/view lifecycle must not own this object.
public actor NativeMonitoringApplicationLifecycle {
    private let catalog: any RestorableWatchedScopeCatalog
    private let runtime: any VolumeMonitoringRuntime
    private var monitoringTask: Task<Void, Never>?
    private var operationEpoch: UInt64 = 0
    private var currentState: NativeMonitoringApplicationState = .stopped
    private var lastReport: WatchedScopeRestorationReport?

    public init(
        catalog: any RestorableWatchedScopeCatalog,
        runtime: any VolumeMonitoringRuntime
    ) {
        self.catalog = catalog
        self.runtime = runtime
    }

    @discardableResult
    public func start() async throws -> WatchedScopeRestorationReport {
        guard monitoringTask == nil,
              currentState != .restoringPermissions,
              currentState != .stopping else {
            throw NativeMonitoringApplicationLifecycleError.alreadyStarted
        }

        operationEpoch &+= 1
        let epoch = operationEpoch
        currentState = .restoringPermissions
        let report: WatchedScopeRestorationReport
        do {
            report = try await catalog.restore()
            try Task.checkCancellation()
            guard operationEpoch == epoch else {
                throw NativeMonitoringApplicationLifecycleError.startCancelled
            }
        } catch {
            if operationEpoch == epoch {
                await catalog.releaseAll()
                currentState = error is CancellationError ? .stopped : .failed
            }
            throw error
        }

        lastReport = report
        guard report.configuredScopeCount > 0 else {
            currentState = .idleWithoutConfiguredScopes
            return report
        }

        let runtime = self.runtime
        monitoringTask = Task { [weak self] in
            do {
                try await runtime.run()
                await self?.runtimeFinished(epoch: epoch, failed: true)
            } catch is CancellationError {
                await self?.runtimeFinished(epoch: epoch, failed: false)
            } catch {
                await self?.runtimeFinished(epoch: epoch, failed: true)
            }
        }
        currentState = .monitoring
        return report
    }

    public func stop() async {
        operationEpoch &+= 1
        currentState = .stopping
        let task = monitoringTask
        monitoringTask = nil
        task?.cancel()
        await task?.value
        await catalog.releaseAll()
        currentState = .stopped
    }

    public func state() -> NativeMonitoringApplicationState {
        currentState
    }

    public func latestRestorationReport() -> WatchedScopeRestorationReport? {
        lastReport
    }

    private func runtimeFinished(epoch: UInt64, failed: Bool) async {
        guard operationEpoch == epoch else { return }
        monitoringTask = nil
        await catalog.releaseAll()
        currentState = failed ? .failed : .stopped
    }
}

public enum NativeMonitoringApplicationState: Sendable, Equatable {
    case stopped
    case restoringPermissions
    case idleWithoutConfiguredScopes
    case monitoring
    case stopping
    case failed
}

public enum NativeMonitoringApplicationLifecycleError: Error, Sendable, Equatable {
    case alreadyStarted
    case startCancelled
}
