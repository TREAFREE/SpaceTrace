import SpaceTraceDomain

public struct ReconciliationSuccess: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let sequence: ReconciliationRevisionSequence
    public let completedAt: ObservationInstant

    public init(
        scopeID: WatchedScopeID,
        sequence: ReconciliationRevisionSequence,
        completedAt: ObservationInstant
    ) {
        self.scopeID = scopeID
        self.sequence = sequence
        self.completedAt = completedAt
    }
}

public enum ReconciliationStatusState: Sendable, Equatable {
    case current(ReconciliationSuccess)
    case pending(
        lastSuccess: ReconciliationSuccess?,
        oldestPendingRevision: DirtyRegionRevision?,
        pendingSince: ObservationInstant?
    )
    case partial(
        lastSuccess: ReconciliationSuccess?,
        attemptedRevision: DirtyRegionRevision,
        attemptedAt: ObservationInstant
    )
    case failed(
        lastSuccess: ReconciliationSuccess?,
        attemptedRevision: DirtyRegionRevision,
        attemptedAt: ObservationInstant
    )
    case permissionRequired(lastSuccess: ReconciliationSuccess?)
    case volumeUnavailable(lastSuccess: ReconciliationSuccess?)
    case historyDisabled
    case baselineUnavailable

    fileprivate var successEvidence: ReconciliationSuccess? {
        switch self {
        case .current(let success):
            success
        case .pending(let lastSuccess, _, _),
             .partial(let lastSuccess, _, _),
             .failed(let lastSuccess, _, _),
             .permissionRequired(let lastSuccess),
             .volumeUnavailable(let lastSuccess):
            lastSuccess
        case .historyDisabled, .baselineUnavailable:
            nil
        }
    }
}

/// Durable status facts reconstructed from the local ledger. Permission and
/// mount readiness are deliberately supplied by the lifecycle coordinator,
/// because neither can be inferred safely from historical SQLite rows alone.
public protocol ReconciliationStatusRepository: Sendable {
    func durableReconciliationStatus(
        for scopeID: WatchedScopeID
    ) async throws -> ReconciliationStatus
}

public enum ReconciliationScopeReadiness: Sendable, Equatable, Hashable {
    case ready
    case permissionRequired
    case volumeUnavailable
}

public protocol ReconciliationStatusLoading: Sendable {
    func load(
        scopeID: WatchedScopeID,
        readiness: ReconciliationScopeReadiness
    ) async throws -> ReconciliationStatus
}

public struct ReconciliationStatusQuery: ReconciliationStatusLoading, Sendable {
    private let repository: any ReconciliationStatusRepository

    public init(repository: any ReconciliationStatusRepository) {
        self.repository = repository
    }

    public func load(
        scopeID: WatchedScopeID,
        readiness: ReconciliationScopeReadiness
    ) async throws -> ReconciliationStatus {
        let durable = try await repository.durableReconciliationStatus(for: scopeID)
        switch durable.state {
        case .historyDisabled, .baselineUnavailable:
            return durable
        default:
            break
        }
        switch readiness {
        case .ready:
            return durable
        case .permissionRequired:
            return try ReconciliationStatus(
                scopeID: scopeID,
                state: .permissionRequired(lastSuccess: durable.state.successEvidence)
            )
        case .volumeUnavailable:
            return try ReconciliationStatus(
                scopeID: scopeID,
                state: .volumeUnavailable(lastSuccess: durable.state.successEvidence)
            )
        }
    }
}

/// One typed status for one watched scope. The case, not an empty collection
/// or absent date, communicates why a complete reconciliation is unavailable.
public struct ReconciliationStatus: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let state: ReconciliationStatusState

    public init(
        scopeID: WatchedScopeID,
        state: ReconciliationStatusState
    ) throws(ReconciliationStatusModelError) {
        if let success = state.successEvidence,
           binaryScopeEqual(success.scopeID, scopeID) == false {
            throw .successScopeMismatch
        }
        self.scopeID = scopeID
        self.state = state
    }
}

public enum ReconciliationStatusModelError: Error, Sendable, Equatable {
    case successScopeMismatch
}

private func binaryScopeEqual(_ lhs: WatchedScopeID, _ rhs: WatchedScopeID) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
}
