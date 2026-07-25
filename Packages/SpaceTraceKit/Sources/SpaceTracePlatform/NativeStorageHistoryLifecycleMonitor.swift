import AppKit
import Foundation
import SpaceTraceApplication

public enum NativeStorageHistoryLifecycleMonitorError:
    Error,
    Sendable,
    Equatable
{
    case invalidSampleInterval
}

/// Converts public macOS lifecycle notifications and power-efficient
/// maintenance opportunities into application-owned events. Native callbacks
/// only enqueue immutable values; all persistence work runs behind the
/// application coordinator.
@MainActor
public final class NativeStorageHistoryLifecycleMonitor {
    private enum PeriodicTimerAction {
        case none
        case pause
        case restart
    }

    private let receiver: any StorageHistoryLifecycleEventReceiving
    private let now: @Sendable () -> Date
    private let sampleInterval: TimeInterval
    private let workspaceNotificationCenter: NotificationCenter
    private let systemNotificationCenter: NotificationCenter
    private let schedulesAutomaticRetention: Bool
    private var eventContinuation: AsyncStream<
        StorageHistoryLifecycleEvent
    >.Continuation?
    private var deliveryTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var notificationTasks: [Task<Void, Never>] = []
    private var retentionScheduler: NSBackgroundActivityScheduler?
    private var retentionTask: Task<Void, Never>?
    private var isStarted = false

    public init(
        receiver: any StorageHistoryLifecycleEventReceiving,
        sampleInterval: TimeInterval = 3_600,
        workspaceNotificationCenter: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        systemNotificationCenter: NotificationCenter = .default,
        schedulesAutomaticRetention: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws(NativeStorageHistoryLifecycleMonitorError) {
        guard sampleInterval > 0, sampleInterval.isFinite else {
            throw .invalidSampleInterval
        }
        self.receiver = receiver
        self.sampleInterval = sampleInterval
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.systemNotificationCenter = systemNotificationCenter
        self.schedulesAutomaticRetention = schedulesAutomaticRetention
        self.now = now
    }

    public func start() {
        guard isStarted == false else { return }
        isStarted = true
        let pair = AsyncStream<StorageHistoryLifecycleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        eventContinuation = pair.continuation
        let receiver = receiver
        deliveryTask = Task { @concurrent in
            for await event in pair.stream {
                guard Task.isCancelled == false else { return }
                _ = await receiver.handle(event)
            }
        }
        eventContinuation?.yield(.started(at: now()))
        startPeriodicTimer()

        notificationTasks = [
            observeWorkspace(
                NSWorkspace.willSleepNotification,
                event: { .willSleep(at: $0) },
                periodicTimerAction: .pause
            ),
            observeWorkspace(
                NSWorkspace.didWakeNotification,
                event: { .didWake(at: $0) },
                periodicTimerAction: .restart
            ),
            observeSystem(
                .NSSystemClockDidChange,
                event: { .significantTimeChanged(at: $0) },
                periodicTimerAction: .restart
            ),
            observeSystem(
                .NSSystemTimeZoneDidChange,
                event: { .significantTimeChanged(at: $0) },
                periodicTimerAction: .restart
            ),
            observeSystem(
                .NSCalendarDayChanged,
                event: { .significantTimeChanged(at: $0) },
                periodicTimerAction: .restart
            ),
        ]
        if schedulesAutomaticRetention {
            startRetentionScheduler()
        }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        notificationTasks.forEach { $0.cancel() }
        notificationTasks.removeAll()
        periodicTask?.cancel()
        periodicTask = nil
        retentionScheduler?.invalidate()
        retentionScheduler = nil
        retentionTask?.cancel()
        retentionTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    private func observeWorkspace(
        _ name: Notification.Name,
        event: @escaping @Sendable (Date) -> StorageHistoryLifecycleEvent,
        periodicTimerAction: PeriodicTimerAction = .none
    ) -> Task<Void, Never> {
        let notifications = workspaceNotificationCenter.notifications(named: name)
        return Task { [weak self] in
            for await _ in notifications {
                guard let self, Task.isCancelled == false else { return }
                eventContinuation?.yield(event(now()))
                apply(periodicTimerAction)
            }
        }
    }

    private func observeSystem(
        _ name: Notification.Name,
        event: @escaping @Sendable (Date) -> StorageHistoryLifecycleEvent,
        periodicTimerAction: PeriodicTimerAction = .none
    ) -> Task<Void, Never> {
        let notifications = systemNotificationCenter.notifications(named: name)
        return Task { [weak self] in
            for await _ in notifications {
                guard let self, Task.isCancelled == false else { return }
                eventContinuation?.yield(event(now()))
                apply(periodicTimerAction)
            }
        }
    }

    private func apply(_ action: PeriodicTimerAction) {
        switch action {
        case .none:
            break
        case .pause:
            periodicTask?.cancel()
            periodicTask = nil
        case .restart:
            startPeriodicTimer()
        }
    }

    private func startPeriodicTimer() {
        periodicTask?.cancel()
        guard isStarted, let continuation = eventContinuation else {
            periodicTask = nil
            return
        }
        let interval = sampleInterval
        let clock = now
        periodicTask = Task { @concurrent in
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                continuation.yield(.periodic(at: clock()))
            }
        }
    }

    private func startRetentionScheduler() {
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "com.TREAFREE.SpaceTrace.storage-history-retention"
        )
        scheduler.repeats = true
        scheduler.interval = 24 * 3_600
        scheduler.tolerance = 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(.deferred)
                    return
                }
                handleRetentionOpportunity(completion: completion)
            }
        }
        retentionScheduler = scheduler
    }

    func handleRetentionOpportunity(
        completion: @escaping NSBackgroundActivityScheduler.CompletionHandler
    ) {
        guard isStarted, retentionTask == nil else {
            completion(.deferred)
            return
        }
        let receiver = receiver
        let date = now()
        let monitor = self
        retentionTask = Task { @concurrent [monitor, receiver] in
            let outcome = await receiver.handle(.maintenance(at: date))
            await monitor.finishRetention(
                outcome: outcome,
                completion: completion
            )
        }
    }

    private func finishRetention(
        outcome: StorageHistoryLifecycleOutcome,
        completion: @escaping NSBackgroundActivityScheduler.CompletionHandler
    ) {
        completion(outcome == .completed ? .finished : .deferred)
        retentionTask = nil
    }
}
