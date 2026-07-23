import Foundation
import SpaceTraceApplication

public struct FSEventStreamRecoveryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int
    public let initialBackoffMilliseconds: Int
    public let maximumBackoffMilliseconds: Int
    public let stabilityThresholdMilliseconds: Int

    public init(
        maximumAttempts: Int = 5,
        initialBackoffMilliseconds: Int = 100,
        maximumBackoffMilliseconds: Int = 2_000,
        stabilityThresholdMilliseconds: Int = 30_000
    ) throws(FSEventStreamRecoveryPolicyError) {
        guard maximumAttempts > 0 else {
            throw .maximumAttemptsMustBePositive
        }
        guard initialBackoffMilliseconds >= 0 else {
            throw .initialBackoffMustBeNonnegative
        }
        guard maximumBackoffMilliseconds >= initialBackoffMilliseconds else {
            throw .maximumBackoffMustCoverInitialBackoff
        }
        guard stabilityThresholdMilliseconds >= 0 else {
            throw .stabilityThresholdMustBeNonnegative
        }
        self.maximumAttempts = maximumAttempts
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.stabilityThresholdMilliseconds = stabilityThresholdMilliseconds
    }

    public static var standard: Self {
        Self(
            validatedMaximumAttempts: 5,
            initialBackoffMilliseconds: 100,
            maximumBackoffMilliseconds: 2_000,
            stabilityThresholdMilliseconds: 30_000
        )
    }

    fileprivate func backoff(forAttempt attempt: Int) -> Duration {
        guard attempt > 1, initialBackoffMilliseconds > 0 else { return .zero }
        let exponent = min(attempt - 2, 30)
        let multiplier = 1 << exponent
        let (candidate, overflow) = initialBackoffMilliseconds
            .multipliedReportingOverflow(by: multiplier)
        let milliseconds = overflow
            ? maximumBackoffMilliseconds
            : min(candidate, maximumBackoffMilliseconds)
        return .milliseconds(milliseconds)
    }

    private init(
        validatedMaximumAttempts: Int,
        initialBackoffMilliseconds: Int,
        maximumBackoffMilliseconds: Int,
        stabilityThresholdMilliseconds: Int
    ) {
        self.maximumAttempts = validatedMaximumAttempts
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.stabilityThresholdMilliseconds = stabilityThresholdMilliseconds
    }
}

public enum FSEventStreamRecoveryPolicyError: Error, Sendable, Equatable {
    case maximumAttemptsMustBePositive
    case initialBackoffMustBeNonnegative
    case maximumBackoffMustCoverInitialBackoff
    case stabilityThresholdMustBeNonnegative
}

public typealias ActiveScopeFSEventStatus = ScopeEventStreamActiveState
public typealias ScopeFSEventRecoveryStatus = ScopeEventStreamRecoveryState

/// Native implementation of the application-owned stream lifecycle port.
/// One scope owns one client and one consumer task; replacement is conditional
/// on the mount generation selected transactionally by the repository.
public actor NativeScopeFSEventSupervisor: ScopeEventStreamSupervisor {
    private struct ActiveStream {
        let status: ActiveScopeFSEventStatus
        let scope: WatchedScope
        let expectedVolumeUUID: UUID?
        let revision: UInt64
        let recoveryAttempt: Int
        let startedAt: ContinuousClock.Instant
        let client: any FSEventStreamControlling
        let task: Task<Void, Never>
    }

    private struct RecoveryContext: Sendable {
        let scope: WatchedScope
        let generationID: MountGenerationID
        let expectedVolumeUUID: UUID?
        let previousStatus: ActiveScopeFSEventStatus
        let revision: UInt64
    }

    private struct RecoveryTask {
        let generationID: MountGenerationID
        let revision: UInt64
        var attempt: Int
        var lastFailure: String
        let task: Task<Void, Never>
    }

    private struct LifecycleObserver {
        let scopeID: WatchedScopeID
        let continuation: AsyncStream<ScopeEventStreamLifecycleState>.Continuation
    }

    private struct ConsumptionOutcome: Sendable {
        let failure: String?
        let processedObservation: Bool
    }

    private struct OpenedStream {
        let client: any FSEventStreamControlling
        let observations: FSEventStreamClient.ObservationStream
    }

    private let repository: any EventJournalRepository
    private let scanner: any CalibrationScanner
    private let resolver: any FSEventDeviceScopeResolving
    private let makeStreamClient: @Sendable () -> any FSEventStreamControlling
    private let mapper: FSEventInvalidationMapper
    private let recoveryPolicy: FSEventStreamRecoveryPolicy
    private let latency: TimeInterval
    private let bufferCapacity: Int
    private let excludeEventsFromThisProcess: Bool
    private var streams: [WatchedScopeID: ActiveStream] = [:]
    private var recoveries: [WatchedScopeID: RecoveryTask] = [:]
    private var revisions: [WatchedScopeID: UInt64] = [:]
    private var failures: [WatchedScopeID: String] = [:]
    private var finalFailures: [WatchedScopeID: ScopeEventStreamFailureState] = [:]
    private var lifecycleObservers: [UUID: LifecycleObserver] = [:]

    public init(
        repository: any EventJournalRepository,
        scanner: any CalibrationScanner,
        resolver: any FSEventDeviceScopeResolving = FSEventDeviceScopeResolver(),
        makeStreamClient: @escaping @Sendable () -> any FSEventStreamControlling = {
            FSEventStreamClient()
        },
        mapper: FSEventInvalidationMapper = FSEventInvalidationMapper(),
        recoveryPolicy: FSEventStreamRecoveryPolicy = .standard,
        latency: TimeInterval = 1,
        bufferCapacity: Int = 512,
        excludeEventsFromThisProcess: Bool = true
    ) {
        self.repository = repository
        self.scanner = scanner
        self.resolver = resolver
        self.makeStreamClient = makeStreamClient
        self.mapper = mapper
        self.recoveryPolicy = recoveryPolicy
        self.latency = latency
        self.bufferCapacity = bufferCapacity
        self.excludeEventsFromThisProcess = excludeEventsFromThisProcess
    }

    public func restart(
        scope: WatchedScope,
        activation: ScopeMountActivation
    ) async throws {
        guard activation.current.scopeID == scope.id,
              activation.current.isActive,
              activation.current.mountPath == scope.mountPath else {
            throw NativeScopeFSEventSupervisorError.invalidActivation
        }

        let revision = nextRevision(for: scope.id)
        await stopCurrent(scopeID: scope.id)

        let resolved = try resolver.resolve(
            watchedURLs: [URL(fileURLWithPath: scope.root.rawValue, isDirectory: true)]
        )
        try validate(
            resolved: resolved,
            expectedMountPath: activation.current.mountPath,
            expectedVolumeUUID: activation.current.volumeUUID
        )

        let identity = resolved.persistentIdentity
        let streamID = try identity?.streamID ?? EventStreamID(
            "fsevents-live/v1/\(scope.id.rawValue)/\(activation.current.generationID.rawValue)"
        )
        let checkpoint = identity == nil
            ? nil
            : try await repository.checkpoint(for: streamID)
        let replayPosition = checkpoint.map {
            FSEventReplayPosition.after(FSEventID(rawValue: $0.rawValue))
        } ?? .sinceNow

        try ensureCurrent(revision, for: scope.id)
        let opened = try await openStream(
            scope: scope,
            resolved: resolved,
            streamID: streamID,
            replayPosition: replayPosition,
            hasStoredCheckpoint: checkpoint != nil,
            revision: revision
        )
        let pipeline = FileSystemCalibrationPipeline(
            streamID: streamID,
            watchRoot: scope.root,
            repository: repository,
            scanner: scanner
        )

        do {
            let restoredAgedRequirement =
                try await repository.restorePathFreeCalibrationRequirement(
                    for: streamID,
                    scopeID: scope.id,
                    at: scope.root
                )
            if activation.requiresCalibration || restoredAgedRequirement {
                let invalidation = try FileSystemInvalidation(
                    path: scope.root.rawValue,
                    cursor: nil,
                    reasons: [
                        .mountChanged,
                        .mustScanSubdirectories,
                        .requiresCalibration,
                    ],
                    itemKind: .directory
                )
                try await pipeline.ingest([invalidation])
            }
            try ensureCurrent(revision, for: scope.id)
        } catch {
            opened.client.stop()
            throw error
        }

        install(
            opened: opened,
            scope: scope,
            expectedVolumeUUID: activation.current.volumeUUID,
            resolved: resolved,
            streamID: streamID,
            generationID: activation.current.generationID,
            revision: revision,
            recoveryAttempt: 0,
            pipeline: pipeline
        )
        failures.removeValue(forKey: scope.id)
    }

    public func stop(
        scopeID: WatchedScopeID,
        matching generationID: MountGenerationID
    ) async {
        let activeMatches = streams[scopeID]?.status.generationID == generationID
        let recoveryMatches = recoveries[scopeID]?.generationID == generationID
        let failureMatches = finalFailures[scopeID]?.generationID == generationID
        guard activeMatches || recoveryMatches || failureMatches else { return }
        _ = nextRevision(for: scopeID)
        await stopCurrent(scopeID: scopeID)
    }

    public func stopAll() async {
        let scopeIDs = Set(streams.keys)
            .union(recoveries.keys)
            .union(finalFailures.keys)
        for scopeID in scopeIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            _ = nextRevision(for: scopeID)
            await stopCurrent(scopeID: scopeID)
        }
    }

    public func activeStatus(
        for scopeID: WatchedScopeID
    ) -> ActiveScopeFSEventStatus? {
        streams[scopeID]?.status
    }

    public func lastFailure(for scopeID: WatchedScopeID) -> String? {
        failures[scopeID]
    }

    public func recoveryStatus(
        for scopeID: WatchedScopeID
    ) -> ScopeFSEventRecoveryStatus? {
        guard let recovery = recoveries[scopeID] else { return nil }
        return ScopeFSEventRecoveryStatus(
            scopeID: scopeID,
            generationID: recovery.generationID,
            attempt: recovery.attempt,
            maximumAttempts: recoveryPolicy.maximumAttempts,
            lastFailure: recovery.lastFailure
        )
    }

    public func lifecycleState(
        for scopeID: WatchedScopeID
    ) -> ScopeEventStreamLifecycleState {
        if let active = streams[scopeID] {
            return .active(active.status)
        }
        if let recovery = recoveryStatus(for: scopeID) {
            return .recovering(recovery)
        }
        if let failure = finalFailures[scopeID] {
            return .failed(failure)
        }
        return .inactive(scopeID: scopeID)
    }

    public func lifecycleUpdates(
        for scopeID: WatchedScopeID,
        bufferCapacity: Int = 16
    ) throws(ScopeEventStreamLifecycleObservationError) -> AsyncStream<ScopeEventStreamLifecycleState> {
        guard bufferCapacity > 0 else {
            throw .invalidBufferCapacity
        }

        let observerID = UUID()
        let pair = AsyncStream<ScopeEventStreamLifecycleState>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferCapacity)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @concurrent [weak self] in
                await self?.removeLifecycleObserver(observerID)
            }
        }
        lifecycleObservers[observerID] = LifecycleObserver(
            scopeID: scopeID,
            continuation: pair.continuation
        )
        pair.continuation.yield(lifecycleState(for: scopeID))
        return pair.stream
    }

    /// Test seam for observing one already-scheduled recovery cycle without
    /// polling or adding production timing sleeps.
    func waitForRecoveryCompletion(for scopeID: WatchedScopeID) async {
        guard let recovery = recoveries[scopeID] else { return }
        await recovery.task.value
    }

    private func nextRevision(for scopeID: WatchedScopeID) -> UInt64 {
        let next = (revisions[scopeID] ?? 0) &+ 1
        revisions[scopeID] = next
        return next
    }

    private func ensureCurrent(
        _ revision: UInt64,
        for scopeID: WatchedScopeID
    ) throws {
        guard revisions[scopeID] == revision else {
            throw NativeScopeFSEventSupervisorError.operationSuperseded
        }
    }

    /// A stored cursor is useful only while the native daemon accepts the
    /// corresponding replay request. If that request cannot be created or
    /// started, conservatively invalidate its history in the same transaction
    /// as scope-level recovery work, then attempt one live stream. Further
    /// live-start failures are left to the runtime's bounded readiness retry.
    private func openStream(
        scope: WatchedScope,
        resolved: ResolvedFSEventDeviceScope,
        streamID: EventStreamID,
        replayPosition: FSEventReplayPosition,
        hasStoredCheckpoint: Bool,
        revision: UInt64
    ) async throws -> OpenedStream {
        do {
            return try startClient(
                configuration: configuration(
                    scope: scope,
                    resolved: resolved,
                    replayPosition: replayPosition
                )
            )
        } catch where hasStoredCheckpoint && Self.isRecoverableStartFailure(error) {
            let recoveryRegion = try DirtyRegion(
                path: scope.root,
                reasons: [
                    .mustScanSubdirectories,
                    .droppedEvents,
                    .requiresCalibration,
                ],
                maximumCursor: nil
            )
            try await repository.invalidateCheckpointAndMarkDirty(
                streamID: streamID,
                regions: [recoveryRegion]
            )
            try ensureCurrent(revision, for: scope.id)
            return try startClient(
                configuration: configuration(
                    scope: scope,
                    resolved: resolved,
                    replayPosition: .sinceNow
                )
            )
        }
    }

    private func configuration(
        scope: WatchedScope,
        resolved: ResolvedFSEventDeviceScope,
        replayPosition: FSEventReplayPosition
    ) throws -> FSEventStreamConfiguration {
        if resolved.persistentIdentity != nil {
            return try resolved.configuration(
                replayPosition: replayPosition,
                latency: latency,
                bufferCapacity: bufferCapacity,
                excludeEventsFromThisProcess: excludeEventsFromThisProcess
            )
        }
        return FSEventStreamConfiguration(
            watchedPaths: [scope.root.rawValue],
            replayPosition: .sinceNow,
            latency: latency,
            bufferCapacity: bufferCapacity,
            excludeEventsFromThisProcess: excludeEventsFromThisProcess
        )
    }

    private func startClient(
        configuration: FSEventStreamConfiguration
    ) throws -> OpenedStream {
        let client = makeStreamClient()
        do {
            return OpenedStream(
                client: client,
                observations: try client.start(configuration: configuration)
            )
        } catch {
            client.stop()
            throw error
        }
    }

    private func install(
        opened: OpenedStream,
        scope: WatchedScope,
        expectedVolumeUUID: UUID?,
        resolved: ResolvedFSEventDeviceScope,
        streamID: EventStreamID,
        generationID: MountGenerationID,
        revision: UInt64,
        recoveryAttempt: Int,
        pipeline: FileSystemCalibrationPipeline
    ) {
        let mapping = mapper
        let task = Task { @concurrent [weak self] in
            let outcome = await Self.consume(
                opened.observations,
                mapper: mapping,
                pipeline: pipeline
            )
            await self?.streamTerminated(
                scopeID: scope.id,
                generationID: generationID,
                revision: revision,
                outcome: outcome
            )
        }
        let status = ActiveScopeFSEventStatus(
            scopeID: scope.id,
            generationID: generationID,
            streamID: streamID,
            persistentIdentity: resolved.persistentIdentity
        )
        streams[scope.id] = ActiveStream(
            status: status,
            scope: scope,
            expectedVolumeUUID: expectedVolumeUUID,
            revision: revision,
            recoveryAttempt: recoveryAttempt,
            startedAt: ContinuousClock().now,
            client: opened.client,
            task: task
        )
        publishLifecycleState(for: scope.id)
    }

    private func stopCurrent(scopeID: WatchedScopeID) async {
        let active = streams.removeValue(forKey: scopeID)
        let recovery = recoveries.removeValue(forKey: scopeID)
        let failure = finalFailures.removeValue(forKey: scopeID)

        active?.client.stop()
        active?.task.cancel()
        recovery?.task.cancel()

        if let active {
            await active.task.value
        }
        if let recovery {
            await recovery.task.value
        }
        failures.removeValue(forKey: scopeID)
        if active != nil || recovery != nil || failure != nil {
            publishLifecycleState(for: scopeID)
        }
    }

    private func streamTerminated(
        scopeID: WatchedScopeID,
        generationID: MountGenerationID,
        revision: UInt64,
        outcome: ConsumptionOutcome
    ) {
        guard let active = streams[scopeID],
              active.status.generationID == generationID,
              active.revision == revision else { return }
        streams.removeValue(forKey: scopeID)
        active.client.stop()

        let failure = outcome.failure ?? "FSEvents stream ended unexpectedly."
        failures[scopeID] = failure
        let elapsed = active.startedAt.duration(to: ContinuousClock().now)
        let wasStable = outcome.processedObservation
            || elapsed >= .milliseconds(recoveryPolicy.stabilityThresholdMilliseconds)
        let startingAttempt = wasStable ? 1 : active.recoveryAttempt + 1
        let context = RecoveryContext(
            scope: active.scope,
            generationID: generationID,
            expectedVolumeUUID: active.expectedVolumeUUID,
            previousStatus: active.status,
            revision: revision
        )
        let task = Task { @concurrent [weak self] in
            guard let self else { return }
            await self.recover(
                context: context,
                startingAttempt: startingAttempt,
                initialFailure: failure
            )
        }
        recoveries[scopeID] = RecoveryTask(
            generationID: generationID,
            revision: revision,
            attempt: min(startingAttempt, recoveryPolicy.maximumAttempts),
            lastFailure: failure,
            task: task
        )
        publishLifecycleState(for: scopeID)
    }

    private func recover(
        context: RecoveryContext,
        startingAttempt: Int,
        initialFailure: String
    ) async {
        var attempt = startingAttempt
        var lastFailure = initialFailure
        var recoveryWorkPersisted = false
        var preparedStreamIDs: Set<EventStreamID> = []

        if attempt > recoveryPolicy.maximumAttempts {
            do {
                try await persistRecoveryWork(for: context.previousStatus, scope: context.scope)
                try ensureRecoveryCurrent(context)
            } catch is CancellationError {
                return
            } catch NativeScopeFSEventSupervisorError.operationSuperseded {
                return
            } catch {
                lastFailure = String(reflecting: error)
            }
            finishExhaustedRecovery(context: context, lastFailure: lastFailure)
            return
        }

        while attempt <= recoveryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                try ensureRecoveryCurrent(context)
                updateRecovery(
                    context: context,
                    attempt: attempt,
                    lastFailure: lastFailure
                )

                if recoveryWorkPersisted == false {
                    try await persistRecoveryWork(
                        for: context.previousStatus,
                        scope: context.scope
                    )
                    try ensureRecoveryCurrent(context)
                    recoveryWorkPersisted = true
                }

                let delay = recoveryPolicy.backoff(forAttempt: attempt)
                if delay > .zero {
                    try await Task.sleep(for: delay)
                    try ensureRecoveryCurrent(context)
                }

                let resolved = try resolver.resolve(
                    watchedURLs: [
                        URL(
                            fileURLWithPath: context.scope.root.rawValue,
                            isDirectory: true
                        )
                    ]
                )
                try validate(
                    resolved: resolved,
                    expectedMountPath: context.scope.mountPath,
                    expectedVolumeUUID: context.expectedVolumeUUID
                )
                let streamID = try resolved.persistentIdentity?.streamID ?? EventStreamID(
                    "fsevents-live/v1/\(context.scope.id.rawValue)/\(context.generationID.rawValue)"
                )
                if streamID != context.previousStatus.streamID,
                   preparedStreamIDs.insert(streamID).inserted {
                    try await persistRecoveryWork(
                        streamID: streamID,
                        hasPersistentIdentity: resolved.persistentIdentity != nil,
                        scope: context.scope
                    )
                    try ensureRecoveryCurrent(context)
                }

                let pipeline = FileSystemCalibrationPipeline(
                    streamID: streamID,
                    watchRoot: context.scope.root,
                    repository: repository,
                    scanner: scanner
                )
                let opened = try startClient(
                    configuration: configuration(
                        scope: context.scope,
                        resolved: resolved,
                        replayPosition: .sinceNow
                    )
                )
                try ensureRecoveryCurrent(context)
                recoveries.removeValue(forKey: context.scope.id)
                install(
                    opened: opened,
                    scope: context.scope,
                    expectedVolumeUUID: context.expectedVolumeUUID,
                    resolved: resolved,
                    streamID: streamID,
                    generationID: context.generationID,
                    revision: context.revision,
                    recoveryAttempt: attempt,
                    pipeline: pipeline
                )
                failures.removeValue(forKey: context.scope.id)
                finalFailures.removeValue(forKey: context.scope.id)
                return
            } catch is CancellationError {
                return
            } catch NativeScopeFSEventSupervisorError.operationSuperseded {
                return
            } catch {
                lastFailure = String(reflecting: error)
                attempt += 1
            }
        }

        finishExhaustedRecovery(context: context, lastFailure: lastFailure)
    }

    private func persistRecoveryWork(
        for status: ActiveScopeFSEventStatus,
        scope: WatchedScope
    ) async throws {
        try await persistRecoveryWork(
            streamID: status.streamID,
            hasPersistentIdentity: status.persistentIdentity != nil,
            scope: scope
        )
    }

    private func persistRecoveryWork(
        streamID: EventStreamID,
        hasPersistentIdentity: Bool,
        scope: WatchedScope
    ) async throws {
        let region = try DirtyRegion(
            path: scope.root,
            reasons: [
                .mustScanSubdirectories,
                .droppedEvents,
                .requiresCalibration,
            ],
            maximumCursor: nil
        )
        if hasPersistentIdentity {
            try await repository.invalidateCheckpointAndMarkDirty(
                streamID: streamID,
                regions: [region]
            )
        } else {
            try await repository.markDirty(streamID: streamID, regions: [region])
        }
    }

    private func ensureRecoveryCurrent(_ context: RecoveryContext) throws {
        try ensureCurrent(context.revision, for: context.scope.id)
        guard let recovery = recoveries[context.scope.id],
              recovery.generationID == context.generationID,
              recovery.revision == context.revision else {
            throw NativeScopeFSEventSupervisorError.operationSuperseded
        }
    }

    private func updateRecovery(
        context: RecoveryContext,
        attempt: Int,
        lastFailure: String
    ) {
        guard var recovery = recoveries[context.scope.id],
              recovery.generationID == context.generationID,
              recovery.revision == context.revision else { return }
        recovery.attempt = attempt
        recovery.lastFailure = lastFailure
        recoveries[context.scope.id] = recovery
        publishLifecycleState(for: context.scope.id)
    }

    private func finishExhaustedRecovery(
        context: RecoveryContext,
        lastFailure: String
    ) {
        guard recoveries[context.scope.id]?.revision == context.revision else { return }
        recoveries.removeValue(forKey: context.scope.id)
        let message = "FSEvents automatic recovery exhausted after "
            + "\(recoveryPolicy.maximumAttempts) attempts. Last failure: \(lastFailure)"
        failures[context.scope.id] = message
        finalFailures[context.scope.id] = ScopeEventStreamFailureState(
            scopeID: context.scope.id,
            generationID: context.generationID,
            attempts: recoveryPolicy.maximumAttempts,
            message: message
        )
        publishLifecycleState(for: context.scope.id)
    }

    private func publishLifecycleState(for scopeID: WatchedScopeID) {
        let state = lifecycleState(for: scopeID)
        for observer in lifecycleObservers.values where observer.scopeID == scopeID {
            observer.continuation.yield(state)
        }
    }

    private func removeLifecycleObserver(_ observerID: UUID) {
        lifecycleObservers.removeValue(forKey: observerID)
    }

    private nonisolated static func consume(
        _ observations: FSEventStreamClient.ObservationStream,
        mapper: FSEventInvalidationMapper,
        pipeline: FileSystemCalibrationPipeline
    ) async -> ConsumptionOutcome {
        var processedObservation = false
        do {
            for try await observation in observations {
                try Task.checkCancellation()
                if let invalidation = try mapper.map(observation) {
                    try await pipeline.ingest([invalidation])
                }
                processedObservation = true
            }
            return ConsumptionOutcome(
                failure: Task.isCancelled ? nil : "FSEvents stream ended unexpectedly.",
                processedObservation: processedObservation
            )
        } catch is CancellationError {
            return ConsumptionOutcome(
                failure: nil,
                processedObservation: processedObservation
            )
        } catch {
            return ConsumptionOutcome(
                failure: String(reflecting: error),
                processedObservation: processedObservation
            )
        }
    }

    private func validate(
        resolved: ResolvedFSEventDeviceScope,
        expectedMountPath: DirtyRegionPath,
        expectedVolumeUUID: UUID?
    ) throws {
        let resolvedMountPath = Self.applicationPath(resolved.deviceTarget.mountPath)
        guard resolvedMountPath == expectedMountPath.rawValue else {
            throw NativeScopeFSEventSupervisorError.resolvedMountPathChanged(
                expected: expectedMountPath.rawValue,
                actual: resolvedMountPath
            )
        }
        if let expectedVolumeUUID {
            guard resolved.volumeUUID == expectedVolumeUUID else {
                throw NativeScopeFSEventSupervisorError.resolvedVolumeChanged
            }
        }
    }

    private nonisolated static func applicationPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private nonisolated static func isRecoverableStartFailure(
        _ error: any Error
    ) -> Bool {
        guard let error = error as? FSEventStreamError else { return false }
        switch error {
        case .creationFailed, .startFailed:
            return true
        default:
            return false
        }
    }
}

public enum NativeScopeFSEventSupervisorError: Error, Sendable, Equatable {
    case invalidActivation
    case resolvedMountPathChanged(expected: String, actual: String)
    case resolvedVolumeChanged
    case operationSuperseded
}
