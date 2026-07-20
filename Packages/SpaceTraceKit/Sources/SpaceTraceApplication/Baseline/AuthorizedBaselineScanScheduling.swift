import Foundation

public enum ScanPowerSource: Sendable, Equatable {
    case external
    case battery
    case unknown
}

public enum ScanThermalPressure: Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public enum ScanSystemActivity: Sendable, Equatable {
    case awake
    case sleeping
}

public struct ScanSchedulingSnapshot: Sendable, Equatable {
    public let powerSource: ScanPowerSource
    public let isLowPowerModeEnabled: Bool
    public let thermalPressure: ScanThermalPressure
    public let systemActivity: ScanSystemActivity

    public init(
        powerSource: ScanPowerSource,
        isLowPowerModeEnabled: Bool,
        thermalPressure: ScanThermalPressure,
        systemActivity: ScanSystemActivity
    ) {
        self.powerSource = powerSource
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalPressure = thermalPressure
        self.systemActivity = systemActivity
    }

    public static let unconstrained = ScanSchedulingSnapshot(
        powerSource: .unknown,
        isLowPowerModeEnabled: false,
        thermalPressure: .nominal,
        systemActivity: .awake
    )
}

public enum AuthorizedBaselineScanDeferralReason: Sendable, Equatable {
    case systemSleeping
    case thermalPressure(ScanThermalPressure)
    case lowPowerMode
}

public enum AuthorizedBaselineScanSchedulingDecision: Sendable, Equatable {
    case runnable(ScanSchedulingSnapshot)
    case deferred(
        reason: AuthorizedBaselineScanDeferralReason,
        snapshot: ScanSchedulingSnapshot
    )

    public var snapshot: ScanSchedulingSnapshot {
        switch self {
        case let .runnable(snapshot), let .deferred(_, snapshot): snapshot
        }
    }
}

public struct AuthorizedBaselineScanSchedulingPolicy: Sendable {
    public init() {}

    public func decision(
        for snapshot: ScanSchedulingSnapshot
    ) -> AuthorizedBaselineScanSchedulingDecision {
        if snapshot.systemActivity == .sleeping {
            return .deferred(reason: .systemSleeping, snapshot: snapshot)
        }
        switch snapshot.thermalPressure {
        case .serious, .critical:
            return .deferred(
                reason: .thermalPressure(snapshot.thermalPressure),
                snapshot: snapshot
            )
        case .nominal, .fair, .unknown:
            break
        }
        if snapshot.isLowPowerModeEnabled {
            return .deferred(reason: .lowPowerMode, snapshot: snapshot)
        }
        // A user-requested baseline may run on ordinary battery power. The
        // source remains part of the snapshot so future background work can
        // apply the lower battery budget without changing this truth model.
        return .runnable(snapshot)
    }
}

public protocol AuthorizedBaselineScanScheduling: Sendable {
    /// Every stream must replay the current decision before later changes.
    func decisions() async -> AsyncStream<AuthorizedBaselineScanSchedulingDecision>
}

public protocol ScanSchedulingSnapshotReceiving: Sendable {
    func update(_ snapshot: ScanSchedulingSnapshot) async
}

public actor AuthorizedBaselineScanSchedulingGate:
    AuthorizedBaselineScanScheduling,
    ScanSchedulingSnapshotReceiving
{
    private struct Observer {
        let continuation: AsyncStream<AuthorizedBaselineScanSchedulingDecision>.Continuation
    }

    private let policy: AuthorizedBaselineScanSchedulingPolicy
    private var currentDecision: AuthorizedBaselineScanSchedulingDecision
    private var observers: [UUID: Observer] = [:]

    public init(
        initialSnapshot: ScanSchedulingSnapshot = .unconstrained,
        policy: AuthorizedBaselineScanSchedulingPolicy = .init()
    ) {
        self.policy = policy
        currentDecision = policy.decision(for: initialSnapshot)
    }

    public func decisions() -> AsyncStream<AuthorizedBaselineScanSchedulingDecision> {
        let observerID = UUID()
        let pair = AsyncStream<AuthorizedBaselineScanSchedulingDecision>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @concurrent [weak self] in
                await self?.removeObserver(observerID)
            }
        }
        observers[observerID] = Observer(continuation: pair.continuation)
        pair.continuation.yield(currentDecision)
        return pair.stream
    }

    public func update(_ snapshot: ScanSchedulingSnapshot) {
        let decision = policy.decision(for: snapshot)
        guard decision != currentDecision else { return }
        currentDecision = decision
        observers.values.forEach { $0.continuation.yield(decision) }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}

public struct UnconstrainedAuthorizedBaselineScanScheduler: AuthorizedBaselineScanScheduling {
    public init() {}

    public func decisions() -> AsyncStream<AuthorizedBaselineScanSchedulingDecision> {
        AsyncStream { continuation in
            continuation.yield(.runnable(.unconstrained))
        }
    }
}
