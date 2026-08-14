public struct ObservationEndpointID: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ObservationEndpointValidationError) {
        guard isValidObservationEvidenceKey(rawValue) else { throw .invalidEndpointID }
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesPrecede(lhs.rawValue, rhs.rawValue)
    }

    public func hash(into hasher: inout Hasher) {
        hashObservationEvidenceBytes(rawValue, into: &hasher)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationEndpointID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ObservationVolumeID: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ObservationEndpointValidationError) {
        guard isValidObservationEvidenceKey(rawValue) else { throw .invalidVolumeID }
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesPrecede(lhs.rawValue, rhs.rawValue)
    }

    public func hash(into hasher: inout Hasher) {
        hashObservationEvidenceBytes(rawValue, into: &hasher)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationVolumeID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ObservationMountGenerationID: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ObservationEndpointValidationError) {
        guard isValidObservationEvidenceKey(rawValue) else { throw .invalidMountGenerationID }
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesPrecede(lhs.rawValue, rhs.rawValue)
    }

    public func hash(into hasher: inout Hasher) {
        hashObservationEvidenceBytes(rawValue, into: &hasher)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationMountGenerationID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ObservationCoverageEpochID: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ObservationEndpointValidationError) {
        guard isValidObservationEvidenceKey(rawValue) else { throw .invalidCoverageEpochID }
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesPrecede(lhs.rawValue, rhs.rawValue)
    }

    public func hash(into hasher: inout Hasher) {
        hashObservationEvidenceBytes(rawValue, into: &hasher)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationCoverageEpochID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ObservationLocationID: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ObservationEndpointValidationError) {
        guard isValidObservationEvidenceKey(rawValue) else { throw .invalidLocationID }
        self.rawValue = rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesEqual(lhs.rawValue, rhs.rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        observationEvidenceBytesPrecede(lhs.rawValue, rhs.rawValue)
    }

    public func hash(into hasher: inout Hasher) {
        hashObservationEvidenceBytes(rawValue, into: &hasher)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationLocationID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ObservationCommitSequence: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(ObservationEndpointValidationError) {
        guard rawValue > 0 else { throw .invalidCommitSequence(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int64.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationCommitSequence must be greater than zero."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ObservationSemanticsVersion: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: Int

    public init(_ rawValue: Int) throws(ObservationEndpointValidationError) {
        guard rawValue > 0 else { throw .invalidSemanticsVersion(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationSemanticsVersion must be greater than zero."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ObservationSubjectIdentityBasis: String, Sendable, Equatable, Hashable, Codable {
    case stableFileSystemObject = "stable_file_system_object"
    case normalizedPath = "normalized_path"
}

/// A durable reference to the parent endpoint that may prove absence.
///
/// This value alone is not proof: the application frame validator must resolve
/// the referenced parent and verify matching context, direct parentage, and
/// complete enumeration before publishing an appearance or disappearance.
public struct ParentAbsenceReference: Sendable, Equatable, Hashable, Codable {
    public let parentEndpointID: ObservationEndpointID
    public let parentSubjectID: SubjectID

    public init(
        parentEndpointID: ObservationEndpointID,
        parentSubjectID: SubjectID
    ) {
        self.parentEndpointID = parentEndpointID
        self.parentSubjectID = parentSubjectID
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownObservationEndpointKeys(
            in: decoder,
            allowed: ["parentEndpointID", "parentSubjectID"],
            typeName: "ParentAbsenceReference"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            parentEndpointID: try container.decode(
                ObservationEndpointID.self,
                forKey: .parentEndpointID
            ),
            parentSubjectID: try container.decode(SubjectID.self, forKey: .parentSubjectID)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case parentEndpointID
        case parentSubjectID
    }
}

public enum ObservationUnavailabilityReason: String, Sendable, Equatable, Hashable, Codable {
    case permissionDenied = "permission_denied"
    case volumeUnavailable = "volume_unavailable"
    case continuityGap = "continuity_gap"
    case incompleteEnumeration = "incomplete_enumeration"
    case identityUnavailable = "identity_unavailable"
    case endpointMissing = "endpoint_missing"
}

public enum ObservationEndpointState: Sendable, Equatable, Hashable, Codable {
    case present(bytes: ByteCount, coverage: ObservationCoverage)
    case absent(ParentAbsenceReference)
    case unknown(ObservationUnavailabilityReason)

    public init(from decoder: any Decoder) throws {
        try rejectUnknownObservationEndpointKeys(
            in: decoder,
            allowed: ["kind", "bytes", "coverage", "parent", "reason"],
            typeName: "ObservationEndpointState"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .present:
            guard container.contains(.parent) == false,
                  container.contains(.reason) == false
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "A present endpoint state cannot contain absence or unknown evidence."
                )
            }
            let coverage = try container.decode(ObservationCoverage.self, forKey: .coverage)
            guard coverage != .unknown else {
                throw DecodingError.dataCorruptedError(
                    forKey: .coverage,
                    in: container,
                    debugDescription: "A present endpoint state cannot use unknown coverage."
                )
            }
            self = .present(
                bytes: try container.decode(ByteCount.self, forKey: .bytes),
                coverage: coverage
            )
        case .absent:
            guard container.contains(.bytes) == false,
                  container.contains(.coverage) == false,
                  container.contains(.reason) == false
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An absent endpoint state can contain only parent evidence."
                )
            }
            self = .absent(
                try container.decode(ParentAbsenceReference.self, forKey: .parent)
            )
        case .unknown:
            guard container.contains(.bytes) == false,
                  container.contains(.coverage) == false,
                  container.contains(.parent) == false
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An unknown endpoint state can contain only an unavailability reason."
                )
            }
            self = .unknown(
                try container.decode(ObservationUnavailabilityReason.self, forKey: .reason)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .present(bytes, coverage):
            guard coverage != .unknown else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "A present endpoint state cannot use unknown coverage."
                    )
                )
            }
            try container.encode(Kind.present, forKey: .kind)
            try container.encode(bytes, forKey: .bytes)
            try container.encode(coverage, forKey: .coverage)
        case .absent(let parent):
            try container.encode(Kind.absent, forKey: .kind)
            try container.encode(parent, forKey: .parent)
        case .unknown(let reason):
            try container.encode(Kind.unknown, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    private enum Kind: String, Codable {
        case present
        case absent
        case unknown
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bytes
        case coverage
        case parent
        case reason
    }
}

/// One immutable, append-only endpoint used as source evidence for a storage
/// change. Paths and display text deliberately remain outside the Domain.
public struct ObservationEndpoint: Sendable, Equatable, Hashable, Codable {
    public let id: ObservationEndpointID
    public let scopeID: ScopeID
    public let volumeID: ObservationVolumeID
    public let mountGenerationID: ObservationMountGenerationID
    public let coverageEpochID: ObservationCoverageEpochID
    public let subjectID: SubjectID
    public let identityBasis: ObservationSubjectIdentityBasis
    public let locationID: ObservationLocationID
    public let metric: StorageMetric
    public let pathSemanticsVersion: ObservationSemanticsVersion
    public let measurementSemanticsVersion: ObservationSemanticsVersion
    public let sequence: ObservationCommitSequence
    public let observedAt: ObservationInstant
    public let state: ObservationEndpointState

    public init(
        id: ObservationEndpointID,
        scopeID: ScopeID,
        volumeID: ObservationVolumeID,
        mountGenerationID: ObservationMountGenerationID,
        coverageEpochID: ObservationCoverageEpochID,
        subjectID: SubjectID,
        identityBasis: ObservationSubjectIdentityBasis,
        locationID: ObservationLocationID,
        metric: StorageMetric,
        pathSemanticsVersion: ObservationSemanticsVersion,
        measurementSemanticsVersion: ObservationSemanticsVersion,
        sequence: ObservationCommitSequence,
        observedAt: ObservationInstant,
        state: ObservationEndpointState
    ) throws(ObservationEndpointValidationError) {
        if case .present(_, .unknown) = state {
            throw .presentCannotUseUnknownCoverage
        }
        if case .absent(let reference) = state,
           reference.parentEndpointID == id || reference.parentSubjectID == subjectID {
            throw .invalidParentAbsenceReference
        }

        self.id = id
        self.scopeID = scopeID
        self.volumeID = volumeID
        self.mountGenerationID = mountGenerationID
        self.coverageEpochID = coverageEpochID
        self.subjectID = subjectID
        self.identityBasis = identityBasis
        self.locationID = locationID
        self.metric = metric
        self.pathSemanticsVersion = pathSemanticsVersion
        self.measurementSemanticsVersion = measurementSemanticsVersion
        self.sequence = sequence
        self.observedAt = observedAt
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownObservationEndpointKeys(
            in: decoder,
            allowed: [
                "id",
                "scopeID",
                "volumeID",
                "mountGenerationID",
                "coverageEpochID",
                "subjectID",
                "identityBasis",
                "locationID",
                "metric",
                "pathSemanticsVersion",
                "measurementSemanticsVersion",
                "sequence",
                "observedAt",
                "state",
            ],
            typeName: "ObservationEndpoint"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ObservationEndpointID.self, forKey: .id),
                scopeID: container.decode(ScopeID.self, forKey: .scopeID),
                volumeID: container.decode(ObservationVolumeID.self, forKey: .volumeID),
                mountGenerationID: container.decode(ObservationMountGenerationID.self, forKey: .mountGenerationID),
                coverageEpochID: container.decode(ObservationCoverageEpochID.self, forKey: .coverageEpochID),
                subjectID: container.decode(SubjectID.self, forKey: .subjectID),
                identityBasis: container.decode(ObservationSubjectIdentityBasis.self, forKey: .identityBasis),
                locationID: container.decode(ObservationLocationID.self, forKey: .locationID),
                metric: container.decode(StorageMetric.self, forKey: .metric),
                pathSemanticsVersion: container.decode(ObservationSemanticsVersion.self, forKey: .pathSemanticsVersion),
                measurementSemanticsVersion: container.decode(ObservationSemanticsVersion.self, forKey: .measurementSemanticsVersion),
                sequence: container.decode(ObservationCommitSequence.self, forKey: .sequence),
                observedAt: container.decode(ObservationInstant.self, forKey: .observedAt),
                state: container.decode(ObservationEndpointState.self, forKey: .state)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Observation endpoint state is inconsistent."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(scopeID, forKey: .scopeID)
        try container.encode(volumeID, forKey: .volumeID)
        try container.encode(mountGenerationID, forKey: .mountGenerationID)
        try container.encode(coverageEpochID, forKey: .coverageEpochID)
        try container.encode(subjectID, forKey: .subjectID)
        try container.encode(identityBasis, forKey: .identityBasis)
        try container.encode(locationID, forKey: .locationID)
        try container.encode(metric, forKey: .metric)
        try container.encode(pathSemanticsVersion, forKey: .pathSemanticsVersion)
        try container.encode(measurementSemanticsVersion, forKey: .measurementSemanticsVersion)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(state, forKey: .state)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case scopeID
        case volumeID
        case mountGenerationID
        case coverageEpochID
        case subjectID
        case identityBasis
        case locationID
        case metric
        case pathSemanticsVersion
        case measurementSemanticsVersion
        case sequence
        case observedAt
        case state
    }
}

public enum ObservationEndpointValidationError: Error, Sendable, Equatable {
    case invalidEndpointID
    case invalidVolumeID
    case invalidMountGenerationID
    case invalidCoverageEpochID
    case invalidLocationID
    case invalidCommitSequence(Int64)
    case invalidSemanticsVersion(Int)
    case presentCannotUseUnknownCoverage
    case invalidParentAbsenceReference
}

private func isValidObservationEvidenceKey(_ value: String) -> Bool {
    value.isEmpty == false
        && value.allSatisfy(\.isWhitespace) == false
        && value.utf8.contains(0) == false
        && value.first?.isWhitespace == false
        && value.last?.isWhitespace == false
}

private func observationEvidenceBytesEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func observationEvidenceBytesPrecede(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private func hashObservationEvidenceBytes(_ value: String, into hasher: inout Hasher) {
    hasher.combine(value.utf8.count)
    for byte in value.utf8 {
        hasher.combine(byte)
    }
}

private func rejectUnknownObservationEndpointKeys(
    in decoder: any Decoder,
    allowed: Set<String>,
    typeName: String
) throws {
    let container = try decoder.container(keyedBy: ObservationEndpointDynamicCodingKey.self)
    guard let unknownKey = container.allKeys.first(
        where: { allowed.contains($0.stringValue) == false }
    ) else {
        return
    }

    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath + [unknownKey],
            debugDescription: "\(typeName) contains an unknown durable field."
        )
    )
}

private struct ObservationEndpointDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
