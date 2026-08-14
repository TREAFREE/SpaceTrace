import Foundation

public actor AuthorizedBaselineScanCoordinator {
    private enum ActiveRootResult: Sendable {
        case completed(AuthorizedBaselineCalibrationOutcome)
        case deferred(
            reason: AuthorizedBaselineScanDeferralReason,
            snapshot: ScanSchedulingSnapshot
        )
    }

    private struct Observer {
        let continuation: AsyncStream<AuthorizedBaselineScanState>.Continuation
    }

    private let contextProvider: any AuthorizedBaselineScanContextProviding
    private let calibrationRunner: any AuthorizedBaselineCalibrationRunning
    private let snapshotRepository: any AuthorizedBaselineSnapshotRepository
    private let volumeCapacityProvider: any StartupVolumeCapacitySnapshotProviding
    private let scheduler: any AuthorizedBaselineScanScheduling
    private let buildMetadata: AuthorizedBaselineBuildMetadata
    private let makeBaselineID: @Sendable () -> AuthorizedBaselineID
    private let now: @Sendable () -> Date
    private var currentState: AuthorizedBaselineScanState = .idle
    private var currentTask: Task<Void, Never>?
    private var operationID: UUID?
    private var activeContext: AuthorizedBaselineScanContext?
    private var completedRootCount = 0
    private var isRestoring = false
    private var observers: [UUID: Observer] = [:]

    public init(
        contextProvider: any AuthorizedBaselineScanContextProviding,
        calibrationRunner: any AuthorizedBaselineCalibrationRunning,
        snapshotRepository: any AuthorizedBaselineSnapshotRepository,
        volumeCapacityProvider: any StartupVolumeCapacitySnapshotProviding,
        scheduler: any AuthorizedBaselineScanScheduling = UnconstrainedAuthorizedBaselineScanScheduler(),
        buildMetadata: AuthorizedBaselineBuildMetadata,
        makeBaselineID: @escaping @Sendable () -> AuthorizedBaselineID = {
            AuthorizedBaselineID()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.contextProvider = contextProvider
        self.calibrationRunner = calibrationRunner
        self.snapshotRepository = snapshotRepository
        self.volumeCapacityProvider = volumeCapacityProvider
        self.scheduler = scheduler
        self.buildMetadata = buildMetadata
        self.makeBaselineID = makeBaselineID
        self.now = now
    }

    public func state() -> AuthorizedBaselineScanState {
        currentState
    }

    public func updates() -> AsyncStream<AuthorizedBaselineScanState> {
        let observerID = UUID()
        let pair = AsyncStream<AuthorizedBaselineScanState>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @concurrent [weak self] in
                await self?.removeObserver(observerID)
            }
        }
        observers[observerID] = Observer(continuation: pair.continuation)
        pair.continuation.yield(currentState)
        return pair.stream
    }

    @discardableResult
    public func start(scopeID: WatchedScopeID) -> Bool {
        start(request: AuthorizedBaselineScanRequest(singleScopeID: scopeID))
    }

    @discardableResult
    public func start(request: AuthorizedBaselineScanRequest) -> Bool {
        guard currentTask == nil, isRestoring == false else { return false }
        let operationID = UUID()
        let startedAt = now()
        self.operationID = operationID
        activeContext = nil
        completedRootCount = 0
        publish(
            .preparing(
                request: request,
                startedAt: startedAt
            )
        )
        currentTask = Task { @concurrent [weak self] in
            await self?.execute(
                request: request,
                operationID: operationID,
                startedAt: startedAt
            )
        }
        return true
    }

    public func cancel() async {
        guard let currentTask else { return }
        currentTask.cancel()
        await currentTask.value
    }

    public func waitForCurrentScan() async {
        await currentTask?.value
    }

    /// Restores only a previously committed baseline. Interrupted scan staging
    /// is recovered by the persistence adapter and is never presented as a
    /// resumable or complete result.
    public func restoreLatest(scopeID: WatchedScopeID) async {
        guard currentTask == nil, isRestoring == false else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            let snapshot = try await snapshotRepository.latestAuthorizedBaseline(
                for: scopeID
            )
            try Task.checkCancellation()
            guard let snapshot else {
                publish(.idle)
                return
            }
            publish(
                .completed(
                    try AuthorizedBaselineScanResult(
                        snapshot: snapshot,
                        scopeID: scopeID,
                        origin: .restoredAfterRestart
                    )
                )
            )
        } catch is CancellationError {
            return
        } catch {
            publish(
                .failed(
                    AuthorizedBaselineScanFailure(
                        scopeID: scopeID,
                        code: .baselinePersistenceFailed,
                        failedAt: now()
                    )
                )
            )
        }
    }

    private func execute(
        request: AuthorizedBaselineScanRequest,
        operationID: UUID,
        startedAt: Date
    ) async {
        defer { finish(operationID: operationID) }
        var currentScopeID = request.scopeIDs[0]
        do {
            var roots: [AuthorizedBaselineRootSnapshot] = []
            roots.reserveCapacity(request.scopeIDs.count)

            for scopeID in request.scopeIDs {
                currentScopeID = scopeID
                // Do not attribute an authorization/monitoring lookup or its
                // cancellation to the previously completed root.
                activeContext = nil
                let context = try await contextProvider.context(for: scopeID)
                try Task.checkCancellation()
                guard self.operationID == operationID else { return }
                activeContext = context

                let completedBeforeRoot = roots.count
                let outcome = try await runRootWhenEligible(
                    context: context,
                    request: request,
                    operationID: operationID,
                    startedAt: startedAt,
                    completedRootCount: completedBeforeRoot
                )
                try Task.checkCancellation()
                guard self.operationID == operationID else { return }

                switch outcome {
                case let .published(aggregate, report):
                    guard let logicalBytes = aggregate.logicalBytes,
                          let allocatedBytes = aggregate.allocatedBytes else {
                        publishFailure(
                            scopeID: scopeID,
                            code: .publishedRootMissing,
                            operationID: operationID
                        )
                        return
                    }
                    roots.append(
                        try AuthorizedBaselineRootSnapshot(
                            context: context,
                            logicalBytes: logicalBytes,
                            allocatedBytes: allocatedBytes,
                            descendantCount: aggregate.descendantCount,
                            entriesVisited: report.entriesVisited,
                            directoriesObserved: report.directoriesStaged
                        )
                    )
                    completedRootCount = roots.count
                case let .incomplete(report, reason):
                    publish(
                        .incomplete(
                            AuthorizedBaselineIncompleteResult(
                                context: context,
                                reason: reason,
                                report: report,
                                startedAt: startedAt,
                                completedAt: now(),
                                completedRootCount: roots.count,
                                totalRootCount: request.scopeIDs.count,
                                unreadableRootCount: reason == .partialCoverage ? 1 : 0
                            )
                        )
                    )
                    return
                }
            }

            try await waitUntilEligible(
                request: request,
                context: activeContext,
                operationID: operationID,
                startedAt: startedAt,
                completedRootCount: roots.count
            )
            let volumeSnapshot = await volumeCapacityProvider.snapshot()
            try Task.checkCancellation()
            let completedAt = now()
            let snapshot = try AuthorizedBaselineSnapshot(
                id: makeBaselineID(),
                startedAt: startedAt,
                committedAt: completedAt,
                build: buildMetadata,
                startupVolume: volumeSnapshot,
                roots: roots
            )
            do {
                try await snapshotRepository.saveAuthorizedBaseline(snapshot)
            } catch {
                publishFailure(
                    scopeID: currentScopeID,
                    code: .baselinePersistenceFailed,
                    operationID: operationID
                )
                return
            }
            publish(
                .completed(
                    try AuthorizedBaselineScanResult(
                        snapshot: snapshot,
                        scopeID: request.scopeIDs[0],
                        origin: .completedScan
                    )
                )
            )
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            publish(
                .cancelled(
                    AuthorizedBaselineScanCancellation(
                        scopeID: request.scopeIDs[0],
                        requestedScopeIDs: request.scopeIDs,
                        context: activeContext,
                        startedAt: startedAt,
                        cancelledAt: now(),
                        completedRootCount: completedRootCount
                    )
                )
            )
        } catch let error as AuthorizedBaselineScanContextError {
            let code: AuthorizedBaselineScanFailureCode = switch error {
            case .scopeNotAuthorized: .scopeNotAuthorized
            case .monitoringNotReady: .monitoringNotReady
            }
            publishFailure(scopeID: currentScopeID, code: code, operationID: operationID)
        } catch let error as AuthorizedBaselineCalibrationRunnerError {
            let code: AuthorizedBaselineScanFailureCode = switch error {
            case .publishedRootMissing: .publishedRootMissing
            case .missingAttempt: .operationFailed
            }
            publishFailure(scopeID: currentScopeID, code: code, operationID: operationID)
        } catch {
            publishFailure(
                scopeID: currentScopeID,
                code: .operationFailed,
                operationID: operationID
            )
        }
    }

    private func runRootWhenEligible(
        context: AuthorizedBaselineScanContext,
        request: AuthorizedBaselineScanRequest,
        operationID: UUID,
        startedAt: Date,
        completedRootCount: Int
    ) async throws -> AuthorizedBaselineCalibrationOutcome {
        var clearedReason: AuthorizedBaselineScanDeferralReason?
        var lastDeferralDecision: AuthorizedBaselineScanSchedulingDecision?

        while true {
            try Task.checkCancellation()
            guard self.operationID == operationID else { throw CancellationError() }

            let decisions = await scheduler.decisions()
            var iterator = decisions.makeAsyncIterator()
            guard var decision = await iterator.next() else {
                throw CancellationError()
            }

            while case let .deferred(reason, snapshot) = decision {
                if lastDeferralDecision != decision {
                    publishDeferral(
                        request: request,
                        context: context,
                        reason: reason,
                        snapshot: snapshot,
                        operationID: operationID,
                        startedAt: startedAt,
                        completedRootCount: completedRootCount
                    )
                    lastDeferralDecision = decision
                }
                clearedReason = reason
                try Task.checkCancellation()
                guard let nextDecision = await iterator.next() else {
                    throw CancellationError()
                }
                decision = nextDecision
            }

            guard case let .runnable(snapshot) = decision else {
                continue
            }
            if let clearedReason {
                publishResume(
                    request: request,
                    context: context,
                    clearedReason: clearedReason,
                    snapshot: snapshot,
                    operationID: operationID,
                    startedAt: startedAt,
                    completedRootCount: completedRootCount
                )
            }
            lastDeferralDecision = nil

            let result = try await raceRootAgainstDeferral(
                context: context,
                operationID: operationID,
                startedAt: startedAt,
                completedRootCount: completedRootCount,
                totalRootCount: request.scopeIDs.count
            )
            switch result {
            case let .completed(outcome):
                return outcome
            case let .deferred(reason, snapshot):
                let decision = AuthorizedBaselineScanSchedulingDecision.deferred(
                    reason: reason,
                    snapshot: snapshot
                )
                publishDeferral(
                    request: request,
                    context: context,
                    reason: reason,
                    snapshot: snapshot,
                    operationID: operationID,
                    startedAt: startedAt,
                    completedRootCount: completedRootCount
                )
                lastDeferralDecision = decision
                clearedReason = reason
            }
        }
    }

    private func raceRootAgainstDeferral(
        context: AuthorizedBaselineScanContext,
        operationID: UUID,
        startedAt: Date,
        completedRootCount: Int,
        totalRootCount: Int
    ) async throws -> ActiveRootResult {
        try await withThrowingTaskGroup(of: ActiveRootResult.self) { group in
            group.addTask { [calibrationRunner] in
                .completed(
                    try await calibrationRunner.run(context: context) { [weak self] update in
                        await self?.receive(
                            update,
                            operationID: operationID,
                            startedAt: startedAt,
                            completedRootCount: completedRootCount,
                            totalRootCount: totalRootCount
                        )
                    }
                )
            }
            group.addTask { [scheduler] in
                let decisions = await scheduler.decisions()
                for await decision in decisions {
                    try Task.checkCancellation()
                    if case let .deferred(reason, snapshot) = decision {
                        return .deferred(reason: reason, snapshot: snapshot)
                    }
                }
                while true {
                    try await Task.sleep(for: .seconds(3_600))
                }
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func waitUntilEligible(
        request: AuthorizedBaselineScanRequest,
        context: AuthorizedBaselineScanContext?,
        operationID: UUID,
        startedAt: Date,
        completedRootCount: Int
    ) async throws {
        let decisions = await scheduler.decisions()
        var clearedReason: AuthorizedBaselineScanDeferralReason?
        for await decision in decisions {
            try Task.checkCancellation()
            guard self.operationID == operationID else { throw CancellationError() }
            switch decision {
            case let .deferred(reason, snapshot):
                clearedReason = reason
                publishDeferral(
                    request: request,
                    context: context,
                    reason: reason,
                    snapshot: snapshot,
                    operationID: operationID,
                    startedAt: startedAt,
                    completedRootCount: completedRootCount
                )
            case let .runnable(snapshot):
                if let clearedReason {
                    publishResume(
                        request: request,
                        context: context,
                        clearedReason: clearedReason,
                        snapshot: snapshot,
                        operationID: operationID,
                        startedAt: startedAt,
                        completedRootCount: completedRootCount
                    )
                }
                return
            }
        }
        throw CancellationError()
    }

    private func publishDeferral(
        request: AuthorizedBaselineScanRequest,
        context: AuthorizedBaselineScanContext?,
        reason: AuthorizedBaselineScanDeferralReason,
        snapshot: ScanSchedulingSnapshot,
        operationID: UUID,
        startedAt: Date,
        completedRootCount: Int
    ) {
        guard self.operationID == operationID, Task.isCancelled == false else { return }
        publish(
            .deferred(
                AuthorizedBaselineScanDeferral(
                    request: request,
                    context: context,
                    reason: reason,
                    snapshot: snapshot,
                    startedAt: startedAt,
                    deferredAt: now(),
                    completedRootCount: completedRootCount
                )
            )
        )
    }

    private func publishResume(
        request: AuthorizedBaselineScanRequest,
        context: AuthorizedBaselineScanContext?,
        clearedReason: AuthorizedBaselineScanDeferralReason,
        snapshot: ScanSchedulingSnapshot,
        operationID: UUID,
        startedAt: Date,
        completedRootCount: Int
    ) {
        guard self.operationID == operationID, Task.isCancelled == false else { return }
        publish(
            .resuming(
                AuthorizedBaselineScanResume(
                    request: request,
                    context: context,
                    clearedReason: clearedReason,
                    snapshot: snapshot,
                    startedAt: startedAt,
                    resumedAt: now(),
                    completedRootCount: completedRootCount
                )
            )
        )
    }

    private func receive(
        _ update: AuthorizedBaselineCalibrationProgress,
        operationID: UUID,
        startedAt: Date,
        completedRootCount: Int,
        totalRootCount: Int
    ) {
        guard self.operationID == operationID, Task.isCancelled == false else { return }
        switch update {
        case let .scanning(context):
            publish(
                .scanning(
                    AuthorizedBaselineScanProgress(
                        context: context,
                        startedAt: startedAt,
                        completedRootCount: completedRootCount,
                        totalRootCount: totalRootCount
                    )
                )
            )
        case let .publishing(context, report):
            publish(
                .publishing(
                    AuthorizedBaselineScanProgress(
                        context: context,
                        startedAt: startedAt,
                        completedRootCount: completedRootCount,
                        totalRootCount: totalRootCount,
                        entriesVisited: report.entriesVisited,
                        directoriesObserved: report.directoriesStaged
                    )
                )
            )
        }
    }

    private func publishFailure(
        scopeID: WatchedScopeID,
        code: AuthorizedBaselineScanFailureCode,
        operationID: UUID
    ) {
        guard self.operationID == operationID else { return }
        publish(
            .failed(
                AuthorizedBaselineScanFailure(
                    scopeID: scopeID,
                    code: code,
                    failedAt: now()
                )
            )
        )
    }

    private func finish(operationID: UUID) {
        guard self.operationID == operationID else { return }
        currentTask = nil
        self.operationID = nil
        activeContext = nil
        completedRootCount = 0
    }

    private func publish(_ state: AuthorizedBaselineScanState) {
        currentState = state
        observers.values.forEach { $0.continuation.yield(state) }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}
