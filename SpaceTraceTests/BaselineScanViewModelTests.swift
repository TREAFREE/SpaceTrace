import Foundation
import SpaceTraceApplication
import Testing
@testable import SpaceTrace

@MainActor
struct BaselineScanViewModelTests {
    @Test("The view model forwards commands and renders typed coordinator updates")
    func forwardsCommandsAndUpdatesState() async throws {
        let scopeID = try WatchedScopeID("scope-primary")
        let coordinator = BaselineScanCoordinatorFake()
        let model = BaselineScanViewModel(coordinator: coordinator)
        let monitoring = Task { await model.monitor() }
        await coordinator.waitUntilObserved()
        let failure = AuthorizedBaselineScanFailure(
            scopeID: scopeID,
            code: .monitoringNotReady,
            failedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        await model.start(scopeID: scopeID)
        await coordinator.send(.failed(failure))
        for _ in 0..<100 where model.state != .failed(failure) {
            await Task.yield()
        }

        #expect(model.state == .failed(failure))
        #expect(await coordinator.startedScopeIDs == [scopeID])
        await model.start(scopeIDs: [scopeID])
        #expect(await coordinator.startedRequests == [[scopeID]])
        await model.restore(scopeID: scopeID)
        #expect(await coordinator.restoredScopeIDs == [scopeID])
        await model.cancel()
        #expect(await coordinator.cancelCount == 1)

        monitoring.cancel()
        await monitoring.value
    }
}

private actor BaselineScanCoordinatorFake: AuthorizedBaselineScanCoordinating {
    private var continuation: AsyncStream<AuthorizedBaselineScanState>.Continuation?
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var startedScopeIDs: [WatchedScopeID] = []
    private(set) var startedRequests: [[WatchedScopeID]] = []
    private(set) var restoredScopeIDs: [WatchedScopeID] = []
    private(set) var cancelCount = 0

    func updates() -> AsyncStream<AuthorizedBaselineScanState> {
        let pair = AsyncStream<AuthorizedBaselineScanState>.makeStream()
        continuation = pair.continuation
        observationWaiters.forEach { $0.resume() }
        observationWaiters.removeAll()
        return pair.stream
    }

    func start(scopeID: WatchedScopeID) -> Bool {
        startedScopeIDs.append(scopeID)
        return true
    }

    func start(request: AuthorizedBaselineScanRequest) -> Bool {
        startedRequests.append(request.scopeIDs)
        return true
    }

    func cancel() {
        cancelCount += 1
    }

    func restoreLatest(scopeID: WatchedScopeID) {
        restoredScopeIDs.append(scopeID)
    }

    func send(_ state: AuthorizedBaselineScanState) {
        continuation?.yield(state)
    }

    func waitUntilObserved() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            observationWaiters.append(continuation)
        }
    }
}
