import Foundation
import Observation
import SpaceTraceApplication

protocol AuthorizedBaselineScanCoordinating: Sendable {
    func updates() async -> AsyncStream<AuthorizedBaselineScanState>
    func start(scopeID: WatchedScopeID) async -> Bool
    func start(request: AuthorizedBaselineScanRequest) async -> Bool
    func restoreLatest(scopeID: WatchedScopeID) async
    func cancel() async
}

extension AuthorizedBaselineScanCoordinator: AuthorizedBaselineScanCoordinating {}

@MainActor
@Observable
final class BaselineScanViewModel {
    private var coordinator: (any AuthorizedBaselineScanCoordinating)?
    private(set) var state: AuthorizedBaselineScanState
    private(set) var publishedContexts: [AuthorizedBaselineScanContext]

    init(
        coordinator: (any AuthorizedBaselineScanCoordinating)? = nil,
        initialState: AuthorizedBaselineScanState = .idle
    ) {
        self.coordinator = coordinator
        state = initialState
        publishedContexts = Self.contexts(from: initialState)
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
            if case .completed = state {
                publishedContexts = Self.contexts(from: state)
            }
        }
    }

    func start(scopeID: WatchedScopeID) async {
        guard let coordinator else {
            handleCompositionFailure(scopeID: scopeID)
            return
        }
        _ = await coordinator.start(scopeID: scopeID)
    }

    func start(scopeIDs: [WatchedScopeID]) async {
        guard let coordinator else {
            handleCompositionFailure(scopeID: scopeIDs.first)
            return
        }
        do {
            _ = await coordinator.start(
                request: try AuthorizedBaselineScanRequest(scopeIDs: scopeIDs)
            )
        } catch {
            handleCompositionFailure(scopeID: scopeIDs.first)
        }
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

    func historyContexts(
        configuredScopeIDs: [WatchedScopeID]
    ) -> [AuthorizedBaselineScanContext] {
        let configured = Set(configuredScopeIDs)
        return publishedContexts.filter { configured.contains($0.scopeID) }
    }

    var lastReconciliationAt: Date? {
        switch state {
        case let .completed(result):
            result.completedAt
        case let .incomplete(result):
            result.completedAt
        case .idle, .preparing, .deferred, .resuming, .scanning, .publishing,
             .cancelled, .failed:
            nil
        }
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

    private static func contexts(
        from state: AuthorizedBaselineScanState
    ) -> [AuthorizedBaselineScanContext] {
        guard case let .completed(result) = state else { return [] }
        return result.snapshot.roots
            .map(\.context)
            .sorted { $0.scopeID.rawValue < $1.scopeID.rawValue }
    }
}
