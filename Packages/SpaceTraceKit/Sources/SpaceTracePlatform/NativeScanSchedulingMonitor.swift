import AppKit
import CoreFoundation
import Foundation
import IOKit.ps
import SpaceTraceApplication

public struct FoundationScanSchedulingSnapshotProvider: Sendable {
    public init() {}

    public func snapshot(
        systemActivity: ScanSystemActivity
    ) -> ScanSchedulingSnapshot {
        let processInfo = ProcessInfo.processInfo
        let powerSourceName: String? = {
            guard let unmanagedSnapshot = IOPSCopyPowerSourcesInfo() else { return nil }
            let powerSnapshot = unmanagedSnapshot.takeRetainedValue()
            return IOPSGetProvidingPowerSourceType(powerSnapshot)
                .takeUnretainedValue() as String
        }()
        return Self.snapshot(
            thermalState: processInfo.thermalState,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            powerSourceName: powerSourceName,
            systemActivity: systemActivity
        )
    }

    static func snapshot(
        thermalState: ProcessInfo.ThermalState,
        isLowPowerModeEnabled: Bool,
        powerSourceName: String?,
        systemActivity: ScanSystemActivity
    ) -> ScanSchedulingSnapshot {
        ScanSchedulingSnapshot(
            powerSource: powerSource(from: powerSourceName),
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            thermalPressure: thermalPressure(from: thermalState),
            systemActivity: systemActivity
        )
    }

    private static func powerSource(from name: String?) -> ScanPowerSource {
        switch name {
        case kIOPMACPowerKey: .external
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: .battery
        default: .unknown
        }
    }

    private static func thermalPressure(
        from state: ProcessInfo.ThermalState
    ) -> ScanThermalPressure {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}

@MainActor
public final class NativeScanSchedulingMonitor {
    private let receiver: any ScanSchedulingSnapshotReceiving
    private let snapshotProvider: FoundationScanSchedulingSnapshotProvider
    private var systemActivity: ScanSystemActivity = .awake
    private var notificationTasks: [Task<Void, Never>] = []
    private var snapshotContinuation: AsyncStream<ScanSchedulingSnapshot>.Continuation?
    private var snapshotDeliveryTask: Task<Void, Never>?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSourceCallbackBox: PowerSourceCallbackBox?
    private var isStarted = false

    public init(
        receiver: any ScanSchedulingSnapshotReceiving,
        snapshotProvider: FoundationScanSchedulingSnapshotProvider = .init()
    ) {
        self.receiver = receiver
        self.snapshotProvider = snapshotProvider
    }

    public func start() {
        guard isStarted == false else { return }
        isStarted = true
        let snapshotPair = AsyncStream<ScanSchedulingSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        snapshotContinuation = snapshotPair.continuation
        snapshotDeliveryTask = Task { @concurrent [receiver, stream = snapshotPair.stream] in
            for await snapshot in stream {
                guard Task.isCancelled == false else { return }
                await receiver.update(snapshot)
            }
        }
        publishCurrentSnapshot()

        notificationTasks = [
            observeProcessInfoNotification(ProcessInfo.thermalStateDidChangeNotification),
            observeProcessInfoNotification(.NSProcessInfoPowerStateDidChange),
            observeWorkspaceNotification(NSWorkspace.willSleepNotification, activity: .sleeping),
            observeWorkspaceNotification(NSWorkspace.didWakeNotification, activity: .awake),
        ]
        startPowerSourceObservation()
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        notificationTasks.forEach { $0.cancel() }
        notificationTasks.removeAll()
        snapshotContinuation?.finish()
        snapshotContinuation = nil
        snapshotDeliveryTask?.cancel()
        snapshotDeliveryTask = nil

        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                powerSourceRunLoopSource,
                .commonModes
            )
        }
        powerSourceRunLoopSource = nil
        powerSourceCallbackBox = nil
    }

    private func observeProcessInfoNotification(
        _ name: Notification.Name
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: name) {
                guard let self, Task.isCancelled == false else { return }
                publishCurrentSnapshot()
            }
        }
    }

    private func observeWorkspaceNotification(
        _ name: Notification.Name,
        activity: ScanSystemActivity
    ) -> Task<Void, Never> {
        Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter
                .notifications(named: name)
            for await _ in notifications {
                guard let self, Task.isCancelled == false else { return }
                systemActivity = activity
                publishCurrentSnapshot()
            }
        }
    }

    private func startPowerSourceObservation() {
        let callbackBox = PowerSourceCallbackBox { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishCurrentSnapshot()
            }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(
            nativePowerSourceDidChange,
            Unmanaged.passUnretained(callbackBox).toOpaque()
        )?.takeRetainedValue() else {
            return
        }
        powerSourceCallbackBox = callbackBox
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func publishCurrentSnapshot() {
        guard isStarted else { return }
        let snapshot = snapshotProvider.snapshot(systemActivity: systemActivity)
        snapshotContinuation?.yield(snapshot)
    }
}

/// IOKit invokes this function through a C callback. The box is immutable and
/// retained by `NativeScanSchedulingMonitor` until its run-loop source is
/// removed, which is the safety invariant behind its Sendable escape hatch.
private final class PowerSourceCallbackBox: @unchecked Sendable {
    let callback: @Sendable () -> Void

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }
}

private func nativePowerSourceDidChange(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PowerSourceCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .callback()
}
