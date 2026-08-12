import SpaceTraceDomain

public struct HistoricalProjectionCorrectionRequestID: Sendable, Equatable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws(HistoricalProjectionCorrectionModelError) {
        guard bytes.count == 16 else { throw .invalidRequestIDLength(bytes.count) }
        self.bytes = bytes
    }
}

public struct HistoricalProjectionCorrectionDigest: Sendable, Equatable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws(HistoricalProjectionCorrectionModelError) {
        guard bytes.count == 32 else { throw .invalidDigestLength(bytes.count) }
        self.bytes = bytes
    }
}

public struct HistoricalCorrectionInputFormatVersion:
    Sendable, Equatable, Hashable, Comparable
{
    public let rawValue: Int

    public init(_ rawValue: Int) throws(HistoricalProjectionCorrectionModelError) {
        guard rawValue > 0 else { throw .invalidCorrectionInputFormatVersion(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Semantic implementation identity frozen for one projection. Schema-v11
/// projections legitimately have no correction-input identity; schema-v12
/// correcting projections carry both the format and digest.
public struct HistoricalProjectionSemanticIdentity: Sendable, Equatable, Hashable {
    public let algorithmVersion: HistoricalFindingAlgorithmVersion
    public let rankingPolicyVersion: HistoricalFindingRankingPolicyVersion
    public let correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion?
    public let correctionInputDigest: HistoricalProjectionCorrectionDigest?

    public init(
        algorithmVersion: HistoricalFindingAlgorithmVersion,
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion,
        correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion?,
        correctionInputDigest: HistoricalProjectionCorrectionDigest?
    ) throws(HistoricalProjectionCorrectionModelError) {
        guard (correctionInputFormatVersion == nil) == (correctionInputDigest == nil) else {
            throw .incompleteCorrectionInputIdentity
        }
        self.algorithmVersion = algorithmVersion
        self.rankingPolicyVersion = rankingPolicyVersion
        self.correctionInputFormatVersion = correctionInputFormatVersion
        self.correctionInputDigest = correctionInputDigest
    }
}

public struct HistoricalProjectionCorrectionReference: Sendable, Equatable {
    public let projectionID: HistoricalProjectionRecordID
    public let projectionDigest: HistoricalProjectionCorrectionDigest
    public let baselineSequence: ObservationCommitSequence
    public let comparisonSequence: ObservationCommitSequence
    public let scopeID: ScopeID
    public let metric: StorageMetric
    public let semanticIdentity: HistoricalProjectionSemanticIdentity

    public init(
        projectionID: HistoricalProjectionRecordID,
        projectionDigest: HistoricalProjectionCorrectionDigest,
        baselineSequence: ObservationCommitSequence,
        comparisonSequence: ObservationCommitSequence,
        scopeID: ScopeID,
        metric: StorageMetric,
        semanticIdentity: HistoricalProjectionSemanticIdentity
    ) throws(HistoricalProjectionCorrectionModelError) {
        guard baselineSequence < comparisonSequence else {
            throw .nonIncreasingFramePair
        }
        guard metric == .logical || metric == .allocated else {
            throw .unsupportedMetric
        }
        self.projectionID = projectionID
        self.projectionDigest = projectionDigest
        self.baselineSequence = baselineSequence
        self.comparisonSequence = comparisonSequence
        self.scopeID = scopeID
        self.metric = metric
        self.semanticIdentity = semanticIdentity
    }
}

/// Complete replacement projection metadata. `findingCount == 0` is a valid
/// corrected result and must not be represented as a fabricated successor
/// finding.
public struct HistoricalProjectionReplacement: Sendable, Equatable {
    public let baselineSequence: ObservationCommitSequence
    public let comparisonSequence: ObservationCommitSequence
    public let scopeID: ScopeID
    public let metric: StorageMetric
    public let semanticIdentity: HistoricalProjectionSemanticIdentity
    public let resultDigest: HistoricalProjectionCorrectionDigest
    public let findingCount: Int

    public init(
        baselineSequence: ObservationCommitSequence,
        comparisonSequence: ObservationCommitSequence,
        scopeID: ScopeID,
        metric: StorageMetric,
        semanticIdentity: HistoricalProjectionSemanticIdentity,
        resultDigest: HistoricalProjectionCorrectionDigest,
        findingCount: Int
    ) throws(HistoricalProjectionCorrectionModelError) {
        guard baselineSequence < comparisonSequence else {
            throw .nonIncreasingFramePair
        }
        guard metric == .logical || metric == .allocated else {
            throw .unsupportedMetric
        }
        guard (0...50_000).contains(findingCount) else {
            throw .invalidFindingCount(findingCount)
        }
        self.baselineSequence = baselineSequence
        self.comparisonSequence = comparisonSequence
        self.scopeID = scopeID
        self.metric = metric
        self.semanticIdentity = semanticIdentity
        self.resultDigest = resultDigest
        self.findingCount = findingCount
    }
}

/// Sequence-free command input. Persistence still reloads the predecessor and
/// frames, reruns the registered implementation, and compares the complete
/// value/digest before it may assign a successor projection ID.
public struct HistoricalProjectionCorrectionRequest: Sendable, Equatable {
    public let requestID: HistoricalProjectionCorrectionRequestID
    public let predecessor: HistoricalProjectionCorrectionReference
    public let replacement: HistoricalProjectionReplacement

    public init(
        requestID: HistoricalProjectionCorrectionRequestID,
        predecessor: HistoricalProjectionCorrectionReference,
        replacement: HistoricalProjectionReplacement
    ) throws(HistoricalProjectionCorrectionModelError) {
        guard predecessor.baselineSequence == replacement.baselineSequence,
              predecessor.comparisonSequence == replacement.comparisonSequence else {
            throw .framePairMismatch
        }
        guard predecessor.scopeID == replacement.scopeID else { throw .scopeMismatch }
        guard predecessor.metric == replacement.metric else { throw .metricMismatch }
        guard predecessor.semanticIdentity != replacement.semanticIdentity else {
            throw .semanticIdentityUnchanged
        }
        guard replacement.semanticIdentity.correctionInputFormatVersion != nil,
              replacement.semanticIdentity.correctionInputDigest != nil else {
            throw .replacementCorrectionInputRequired
        }
        self.requestID = requestID
        self.predecessor = predecessor
        self.replacement = replacement
    }
}

public enum HistoricalProjectionCorrectionModelError: Error, Sendable, Equatable {
    case invalidRequestIDLength(Int)
    case invalidDigestLength(Int)
    case invalidCorrectionInputFormatVersion(Int)
    case incompleteCorrectionInputIdentity
    case nonIncreasingFramePair
    case unsupportedMetric
    case invalidFindingCount(Int)
    case framePairMismatch
    case scopeMismatch
    case metricMismatch
    case replacementCorrectionInputRequired
    case semanticIdentityUnchanged
}
