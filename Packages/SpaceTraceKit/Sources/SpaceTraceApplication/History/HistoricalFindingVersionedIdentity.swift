import SpaceTraceDomain

/// Database-owned identity for a finding emitted by a schema-v12 correcting
/// projection. It intentionally does not share a namespace with
/// `HistoricalFindingRecordID`.
public struct HistoricalCorrectedFindingRecordID:
    Sendable, Equatable, Hashable, Comparable
{
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(HistoricalFindingVersionedIdentityError) {
        guard rawValue > 0 else {
            throw .invalidCorrectedFindingRecordID(rawValue)
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct HistoricalCorrectedRetractionRecordID:
    Sendable, Equatable, Hashable, Comparable
{
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(HistoricalFindingVersionedIdentityError) {
        guard rawValue > 0 else {
            throw .invalidCorrectedRetractionRecordID(rawValue)
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Projection identity with an explicit source discriminator. Numeric values
/// from the original and correcting tables are never interchangeable.
public enum HistoricalProjectionVersionID: Sendable, Equatable, Hashable, Comparable {
    case original(HistoricalProjectionRecordID)
    case correcting(HistoricalCorrectingProjectionRecordID)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.original(lhsID), .original(rhsID)):
            lhsID < rhsID
        case (.original, .correcting):
            true
        case (.correcting, .original):
            false
        case let (.correcting(lhsID), .correcting(rhsID)):
            lhsID < rhsID
        }
    }
}

/// Finding identity with an explicit source discriminator. Ordering is stable
/// across launches: original values precede corrected values, then each table
/// uses its positive database ID.
public enum HistoricalFindingVersionID: Sendable, Equatable, Hashable, Comparable {
    case original(HistoricalFindingRecordID)
    case corrected(HistoricalCorrectedFindingRecordID)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.original(lhsID), .original(rhsID)):
            lhsID < rhsID
        case (.original, .corrected):
            true
        case (.corrected, .original):
            false
        case let (.corrected(lhsID), .corrected(rhsID)):
            lhsID < rhsID
        }
    }
}

public struct VersionedEffectiveHistoricalFinding: Sendable, Equatable {
    public let recordID: HistoricalFindingVersionID
    public let projectionID: HistoricalProjectionVersionID
    public let comparisonSequence: ObservationCommitSequence
    public let positiveRank: Int?
    public let draft: HistoricalFindingDraft

    public init(
        recordID: HistoricalFindingVersionID,
        projectionID: HistoricalProjectionVersionID,
        comparisonSequence: ObservationCommitSequence,
        positiveRank: Int?,
        draft: HistoricalFindingDraft
    ) throws(HistoricalFindingVersionedIdentityError) {
        switch (recordID, projectionID) {
        case (.original, .original), (.corrected, .correcting):
            break
        case (.original, .correcting), (.corrected, .original):
            throw .findingProjectionSourceMismatch
        }
        if let positiveRank, positiveRank <= 0 {
            throw .invalidPositiveRank(positiveRank)
        }
        guard draft.evidence.comparisonSequence == comparisonSequence else {
            throw .findingComparisonSequenceMismatch
        }
        self.recordID = recordID
        self.projectionID = projectionID
        self.comparisonSequence = comparisonSequence
        self.positiveRank = positiveRank
        self.draft = draft
    }

    public init(original value: EffectiveHistoricalFinding)
        throws(HistoricalFindingVersionedIdentityError)
    {
        try self.init(
            recordID: .original(value.recordID),
            projectionID: .original(value.projectionID),
            comparisonSequence: value.comparisonSequence,
            positiveRank: value.positiveRank,
            draft: value.draft
        )
    }
}

public struct HistoricalCorrectedFindingRetractionRecord: Sendable, Equatable {
    public let recordID: HistoricalCorrectedRetractionRecordID
    public let requestID: HistoricalRetractionRequestID
    public let findingID: HistoricalCorrectedFindingRecordID
    public let reason: HistoricalFindingRetractionReason
    public let committedAt: ObservationInstant
    public let expiresAt: ObservationInstant

    public init(
        recordID: HistoricalCorrectedRetractionRecordID,
        requestID: HistoricalRetractionRequestID,
        findingID: HistoricalCorrectedFindingRecordID,
        reason: HistoricalFindingRetractionReason,
        committedAt: ObservationInstant,
        expiresAt: ObservationInstant
    ) throws(HistoricalFindingVersionedIdentityError) {
        guard committedAt <= expiresAt else {
            throw .correctedRetractionOutlivesTarget
        }
        self.recordID = recordID
        self.requestID = requestID
        self.findingID = findingID
        self.reason = reason
        self.committedAt = committedAt
        self.expiresAt = expiresAt
    }
}

public enum HistoricalFindingVersionedRetraction: Sendable, Equatable {
    case original(HistoricalFindingRetractionRecord)
    case corrected(HistoricalCorrectedFindingRetractionRecord)

    public var findingID: HistoricalFindingVersionID {
        switch self {
        case .original(let value): .original(value.findingID)
        case .corrected(let value): .corrected(value.findingID)
        }
    }

    public var committedAt: ObservationInstant {
        switch self {
        case .original(let value): value.committedAt
        case .corrected(let value): value.committedAt
        }
    }
}

public struct VersionedHistoricalFindingAuditRecord: Sendable, Equatable {
    public let finding: VersionedEffectiveHistoricalFinding
    public let draftSHA256: HistoricalEvidenceDigest
    public let retraction: HistoricalFindingVersionedRetraction?

    public init(
        finding: VersionedEffectiveHistoricalFinding,
        draftSHA256: HistoricalEvidenceDigest,
        retraction: HistoricalFindingVersionedRetraction?
    ) throws(HistoricalFindingVersionedIdentityError) {
        if let retraction, retraction.findingID != finding.recordID {
            throw .versionedRetractionTargetMismatch
        }
        self.finding = finding
        self.draftSHA256 = draftSHA256
        self.retraction = retraction
    }

    public init(original value: HistoricalFindingAuditRecord)
        throws(HistoricalFindingVersionedIdentityError)
    {
        try self.init(
            finding: VersionedEffectiveHistoricalFinding(original: value.finding),
            draftSHA256: value.draftSHA256,
            retraction: value.retraction.map(HistoricalFindingVersionedRetraction.original)
        )
    }
}

/// Minimal, validated audit root used by the integrity-only mutation path.
/// Public overview/audit models are reconstructed separately and remain
/// read-only; this value is package-scoped so UI code cannot manufacture an
/// invalidation target.
package struct HistoricalCorrectedFindingIntegrityAuditRecord: Sendable, Equatable {
    package let findingID: HistoricalCorrectedFindingRecordID
    package let projectionID: HistoricalCorrectingProjectionRecordID
    package let draftSHA256: HistoricalEvidenceDigest
    package let retraction: HistoricalCorrectedFindingRetractionRecord?

    package init(
        findingID: HistoricalCorrectedFindingRecordID,
        projectionID: HistoricalCorrectingProjectionRecordID,
        draftSHA256: HistoricalEvidenceDigest,
        retraction: HistoricalCorrectedFindingRetractionRecord?
    ) throws(HistoricalFindingVersionedIdentityError) {
        if let retraction, retraction.findingID != findingID {
            throw .correctedRetractionTargetMismatch
        }
        self.findingID = findingID
        self.projectionID = projectionID
        self.draftSHA256 = draftSHA256
        self.retraction = retraction
    }
}

package struct HistoricalCorrectedFindingEvidenceInvalidationCommand:
    Sendable, Equatable
{
    package let requestID: HistoricalRetractionRequestID
    package let findingID: HistoricalCorrectedFindingRecordID
    package let expectedDraftSHA256: HistoricalEvidenceDigest

    fileprivate init(
        requestID: HistoricalRetractionRequestID,
        storedAuditRecord: HistoricalCorrectedFindingIntegrityAuditRecord
    ) {
        self.requestID = requestID
        findingID = storedAuditRecord.findingID
        expectedDraftSHA256 = storedAuditRecord.draftSHA256
    }
}

package enum HistoricalCorrectedFindingIntegrityReconciliationAuthorizer {
    package static func authorizeEvidenceInvalidation(
        requestID: HistoricalRetractionRequestID,
        failure: HistoricalFindingIntegrityFailure,
        storedAuditRecord: HistoricalCorrectedFindingIntegrityAuditRecord
    ) throws(HistoricalFindingVersionedIdentityError)
        -> HistoricalCorrectedFindingEvidenceInvalidationCommand
    {
        _ = failure
        guard storedAuditRecord.retraction == nil else {
            throw .correctedFindingAlreadyRetracted
        }
        return HistoricalCorrectedFindingEvidenceInvalidationCommand(
            requestID: requestID,
            storedAuditRecord: storedAuditRecord
        )
    }
}

package enum HistoricalCorrectedRetractionCommitOutcome: Sendable, Equatable {
    case newlyCommitted(HistoricalCorrectedFindingRetractionRecord)
    case alreadyCommitted(HistoricalCorrectedFindingRetractionRecord)
}

package protocol HistoricalCorrectedFindingIntegrityReconciliationRepository: Sendable {
    func historicalCorrectedFindingIntegrityAuditRecord(
        id: HistoricalCorrectedFindingRecordID
    ) async throws -> HistoricalCorrectedFindingIntegrityAuditRecord?

    func commitCorrectedEvidenceInvalidation(
        _ command: HistoricalCorrectedFindingEvidenceInvalidationCommand
    ) async throws -> HistoricalCorrectedRetractionCommitOutcome
}

public enum HistoricalFindingVersionedIdentityError: Error, Sendable, Equatable {
    case invalidCorrectedFindingRecordID(Int64)
    case invalidCorrectedRetractionRecordID(Int64)
    case correctedRetractionTargetMismatch
    case correctedRetractionOutlivesTarget
    case correctedFindingAlreadyRetracted
    case findingProjectionSourceMismatch
    case invalidPositiveRank(Int)
    case findingComparisonSequenceMismatch
    case versionedRetractionTargetMismatch
}
