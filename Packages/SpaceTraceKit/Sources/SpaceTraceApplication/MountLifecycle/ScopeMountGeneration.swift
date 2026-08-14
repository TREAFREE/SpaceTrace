import Foundation

/// Stable application identity for one user-approved watch scope.
public struct WatchedScopeID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ScopeMountGenerationError) {
        guard Self.isSafePersistenceKey(rawValue) else {
            throw .invalidScopeID
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "WatchedScopeID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isSafePersistenceKey(_ value: String) -> Bool {
        value.isEmpty == false
            && value.allSatisfy(\.isWhitespace) == false
            && value.utf8.contains(0) == false
            && value.first?.isWhitespace == false
            && value.last?.isWhitespace == false
    }
}

/// One continuous period during which a scope's volume is mounted.
///
/// This identifier is deliberately separate from `dev_t`: the device number
/// is useful only while opening the current native stream and is never durable.
public struct MountGenerationID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public init(_ rawValue: String) throws(ScopeMountGenerationError) {
        guard rawValue.isEmpty == false,
              rawValue.allSatisfy(\.isWhitespace) == false,
              rawValue.utf8.contains(0) == false,
              rawValue.first?.isWhitespace == false,
              rawValue.last?.isWhitespace == false else {
            throw .invalidMountGenerationID
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "MountGenerationID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Owned, persistent-safe evidence copied from the current mount observation.
/// Display names and ephemeral device identifiers are intentionally absent.
public struct VolumeMountEvidence: Sendable, Equatable, Hashable, Codable {
    public let mountPath: DirtyRegionPath
    public let volumeUUID: UUID?

    public init(mountPath: DirtyRegionPath, volumeUUID: UUID?) throws(ScopeMountGenerationError) {
        guard mountPath.rawValue == "/" || mountPath.rawValue.hasSuffix("/") == false else {
            throw .invalidMountPath
        }
        self.mountPath = mountPath
        self.volumeUUID = volumeUUID
    }
}

/// Last durable scope-to-volume mapping. Inactive rows retain the evidence
/// required to classify the next mount without claiming temporal continuity.
public struct ScopeMountGeneration: Sendable, Equatable, Hashable, Codable {
    public let scopeID: WatchedScopeID
    public let generationID: MountGenerationID
    public let mountPath: DirtyRegionPath
    public let volumeUUID: UUID?
    public let isActive: Bool

    public init(
        scopeID: WatchedScopeID,
        generationID: MountGenerationID,
        mountPath: DirtyRegionPath,
        volumeUUID: UUID?,
        isActive: Bool
    ) {
        self.scopeID = scopeID
        self.generationID = generationID
        self.mountPath = mountPath
        self.volumeUUID = volumeUUID
        self.isActive = isActive
    }
}

public enum ScopeMountActivationReason: String, Sendable, Equatable, Codable {
    case firstMount
    case duplicateNotification
    case activeMountUpdated
    case remountedSameVolume
    case replacementVolume
    case identityUnavailable
}

public struct ScopeMountActivation: Sendable, Equatable, Codable {
    public let previous: ScopeMountGeneration?
    public let current: ScopeMountGeneration
    public let reason: ScopeMountActivationReason
    public let requiresCalibration: Bool

    public init(
        previous: ScopeMountGeneration?,
        current: ScopeMountGeneration,
        reason: ScopeMountActivationReason,
        requiresCalibration: Bool
    ) {
        self.previous = previous
        self.current = current
        self.reason = reason
        self.requiresCalibration = requiresCalibration
    }
}

/// Pure transition rules shared by transactional repositories and unit tests.
public enum ScopeMountGenerationStateMachine {
    public static func activate(
        previous: ScopeMountGeneration?,
        scopeID: WatchedScopeID,
        evidence: VolumeMountEvidence,
        proposedGenerationID: MountGenerationID
    ) -> ScopeMountActivation {
        guard let previous else {
            return open(
                previous: nil,
                scopeID: scopeID,
                evidence: evidence,
                generationID: proposedGenerationID,
                reason: evidence.volumeUUID == nil ? .identityUnavailable : .firstMount
            )
        }

        guard previous.scopeID == scopeID else {
            return open(
                previous: previous,
                scopeID: scopeID,
                evidence: evidence,
                generationID: proposedGenerationID,
                reason: evidence.volumeUUID == nil ? .identityUnavailable : .firstMount
            )
        }

        if previous.isActive {
            return transitionFromActive(
                previous: previous,
                evidence: evidence,
                proposedGenerationID: proposedGenerationID
            )
        }

        let reason: ScopeMountActivationReason
        if let previousVolumeUUID = previous.volumeUUID,
           let currentVolumeUUID = evidence.volumeUUID {
            reason = previousVolumeUUID == currentVolumeUUID
                ? .remountedSameVolume
                : .replacementVolume
        } else {
            reason = .identityUnavailable
        }
        return open(
            previous: previous,
            scopeID: scopeID,
            evidence: evidence,
            generationID: proposedGenerationID,
            reason: reason
        )
    }

    private static func transitionFromActive(
        previous: ScopeMountGeneration,
        evidence: VolumeMountEvidence,
        proposedGenerationID: MountGenerationID
    ) -> ScopeMountActivation {
        if previous.volumeUUID != nil, evidence.volumeUUID == nil {
            return open(
                previous: previous,
                scopeID: previous.scopeID,
                evidence: evidence,
                generationID: proposedGenerationID,
                reason: .identityUnavailable
            )
        }
        if let previousVolumeUUID = previous.volumeUUID,
           let currentVolumeUUID = evidence.volumeUUID,
           previousVolumeUUID != currentVolumeUUID {
            return open(
                previous: previous,
                scopeID: previous.scopeID,
                evidence: evidence,
                generationID: proposedGenerationID,
                reason: .replacementVolume
            )
        }

        let resolvedVolumeUUID = evidence.volumeUUID ?? previous.volumeUUID
        let current = ScopeMountGeneration(
            scopeID: previous.scopeID,
            generationID: previous.generationID,
            mountPath: evidence.mountPath,
            volumeUUID: resolvedVolumeUUID,
            isActive: true
        )
        let isDuplicate = current == previous
        return ScopeMountActivation(
            previous: previous,
            current: current,
            reason: isDuplicate ? .duplicateNotification : .activeMountUpdated,
            requiresCalibration: isDuplicate == false
        )
    }

    private static func open(
        previous: ScopeMountGeneration?,
        scopeID: WatchedScopeID,
        evidence: VolumeMountEvidence,
        generationID: MountGenerationID,
        reason: ScopeMountActivationReason
    ) -> ScopeMountActivation {
        ScopeMountActivation(
            previous: previous,
            current: ScopeMountGeneration(
                scopeID: scopeID,
                generationID: generationID,
                mountPath: evidence.mountPath,
                volumeUUID: evidence.volumeUUID,
                isActive: true
            ),
            reason: reason,
            requiresCalibration: true
        )
    }
}

/// Transactional application port. Implementations must classify and persist
/// activation inside one write transaction, and close only the expected active
/// generation so a late unmount callback cannot deactivate a replacement.
public protocol ScopeMountGenerationRepository: Sendable {
    func activateScopeMount(
        scopeID: WatchedScopeID,
        evidence: VolumeMountEvidence,
        proposedGenerationID: MountGenerationID
    ) async throws -> ScopeMountActivation

    func deactivateScopeMount(
        scopeID: WatchedScopeID,
        matching generationID: MountGenerationID
    ) async throws -> Bool

    func scopeMountGeneration(
        for scopeID: WatchedScopeID
    ) async throws -> ScopeMountGeneration?
}

public enum ScopeMountGenerationError: Error, Sendable, Equatable {
    case invalidScopeID
    case invalidMountGenerationID
    case invalidMountPath
}
