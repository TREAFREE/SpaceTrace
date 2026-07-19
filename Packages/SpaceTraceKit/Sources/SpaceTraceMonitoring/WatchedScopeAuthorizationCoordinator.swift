import Foundation
import SpaceTraceApplication

/// Serializes user-driven grant changes with the process-owned native runtime.
/// UI code supplies only URLs returned by the system picker and receives a
/// privacy-safe restoration report plus the exact selected root it already owns.
public actor WatchedScopeAuthorizationCoordinator {
    private let catalog: any MutableWatchedScopeCatalog
    private let lifecycle: NativeMonitoringApplicationLifecycle
    private var isTransitioning = false
    private var operationEpoch: UInt64 = 0

    public init(
        catalog: any MutableWatchedScopeCatalog,
        lifecycle: NativeMonitoringApplicationLifecycle
    ) {
        self.catalog = catalog
        self.lifecycle = lifecycle
    }

    @discardableResult
    public func start() async throws -> WatchedScopeRestorationReport {
        let epoch = try beginTransition()
        defer { finishTransition(epoch: epoch) }
        let report = try await lifecycle.start()
        try checkTransition(epoch)
        return report
    }

    public func stop() async {
        operationEpoch &+= 1
        isTransitioning = true
        await lifecycle.stop()
        isTransitioning = false
    }

    /// Rechecks only grants that the catalog classifies as temporarily
    /// unavailable. Stale or identity-changing bookmarks remain fail-closed.
    public func refresh() async throws -> WatchedScopeRestorationReport {
        guard isTransitioning == false else {
            throw WatchedScopeAuthorizationCoordinatorError.transitionInProgress
        }
        _ = try await catalog.watchedScopes()
        return await catalog.restorationReport()
    }

    @discardableResult
    public func authorize(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) async throws -> WatchedScopeRestorationReport {
        let epoch = try beginTransition()
        defer { finishTransition(epoch: epoch) }

        await lifecycle.stop()
        try checkTransition(epoch)
        do {
            _ = try await catalog.acquire(selectedURL: selectedURL, scopeID: scopeID)
            try checkTransition(epoch)
            let report = try await lifecycle.start()
            try checkTransition(epoch)
            return report
        } catch {
            if operationEpoch == epoch {
                await resumeAfterFailedMutation()
            }
            throw error
        }
    }

    @discardableResult
    public func revoke(scopeID: WatchedScopeID) async throws -> WatchedScopeRestorationReport {
        let epoch = try beginTransition()
        defer { finishTransition(epoch: epoch) }

        await lifecycle.stop()
        try checkTransition(epoch)
        do {
            try await catalog.remove(scopeID: scopeID)
            try checkTransition(epoch)
            let report = try await lifecycle.start()
            try checkTransition(epoch)
            return report
        } catch {
            if operationEpoch == epoch {
                await resumeAfterFailedMutation()
            }
            throw error
        }
    }

    private func beginTransition() throws -> UInt64 {
        guard isTransitioning == false else {
            throw WatchedScopeAuthorizationCoordinatorError.transitionInProgress
        }
        isTransitioning = true
        operationEpoch &+= 1
        return operationEpoch
    }

    private func checkTransition(_ epoch: UInt64) throws {
        guard operationEpoch == epoch, Task.isCancelled == false else {
            throw WatchedScopeAuthorizationCoordinatorError.transitionCancelled
        }
    }

    private func finishTransition(epoch: UInt64) {
        if operationEpoch == epoch {
            isTransitioning = false
        }
    }

    private func resumeAfterFailedMutation() async {
        _ = try? await lifecycle.start()
    }
}

public enum WatchedScopeAuthorizationCoordinatorError: Error, Sendable, Equatable {
    case transitionInProgress
    case transitionCancelled
}
