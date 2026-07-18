public struct ScopeEventStreamActiveState: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let generationID: MountGenerationID
    public let streamID: EventStreamID
    public let persistentIdentity: PersistentEventStreamIdentity?

    public init(
        scopeID: WatchedScopeID,
        generationID: MountGenerationID,
        streamID: EventStreamID,
        persistentIdentity: PersistentEventStreamIdentity?
    ) {
        self.scopeID = scopeID
        self.generationID = generationID
        self.streamID = streamID
        self.persistentIdentity = persistentIdentity
    }
}

public struct ScopeEventStreamRecoveryState: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let generationID: MountGenerationID
    public let attempt: Int
    public let maximumAttempts: Int
    public let lastFailure: String

    public init(
        scopeID: WatchedScopeID,
        generationID: MountGenerationID,
        attempt: Int,
        maximumAttempts: Int,
        lastFailure: String
    ) {
        self.scopeID = scopeID
        self.generationID = generationID
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.lastFailure = lastFailure
    }
}

public struct ScopeEventStreamFailureState: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let generationID: MountGenerationID
    public let attempts: Int
    public let message: String

    public init(
        scopeID: WatchedScopeID,
        generationID: MountGenerationID,
        attempts: Int,
        message: String
    ) {
        self.scopeID = scopeID
        self.generationID = generationID
        self.attempts = attempts
        self.message = message
    }
}

/// Application-owned read model for one approved scope's native event stream.
/// Presentation code consumes this state without depending on CoreServices or
/// the concrete FSEvents adapter.
public enum ScopeEventStreamLifecycleState: Sendable, Equatable {
    case inactive(scopeID: WatchedScopeID)
    case active(ScopeEventStreamActiveState)
    case recovering(ScopeEventStreamRecoveryState)
    case failed(ScopeEventStreamFailureState)

    public var scopeID: WatchedScopeID {
        switch self {
        case let .inactive(scopeID):
            scopeID
        case let .active(state):
            state.scopeID
        case let .recovering(state):
            state.scopeID
        case let .failed(state):
            state.scopeID
        }
    }

    public var phase: ScopeEventStreamLifecyclePhase {
        switch self {
        case .inactive:
            .inactive
        case .active:
            .active
        case .recovering:
            .recovering
        case .failed:
            .failed
        }
    }
}

public enum ScopeEventStreamLifecyclePhase: String, Sendable, Equatable, Codable {
    case inactive
    case active
    case recovering
    case failed
}

public enum ScopeEventStreamLifecycleObservationError: Error, Sendable, Equatable {
    case invalidBufferCapacity
}
