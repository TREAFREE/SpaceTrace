import Foundation

public enum StorageHistoryLifecycleEvent: Sendable, Equatable {
    case started(at: Date)
    case periodic(at: Date)
    case willSleep(at: Date)
    case didWake(at: Date)
    case significantTimeChanged(at: Date)
    case maintenance(at: Date)

    public var occurredAt: Date {
        switch self {
        case let .started(at),
             let .periodic(at),
             let .willSleep(at),
             let .didWake(at),
             let .significantTimeChanged(at),
             let .maintenance(at):
            at
        }
    }
}

public enum StorageHistoryBackgroundPhase: Sendable, Equatable {
    case stopped
    case awake
    case sleeping
}

public enum StorageHistoryLifecycleOutcome: Sendable, Equatable {
    case completed
    case deferredWhileSleeping
    case failed
    case stopped
}

public struct StorageHistoryBackgroundState: Sendable, Equatable {
    public let phase: StorageHistoryBackgroundPhase
    public let processedEventCount: Int
    public let lastSampleTrigger: StorageHistorySampleTrigger?
    public let lastSampleAttemptAt: Date?
    public let lastSuccessfulSampleAt: Date?
    public let sampleFailureCount: Int
    public let consecutiveSampleFailureCount: Int
    public let lastRetentionAttemptAt: Date?
    public let lastSuccessfulRetentionAt: Date?
    public let retentionFailureCount: Int

    public init(
        phase: StorageHistoryBackgroundPhase,
        processedEventCount: Int,
        lastSampleTrigger: StorageHistorySampleTrigger?,
        lastSampleAttemptAt: Date?,
        lastSuccessfulSampleAt: Date?,
        sampleFailureCount: Int,
        consecutiveSampleFailureCount: Int,
        lastRetentionAttemptAt: Date?,
        lastSuccessfulRetentionAt: Date?,
        retentionFailureCount: Int
    ) {
        self.phase = phase
        self.processedEventCount = processedEventCount
        self.lastSampleTrigger = lastSampleTrigger
        self.lastSampleAttemptAt = lastSampleAttemptAt
        self.lastSuccessfulSampleAt = lastSuccessfulSampleAt
        self.sampleFailureCount = sampleFailureCount
        self.consecutiveSampleFailureCount = consecutiveSampleFailureCount
        self.lastRetentionAttemptAt = lastRetentionAttemptAt
        self.lastSuccessfulRetentionAt = lastSuccessfulRetentionAt
        self.retentionFailureCount = retentionFailureCount
    }

    public static let stopped = StorageHistoryBackgroundState(
        phase: .stopped,
        processedEventCount: 0,
        lastSampleTrigger: nil,
        lastSampleAttemptAt: nil,
        lastSuccessfulSampleAt: nil,
        sampleFailureCount: 0,
        consecutiveSampleFailureCount: 0,
        lastRetentionAttemptAt: nil,
        lastSuccessfulRetentionAt: nil,
        retentionFailureCount: 0
    )
}

public protocol StorageHistoryRetentionApplying: Sendable {
    func applyStorageHistoryRetention(referenceDate: Date) async throws
}

public protocol StorageHistoryLifecycleEventReceiving: Sendable {
    func handle(
        _ event: StorageHistoryLifecycleEvent
    ) async -> StorageHistoryLifecycleOutcome
}

public protocol StorageHistoryBackgroundStateObserving: Sendable {
    func updates() async -> AsyncStream<StorageHistoryBackgroundState>
}

/// Serializes low-frequency capacity sampling and retention behind one owned
/// worker. The request stream is bounded; platform callbacks never perform
/// database or filesystem work themselves.
public actor StorageHistoryBackgroundCoordinator:
    StorageHistoryLifecycleEventReceiving,
    StorageHistoryBackgroundStateObserving
{
    private struct Request: Sendable {
        let event: StorageHistoryLifecycleEvent
        let continuation: CheckedContinuation<
            StorageHistoryLifecycleOutcome,
            Never
        >
    }

    private struct Observer {
        let continuation: AsyncStream<
            StorageHistoryBackgroundState
        >.Continuation
    }

    private let recorder: any StartupVolumeCapacityRecording
    private let retention: any StorageHistoryRetentionApplying
    private let requests: AsyncStream<Request>
    private let requestContinuation: AsyncStream<Request>.Continuation
    private var workerTask: Task<Void, Never>?
    private var isAcceptingEvents = false
    private var phase: StorageHistoryBackgroundPhase = .stopped
    private var processedEventCount = 0
    private var lastSampleTrigger: StorageHistorySampleTrigger?
    private var lastSampleAttemptAt: Date?
    private var lastSuccessfulSampleAt: Date?
    private var sampleFailureCount = 0
    private var consecutiveSampleFailureCount = 0
    private var lastRetentionAttemptAt: Date?
    private var lastSuccessfulRetentionAt: Date?
    private var retentionFailureCount = 0
    private var observers: [UUID: Observer] = [:]

    public init(
        recorder: any StartupVolumeCapacityRecording,
        retention: any StorageHistoryRetentionApplying
    ) {
        self.recorder = recorder
        self.retention = retention
        let pair = AsyncStream<Request>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        requests = pair.stream
        requestContinuation = pair.continuation
    }

    public var currentState: StorageHistoryBackgroundState {
        makeState()
    }

    public func start() {
        guard workerTask == nil else { return }
        isAcceptingEvents = true
        let stream = requests
        workerTask = Task { @concurrent [weak self, stream] in
            for await request in stream {
                guard let self, Task.isCancelled == false else {
                    request.continuation.resume(returning: .stopped)
                    continue
                }
                await self.process(request)
            }
        }
    }

    public func handle(
        _ event: StorageHistoryLifecycleEvent
    ) async -> StorageHistoryLifecycleOutcome {
        guard isAcceptingEvents else { return .stopped }
        return await withCheckedContinuation { continuation in
            let result = requestContinuation.yield(
                Request(event: event, continuation: continuation)
            )
            if case .dropped(let request) = result {
                request.continuation.resume(returning: .failed)
            } else if case .terminated = result {
                continuation.resume(returning: .stopped)
            }
        }
    }

    public func updates() -> AsyncStream<StorageHistoryBackgroundState> {
        let observerID = UUID()
        let pair = AsyncStream<StorageHistoryBackgroundState>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @concurrent [weak self] in
                await self?.removeObserver(observerID)
            }
        }
        observers[observerID] = Observer(continuation: pair.continuation)
        pair.continuation.yield(makeState())
        return pair.stream
    }

    public func stop() async {
        guard workerTask != nil else {
            phase = .stopped
            publishState()
            return
        }
        isAcceptingEvents = false
        requestContinuation.finish()
        let task = workerTask
        await task?.value
        workerTask = nil
        phase = .stopped
        publishState()
        observers.values.forEach { $0.continuation.finish() }
        observers.removeAll()
    }

    private func process(_ request: Request) async {
        processedEventCount += 1
        let outcome: StorageHistoryLifecycleOutcome
        switch request.event {
        case let .started(at):
            phase = .awake
            outcome = await sample(trigger: .startup, at: at)
        case let .periodic(at):
            outcome = phase == .sleeping
                ? .deferredWhileSleeping
                : await sample(trigger: .periodic, at: at)
        case .willSleep:
            phase = .sleeping
            outcome = .completed
        case let .didWake(at):
            phase = .awake
            outcome = await sample(trigger: .wake, at: at)
        case let .significantTimeChanged(at):
            outcome = phase == .sleeping
                ? .deferredWhileSleeping
                : await sample(trigger: .significantTimeChange, at: at)
        case let .maintenance(at):
            outcome = phase == .sleeping
                ? .deferredWhileSleeping
                : await applyRetention(at: at)
        }
        publishState()
        request.continuation.resume(returning: outcome)
    }

    private func sample(
        trigger: StorageHistorySampleTrigger,
        at date: Date
    ) async -> StorageHistoryLifecycleOutcome {
        lastSampleTrigger = trigger
        lastSampleAttemptAt = date
        do {
            try await recorder.record(trigger: trigger)
            lastSuccessfulSampleAt = date
            consecutiveSampleFailureCount = 0
            return .completed
        } catch {
            sampleFailureCount += 1
            consecutiveSampleFailureCount += 1
            return .failed
        }
    }

    private func applyRetention(
        at date: Date
    ) async -> StorageHistoryLifecycleOutcome {
        lastRetentionAttemptAt = date
        do {
            try await retention.applyStorageHistoryRetention(
                referenceDate: date
            )
            lastSuccessfulRetentionAt = date
            return .completed
        } catch {
            retentionFailureCount += 1
            return .failed
        }
    }

    private func makeState() -> StorageHistoryBackgroundState {
        StorageHistoryBackgroundState(
            phase: phase,
            processedEventCount: processedEventCount,
            lastSampleTrigger: lastSampleTrigger,
            lastSampleAttemptAt: lastSampleAttemptAt,
            lastSuccessfulSampleAt: lastSuccessfulSampleAt,
            sampleFailureCount: sampleFailureCount,
            consecutiveSampleFailureCount: consecutiveSampleFailureCount,
            lastRetentionAttemptAt: lastRetentionAttemptAt,
            lastSuccessfulRetentionAt: lastSuccessfulRetentionAt,
            retentionFailureCount: retentionFailureCount
        )
    }

    private func publishState() {
        let state = makeState()
        observers.values.forEach { $0.continuation.yield(state) }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}
