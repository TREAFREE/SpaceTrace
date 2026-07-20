import SpaceTraceApplication

/// Resolves a baseline only against an already restored user grant and its
/// currently active FSEvents generation. It never derives or broadens access.
public actor NativeAuthorizedBaselineScanContextProvider: AuthorizedBaselineScanContextProviding {
    private let catalog: any WatchedScopeCatalog
    private let runtime: NativeVolumeMonitoringRuntime

    public init(
        catalog: any WatchedScopeCatalog,
        runtime: NativeVolumeMonitoringRuntime
    ) {
        self.catalog = catalog
        self.runtime = runtime
    }

    public func context(
        for scopeID: WatchedScopeID
    ) async throws -> AuthorizedBaselineScanContext {
        guard let scope = try await catalog.watchedScopes().first(where: { $0.id == scopeID }) else {
            throw AuthorizedBaselineScanContextError.scopeNotAuthorized
        }
        guard let active = await runtime.activeStatus(for: scopeID) else {
            throw AuthorizedBaselineScanContextError.monitoringNotReady
        }
        return AuthorizedBaselineScanContext(
            scopeID: scopeID,
            root: scope.root,
            streamID: active.streamID
        )
    }
}
