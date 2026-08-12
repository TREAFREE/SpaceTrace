import Foundation
import SpaceTraceAttribution
import SpaceTraceDomain

/// A sequence-free directory state that carries the two released directory
/// metrics under one shared evidence shape.
public enum HistoricalPairedObservationStateCandidate: Sendable, Equatable {
    case present(
        logicalBytes: ByteCount,
        allocatedBytes: ByteCount,
        measurementCoverage: ObservationCoverage
    )
    case absent
    case unknown(ObservationUnavailabilityReason)
}

/// One node in an endpoint-ID-free paired observation candidate.
public struct HistoricalPairedObservationNodeCandidate: Sendable, Equatable {
    public let subjectID: SubjectID
    public let identityBasis: ObservationSubjectIdentityBasis
    public let parentSubjectID: SubjectID?
    public let locationID: ObservationLocationID
    public let path: String
    public let displayName: String
    public let observedAt: ObservationInstant
    public let state: HistoricalPairedObservationStateCandidate
    public let directChildrenCoverage: ObservationCoverage
    public let classification: VersionedAttributionDecision?
    public let stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?

    public init(
        subjectID: SubjectID,
        identityBasis: ObservationSubjectIdentityBasis,
        parentSubjectID: SubjectID?,
        locationID: ObservationLocationID,
        path: String,
        displayName: String,
        observedAt: ObservationInstant,
        state: HistoricalPairedObservationStateCandidate,
        directChildrenCoverage: ObservationCoverage,
        classification: VersionedAttributionDecision?,
        stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?
    ) throws(HistoricalFindingPersistenceModelError) {
        guard isCanonicalPairedObservationPath(path) else {
            throw .invalidObservationModel(.invalidPath)
        }
        guard isValidPairedObservationDisplayName(displayName) else {
            throw .invalidObservationModel(.invalidDisplayName)
        }

        switch state {
        case .present(_, _, let coverage):
            guard coverage != .unknown else {
                throw .presentCannotUseUnknownCoverage
            }
            guard classification != nil else {
                throw .invalidObservationModel(.presentNodeRequiresClassification)
            }
        case .absent, .unknown:
            guard classification == nil else {
                throw .invalidObservationModel(.unavailableNodeCannotContainClassification)
            }
            guard directChildrenCoverage == .unknown else {
                throw .invalidObservationModel(
                    .unavailableNodeRequiresUnknownDirectChildrenCoverage
                )
            }
        }

        if stableIdentityEvidence != nil,
           identityBasis != .stableFileSystemObject {
            throw .invalidObservationModel(.stableIdentityEvidenceRequiresStableObjectBasis)
        }

        self.subjectID = subjectID
        self.identityBasis = identityBasis
        self.parentSubjectID = parentSubjectID
        self.locationID = locationID
        self.path = path
        self.displayName = displayName
        self.observedAt = observedAt
        self.state = state
        self.directChildrenCoverage = directChildrenCoverage
        self.classification = classification
        self.stableIdentityEvidence = stableIdentityEvidence
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.subjectID == rhs.subjectID
            && lhs.identityBasis == rhs.identityBasis
            && lhs.parentSubjectID == rhs.parentSubjectID
            && lhs.locationID == rhs.locationID
            && binaryEqual(lhs.path, rhs.path)
            && binaryEqual(lhs.displayName, rhs.displayName)
            && lhs.observedAt == rhs.observedAt
            && lhs.state == rhs.state
            && lhs.directChildrenCoverage == rhs.directChildrenCoverage
            && lhs.classification == rhs.classification
            && lhs.stableIdentityEvidence == rhs.stableIdentityEvidence
    }
}

/// One canonical shared directory tree awaiting database-owned node IDs and
/// two consecutive commit sequences.
public struct HistoricalPairedObservationCandidate: Sendable, Equatable {
    public let rootSubjectID: SubjectID
    public let rootPath: String
    public let nodes: [HistoricalPairedObservationNodeCandidate]
    public let scopeID: ScopeID
    public let volumeID: ObservationVolumeID
    public let mountGenerationID: ObservationMountGenerationID
    public let coverageEpochID: ObservationCoverageEpochID
    public let pathSemanticsVersion: ObservationSemanticsVersion
    public let measurementSemanticsVersion: ObservationSemanticsVersion

    public init(
        rootSubjectID: SubjectID,
        rootPath: String,
        nodes: [HistoricalPairedObservationNodeCandidate],
        scopeID: ScopeID,
        volumeID: ObservationVolumeID,
        mountGenerationID: ObservationMountGenerationID,
        coverageEpochID: ObservationCoverageEpochID,
        pathSemanticsVersion: ObservationSemanticsVersion,
        measurementSemanticsVersion: ObservationSemanticsVersion
    ) throws(HistoricalFindingPersistenceModelError) {
        let canonicalNodes = nodes.sorted(by: canonicalPairedObservationNodeOrder)
        guard Set(canonicalNodes.map(\.subjectID)).count == canonicalNodes.count else {
            throw .invalidObservationModel(.duplicateSubjectID)
        }
        guard let root = canonicalNodes.first(where: { $0.subjectID == rootSubjectID }) else {
            throw .invalidObservationModel(.missingRootNode)
        }
        if case .absent = root.state {
            throw .rootCannotBeAbsent
        }

        self.rootSubjectID = rootSubjectID
        self.rootPath = rootPath
        self.nodes = canonicalNodes
        self.scopeID = scopeID
        self.volumeID = volumeID
        self.mountGenerationID = mountGenerationID
        self.coverageEpochID = coverageEpochID
        self.pathSemanticsVersion = pathSemanticsVersion
        self.measurementSemanticsVersion = measurementSemanticsVersion

        let provisionalAssignments = Dictionary(
            uniqueKeysWithValues: canonicalNodes.enumerated().map { offset, node in
                (node.subjectID, Int64(offset + 1))
            }
        )
        let logicalSequence: ObservationCommitSequence
        let allocatedSequence: ObservationCommitSequence
        do {
            logicalSequence = try ObservationCommitSequence(1)
            allocatedSequence = try ObservationCommitSequence(2)
        } catch {
            throw .invalidEndpointConstruction
        }
        let materializer = HistoricalPairedObservationCommitMaterializer(candidate: self)
        _ = try materializer.materialize(
            storeGeneration: HistoricalStoreGeneration(
                validatedBytes: Array(repeating: 0xa5, count: 16)
            ),
            nodeIDs: provisionalAssignments,
            logicalSequence: logicalSequence,
            allocatedSequence: allocatedSequence
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootSubjectID == rhs.rootSubjectID
            && binaryEqual(lhs.rootPath, rhs.rootPath)
            && lhs.nodes == rhs.nodes
            && lhs.scopeID == rhs.scopeID
            && lhs.volumeID == rhs.volumeID
            && lhs.mountGenerationID == rhs.mountGenerationID
            && lhs.coverageEpochID == rhs.coverageEpochID
            && lhs.pathSemanticsVersion == rhs.pathSemanticsVersion
            && lhs.measurementSemanticsVersion == rhs.measurementSemanticsVersion
    }
}

public struct HistoricalCalibrationFinalizationRequest: Sendable, Equatable {
    public let runID: CalibrationRunID
    public let report: CalibrationReport
    public let workItem: DirtyRegionWorkItem
    public let streamID: EventStreamID
    public let observation: HistoricalPairedObservationCandidate

    package let disabledReceiptIDBytes: [UInt8]

    public init(
        runID: CalibrationRunID,
        report: CalibrationReport,
        workItem: DirtyRegionWorkItem,
        streamID: EventStreamID,
        observation: HistoricalPairedObservationCandidate
    ) throws(HistoricalFindingPersistenceModelError) {
        guard let receiptBytes = canonicalUUIDBytes(runID.rawValue) else {
            throw .invalidCanonicalRunID
        }

        self.runID = runID
        self.report = report
        self.workItem = workItem
        self.streamID = streamID
        self.observation = observation
        disabledReceiptIDBytes = receiptBytes
    }
}

public enum HistoricalCalibrationCommitDisposition: Sendable, Equatable {
    case newlyCommitted
    case alreadyCommitted
}

public struct HistoricalObservationFrameCommit: Sendable, Equatable {
    public let sequence: ObservationCommitSequence
    public let rootEndpointID: ObservationEndpointID
    public let endpointCount: Int

    public init(
        sequence: ObservationCommitSequence,
        rootEndpointID: ObservationEndpointID,
        endpointCount: Int
    ) throws(HistoricalFindingPersistenceModelError) {
        guard endpointCount > 0 else {
            throw .invalidEndpointCount(endpointCount)
        }
        self.sequence = sequence
        self.rootEndpointID = rootEndpointID
        self.endpointCount = endpointCount
    }
}

public struct HistoricalCalibrationCommit: Sendable, Equatable {
    public let disposition: HistoricalCalibrationCommitDisposition
    public let logical: HistoricalObservationFrameCommit
    public let allocated: HistoricalObservationFrameCommit
    public let reconciliationRevisions: [ReconciliationRevision]

    public init(
        disposition: HistoricalCalibrationCommitDisposition,
        logical: HistoricalObservationFrameCommit,
        allocated: HistoricalObservationFrameCommit,
        reconciliationRevisions: [ReconciliationRevision] = []
    ) {
        self.disposition = disposition
        self.logical = logical
        self.allocated = allocated
        self.reconciliationRevisions = reconciliationRevisions.sorted {
            $0.id < $1.id
        }
    }
}

public enum HistoricalCalibrationFinalizationOutcome: Sendable, Equatable {
    case published(HistoricalCalibrationCommit)
    case superseded
    case historyDisabled
}

public struct HistoricalPathHistoryPolicy: Sendable, Equatable, Hashable {
    public let retentionDays: Int

    public init(retentionDays: Int) throws(HistoricalFindingPersistenceModelError) {
        guard (0...30).contains(retentionDays) else {
            throw .invalidRetentionDays(retentionDays)
        }
        self.retentionDays = retentionDays
    }
}

public enum HistoricalPathHistoryAvailability: Sendable, Equatable {
    case historyDisabled
    case baselineUnavailable
    case available
}

public struct HistoricalRetractionRequestID: Sendable, Equatable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws(HistoricalFindingPersistenceModelError) {
        guard bytes.count == 16 else {
            throw .invalidRetractionRequestID
        }
        self.bytes = bytes
    }
}

public struct HistoricalEvidenceDigest: Sendable, Equatable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws(HistoricalFindingPersistenceModelError) {
        guard bytes.count == 32 else {
            throw .invalidEvidenceDigest
        }
        self.bytes = bytes
    }
}

public struct HistoricalFindingRecordID: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(HistoricalFindingPersistenceModelError) {
        guard rawValue > 0 else { throw .invalidRecordID(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HistoricalProjectionRecordID: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(HistoricalFindingPersistenceModelError) {
        guard rawValue > 0 else { throw .invalidRecordID(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HistoricalProjectionWorkID: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(HistoricalFindingPersistenceModelError) {
        guard rawValue > 0 else { throw .invalidRecordID(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HistoricalRetractionRecordID: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(HistoricalFindingPersistenceModelError) {
        guard rawValue > 0 else { throw .invalidRecordID(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HistoricalProjectionWork: Sendable, Equatable {
    public let recordID: HistoricalProjectionWorkID
    public let baselineSequence: ObservationCommitSequence
    public let comparisonSequence: ObservationCommitSequence
    public let algorithmVersion: HistoricalFindingAlgorithmVersion
    public let rankingPolicyVersion: HistoricalFindingRankingPolicyVersion
    public let positiveLimit: Int

    public init(
        recordID: HistoricalProjectionWorkID,
        baselineSequence: ObservationCommitSequence,
        comparisonSequence: ObservationCommitSequence,
        algorithmVersion: HistoricalFindingAlgorithmVersion,
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion,
        positiveLimit: Int
    ) throws(HistoricalFindingPersistenceModelError) {
        guard comparisonSequence > baselineSequence else {
            throw .nonIncreasingProjectionWork
        }
        guard algorithmVersion.rawValue == 1, rankingPolicyVersion.rawValue == 1 else {
            throw .unsupportedProjectionVersion
        }
        guard (1...100).contains(positiveLimit) else {
            throw .invalidProjectionPositiveLimit(positiveLimit)
        }
        self.recordID = recordID
        self.baselineSequence = baselineSequence
        self.comparisonSequence = comparisonSequence
        self.algorithmVersion = algorithmVersion
        self.rankingPolicyVersion = rankingPolicyVersion
        self.positiveLimit = positiveLimit
    }
}

public enum HistoricalProjectionCommitOutcome: Sendable, Equatable {
    case newlyCommitted(HistoricalProjectionRecordID)
    case alreadyCommitted(HistoricalProjectionRecordID)
}

public enum HistoricalFindingRetractionReason: Sendable, Equatable {
    case evidenceInvalidated
}

public struct HistoricalFindingRetractionRecord: Sendable, Equatable {
    public let recordID: HistoricalRetractionRecordID
    public let requestID: HistoricalRetractionRequestID
    public let findingID: HistoricalFindingRecordID
    public let reason: HistoricalFindingRetractionReason
    public let committedAt: ObservationInstant

    public init(
        recordID: HistoricalRetractionRecordID,
        requestID: HistoricalRetractionRequestID,
        findingID: HistoricalFindingRecordID,
        reason: HistoricalFindingRetractionReason,
        committedAt: ObservationInstant
    ) {
        self.recordID = recordID
        self.requestID = requestID
        self.findingID = findingID
        self.reason = reason
        self.committedAt = committedAt
    }
}

public enum HistoricalRetractionCommitOutcome: Sendable, Equatable {
    case newlyCommitted(HistoricalFindingRetractionRecord)
    case alreadyCommitted(HistoricalFindingRetractionRecord)
}

public struct HistoricalFindingEvidenceInvalidationCommand: Sendable, Equatable {
    public let requestID: HistoricalRetractionRequestID
    public let findingID: HistoricalFindingRecordID
    public let expectedDraftSHA256: HistoricalEvidenceDigest

    fileprivate init(
        requestID: HistoricalRetractionRequestID,
        storedAuditRecord: HistoricalFindingAuditRecord
    ) {
        self.requestID = requestID
        findingID = storedAuditRecord.finding.recordID
        expectedDraftSHA256 = storedAuditRecord.draftSHA256
    }
}

/// Evidence invalidation is deliberately narrower than a user action or a
/// classifier decision. Only an integrity workflow can provide one of these
/// typed failures, and neither case carries paths or mutable UI input.
enum HistoricalFindingIntegrityFailure: Sendable, Equatable {
    case ledgerIntegrityViolation
    case projectionIntegrityViolation
}

/// The sole Application-layer constructor for a retraction command. The
/// command copies immutable identity and digest evidence from the audit read;
/// callers cannot supply either field independently.
enum HistoricalFindingIntegrityReconciliationAuthorizer {
    static func authorizeEvidenceInvalidation(
        requestID: HistoricalRetractionRequestID,
        failure: HistoricalFindingIntegrityFailure,
        storedAuditRecord: HistoricalFindingAuditRecord
    ) throws(HistoricalFindingPersistenceModelError) -> HistoricalFindingEvidenceInvalidationCommand {
        _ = failure
        guard storedAuditRecord.retraction == nil else {
            throw .findingAlreadyRetracted
        }
        return HistoricalFindingEvidenceInvalidationCommand(
            requestID: requestID,
            storedAuditRecord: storedAuditRecord
        )
    }
}

public struct EffectiveHistoricalFinding: Sendable, Equatable {
    public let recordID: HistoricalFindingRecordID
    public let projectionID: HistoricalProjectionRecordID
    public let comparisonSequence: ObservationCommitSequence
    public let positiveRank: Int?
    public let draft: HistoricalFindingDraft

    public init(
        recordID: HistoricalFindingRecordID,
        projectionID: HistoricalProjectionRecordID,
        comparisonSequence: ObservationCommitSequence,
        positiveRank: Int?,
        draft: HistoricalFindingDraft
    ) throws(HistoricalFindingPersistenceModelError) {
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
}

public struct HistoricalFindingAuditRecord: Sendable, Equatable {
    public let finding: EffectiveHistoricalFinding
    public let draftSHA256: HistoricalEvidenceDigest
    public let retraction: HistoricalFindingRetractionRecord?

    public init(
        finding: EffectiveHistoricalFinding,
        draftSHA256: HistoricalEvidenceDigest,
        retraction: HistoricalFindingRetractionRecord?
    ) throws(HistoricalFindingPersistenceModelError) {
        if let retraction, retraction.findingID != finding.recordID {
            throw .retractionTargetMismatch
        }
        self.finding = finding
        self.draftSHA256 = draftSHA256
        self.retraction = retraction
    }
}

public struct HistoricalFindingQueryLimit: Sendable, Equatable, Hashable {
    public let rawValue: Int

    public init(_ rawValue: Int) throws(HistoricalFindingPersistenceModelError) {
        guard (1...1_000).contains(rawValue) else {
            throw .invalidQueryLimit(rawValue)
        }
        self.rawValue = rawValue
    }
}

/// The narrow persistence seam needed by the recoverable projection lifecycle.
/// Keeping it separate lets the pure application service be tested without an
/// event-journal or SQLite implementation.
public protocol HistoricalFindingProjectionRepository: Sendable {
    func historicalObservationFrame(
        sequence: ObservationCommitSequence
    ) async throws -> HistoricalFindingObservationFrame?

    func nextHistoricalProjectionWork() async throws -> HistoricalProjectionWork?

    func commitHistoricalProjection(
        _ result: HistoricalFindingGenerationResult,
        for work: HistoricalProjectionWork
    ) async throws -> HistoricalProjectionCommitOutcome
}

/// Narrow atomic publication seam used by the calibration pipeline.
public protocol HistoricalCalibrationFinalizationRepository: EventJournalRepository {
    func finalizeCalibrationWithHistoricalFrames(
        _ request: HistoricalCalibrationFinalizationRequest
    ) async throws -> HistoricalCalibrationFinalizationOutcome
}

/// Public history persistence boundary. Evidence invalidation is intentionally
/// absent: ordinary app, UI, classifier, and cleanup callers cannot request it.
public protocol HistoricalFindingOverviewRepository: Sendable {
    func effectiveHistoricalFindings(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) async throws -> [EffectiveHistoricalFinding]

    func historicalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) async throws -> [HistoricalFindingAuditRecord]

    func evidenceInvalidatedHistoricalFindingAuditRecords(
        for scopeID: ScopeID,
        through comparisonSequence: ObservationCommitSequence,
        limit: HistoricalFindingQueryLimit
    ) async throws -> [HistoricalFindingAuditRecord]

    func historicalPathHistoryPolicy() async throws -> HistoricalPathHistoryPolicy

    func historicalPathHistoryAvailability(
        for scopeID: ScopeID
    ) async throws -> HistoricalPathHistoryAvailability

    func setHistoricalPathHistoryPolicy(
        _ policy: HistoricalPathHistoryPolicy
    ) async throws
}

public protocol HistoricalFindingPersistenceRepository:
    HistoricalCalibrationFinalizationRepository,
    HistoricalFindingProjectionRepository,
    HistoricalFindingOverviewRepository
{
    func historicalFindingAuditRecord(
        id: HistoricalFindingRecordID
    ) async throws -> HistoricalFindingAuditRecord?

}

/// Package-only mutation surface for current-validity invalidation. v1 does
/// not model a replacement, correction projection, same-pair reprojection,
/// or an as-of correction view. Those require a versioned generator registry,
/// frozen correction input and work request, a schema migration, crash and
/// retention benchmarks, and an approved ADR-006 amendment.
package protocol HistoricalFindingIntegrityReconciliationRepository: Sendable {
    func commitEvidenceInvalidation(
        _ command: HistoricalFindingEvidenceInvalidationCommand
    ) async throws -> HistoricalRetractionCommitOutcome
}

// MARK: - Validation

public enum HistoricalFindingPersistenceModelError: Error, Sendable, Equatable {
    case invalidObservationModel(HistoricalFindingModelError)
    case presentCannotUseUnknownCoverage
    case rootCannotBeAbsent
    case invalidEndpointConstruction
    case invalidStoreGeneration
    case incompleteNodeIDAssignment
    case unexpectedNodeIDAssignment
    case invalidNodeID(Int64)
    case reusedNodeID(Int64)
    case nonConsecutiveCommitSequences
    case invalidCanonicalRunID
    case invalidEndpointCount(Int)
    case invalidRetentionDays(Int)
    case invalidQueryLimit(Int)
    case invalidRetractionRequestID
    case invalidEvidenceDigest
    case invalidRecordID(Int64)
    case nonIncreasingProjectionWork
    case unsupportedProjectionVersion
    case invalidProjectionPositiveLimit(Int)
    case invalidPositiveRank(Int)
    case findingComparisonSequenceMismatch
    case retractionTargetMismatch
    case findingAlreadyRetracted
}

package struct HistoricalStoreGeneration: Sendable, Equatable {
    package let bytes: [UInt8]

    package init(bytes: [UInt8]) throws(HistoricalFindingPersistenceModelError) {
        guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else {
            throw .invalidStoreGeneration
        }
        self.bytes = bytes
    }

    fileprivate init(validatedBytes bytes: [UInt8]) {
        self.bytes = bytes
    }
}

package struct HistoricalPairedMaterializedFrames: Sendable, Equatable {
    package let logical: HistoricalFindingObservationFrame
    package let allocated: HistoricalFindingObservationFrame
}

/// Converts a validated sequence-free candidate only after SQLite has assigned
/// its store generation, complete node-ID map, and consecutive frame markers.
/// Persistence must keep the result actor-local until the surrounding database
/// transaction commits; Task 1 deliberately provides no public materializer.
package struct HistoricalPairedObservationCommitMaterializer: Sendable {
    private let candidate: HistoricalPairedObservationCandidate

    package init(candidate: HistoricalPairedObservationCandidate) {
        self.candidate = candidate
    }

    package func materialize(
        storeGeneration: HistoricalStoreGeneration,
        nodeIDs: [SubjectID: Int64],
        logicalSequence: ObservationCommitSequence,
        allocatedSequence: ObservationCommitSequence
    ) throws(HistoricalFindingPersistenceModelError) -> HistoricalPairedMaterializedFrames {
        guard logicalSequence.rawValue < Int64.max,
              allocatedSequence.rawValue == logicalSequence.rawValue + 1 else {
            throw .nonConsecutiveCommitSequences
        }

        let candidateSubjects = Set(candidate.nodes.map(\.subjectID))
        let assignedSubjects = Set(nodeIDs.keys)
        guard assignedSubjects.isSubset(of: candidateSubjects) else {
            throw .unexpectedNodeIDAssignment
        }
        guard candidateSubjects == assignedSubjects else {
            throw .incompleteNodeIDAssignment
        }

        var observedNodeIDs: Set<Int64> = []
        for nodeID in nodeIDs.values {
            guard nodeID > 0 else { throw .invalidNodeID(nodeID) }
            guard observedNodeIDs.insert(nodeID).inserted else {
                throw .reusedNodeID(nodeID)
            }
        }

        let logical = try materializeFrame(
            metric: .logical,
            sequence: logicalSequence,
            storeGeneration: storeGeneration,
            nodeIDs: nodeIDs
        )
        let allocated = try materializeFrame(
            metric: .allocated,
            sequence: allocatedSequence,
            storeGeneration: storeGeneration,
            nodeIDs: nodeIDs
        )
        return HistoricalPairedMaterializedFrames(logical: logical, allocated: allocated)
    }

    private func materializeFrame(
        metric: StorageMetric,
        sequence: ObservationCommitSequence,
        storeGeneration: HistoricalStoreGeneration,
        nodeIDs: [SubjectID: Int64]
    ) throws(HistoricalFindingPersistenceModelError) -> HistoricalFindingObservationFrame {
        var endpointIDs: [SubjectID: ObservationEndpointID] = [:]
        for node in candidate.nodes {
            guard let nodeID = nodeIDs[node.subjectID] else {
                throw .incompleteNodeIDAssignment
            }
            do {
                endpointIDs[node.subjectID] = try ObservationEndpointID(
                    committedEndpointID(
                        storeGeneration: storeGeneration,
                        nodeID: nodeID,
                        metric: metric
                    )
                )
            } catch {
                throw .invalidEndpointConstruction
            }
        }

        var nodes: [HistoricalFindingNode] = []
        nodes.reserveCapacity(candidate.nodes.count)
        for node in candidate.nodes {
            guard let endpointID = endpointIDs[node.subjectID] else {
                throw .incompleteNodeIDAssignment
            }
            let state: ObservationEndpointState
            switch node.state {
            case let .present(logicalBytes, allocatedBytes, coverage):
                state = .present(
                    bytes: metric == .logical ? logicalBytes : allocatedBytes,
                    coverage: coverage
                )
            case .absent:
                guard let parentSubjectID = node.parentSubjectID,
                      let parentEndpointID = endpointIDs[parentSubjectID] else {
                    throw .invalidObservationModel(.nonRootNodeRequiresParent)
                }
                state = .absent(
                    ParentAbsenceReference(
                        parentEndpointID: parentEndpointID,
                        parentSubjectID: parentSubjectID
                    )
                )
            case .unknown(let reason):
                state = .unknown(reason)
            }

            let endpoint: ObservationEndpoint
            do {
                endpoint = try ObservationEndpoint(
                    id: endpointID,
                    scopeID: candidate.scopeID,
                    volumeID: candidate.volumeID,
                    mountGenerationID: candidate.mountGenerationID,
                    coverageEpochID: candidate.coverageEpochID,
                    subjectID: node.subjectID,
                    identityBasis: node.identityBasis,
                    locationID: node.locationID,
                    metric: metric,
                    pathSemanticsVersion: candidate.pathSemanticsVersion,
                    measurementSemanticsVersion: candidate.measurementSemanticsVersion,
                    sequence: sequence,
                    observedAt: node.observedAt,
                    state: state
                )
            } catch {
                throw .invalidEndpointConstruction
            }

            do {
                nodes.append(
                    try HistoricalFindingNode(
                        endpoint: endpoint,
                        parentSubjectID: node.parentSubjectID,
                        path: node.path,
                        displayName: node.displayName,
                        directChildrenCoverage: node.directChildrenCoverage,
                        classification: node.classification,
                        stableIdentityEvidence: node.stableIdentityEvidence
                    )
                )
            } catch let findingError {
                throw .invalidObservationModel(findingError)
            }
        }

        do {
            return try HistoricalFindingObservationFrame(
                rootSubjectID: candidate.rootSubjectID,
                rootPath: candidate.rootPath,
                nodes: nodes
            )
        } catch let findingError {
            throw .invalidObservationModel(findingError)
        }
    }
}

package extension HistoricalFindingObservationFrame {
    var rootEndpointID: ObservationEndpointID {
        nodes.first(where: { $0.endpoint.subjectID == rootSubjectID })?.endpoint.id
            ?? nodes[0].endpoint.id
    }
}

private func canonicalPairedObservationNodeOrder(
    _ lhs: HistoricalPairedObservationNodeCandidate,
    _ rhs: HistoricalPairedObservationNodeCandidate
) -> Bool {
    if lhs.subjectID != rhs.subjectID {
        return binaryPrecedes(lhs.subjectID.rawValue, rhs.subjectID.rawValue)
    }
    return binaryPrecedes(lhs.locationID.rawValue, rhs.locationID.rawValue)
}

private func committedEndpointID(
    storeGeneration: HistoricalStoreGeneration,
    nodeID: Int64,
    metric: StorageMetric
) -> String {
    let generation = storeGeneration.bytes.map { String(format: "%02x", $0) }.joined()
    let node = String(format: "%016llx", UInt64(nodeID))
    let metricCode = metric == .logical ? "01" : "02"
    return "st11:\(generation):\(node):\(metricCode)"
}

private func canonicalUUIDBytes(_ value: String) -> [UInt8]? {
    guard value.utf8.count == 36 else { return nil }
    let bytes = Array(value.utf8)
    let hyphenOffsets = Set([8, 13, 18, 23])
    var result: [UInt8] = []
    result.reserveCapacity(16)
    var pendingHighNibble: UInt8?

    for (offset, byte) in bytes.enumerated() {
        if hyphenOffsets.contains(offset) {
            guard byte == UInt8(ascii: "-") else { return nil }
            continue
        }
        let nibble: UInt8
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            nibble = byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            nibble = byte - UInt8(ascii: "a") + 10
        default:
            return nil
        }
        if let highNibble = pendingHighNibble {
            result.append((highNibble << 4) | nibble)
            pendingHighNibble = nil
        } else {
            pendingHighNibble = nibble
        }
    }
    guard pendingHighNibble == nil, result.count == 16 else { return nil }
    return result
}

private func isCanonicalPairedObservationPath(_ path: String) -> Bool {
    guard path.utf8.first == UInt8(ascii: "/"),
          path.utf8.contains(0) == false else {
        return false
    }
    if path == "/" { return true }
    guard path.hasSuffix("/") == false else { return false }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    return components.isEmpty == false
        && components.allSatisfy { component in
            component.isEmpty == false && component != "." && component != ".."
        }
}

private func isValidPairedObservationDisplayName(_ displayName: String) -> Bool {
    displayName.isEmpty == false
        && displayName != "."
        && displayName != ".."
        && displayName.contains("/") == false
        && displayName.utf8.contains(0) == false
}
