import Foundation

public actor AuthorizedBaselineScanCoordinator {
    private struct Observer {
        let continuation: AsyncStream<AuthorizedBaselineScanState>.Continuation
    }

    private let contextProvider: any AuthorizedBaselineScanContextProviding
    private let calibrationRunner: any AuthorizedBaselineCalibrationRunning
    private let now: @Sendable () -> Date
    private var currentState: AuthorizedBaselineScanState = .idle
    private var currentTask: Task<Void, Never>?
    private var operationID: UUID?
    private var activeContext: AuthorizedBaselineScanContext?
    private var observers: [UUID: Observer] = [:]

    public init(
        contextProvider: any AuthorizedBaselineScanContextProviding,
        calibrationRunner: any AuthorizedBaselineCalibrationRunning,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.contextProvider = contextProvider
        self.calibrationRunner = calibrationRunner
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
        guard currentTask == nil else { return false }
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
                publish(
                    .completed(
                        AuthorizedBaselineScanResult(
                            context: context,
                            logicalBytes: logicalBytes,
                            allocatedBytes: allocatedBytes,
                            descendantCount: aggregate.descendantCount,
                            report: report,
                            startedAt: startedAt,
                            completedAt: now()
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
