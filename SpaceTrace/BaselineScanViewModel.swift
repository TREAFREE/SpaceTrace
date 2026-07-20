import Foundation
import Observation
import SpaceTraceApplication

protocol AuthorizedBaselineScanCoordinating: Sendable {
    func updates() async -> AsyncStream<AuthorizedBaselineScanState>
    func start(scopeID: WatchedScopeID) async -> Bool
    func restoreLatest(scopeID: WatchedScopeID) async
    func cancel() async
}

extension AuthorizedBaselineScanCoordinator: AuthorizedBaselineScanCoordinating {}

@MainActor
@Observable
final class BaselineScanViewModel {
    private var coordinator: (any AuthorizedBaselineScanCoordinating)?
    private(set) var state: AuthorizedBaselineScanState

    init(
        coordinator: (any AuthorizedBaselineScanCoordinating)? = nil,
        initialState: AuthorizedBaselineScanState = .idle
    ) {
        self.coordinator = coordinator
        state = initialState
    }

    func connect(_ coordinator: any AuthorizedBaselineScanCoordinating) {
        self.coordinator = coordinator
    }

    func monitor() async {
        guard let coordinator else { return }
        let updates = await coordinator.updates()
        for await state in updates {
            guard Task.isCancelled == false else { return }
            self.state = state
        }
    }

    func start(scopeID: WatchedScopeID) async {
        guard let coordinator else {
            handleCompositionFailure(scopeID: scopeID)
            return
        }
        _ = await coordinator.start(scopeID: scopeID)
    }

    func restore(scopeID: WatchedScopeID?) async {
        guard let scopeID else {
            state = .idle
            return
        }
        guard let coordinator else {
            handleCompositionFailure(scopeID: scopeID)
            return
        }
        await coordinator.restoreLatest(scopeID: scopeID)
    }

    func cancel() async {
        await coordinator?.cancel()
    }

    func handleCompositionFailure(scopeID: WatchedScopeID? = nil) {
        guard let scopeID else {
            state = .idle
            return
        }
        state = .failed(
            AuthorizedBaselineScanFailure(
                scopeID: scopeID,
                code: .operationFailed,
                failedAt: Date()
            )
        )
    }
}
