import Foundation

public actor AuthorizedBaselineScanCoordinator {
    private struct Observer {
        let continuation: AsyncStream<AuthorizedBaselineScanState>.Continuation
    }

    private let contextProvider: any AuthorizedBaselineScanContextProviding
    private let calibrationRunner: any AuthorizedBaselineCalibrationRunning
    private let snapshotRepository: any AuthorizedBaselineSnapshotRepository
    private let volumeCapacityProvider: any StartupVolumeCapacitySnapshotProviding
    private let buildMetadata: AuthorizedBaselineBuildMetadata
    private let makeBaselineID: @Sendable () -> AuthorizedBaselineID
    private let now: @Sendable () -> Date
    private var currentState: AuthorizedBaselineScanState = .idle
    private var currentTask: Task<Void, Never>?
    private var operationID: UUID?
    private var activeContext: AuthorizedBaselineScanContext?
    private var isRestoring = false
    private var observers: [UUID: Observer] = [:]

    public init(
        contextProvider: any AuthorizedBaselineScanContextProviding,
        calibrationRunner: any AuthorizedBaselineCalibrationRunning,
        snapshotRepository: any AuthorizedBaselineSnapshotRepository,
        volumeCapacityProvider: any StartupVolumeCapacitySnapshotProviding,
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
        guard currentTask == nil, isRestoring == false else { return false }
        let operationID = UUID()
        let startedAt = now()
        self.operationID = operationID
        activeContext = nil
        publish(.preparing(scopeID: scopeID, startedAt: startedAt))
        currentTask = Task { @concurrent [weak self] in
            await self?.execute(
                scopeID: scopeID,
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
        scopeID: WatchedScopeID,
        operationID: UUID,
        startedAt: Date
    ) async {
        defer { finish(operationID: operationID) }
        do {
            let context = try await contextProvider.context(for: scopeID)
            try Task.checkCancellation()
            guard self.operationID == operationID else { return }
            activeContext = context

            let outcome = try await calibrationRunner.run(context: context) { [weak self] update in
                await self?.receive(
                    update,
                    operationID: operationID,
                    startedAt: startedAt
                )
            }
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
                let volumeSnapshot = await volumeCapacityProvider.snapshot()
                try Task.checkCancellation()
                let completedAt = now()
                let rootSnapshot = try AuthorizedBaselineRootSnapshot(
                    context: context,
                    logicalBytes: logicalBytes,
                    allocatedBytes: allocatedBytes,
                    descendantCount: aggregate.descendantCount,
                    entriesVisited: report.entriesVisited,
                    directoriesObserved: report.directoriesStaged
                )
                let snapshot = try AuthorizedBaselineSnapshot(
                    id: makeBaselineID(),
                    startedAt: startedAt,
                    committedAt: completedAt,
                    build: buildMetadata,
                    startupVolume: volumeSnapshot,
                    roots: [rootSnapshot]
                )
                do {
                    try await snapshotRepository.saveAuthorizedBaseline(snapshot)
                } catch {
                    publishFailure(
                        scopeID: scopeID,
                        code: .baselinePersistenceFailed,
                        operationID: operationID
                    )
                    return
                }
                publish(
                    .completed(
                        try AuthorizedBaselineScanResult(
                            snapshot: snapshot,
                            scopeID: scopeID,
                            origin: .completedScan
                        )
                    )
                )
            case let .incomplete(report, reason):
                publish(
                    .incomplete(
                        AuthorizedBaselineIncompleteResult(
                            context: context,
                            reason: reason,
                            report: report,
                            startedAt: startedAt,
                            completedAt: now()
                        )
                    )
                )
            }
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            publish(
                .cancelled(
                    AuthorizedBaselineScanCancellation(
                        scopeID: scopeID,
                        context: activeContext,
                        startedAt: startedAt,
                        cancelledAt: now()
                    )
                )
            )
        } catch let error as AuthorizedBaselineScanContextError {
            let code: AuthorizedBaselineScanFailureCode = switch error {
            case .scopeNotAuthorized: .scopeNotAuthorized
            case .monitoringNotReady: .monitoringNotReady
            }
            publishFailure(scopeID: scopeID, code: code, operationID: operationID)
        } catch let error as AuthorizedBaselineCalibrationRunnerError {
            let code: AuthorizedBaselineScanFailureCode = switch error {
            case .publishedRootMissing: .publishedRootMissing
            case .missingAttempt: .operationFailed
            }
            publishFailure(scopeID: scopeID, code: code, operationID: operationID)
        } catch {
            publishFailure(scopeID: scopeID, code: .operationFailed, operationID: operationID)
        }
    }

    private func receive(
        _ update: AuthorizedBaselineCalibrationProgress,
        operationID: UUID,
        startedAt: Date
    ) {
        guard self.operationID == operationID, Task.isCancelled == false else { return }
        switch update {
        case let .scanning(context):
            publish(
                .scanning(
                    AuthorizedBaselineScanProgress(
                        context: context,
                        startedAt: startedAt
                    )
                )
            )
        case let .publishing(context, report):
            publish(
                .publishing(
                    AuthorizedBaselineScanProgress(
                        context: context,
                        startedAt: startedAt,
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
    }

    private func publish(_ state: AuthorizedBaselineScanState) {
        currentState = state
        observers.values.forEach { $0.continuation.yield(state) }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }
}
