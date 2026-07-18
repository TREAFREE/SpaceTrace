import Foundation
import SpaceTraceApplication
import SpaceTraceFileSystem
import SpaceTracePlatform

/// Non-UI composition root for the volume lifecycle and filesystem
/// invalidation pipeline. The app can own `run()` in one utility-priority task
/// and cancel that task during shutdown or sleep transitions.
public actor NativeVolumeMonitoringRuntime {
    private let eventSource: DiskArbitrationVolumeEventSource
    private let coordinator: ScopeMonitoringCoordinator
    private let supervisor: NativeScopeFSEventSupervisor
    private let eventBufferCapacity: Int
    private var isRunning = false
    private var isObservingEvents = false
    private var lastObservedSignal: VolumeLifecycleSignal?
    private var lastMonitoringResult: ScopeMonitoringResult?

    public init(
        catalog: any WatchedScopeCatalog,
        repository: any EventJournalRepository & ScopeMountGenerationRepository,
        scanner: any CalibrationScanner,
        eventSource: DiskArbitrationVolumeEventSource = DiskArbitrationVolumeEventSource(),
        eventBufferCapacity: Int = 128,
        fseventLatency: TimeInterval = 1,
        fseventBufferCapacity: Int = 512,
        fseventRecoveryPolicy: FSEventStreamRecoveryPolicy = .standard,
        excludeEventsFromThisProcess: Bool = true
    ) {
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: scanner,
            recoveryPolicy: fseventRecoveryPolicy,
            latency: fseventLatency,
            bufferCapacity: fseventBufferCapacity,
            excludeEventsFromThisProcess: excludeEventsFromThisProcess
        )
        self.eventSource = eventSource
        self.supervisor = supervisor
        self.coordinator = ScopeMonitoringCoordinator(
            catalog: catalog,
            repository: repository,
            supervisor: supervisor,
            evidenceResolver: FSEventScopeMountEvidenceResolver()
        )
        self.eventBufferCapacity = eventBufferCapacity
    }

    public func run() async throws {
        guard isRunning == false else {
            throw NativeVolumeMonitoringRuntimeError.alreadyRunning
        }
        guard eventBufferCapacity > 0 else {
            throw NativeVolumeMonitoringRuntimeError.invalidEventBufferCapacity
        }
        isRunning = true
        defer {
            isRunning = false
            isObservingEvents = false
        }

        let source = eventSource
        do {
            try await withTaskCancellationHandler {
                try await runUntilCancelled()
            } onCancel: {
                source.stop()
            }
        } catch {
            source.stop()
            try? await coordinator.shutdown()
            await supervisor.stopAll()
            throw error
        }
    }

    public func activeStatus(
        for scopeID: WatchedScopeID
    ) async -> ActiveScopeFSEventStatus? {
        await supervisor.activeStatus(for: scopeID)
    }

    public func lastStreamFailure(for scopeID: WatchedScopeID) async -> String? {
        await supervisor.lastFailure(for: scopeID)
    }

    public func streamRecoveryStatus(
        for scopeID: WatchedScopeID
    ) async -> ScopeFSEventRecoveryStatus? {
        await supervisor.recoveryStatus(for: scopeID)
    }

    public func isObservingVolumeEvents() -> Bool {
        isObservingEvents
    }

    public func lastVolumeSignal() -> VolumeLifecycleSignal? {
        lastObservedSignal
    }

    public func lastResult() -> ScopeMonitoringResult? {
        lastMonitoringResult
    }

    private func runUntilCancelled() async throws {
        while true {
            try Task.checkCancellation()
            let events = try eventSource.start(bufferCapacity: eventBufferCapacity)
            isObservingEvents = true
            var mustRestartSource = false

            for await event in events {
                try Task.checkCancellation()
                let signal = try event.lifecycleSignal()
                lastObservedSignal = signal
                let result = try await processWithMountReadinessRetry(
                    signal
                )
                lastMonitoringResult = result
                if result.requiresVolumeEventSourceRestart {
                    mustRestartSource = true
                    eventSource.stop()
                    break
                }
            }
            isObservingEvents = false

            try Task.checkCancellation()
            guard mustRestartSource else {
                throw NativeVolumeMonitoringRuntimeError.eventSourceEnded
            }
            await Task.yield()
        }
    }

    private func processWithMountReadinessRetry(
        _ signal: VolumeLifecycleSignal
    ) async throws -> ScopeMonitoringResult {
        let maximumAttempts = 8
        for attempt in 0..<maximumAttempts {
            do {
                return try await coordinator.process(signal)
            } catch where Self.isTransientMountReadinessError(error) {
                guard attempt + 1 < maximumAttempts else { throw error }
                try await Task.sleep(for: .milliseconds(50 * (attempt + 1)))
            }
        }
        preconditionFailure("The bounded retry loop must return or throw.")
    }

    private nonisolated static func isTransientMountReadinessError(
        _ error: any Error
    ) -> Bool {
        if let error = error as? FSEventDeviceScopeError {
            switch error {
            case .unavailablePath, .watchPathMustBeDirectory, .volumeRootUnavailable:
                return true
            default:
                return false
            }
        }
        if let error = error as? FSEventStreamError {
            switch error {
            case .creationFailed, .startFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

public enum NativeVolumeMonitoringRuntimeError: Error, Sendable, Equatable {
    case alreadyRunning
    case invalidEventBufferCapacity
    case eventSourceEnded
}
