public enum StorageChangeKind: String, Sendable, Equatable, Hashable, Codable {
    case growth
    case decrease
    case unchanged
    case appearanceCandidate = "appearance_candidate"
    case disappearanceCandidate = "disappearance_candidate"
    case relocationCandidate = "relocation_candidate"
}

/// A metric-preserving comparison of two immutable observation endpoints.
///
/// This value contains no user-facing path or copy. Candidate cases deliberately
/// stop short of a user-facing appearance, disappearance, or move claim. The
/// application projection must validate both complete frames first.
public struct StorageChange: Sendable, Equatable, Hashable, Codable {
    public let kind: StorageChangeKind
    public let baselineEndpointID: ObservationEndpointID
    public let comparisonEndpointID: ObservationEndpointID
    public let scopeID: ScopeID
    public let volumeID: ObservationVolumeID
    public let mountGenerationID: ObservationMountGenerationID
    public let coverageEpochID: ObservationCoverageEpochID
    public let subjectID: SubjectID
    public let identityBasis: ObservationSubjectIdentityBasis
    public let metric: StorageMetric
    public let sourceLocationID: ObservationLocationID
    public let destinationLocationID: ObservationLocationID
    public let baselineBytes: ByteCount?
    public let comparisonBytes: ByteCount?
    public let inclusiveDelta: StorageDelta
    public let baselineSequence: ObservationCommitSequence
    public let comparisonSequence: ObservationCommitSequence
    public let baselineTime: ObservationInstant
    public let comparisonTime: ObservationInstant

    init(
        kind: StorageChangeKind,
        baseline: ObservationEndpoint,
        comparison: ObservationEndpoint,
        baselineBytes: ByteCount?,
        comparisonBytes: ByteCount?,
        inclusiveDelta: StorageDelta
    ) {
        let payload = StorageChangePayload(
            kind: kind,
            baselineEndpointID: baseline.id,
            comparisonEndpointID: comparison.id,
            scopeID: comparison.scopeID,
            volumeID: comparison.volumeID,
            mountGenerationID: comparison.mountGenerationID,
            coverageEpochID: comparison.coverageEpochID,
            subjectID: comparison.subjectID,
            identityBasis: comparison.identityBasis,
            metric: comparison.metric,
            sourceLocationID: baseline.locationID,
            destinationLocationID: comparison.locationID,
            baselineBytes: baselineBytes,
            comparisonBytes: comparisonBytes,
            inclusiveDelta: inclusiveDelta,
            baselineSequence: baseline.sequence,
            comparisonSequence: comparison.sequence,
            baselineTime: baseline.observedAt,
            comparisonTime: comparison.observedAt
        )
        precondition(payload.hasValidInvariants)
        self.init(validated: payload)
    }

    public init(from decoder: any Decoder) throws {
        let payload = try StorageChangePayload(from: decoder)
        guard payload.hasValidInvariants else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "StorageChange fields violate comparison invariants."
                )
            )
        }
        self.init(validated: payload)
    }

    public func encode(to encoder: any Encoder) throws {
        try payload.encode(to: encoder)
    }

    private init(validated payload: StorageChangePayload) {
        kind = payload.kind
        baselineEndpointID = payload.baselineEndpointID
        comparisonEndpointID = payload.comparisonEndpointID
        scopeID = payload.scopeID
        volumeID = payload.volumeID
        mountGenerationID = payload.mountGenerationID
        coverageEpochID = payload.coverageEpochID
        subjectID = payload.subjectID
        identityBasis = payload.identityBasis
        metric = payload.metric
        sourceLocationID = payload.sourceLocationID
        destinationLocationID = payload.destinationLocationID
        baselineBytes = payload.baselineBytes
        comparisonBytes = payload.comparisonBytes
        inclusiveDelta = payload.inclusiveDelta
        baselineSequence = payload.baselineSequence
        comparisonSequence = payload.comparisonSequence
        baselineTime = payload.baselineTime
        comparisonTime = payload.comparisonTime
    }

    private var payload: StorageChangePayload {
        StorageChangePayload(
            kind: kind,
            baselineEndpointID: baselineEndpointID,
            comparisonEndpointID: comparisonEndpointID,
            scopeID: scopeID,
            volumeID: volumeID,
            mountGenerationID: mountGenerationID,
            coverageEpochID: coverageEpochID,
            subjectID: subjectID,
            identityBasis: identityBasis,
            metric: metric,
            sourceLocationID: sourceLocationID,
            destinationLocationID: destinationLocationID,
            baselineBytes: baselineBytes,
            comparisonBytes: comparisonBytes,
            inclusiveDelta: inclusiveDelta,
            baselineSequence: baselineSequence,
            comparisonSequence: comparisonSequence,
            baselineTime: baselineTime,
            comparisonTime: comparisonTime
        )
    }
}

private struct StorageChangePayload: Codable {
    let kind: StorageChangeKind
    let baselineEndpointID: ObservationEndpointID
    let comparisonEndpointID: ObservationEndpointID
    let scopeID: ScopeID
    let volumeID: ObservationVolumeID
    let mountGenerationID: ObservationMountGenerationID
    let coverageEpochID: ObservationCoverageEpochID
    let subjectID: SubjectID
    let identityBasis: ObservationSubjectIdentityBasis
    let metric: StorageMetric
    let sourceLocationID: ObservationLocationID
    let destinationLocationID: ObservationLocationID
    let baselineBytes: ByteCount?
    let comparisonBytes: ByteCount?
    let inclusiveDelta: StorageDelta
    let baselineSequence: ObservationCommitSequence
    let comparisonSequence: ObservationCommitSequence
    let baselineTime: ObservationInstant
    let comparisonTime: ObservationInstant

    var hasValidInvariants: Bool {
        guard baselineEndpointID != comparisonEndpointID,
              comparisonSequence > baselineSequence,
              inclusiveDelta.metric == metric,
              inclusiveDelta.bytes == expectedDeltaBytes
        else {
            return false
        }

        let sameLocation = sourceLocationID == destinationLocationID
        switch kind {
        case .growth:
            return sameLocation
                && baselineBytes != nil
                && comparisonBytes != nil
                && inclusiveDelta.bytes > 0
        case .decrease:
            return sameLocation
                && baselineBytes != nil
                && comparisonBytes != nil
                && inclusiveDelta.bytes < 0
        case .unchanged:
            let bothPresent = baselineBytes != nil && comparisonBytes != nil
            let bothAbsent = baselineBytes == nil && comparisonBytes == nil
            return sameLocation
                && (bothPresent || bothAbsent)
                && inclusiveDelta.bytes == 0
        case .appearanceCandidate:
            return sameLocation && baselineBytes == nil && comparisonBytes != nil
        case .disappearanceCandidate:
            return sameLocation && baselineBytes != nil && comparisonBytes == nil
        case .relocationCandidate:
            return sameLocation == false
                && identityBasis == .stableFileSystemObject
                && baselineBytes != nil
                && comparisonBytes != nil
        }
    }

    private var expectedDeltaBytes: Int64 {
        switch (baselineBytes, comparisonBytes) {
        case let (.some(baselineBytes), .some(comparisonBytes)):
            comparisonBytes.value - baselineBytes.value
        case let (.none, .some(comparisonBytes)):
            comparisonBytes.value
        case let (.some(baselineBytes), .none):
            -baselineBytes.value
        case (.none, .none):
            0
        }
    }
}

/// Expected reasons why two otherwise valid endpoints cannot support a
/// storage-change claim. These cases are data, not exceptional control flow.
public enum ObservationIncomparability: Sendable, Equatable, Hashable, Codable {
    case scopeMismatch
    case volumeMismatch
    case mountGenerationMismatch
    case coverageEpochMismatch
    case subjectMismatch
    case identityBasisMismatch
    case metricMismatch
    case pathSemanticsMismatch
    case measurementSemanticsMismatch
    case nonIncreasingSequence(baseline: Int64, comparison: Int64)
    case incompleteCoverage(
        baseline: ObservationCoverage,
        comparison: ObservationCoverage
    )
    case unavailable(
        baseline: ObservationUnavailabilityReason?,
        comparison: ObservationUnavailabilityReason?
    )
    case locationChangedWithoutStableIdentity
    case locationChangedWithoutTwoPresentEndpoints

    public init(from decoder: any Decoder) throws {
        let payload = try ObservationIncomparabilityPayload(from: decoder)
        guard payload.hasValidInvariants else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ObservationIncomparability contains an impossible reason payload."
                )
            )
        }
        self = payload.value
    }

    public func encode(to encoder: any Encoder) throws {
        let payload = ObservationIncomparabilityPayload(self)
        guard payload.hasValidInvariants else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "ObservationIncomparability contains an impossible reason payload."
                )
            )
        }
        try payload.encode(to: encoder)
    }
}

private enum ObservationIncomparabilityPayload: Codable {
    case scopeMismatch
    case volumeMismatch
    case mountGenerationMismatch
    case coverageEpochMismatch
    case subjectMismatch
    case identityBasisMismatch
    case metricMismatch
    case pathSemanticsMismatch
    case measurementSemanticsMismatch
    case nonIncreasingSequence(baseline: Int64, comparison: Int64)
    case incompleteCoverage(
        baseline: ObservationCoverage,
        comparison: ObservationCoverage
    )
    case unavailable(
        baseline: ObservationUnavailabilityReason?,
        comparison: ObservationUnavailabilityReason?
    )
    case locationChangedWithoutStableIdentity
    case locationChangedWithoutTwoPresentEndpoints

    init(_ value: ObservationIncomparability) {
        switch value {
        case .scopeMismatch:
            self = .scopeMismatch
        case .volumeMismatch:
            self = .volumeMismatch
        case .mountGenerationMismatch:
            self = .mountGenerationMismatch
        case .coverageEpochMismatch:
            self = .coverageEpochMismatch
        case .subjectMismatch:
            self = .subjectMismatch
        case .identityBasisMismatch:
            self = .identityBasisMismatch
        case .metricMismatch:
            self = .metricMismatch
        case .pathSemanticsMismatch:
            self = .pathSemanticsMismatch
        case .measurementSemanticsMismatch:
            self = .measurementSemanticsMismatch
        case .nonIncreasingSequence(let baseline, let comparison):
            self = .nonIncreasingSequence(baseline: baseline, comparison: comparison)
        case .incompleteCoverage(let baseline, let comparison):
            self = .incompleteCoverage(baseline: baseline, comparison: comparison)
        case .unavailable(let baseline, let comparison):
            self = .unavailable(baseline: baseline, comparison: comparison)
        case .locationChangedWithoutStableIdentity:
            self = .locationChangedWithoutStableIdentity
        case .locationChangedWithoutTwoPresentEndpoints:
            self = .locationChangedWithoutTwoPresentEndpoints
        }
    }

    var value: ObservationIncomparability {
        switch self {
        case .scopeMismatch:
            .scopeMismatch
        case .volumeMismatch:
            .volumeMismatch
        case .mountGenerationMismatch:
            .mountGenerationMismatch
        case .coverageEpochMismatch:
            .coverageEpochMismatch
        case .subjectMismatch:
            .subjectMismatch
        case .identityBasisMismatch:
            .identityBasisMismatch
        case .metricMismatch:
            .metricMismatch
        case .pathSemanticsMismatch:
            .pathSemanticsMismatch
        case .measurementSemanticsMismatch:
            .measurementSemanticsMismatch
        case .nonIncreasingSequence(let baseline, let comparison):
            .nonIncreasingSequence(baseline: baseline, comparison: comparison)
        case .incompleteCoverage(let baseline, let comparison):
            .incompleteCoverage(baseline: baseline, comparison: comparison)
        case .unavailable(let baseline, let comparison):
            .unavailable(baseline: baseline, comparison: comparison)
        case .locationChangedWithoutStableIdentity:
            .locationChangedWithoutStableIdentity
        case .locationChangedWithoutTwoPresentEndpoints:
            .locationChangedWithoutTwoPresentEndpoints
        }
    }

    var hasValidInvariants: Bool {
        switch self {
        case .nonIncreasingSequence(let baseline, let comparison):
            baseline > 0 && comparison > 0 && comparison <= baseline
        case .incompleteCoverage(let baseline, let comparison):
            baseline != .unknown
                && comparison != .unknown
                && (baseline == .partial || comparison == .partial)
        case .unavailable(let baseline, let comparison):
            baseline != nil || comparison != nil
        default:
            true
        }
    }
}

public enum ObservationComparisonOutcome: Sendable, Equatable, Hashable, Codable {
    case comparable(StorageChange)
    case incomparable(ObservationIncomparability)
    case corrupt(ObservationComparisonCorruption)
}

public enum ObservationComparisonCorruption: String, Sendable, Equatable, Hashable, Codable {
    case endpointIDReuse = "endpoint_id_reuse"
}

public extension ObservationEndpoint {
    /// Compares byte measurements using the monotonic commit sequence. Wall
    /// clock timestamps are retained as evidence but deliberately do not order
    /// endpoints because sleep, clock correction, and timezone changes can make
    /// them repeat or move backward.
    func compare(from baseline: ObservationEndpoint) -> ObservationComparisonOutcome {
        guard id != baseline.id else { return .corrupt(.endpointIDReuse) }
        guard scopeID == baseline.scopeID else { return .incomparable(.scopeMismatch) }
        guard volumeID == baseline.volumeID else { return .incomparable(.volumeMismatch) }
        guard mountGenerationID == baseline.mountGenerationID else {
            return .incomparable(.mountGenerationMismatch)
        }
        guard coverageEpochID == baseline.coverageEpochID else {
            return .incomparable(.coverageEpochMismatch)
        }
        guard subjectID == baseline.subjectID else { return .incomparable(.subjectMismatch) }
        guard identityBasis == baseline.identityBasis else {
            return .incomparable(.identityBasisMismatch)
        }
        guard metric == baseline.metric else { return .incomparable(.metricMismatch) }
        guard pathSemanticsVersion == baseline.pathSemanticsVersion else {
            return .incomparable(.pathSemanticsMismatch)
        }
        guard measurementSemanticsVersion == baseline.measurementSemanticsVersion else {
            return .incomparable(.measurementSemanticsMismatch)
        }
        guard sequence > baseline.sequence else {
            return .incomparable(
                .nonIncreasingSequence(
                    baseline: baseline.sequence.rawValue,
                    comparison: sequence.rawValue
                )
            )
        }

        let baselineReason = baseline.state.unavailabilityReason
        let comparisonReason = state.unavailabilityReason
        if baselineReason != nil || comparisonReason != nil {
            return .incomparable(
                .unavailable(
                    baseline: baseline.state.unavailabilityReason,
                    comparison: state.unavailabilityReason
                )
            )
        }

        let baselineCoverage = baseline.state.effectiveCoverage
        let comparisonCoverage = state.effectiveCoverage
        guard baselineCoverage == .complete, comparisonCoverage == .complete else {
            return .incomparable(
                .incompleteCoverage(
                    baseline: baselineCoverage,
                    comparison: comparisonCoverage
                )
            )
        }

        let locationsDiffer = locationID != baseline.locationID
        if locationsDiffer, identityBasis != .stableFileSystemObject {
            return .incomparable(.locationChangedWithoutStableIdentity)
        }

        let baselineBytes = baseline.state.completeBytes
        let comparisonBytes = state.completeBytes
        if locationsDiffer, baselineBytes == nil || comparisonBytes == nil {
            return .incomparable(.locationChangedWithoutTwoPresentEndpoints)
        }

        let deltaBytes: Int64
        switch (baselineBytes, comparisonBytes) {
        case let (.some(baselineBytes), .some(comparisonBytes)):
            // ByteCount is restricted to 0...Int64.max, so this signed
            // subtraction is representable throughout its entire domain.
            deltaBytes = comparisonBytes.value - baselineBytes.value
        case let (.none, .some(comparisonBytes)):
            deltaBytes = comparisonBytes.value
        case let (.some(baselineBytes), .none):
            deltaBytes = -baselineBytes.value
        case (.none, .none):
            deltaBytes = 0
        }

        let kind: StorageChangeKind
        if locationsDiffer {
            kind = .relocationCandidate
        } else {
            switch (baselineBytes, comparisonBytes, deltaBytes) {
            case (.none, .some, _):
                kind = .appearanceCandidate
            case (.some, .none, _):
                kind = .disappearanceCandidate
            case (_, _, let bytes) where bytes > 0:
                kind = .growth
            case (_, _, let bytes) where bytes < 0:
                kind = .decrease
            default:
                kind = .unchanged
            }
        }

        return .comparable(
            StorageChange(
                kind: kind,
                baseline: baseline,
                comparison: self,
                baselineBytes: baselineBytes,
                comparisonBytes: comparisonBytes,
                inclusiveDelta: StorageDelta(metric: metric, bytes: deltaBytes)
            )
        )
    }
}

private extension ObservationEndpointState {
    var unavailabilityReason: ObservationUnavailabilityReason? {
        guard case .unknown(let reason) = self else { return nil }
        return reason
    }

    var effectiveCoverage: ObservationCoverage {
        switch self {
        case .present(_, let coverage):
            coverage
        case .absent:
            .complete
        case .unknown:
            .unknown
        }
    }

    var completeBytes: ByteCount? {
        guard case .present(let bytes, .complete) = self else { return nil }
        return bytes
    }
}
