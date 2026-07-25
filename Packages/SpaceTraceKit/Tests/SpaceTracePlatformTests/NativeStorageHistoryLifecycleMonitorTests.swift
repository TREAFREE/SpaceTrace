import AppKit
import Foundation
import SpaceTraceApplication
import Synchronization
import Testing
@testable import SpaceTracePlatform

@MainActor
struct NativeStorageHistoryLifecycleMonitorTests {
    @Test("Invalid periodic sampling intervals fail without crashing")
    func rejectsInvalidSampleInterval() {
        let receiver = LifecycleReceiverFake()

        #expect(throws: NativeStorageHistoryLifecycleMonitorError.invalidSampleInterval) {
            _ = try NativeStorageHistoryLifecycleMonitor(
                receiver: receiver,
                sampleInterval: 0,
                schedulesAutomaticRetention: false
            )
        }
    }

    @Test("Workspace and system notifications become typed lifecycle events")
    func forwardsLifecycleNotifications() async throws {
        let workspaceCenter = NotificationCenter()
        let systemCenter = NotificationCenter()
        let timestamp = Date(timeIntervalSince1970: 1_900_000_000)
        let receiver = LifecycleReceiverFake()
        let monitor = try NativeStorageHistoryLifecycleMonitor(
            receiver: receiver,
            sampleInterval: 86_400,
            workspaceNotificationCenter: workspaceCenter,
            systemNotificationCenter: systemCenter,
            schedulesAutomaticRetention: false,
            now: { timestamp }
        )

        monitor.start()
        try await waitForEventCount(1, receiver: receiver)
        await allowNotificationSubscriptionsToStart()

        workspaceCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        try await waitForEventCount(2, receiver: receiver)
        workspaceCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        try await waitForEventCount(3, receiver: receiver)
        systemCenter.post(
            name: .NSSystemClockDidChange,
            object: nil
        )
        try await waitForEventCount(4, receiver: receiver)
        systemCenter.post(
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
        try await waitForEventCount(5, receiver: receiver)
        systemCenter.post(
            name: .NSCalendarDayChanged,
            object: nil
        )
        try await waitForEventCount(6, receiver: receiver)

        monitor.stop()

        #expect(
            await receiver.events == [
                .started(at: timestamp),
                .willSleep(at: timestamp),
                .didWake(at: timestamp),
                .significantTimeChanged(at: timestamp),
                .significantTimeChanged(at: timestamp),
                .significantTimeChanged(at: timestamp),
            ]
        )
    }

    @Test("Automatic retention opportunities are single-flight and report completion")
    func serializesRetentionOpportunities() async throws {
        let receiver = DelayedRetentionReceiverFake()
        let results = RetentionResultBox()
        let monitor = try NativeStorageHistoryLifecycleMonitor(
            receiver: receiver,
            sampleInterval: 86_400,
            schedulesAutomaticRetention: false
        )
        monitor.start()
        try await waitForEventCount(1, receiver: receiver)

        monitor.handleRetentionOpportunity { result in
            results.append(result)
        }
        try await waitForEventCount(2, receiver: receiver)
        monitor.handleRetentionOpportunity { result in
            results.append(result)
        }

        #expect(results.values == [.deferred])

        await receiver.releaseMaintenance()
        try await waitForResultCount(2, results: results)
        monitor.stop()

        #expect(results.values == [.deferred, .finished])
    }

    private func allowNotificationSubscriptionsToStart() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private func waitForEventCount(
        _ expected: Int,
        receiver: LifecycleReceiverFake
    ) async throws {
        for _ in 0..<100 {
            if await receiver.events.count >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(expected) lifecycle events.")
        throw LifecycleMonitorFixtureError.timeout
    }

    private func waitForEventCount(
        _ expected: Int,
        receiver: DelayedRetentionReceiverFake
    ) async throws {
        for _ in 0..<100 {
            if await receiver.events.count >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(expected) lifecycle events.")
        throw LifecycleMonitorFixtureError.timeout
    }

    private func waitForResultCount(
        _ expected: Int,
        results: RetentionResultBox
    ) async throws {
        for _ in 0..<100 {
            if results.values.count >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(expected) retention results.")
        throw LifecycleMonitorFixtureError.timeout
    }
}

private actor LifecycleReceiverFake: StorageHistoryLifecycleEventReceiving {
    private(set) var events: [StorageHistoryLifecycleEvent] = []

    func handle(
        _ event: StorageHistoryLifecycleEvent
    ) -> StorageHistoryLifecycleOutcome {
        events.append(event)
        return .completed
    }
}

private actor DelayedRetentionReceiverFake:
    StorageHistoryLifecycleEventReceiving
{
    private(set) var events: [StorageHistoryLifecycleEvent] = []
    private var maintenanceContinuation: CheckedContinuation<Void, Never>?

    func handle(
        _ event: StorageHistoryLifecycleEvent
    ) async -> StorageHistoryLifecycleOutcome {
        events.append(event)
        guard case .maintenance = event else { return .completed }
        await withCheckedContinuation { continuation in
            maintenanceContinuation = continuation
        }
        return .completed
    }

    func releaseMaintenance() {
        maintenanceContinuation?.resume()
        maintenanceContinuation = nil
    }
}

private final class RetentionResultBox: Sendable {
    private let storage = Mutex<[NSBackgroundActivityScheduler.Result]>([])

    var values: [NSBackgroundActivityScheduler.Result] {
        storage.withLock { $0 }
    }

    func append(_ value: NSBackgroundActivityScheduler.Result) {
        storage.withLock { $0.append(value) }
    }
}

private enum LifecycleMonitorFixtureError: Error {
    case timeout
}
