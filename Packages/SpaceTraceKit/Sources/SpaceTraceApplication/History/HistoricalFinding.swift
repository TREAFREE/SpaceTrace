import SpaceTraceAttribution
import SpaceTraceDomain

/// The filesystem node kind frozen alongside a stable-object reuse guard.
///
/// Finding projection v1 currently projects directory aggregates only. Keeping
/// the kind in the proof prevents a future inode reuse from being accepted across node
/// kinds without changing the durable contract.
public enum HistoricalFindingNodeKind: String, Sendable, Equatable, Hashable, Codable {
    case directory
}

/// Whether one stable object identity can be treated as unique in this frame.
///
/// This is scanner evidence, not a value inferred from a directory's POSIX
/// link count. Directory link counts do not have regular-file hard-link
/// semantics.
public enum HistoricalFindingLinkStatus: String, Sendable, Equatable, Hashable, Codable {
    case unique
    case ambiguous
    case unknown
}

/// Nanosecond-resolution filesystem birth time used only as an identity reuse
/// qualification. `ObservationInstant` is intentionally not reused here: its
/// millisecond precision is sufficient for UI timelines but can discard
/// filesystem identity evidence.
public struct HistoricalFindingBirthTime: Sendable, Equatable, Hashable, Comparable, Codable {
    public let secondsSince1970: Int64
    public let nanoseconds: Int32

    public init(
        secondsSince1970: Int64,
        nanoseconds: Int32
    ) throws(HistoricalFindingModelError) {
        guard secondsSince1970 >= 0,
              (0..<1_000_000_000).contains(nanoseconds)
        else {
            throw .invalidStableIdentityBirthTime
        }

        self.secondsSince1970 = secondsSince1970
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.secondsSince1970 != rhs.secondsSince1970 {
            return lhs.secondsSince1970 < rhs.secondsSince1970
        }
        return lhs.nanoseconds < rhs.nanoseconds
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: ["secondsSince1970", "nanoseconds"],
            typeName: "HistoricalFindingBirthTime"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                secondsSince1970: container.decode(Int64.self, forKey: .secondsSince1970),
                nanoseconds: container.decode(Int32.self, forKey: .nanoseconds)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .nanoseconds,
                in: container,
                debugDescription: "Filesystem birth time is outside its valid range."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case secondsSince1970
        case nanoseconds
    }
}

/// Evidence that prevents an opaque filesystem identity from being accepted
/// after the underlying inode or object number has been reused.
public enum HistoricalFindingIdentityReuseGuard: Sendable, Equatable, Hashable, Codable {
    case generationToken(String)
    case birthTime(HistoricalFindingBirthTime)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.generationToken(lhsToken), .generationToken(rhsToken)):
            binaryEqual(lhsToken, rhsToken)
        case let (.birthTime(lhsTime), .birthTime(rhsTime)):
            lhsTime == rhsTime
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .generationToken(let token):
            hasher.combine(0)
            hasher.combine(token.utf8.count)
            for byte in token.utf8 {
                hasher.combine(byte)
            }
        case .birthTime(let birthTime):
            hasher.combine(1)
            hasher.combine(birthTime)
        }
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: ["kind", "generationToken", "birthTime"],
            typeName: "HistoricalFindingIdentityReuseGuard"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .generationToken:
            guard container.contains(.birthTime) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .birthTime,
                    in: container,
                    debugDescription: "A generation-token guard cannot contain a birth time."
                )
            }
            let token = try container.decode(String.self, forKey: .generationToken)
            guard Self.isValidGenerationToken(token) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .generationToken,
                    in: container,
                    debugDescription: "A generation token must be non-empty and contain no NUL byte."
                )
            }
            self = .generationToken(token)
        case .birthTime:
            guard container.contains(.generationToken) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .generationToken,
                    in: container,
                    debugDescription: "A birth-time guard cannot contain a generation token."
                )
            }
            self = .birthTime(
                try container.decode(HistoricalFindingBirthTime.self, forKey: .birthTime)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .generationToken(let token):
            guard Self.isValidGenerationToken(token) else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "A generation token must be non-empty and contain no NUL byte."
                    )
                )
            }
            try container.encode(Kind.generationToken, forKey: .kind)
            try container.encode(token, forKey: .generationToken)
        case .birthTime(let birthTime):
            try container.encode(Kind.birthTime, forKey: .kind)
            try container.encode(birthTime, forKey: .birthTime)
        }
    }

    fileprivate var isValid: Bool {
        switch self {
        case .generationToken(let token):
            Self.isValidGenerationToken(token)
        case .birthTime:
            true
        }
    }

    private static func isValidGenerationToken(_ value: String) -> Bool {
        value.isEmpty == false
            && value.allSatisfy(\.isWhitespace) == false
            && value.utf8.contains(0) == false
    }

    private enum Kind: String, Codable {
        case generationToken = "generation_token"
        case birthTime = "birth_time"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case generationToken
        case birthTime
    }
}

/// The extra proof required before a stable-object endpoint comparison may be
/// promoted from a relocation candidate to a user-facing move finding.
public struct HistoricalFindingStableIdentityEvidence: Sendable, Equatable, Hashable, Codable {
    public let reuseGuard: HistoricalFindingIdentityReuseGuard
    public let nodeKind: HistoricalFindingNodeKind
    public let linkStatus: HistoricalFindingLinkStatus

    public init(
        reuseGuard: HistoricalFindingIdentityReuseGuard,
        nodeKind: HistoricalFindingNodeKind,
        linkStatus: HistoricalFindingLinkStatus
    ) throws(HistoricalFindingModelError) {
        guard reuseGuard.isValid else {
            throw .invalidStableIdentityReuseGuard
        }

        self.reuseGuard = reuseGuard
        self.nodeKind = nodeKind
        self.linkStatus = linkStatus
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: ["reuseGuard", "nodeKind", "linkStatus"],
            typeName: "HistoricalFindingStableIdentityEvidence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                reuseGuard: container.decode(
                    HistoricalFindingIdentityReuseGuard.self,
                    forKey: .reuseGuard
                ),
                nodeKind: container.decode(HistoricalFindingNodeKind.self, forKey: .nodeKind),
                linkStatus: container.decode(HistoricalFindingLinkStatus.self, forKey: .linkStatus)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .reuseGuard,
                in: container,
                debugDescription: "Stable identity evidence contains an invalid reuse guard."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reuseGuard
        case nodeKind
        case linkStatus
    }
}

/// One directory node in a single immutable observation frame.
///
/// `directChildrenCoverage` is deliberately independent from the endpoint's
/// measurement coverage. Complete aggregate bytes do not prove that the list
/// of immediate child directories was completely enumerated.
public struct HistoricalFindingNode: Sendable, Equatable, Hashable, Codable {
    public let endpoint: ObservationEndpoint
    public let parentSubjectID: SubjectID?
    public let path: String
    public let displayName: String
    public let directChildrenCoverage: ObservationCoverage
    public let classification: VersionedAttributionDecision?
    public let stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?

    public init(
        endpoint: ObservationEndpoint,
        parentSubjectID: SubjectID?,
        path: String,
        displayName: String,
        directChildrenCoverage: ObservationCoverage,
        classification: VersionedAttributionDecision?,
        stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?
    ) throws(HistoricalFindingModelError) {
        guard isCanonicalHistoricalFindingPath(path) else {
            throw .invalidPath
        }
        guard isValidHistoricalFindingDisplayName(displayName) else {
            throw .invalidDisplayName
        }

        switch endpoint.state {
        case .present:
            guard classification != nil else {
                throw .presentNodeRequiresClassification
            }
        case .absent, .unknown:
            guard classification == nil else {
                throw .unavailableNodeCannotContainClassification
            }
            guard directChildrenCoverage == .unknown else {
                throw .unavailableNodeRequiresUnknownDirectChildrenCoverage
            }
        }

        if stableIdentityEvidence != nil,
           endpoint.identityBasis != .stableFileSystemObject {
            throw .stableIdentityEvidenceRequiresStableObjectBasis
        }

        self.endpoint = endpoint
        self.parentSubjectID = parentSubjectID
        self.path = path
        self.displayName = displayName
        self.directChildrenCoverage = directChildrenCoverage
        self.classification = classification
        self.stableIdentityEvidence = stableIdentityEvidence
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: [
                "endpoint",
                "parentSubjectID",
                "path",
                "displayName",
                "directChildrenCoverage",
                "classification",
                "stableIdentityEvidence",
            ],
            typeName: "HistoricalFindingNode"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                endpoint: container.decode(ObservationEndpoint.self, forKey: .endpoint),
                parentSubjectID: container.decodeCanonicalOptional(
                    SubjectID.self,
                    forKey: .parentSubjectID
                ),
                path: container.decode(String.self, forKey: .path),
                displayName: container.decode(String.self, forKey: .displayName),
                directChildrenCoverage: container.decode(
                    ObservationCoverage.self,
                    forKey: .directChildrenCoverage
                ),
                classification: container.decodeCanonicalOptional(
                    VersionedAttributionDecision.self,
                    forKey: .classification
                ),
                stableIdentityEvidence: container.decodeCanonicalOptional(
                    HistoricalFindingStableIdentityEvidence.self,
                    forKey: .stableIdentityEvidence
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Historical finding node fields violate model invariants."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encodeIfPresent(parentSubjectID, forKey: .parentSubjectID)
        try container.encode(path, forKey: .path)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(directChildrenCoverage, forKey: .directChildrenCoverage)
        try container.encodeIfPresent(classification, forKey: .classification)
        try container.encodeIfPresent(stableIdentityEvidence, forKey: .stableIdentityEvidence)
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case parentSubjectID
        case path
        case displayName
        case directChildrenCoverage
        case classification
        case stableIdentityEvidence
    }
}

/// A validated, immutable directory-tree frame committed under one measurement
/// context and one monotonic sequence.
public struct HistoricalFindingObservationFrame: Sendable, Equatable, Hashable, Codable {
    public let rootSubjectID: SubjectID
    public let rootPath: String
    public let nodes: [HistoricalFindingNode]

    public let scopeID: ScopeID
    public let volumeID: ObservationVolumeID
    public let mountGenerationID: ObservationMountGenerationID
    public let coverageEpochID: ObservationCoverageEpochID
    public let metric: StorageMetric
    public let pathSemanticsVersion: ObservationSemanticsVersion
    public let measurementSemanticsVersion: ObservationSemanticsVersion
    public let sequence: ObservationCommitSequence

    public init(
        rootSubjectID: SubjectID,
        rootPath: String,
        nodes: [HistoricalFindingNode]
    ) throws(HistoricalFindingModelError) {
        guard isCanonicalHistoricalFindingPath(rootPath) else {
            throw .invalidPath
        }
        guard nodes.isEmpty == false else {
            throw .emptyFrame
        }

        let endpointIDs = Set(nodes.map(\.endpoint.id))
        guard endpointIDs.count == nodes.count else {
            throw .duplicateEndpointID
        }
        let subjectIDs = Set(nodes.map(\.endpoint.subjectID))
        guard subjectIDs.count == nodes.count else {
            throw .duplicateSubjectID
        }
        let locationIDs = Set(nodes.map(\.endpoint.locationID))
        guard locationIDs.count == nodes.count else {
            throw .duplicateLocationID
        }
        let binaryPaths = Set(nodes.map { Array($0.path.utf8) })
        guard binaryPaths.count == nodes.count else {
            throw .duplicatePath
        }

        guard let root = nodes.first(where: { $0.endpoint.subjectID == rootSubjectID }) else {
            throw .missingRootNode
        }
        guard root.parentSubjectID == nil,
              binaryEqual(root.path, rootPath)
        else {
            throw .invalidRootNode
        }
        guard root.endpoint.metric != .volumeAvailable else {
            throw .unsupportedDirectoryMetric
        }

        for node in nodes {
            guard node.endpoint.scopeID == root.endpoint.scopeID else {
                throw .inconsistentScope
            }
            guard node.endpoint.volumeID == root.endpoint.volumeID else {
                throw .inconsistentVolume
            }
            guard node.endpoint.mountGenerationID == root.endpoint.mountGenerationID else {
                throw .inconsistentMountGeneration
            }
            guard node.endpoint.coverageEpochID == root.endpoint.coverageEpochID else {
                throw .inconsistentCoverageEpoch
            }
            guard node.endpoint.metric == root.endpoint.metric else {
                throw .inconsistentMetric
            }
            guard node.endpoint.pathSemanticsVersion == root.endpoint.pathSemanticsVersion else {
                throw .inconsistentPathSemantics
            }
            guard node.endpoint.measurementSemanticsVersion
                == root.endpoint.measurementSemanticsVersion
            else {
                throw .inconsistentMeasurementSemantics
            }
            guard node.endpoint.sequence == root.endpoint.sequence else {
                throw .inconsistentSequence
            }
            guard isHistoricalFindingPath(node.path, containedIn: rootPath) else {
                throw .nodeOutsideRoot
            }
        }

        let nodesBySubject = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.endpoint.subjectID, $0) }
        )
        let nodesByEndpointID = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.endpoint.id, $0) }
        )
        for node in nodes where node.endpoint.subjectID != rootSubjectID {
            guard node.parentSubjectID != nil else {
                throw .nonRootNodeRequiresParent
            }
        }
        try Self.validateParentGraph(
            rootSubjectID: rootSubjectID,
            nodes: nodes,
            nodesBySubject: nodesBySubject
        )
        for node in nodes where node.endpoint.subjectID != rootSubjectID {
            guard let parentSubjectID = node.parentSubjectID,
                  let parent = nodesBySubject[parentSubjectID]
            else {
                throw .missingParent
            }
            guard binaryEqual(parent.path, directParentPath(of: node.path)) else {
                throw .nonDirectParent
            }
            guard case .present = parent.endpoint.state else {
                throw .unavailableParentCannotContainNode
            }
        }

        for node in nodes {
            guard case .absent(let reference) = node.endpoint.state else {
                continue
            }
            guard let parent = nodesByEndpointID[reference.parentEndpointID],
                  parent.endpoint.subjectID == reference.parentSubjectID,
                  node.parentSubjectID == reference.parentSubjectID,
                  binaryEqual(parent.path, directParentPath(of: node.path))
            else {
                throw .invalidAbsenceParentReference
            }
            guard case .present(_, .complete) = parent.endpoint.state,
                  parent.directChildrenCoverage == .complete
            else {
                throw .absenceParentEvidenceIncomplete
            }
        }

        let canonicalNodes = nodes.sorted(by: canonicalHistoricalFindingNodeOrder)
        self.rootSubjectID = rootSubjectID
        self.rootPath = rootPath
        self.nodes = canonicalNodes
        scopeID = root.endpoint.scopeID
        volumeID = root.endpoint.volumeID
        mountGenerationID = root.endpoint.mountGenerationID
        coverageEpochID = root.endpoint.coverageEpochID
        metric = root.endpoint.metric
        pathSemanticsVersion = root.endpoint.pathSemanticsVersion
        measurementSemanticsVersion = root.endpoint.measurementSemanticsVersion
        sequence = root.endpoint.sequence
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: ["rootSubjectID", "rootPath", "nodes"],
            typeName: "HistoricalFindingObservationFrame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedNodes = try container.decode(
            [HistoricalFindingNode].self,
            forKey: .nodes
        )
        guard decodedNodes == decodedNodes.sorted(by: canonicalHistoricalFindingNodeOrder) else {
            throw DecodingError.dataCorruptedError(
                forKey: .nodes,
                in: container,
                debugDescription: "Historical observation frame nodes are not canonically ordered."
            )
        }
        do {
            try self.init(
                rootSubjectID: container.decode(SubjectID.self, forKey: .rootSubjectID),
                rootPath: container.decode(String.self, forKey: .rootPath),
                nodes: decodedNodes
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Historical observation frame fields violate model invariants."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootSubjectID, forKey: .rootSubjectID)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(nodes, forKey: .nodes)
    }

    private static func validateParentGraph(
        rootSubjectID: SubjectID,
        nodes: [HistoricalFindingNode],
        nodesBySubject: [SubjectID: HistoricalFindingNode]
    ) throws(HistoricalFindingModelError) {
        var validated = Set([rootSubjectID])
        for node in nodes where validated.contains(node.endpoint.subjectID) == false {
            var chain: [SubjectID] = []
            var local = Set<SubjectID>()
            var subject = node.endpoint.subjectID

            while validated.contains(subject) == false {
                guard local.insert(subject).inserted else {
                    throw .cyclicParentGraph
                }
                chain.append(subject)
                guard let current = nodesBySubject[subject],
                      let parentSubjectID = current.parentSubjectID,
                      nodesBySubject[parentSubjectID] != nil
                else {
                    throw .missingParent
                }
                subject = parentSubjectID
            }
            validated.formUnion(chain)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rootSubjectID
        case rootPath
        case nodes
    }
}

public enum HistoricalFindingModelError: Error, Sendable, Equatable {
    case invalidAlgorithmVersion
    case invalidRankingPolicyVersion
    case invalidStableIdentityReuseGuard
    case invalidStableIdentityBirthTime
    case invalidPath
    case invalidDisplayName
    case presentNodeRequiresClassification
    case unavailableNodeCannotContainClassification
    case unavailableNodeRequiresUnknownDirectChildrenCoverage
    case stableIdentityEvidenceRequiresStableObjectBasis
    case emptyFrame
    case duplicateEndpointID
    case duplicateSubjectID
    case duplicateLocationID
    case duplicatePath
    case missingRootNode
    case invalidRootNode
    case unsupportedDirectoryMetric
    case inconsistentScope
    case inconsistentVolume
    case inconsistentMountGeneration
    case inconsistentCoverageEpoch
    case inconsistentMetric
    case inconsistentPathSemantics
    case inconsistentMeasurementSemantics
    case inconsistentSequence
    case nodeOutsideRoot
    case nonRootNodeRequiresParent
    case missingParent
    case cyclicParentGraph
    case nonDirectParent
    case unavailableParentCannotContainNode
    case invalidAbsenceParentReference
    case absenceParentEvidenceIncomplete
}

public struct HistoricalFindingAlgorithmVersion: Sendable, Equatable, Hashable, Comparable, Codable {
    public let rawValue: Int

    public init(_ rawValue: Int) throws(HistoricalFindingModelError) {
        guard rawValue > 0 else { throw .invalidAlgorithmVersion }
        self.rawValue = rawValue
    }

    init(validatedRawValue rawValue: Int) {
        precondition(rawValue > 0)
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(Int.self))
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Historical finding algorithm versions must be positive."
            )
        }
    }


    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct HistoricalFindingRankingPolicyVersion: Sendable, Equatable, Hashable, Comparable, Codable {
    public let rawValue: Int

    public init(_ rawValue: Int) throws(HistoricalFindingModelError) {
        guard rawValue > 0 else { throw .invalidRankingPolicyVersion }
        self.rawValue = rawValue
    }

    init(validatedRawValue rawValue: Int) {
        precondition(rawValue > 0)
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(Int.self))
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Historical finding ranking policy versions must be positive."
            )
        }
    }


    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum HistoricalFindingKind: String, Sendable, Equatable, Hashable, Codable {
    case growth
    case decrease
    case appearance
    case disappearance
    case move
}

/// A structured idempotency key. It deliberately avoids `Hasher`, UUIDs, and
/// delimiter-based string concatenation so the same immutable evidence always
/// reconstructs the same key.
public struct HistoricalFindingKey: Sendable, Equatable, Hashable, Comparable, Codable {
    public let algorithmVersion: HistoricalFindingAlgorithmVersion
    public let rankingPolicyVersion: HistoricalFindingRankingPolicyVersion
    public let baselineEndpointID: ObservationEndpointID
    public let comparisonEndpointID: ObservationEndpointID
    public let kind: HistoricalFindingKind
    public let baselineCatalogVersion: AttributionCatalogVersion?
    public let comparisonCatalogVersion: AttributionCatalogVersion?

    private init(
        algorithmVersion: HistoricalFindingAlgorithmVersion,
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion,
        baselineEndpointID: ObservationEndpointID,
        comparisonEndpointID: ObservationEndpointID,
        kind: HistoricalFindingKind,
        baselineCatalogVersion: AttributionCatalogVersion?,
        comparisonCatalogVersion: AttributionCatalogVersion?
    ) {
        self.algorithmVersion = algorithmVersion
        self.rankingPolicyVersion = rankingPolicyVersion
        self.baselineEndpointID = baselineEndpointID
        self.comparisonEndpointID = comparisonEndpointID
        self.kind = kind
        self.baselineCatalogVersion = baselineCatalogVersion
        self.comparisonCatalogVersion = comparisonCatalogVersion
    }

    static func make(
        kind: HistoricalFindingKind,
        evidence: HistoricalFindingEvidence
    ) -> Self {
        Self(
            algorithmVersion: evidence.algorithmVersion,
            rankingPolicyVersion: evidence.rankingPolicyVersion,
            baselineEndpointID: evidence.baselineEndpointID,
            comparisonEndpointID: evidence.comparisonEndpointID,
            kind: kind,
            baselineCatalogVersion: evidence.baselineClassificationDecision?.catalogVersion,
            comparisonCatalogVersion: evidence.comparisonClassificationDecision?.catalogVersion
        )
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.algorithmVersion != rhs.algorithmVersion {
            return lhs.algorithmVersion < rhs.algorithmVersion
        }
        if lhs.rankingPolicyVersion != rhs.rankingPolicyVersion {
            return lhs.rankingPolicyVersion < rhs.rankingPolicyVersion
        }
        if lhs.baselineEndpointID != rhs.baselineEndpointID {
            return lhs.baselineEndpointID < rhs.baselineEndpointID
        }
        if lhs.comparisonEndpointID != rhs.comparisonEndpointID {
            return lhs.comparisonEndpointID < rhs.comparisonEndpointID
        }
        if lhs.kind != rhs.kind {
            return binaryPrecedes(lhs.kind.rawValue, rhs.kind.rawValue)
        }
        let lhsBaselineVersion = lhs.baselineCatalogVersion?.rawValue ?? 0
        let rhsBaselineVersion = rhs.baselineCatalogVersion?.rawValue ?? 0
        if lhsBaselineVersion != rhsBaselineVersion {
            return lhsBaselineVersion < rhsBaselineVersion
        }
        return (lhs.comparisonCatalogVersion?.rawValue ?? 0)
            < (rhs.comparisonCatalogVersion?.rawValue ?? 0)
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: [
                "algorithmVersion",
                "rankingPolicyVersion",
                "baselineEndpointID",
                "comparisonEndpointID",
                "kind",
                "baselineCatalogVersion",
                "comparisonCatalogVersion",
            ],
            typeName: "HistoricalFindingKey"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            algorithmVersion: try container.decode(
                HistoricalFindingAlgorithmVersion.self,
                forKey: .algorithmVersion
            ),
            rankingPolicyVersion: try container.decode(
                HistoricalFindingRankingPolicyVersion.self,
                forKey: .rankingPolicyVersion
            ),
            baselineEndpointID: try container.decode(
                ObservationEndpointID.self,
                forKey: .baselineEndpointID
            ),
            comparisonEndpointID: try container.decode(
                ObservationEndpointID.self,
                forKey: .comparisonEndpointID
            ),
            kind: try container.decode(HistoricalFindingKind.self, forKey: .kind),
            baselineCatalogVersion: try container.decodeCanonicalOptional(
                AttributionCatalogVersion.self,
                forKey: .baselineCatalogVersion
            ),
            comparisonCatalogVersion: try container.decodeCanonicalOptional(
                AttributionCatalogVersion.self,
                forKey: .comparisonCatalogVersion
            )
        )
        guard hasValidDurableShape else {
            throw historicalFindingDecodingError(
                decoder,
                "Historical finding key reuses one endpoint identifier."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard hasValidDurableShape else {
            throw historicalFindingEncodingError(
                self,
                encoder,
                "Historical finding key reuses one endpoint identifier."
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(algorithmVersion, forKey: .algorithmVersion)
        try container.encode(rankingPolicyVersion, forKey: .rankingPolicyVersion)
        try container.encode(baselineEndpointID, forKey: .baselineEndpointID)
        try container.encode(comparisonEndpointID, forKey: .comparisonEndpointID)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(baselineCatalogVersion, forKey: .baselineCatalogVersion)
        try container.encodeIfPresent(comparisonCatalogVersion, forKey: .comparisonCatalogVersion)
    }

    fileprivate var hasValidDurableShape: Bool {
        algorithmVersion.rawValue == 1
            && rankingPolicyVersion.rawValue == 1
            && baselineEndpointID != comparisonEndpointID
    }

    private enum CodingKeys: String, CodingKey {
        case algorithmVersion
        case rankingPolicyVersion
        case baselineEndpointID
        case comparisonEndpointID
        case kind
        case baselineCatalogVersion
        case comparisonCatalogVersion
    }
}

public enum HistoricalFindingMovementContext: Sendable, Equatable, Hashable, Codable {
    case inheritedFromAncestor(HistoricalFindingKey)

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: ["kind", "ancestorKey"],
            typeName: "HistoricalFindingMovementContext"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .inheritedFromAncestor:
            self = .inheritedFromAncestor(
                try container.decode(HistoricalFindingKey.self, forKey: .ancestorKey)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inheritedFromAncestor(let ancestorKey):
            try container.encode(Kind.inheritedFromAncestor, forKey: .kind)
            try container.encode(ancestorKey, forKey: .ancestorKey)
        }
    }

    private enum Kind: String, Codable {
        case inheritedFromAncestor = "inherited_from_ancestor"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case ancestorKey
    }
}

/// Immutable evidence copied into a finding draft. Path-bearing fields remain
/// Sensitive local Application data and must never be emitted to Release logs
/// or path-free diagnostics.
public struct HistoricalFindingEvidence: Sendable, Equatable, Hashable, Codable {
    public let algorithmVersion: HistoricalFindingAlgorithmVersion
    public let rankingPolicyVersion: HistoricalFindingRankingPolicyVersion
    public let scopeID: ScopeID
    public let volumeID: ObservationVolumeID
    public let mountGenerationID: ObservationMountGenerationID
    public let coverageEpochID: ObservationCoverageEpochID
    public let metric: StorageMetric
    public let baselineEndpointID: ObservationEndpointID
    public let comparisonEndpointID: ObservationEndpointID
    public let sourceLocationID: ObservationLocationID
    public let destinationLocationID: ObservationLocationID
    public let baselinePath: String
    public let comparisonPath: String
    public let baselineDisplayName: String
    public let comparisonDisplayName: String
    public let baselineSequence: ObservationCommitSequence
    public let comparisonSequence: ObservationCommitSequence
    public let baselineTime: ObservationInstant
    public let comparisonTime: ObservationInstant
    public let baselineCoverage: ObservationCoverage
    public let comparisonCoverage: ObservationCoverage
    public let baselineClassificationDecision: VersionedAttributionDecision?
    public let comparisonClassificationDecision: VersionedAttributionDecision?
    public let baselineAbsenceReference: ParentAbsenceReference?
    public let comparisonAbsenceReference: ParentAbsenceReference?
    public let baselineStableIdentityEvidence: HistoricalFindingStableIdentityEvidence?
    public let comparisonStableIdentityEvidence: HistoricalFindingStableIdentityEvidence?

    init(
        algorithmVersion: HistoricalFindingAlgorithmVersion,
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion,
        baseline: HistoricalFindingNode,
        comparison: HistoricalFindingNode
    ) {
        self.algorithmVersion = algorithmVersion
        self.rankingPolicyVersion = rankingPolicyVersion
        scopeID = comparison.endpoint.scopeID
        volumeID = comparison.endpoint.volumeID
        mountGenerationID = comparison.endpoint.mountGenerationID
        coverageEpochID = comparison.endpoint.coverageEpochID
        metric = comparison.endpoint.metric
        baselineEndpointID = baseline.endpoint.id
        comparisonEndpointID = comparison.endpoint.id
        sourceLocationID = baseline.endpoint.locationID
        destinationLocationID = comparison.endpoint.locationID
        baselinePath = baseline.path
        comparisonPath = comparison.path
        baselineDisplayName = baseline.displayName
        comparisonDisplayName = comparison.displayName
        baselineSequence = baseline.endpoint.sequence
        comparisonSequence = comparison.endpoint.sequence
        baselineTime = baseline.endpoint.observedAt
        comparisonTime = comparison.endpoint.observedAt
        baselineCoverage = baseline.endpoint.state.findingEvidenceCoverage
        comparisonCoverage = comparison.endpoint.state.findingEvidenceCoverage
        baselineClassificationDecision = baseline.classification
        comparisonClassificationDecision = comparison.classification
        baselineAbsenceReference = baseline.endpoint.state.findingAbsenceReference
        comparisonAbsenceReference = comparison.endpoint.state.findingAbsenceReference
        baselineStableIdentityEvidence = baseline.stableIdentityEvidence
        comparisonStableIdentityEvidence = comparison.stableIdentityEvidence
        precondition(hasValidDurableShape)
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: [
                "algorithmVersion",
                "rankingPolicyVersion",
                "scopeID",
                "volumeID",
                "mountGenerationID",
                "coverageEpochID",
                "metric",
                "baselineEndpointID",
                "comparisonEndpointID",
                "sourceLocationID",
                "destinationLocationID",
                "baselinePath",
                "comparisonPath",
                "baselineDisplayName",
                "comparisonDisplayName",
                "baselineSequence",
                "comparisonSequence",
                "baselineTime",
                "comparisonTime",
                "baselineCoverage",
                "comparisonCoverage",
                "baselineClassificationDecision",
                "comparisonClassificationDecision",
                "baselineAbsenceReference",
                "comparisonAbsenceReference",
                "baselineStableIdentityEvidence",
                "comparisonStableIdentityEvidence",
            ],
            typeName: "HistoricalFindingEvidence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        algorithmVersion = try container.decode(
            HistoricalFindingAlgorithmVersion.self,
            forKey: .algorithmVersion
        )
        rankingPolicyVersion = try container.decode(
            HistoricalFindingRankingPolicyVersion.self,
            forKey: .rankingPolicyVersion
        )
        scopeID = try container.decode(ScopeID.self, forKey: .scopeID)
        volumeID = try container.decode(ObservationVolumeID.self, forKey: .volumeID)
        mountGenerationID = try container.decode(
            ObservationMountGenerationID.self,
            forKey: .mountGenerationID
        )
        coverageEpochID = try container.decode(
            ObservationCoverageEpochID.self,
            forKey: .coverageEpochID
        )
        metric = try container.decode(StorageMetric.self, forKey: .metric)
        baselineEndpointID = try container.decode(
            ObservationEndpointID.self,
            forKey: .baselineEndpointID
        )
        comparisonEndpointID = try container.decode(
            ObservationEndpointID.self,
            forKey: .comparisonEndpointID
        )
        sourceLocationID = try container.decode(
            ObservationLocationID.self,
            forKey: .sourceLocationID
        )
        destinationLocationID = try container.decode(
            ObservationLocationID.self,
            forKey: .destinationLocationID
        )
        baselinePath = try container.decode(String.self, forKey: .baselinePath)
        comparisonPath = try container.decode(String.self, forKey: .comparisonPath)
        baselineDisplayName = try container.decode(String.self, forKey: .baselineDisplayName)
        comparisonDisplayName = try container.decode(String.self, forKey: .comparisonDisplayName)
        baselineSequence = try container.decode(
            ObservationCommitSequence.self,
            forKey: .baselineSequence
        )
        comparisonSequence = try container.decode(
            ObservationCommitSequence.self,
            forKey: .comparisonSequence
        )
        baselineTime = try container.decode(ObservationInstant.self, forKey: .baselineTime)
        comparisonTime = try container.decode(ObservationInstant.self, forKey: .comparisonTime)
        baselineCoverage = try container.decode(
            ObservationCoverage.self,
            forKey: .baselineCoverage
        )
        comparisonCoverage = try container.decode(
            ObservationCoverage.self,
            forKey: .comparisonCoverage
        )
        baselineClassificationDecision = try container.decodeCanonicalOptional(
            VersionedAttributionDecision.self,
            forKey: .baselineClassificationDecision
        )
        comparisonClassificationDecision = try container.decodeCanonicalOptional(
            VersionedAttributionDecision.self,
            forKey: .comparisonClassificationDecision
        )
        baselineAbsenceReference = try container.decodeCanonicalOptional(
            ParentAbsenceReference.self,
            forKey: .baselineAbsenceReference
        )
        comparisonAbsenceReference = try container.decodeCanonicalOptional(
            ParentAbsenceReference.self,
            forKey: .comparisonAbsenceReference
        )
        baselineStableIdentityEvidence = try container.decodeCanonicalOptional(
            HistoricalFindingStableIdentityEvidence.self,
            forKey: .baselineStableIdentityEvidence
        )
        comparisonStableIdentityEvidence = try container.decodeCanonicalOptional(
            HistoricalFindingStableIdentityEvidence.self,
            forKey: .comparisonStableIdentityEvidence
        )

        guard hasValidDurableShape else {
            throw historicalFindingDecodingError(
                decoder,
                "Historical finding evidence fields violate immutable comparison invariants."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard hasValidDurableShape else {
            throw historicalFindingEncodingError(
                self,
                encoder,
                "Historical finding evidence fields violate immutable comparison invariants."
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(algorithmVersion, forKey: .algorithmVersion)
        try container.encode(rankingPolicyVersion, forKey: .rankingPolicyVersion)
        try container.encode(scopeID, forKey: .scopeID)
        try container.encode(volumeID, forKey: .volumeID)
        try container.encode(mountGenerationID, forKey: .mountGenerationID)
        try container.encode(coverageEpochID, forKey: .coverageEpochID)
        try container.encode(metric, forKey: .metric)
        try container.encode(baselineEndpointID, forKey: .baselineEndpointID)
        try container.encode(comparisonEndpointID, forKey: .comparisonEndpointID)
        try container.encode(sourceLocationID, forKey: .sourceLocationID)
        try container.encode(destinationLocationID, forKey: .destinationLocationID)
        try container.encode(baselinePath, forKey: .baselinePath)
        try container.encode(comparisonPath, forKey: .comparisonPath)
        try container.encode(baselineDisplayName, forKey: .baselineDisplayName)
        try container.encode(comparisonDisplayName, forKey: .comparisonDisplayName)
        try container.encode(baselineSequence, forKey: .baselineSequence)
        try container.encode(comparisonSequence, forKey: .comparisonSequence)
        try container.encode(baselineTime, forKey: .baselineTime)
        try container.encode(comparisonTime, forKey: .comparisonTime)
        try container.encode(baselineCoverage, forKey: .baselineCoverage)
        try container.encode(comparisonCoverage, forKey: .comparisonCoverage)
        try container.encodeIfPresent(
            baselineClassificationDecision,
            forKey: .baselineClassificationDecision
        )
        try container.encodeIfPresent(
            comparisonClassificationDecision,
            forKey: .comparisonClassificationDecision
        )
        try container.encodeIfPresent(baselineAbsenceReference, forKey: .baselineAbsenceReference)
        try container.encodeIfPresent(
            comparisonAbsenceReference,
            forKey: .comparisonAbsenceReference
        )
        try container.encodeIfPresent(
            baselineStableIdentityEvidence,
            forKey: .baselineStableIdentityEvidence
        )
        try container.encodeIfPresent(
            comparisonStableIdentityEvidence,
            forKey: .comparisonStableIdentityEvidence
        )
    }

    fileprivate var hasValidDurableShape: Bool {
        guard algorithmVersion.rawValue == 1,
              rankingPolicyVersion.rawValue == 1,
              baselineEndpointID != comparisonEndpointID,
              comparisonSequence > baselineSequence,
              metric != .volumeAvailable,
              baselineCoverage == .complete,
              comparisonCoverage == .complete,
              isCanonicalHistoricalFindingPath(baselinePath),
              isCanonicalHistoricalFindingPath(comparisonPath),
              isValidHistoricalFindingDisplayName(baselineDisplayName),
              isValidHistoricalFindingDisplayName(comparisonDisplayName),
              Self.isAvailableEvidenceSide(
                  classification: baselineClassificationDecision,
                  absenceReference: baselineAbsenceReference,
                  endpointID: baselineEndpointID
              ),
              Self.isAvailableEvidenceSide(
                  classification: comparisonClassificationDecision,
                  absenceReference: comparisonAbsenceReference,
                  endpointID: comparisonEndpointID
              ),
              baselineAbsenceReference?.parentEndpointID != comparisonEndpointID,
              comparisonAbsenceReference?.parentEndpointID != baselineEndpointID
        else {
            return false
        }
        return true
    }

    private static func isAvailableEvidenceSide(
        classification: VersionedAttributionDecision?,
        absenceReference: ParentAbsenceReference?,
        endpointID: ObservationEndpointID
    ) -> Bool {
        switch (classification, absenceReference) {
        case (.some, .none):
            true
        case (.none, .some(let reference)):
            reference.parentEndpointID != endpointID
        case (.none, .none), (.some, .some):
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case algorithmVersion
        case rankingPolicyVersion
        case scopeID
        case volumeID
        case mountGenerationID
        case coverageEpochID
        case metric
        case baselineEndpointID
        case comparisonEndpointID
        case sourceLocationID
        case destinationLocationID
        case baselinePath
        case comparisonPath
        case baselineDisplayName
        case comparisonDisplayName
        case baselineSequence
        case comparisonSequence
        case baselineTime
        case comparisonTime
        case baselineCoverage
        case comparisonCoverage
        case baselineClassificationDecision
        case comparisonClassificationDecision
        case baselineAbsenceReference
        case comparisonAbsenceReference
        case baselineStableIdentityEvidence
        case comparisonStableIdentityEvidence
    }
}

public struct HistoricalFindingDraft: Sendable, Equatable, Hashable, Codable {
    public let key: HistoricalFindingKey
    public let kind: HistoricalFindingKind
    public let evidence: HistoricalFindingEvidence
    public let inclusiveDelta: StorageDelta
    public let rankingContribution: StorageDelta?
    public let movementContext: HistoricalFindingMovementContext?

    init(
        kind: HistoricalFindingKind,
        evidence: HistoricalFindingEvidence,
        inclusiveDelta: StorageDelta,
        rankingContribution: StorageDelta?,
        movementContext: HistoricalFindingMovementContext?
    ) {
        self.kind = kind
        self.evidence = evidence
        self.inclusiveDelta = inclusiveDelta
        self.rankingContribution = rankingContribution
        self.movementContext = movementContext
        key = HistoricalFindingKey.make(kind: kind, evidence: evidence)
        precondition(hasValidDurableShape)
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: [
                "key",
                "kind",
                "evidence",
                "inclusiveDelta",
                "rankingContribution",
                "movementContext",
            ],
            typeName: "HistoricalFindingDraft"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(HistoricalFindingKey.self, forKey: .key)
        kind = try container.decode(HistoricalFindingKind.self, forKey: .kind)
        evidence = try container.decode(HistoricalFindingEvidence.self, forKey: .evidence)
        inclusiveDelta = try container.decode(StorageDelta.self, forKey: .inclusiveDelta)
        rankingContribution = try container.decodeCanonicalOptional(
            StorageDelta.self,
            forKey: .rankingContribution
        )
        movementContext = try container.decodeCanonicalOptional(
            HistoricalFindingMovementContext.self,
            forKey: .movementContext
        )
        guard hasValidDurableShape else {
            throw historicalFindingDecodingError(
                decoder,
                "Historical finding draft fields contradict their evidence or key."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard hasValidDurableShape else {
            throw historicalFindingEncodingError(
                self,
                encoder,
                "Historical finding draft fields contradict their evidence or key."
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(kind, forKey: .kind)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(inclusiveDelta, forKey: .inclusiveDelta)
        try container.encodeIfPresent(rankingContribution, forKey: .rankingContribution)
        try container.encodeIfPresent(movementContext, forKey: .movementContext)
    }

    fileprivate var hasValidDurableShape: Bool {
        guard evidence.hasValidDurableShape,
              key.hasValidDurableShape,
              key == HistoricalFindingKey.make(kind: kind, evidence: evidence),
              inclusiveDelta.metric == evidence.metric,
              rankingContribution?.metric == nil || rankingContribution?.metric == evidence.metric
        else {
            return false
        }

        let baselinePresent = evidence.baselineClassificationDecision != nil
            && evidence.baselineAbsenceReference == nil
        let comparisonPresent = evidence.comparisonClassificationDecision != nil
            && evidence.comparisonAbsenceReference == nil
        let baselineAbsent = evidence.baselineClassificationDecision == nil
            && evidence.baselineAbsenceReference != nil
        let comparisonAbsent = evidence.comparisonClassificationDecision == nil
            && evidence.comparisonAbsenceReference != nil

        switch kind {
        case .growth, .decrease:
            guard baselinePresent, comparisonPresent else { return false }
            guard (kind == .growth && inclusiveDelta.bytes > 0)
                    || (kind == .decrease && inclusiveDelta.bytes < 0)
            else {
                return false
            }
            switch movementContext {
            case nil:
                return evidence.sourceLocationID == evidence.destinationLocationID
            case .inheritedFromAncestor(let ancestorKey):
                return evidence.sourceLocationID != evidence.destinationLocationID
                    && ancestorKey.kind == .move
                    && ancestorKey.algorithmVersion == evidence.algorithmVersion
                    && ancestorKey.rankingPolicyVersion == evidence.rankingPolicyVersion
                    && ancestorKey != key
                    && hasQualifiedStableIdentityPair
            }
        case .appearance:
            return baselineAbsent
                && comparisonPresent
                && inclusiveDelta.bytes >= 0
                && rankingContribution == inclusiveDelta
                && movementContext == nil
                && evidence.sourceLocationID == evidence.destinationLocationID
        case .disappearance:
            return baselinePresent
                && comparisonAbsent
                && inclusiveDelta.bytes <= 0
                && rankingContribution == inclusiveDelta
                && movementContext == nil
                && evidence.sourceLocationID == evidence.destinationLocationID
        case .move:
            return baselinePresent
                && comparisonPresent
                && evidence.sourceLocationID != evidence.destinationLocationID
                && rankingContribution == nil
                && movementContext == nil
                && hasQualifiedStableIdentityPair
        }
    }

    private var hasQualifiedStableIdentityPair: Bool {
        guard let baseline = evidence.baselineStableIdentityEvidence,
              let comparison = evidence.comparisonStableIdentityEvidence
        else {
            return false
        }
        return baseline.reuseGuard == comparison.reuseGuard
            && baseline.nodeKind == comparison.nodeKind
            && baseline.linkStatus == .unique
            && comparison.linkStatus == .unique
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case kind
        case evidence
        case inclusiveDelta
        case rankingContribution
        case movementContext
    }
}

public enum HistoricalFindingReason: String, Sendable, Equatable, Hashable, Codable {
    case frameRootSubjectMismatch = "frame_root_subject_mismatch"
    case frameScopeMismatch = "frame_scope_mismatch"
    case frameVolumeMismatch = "frame_volume_mismatch"
    case frameMountGenerationMismatch = "frame_mount_generation_mismatch"
    case frameCoverageEpochMismatch = "frame_coverage_epoch_mismatch"
    case frameMetricMismatch = "frame_metric_mismatch"
    case framePathSemanticsMismatch = "frame_path_semantics_mismatch"
    case frameMeasurementSemanticsMismatch = "frame_measurement_semantics_mismatch"
    case frameNonIncreasingSequence = "frame_non_increasing_sequence"
    case missingBaselineEndpoint = "missing_baseline_endpoint"
    case missingComparisonEndpoint = "missing_comparison_endpoint"
    case endpointScopeMismatch = "endpoint_scope_mismatch"
    case endpointVolumeMismatch = "endpoint_volume_mismatch"
    case endpointMountGenerationMismatch = "endpoint_mount_generation_mismatch"
    case endpointCoverageEpochMismatch = "endpoint_coverage_epoch_mismatch"
    case endpointSubjectMismatch = "endpoint_subject_mismatch"
    case endpointIdentityBasisMismatch = "endpoint_identity_basis_mismatch"
    case endpointMetricMismatch = "endpoint_metric_mismatch"
    case endpointPathSemanticsMismatch = "endpoint_path_semantics_mismatch"
    case endpointMeasurementSemanticsMismatch = "endpoint_measurement_semantics_mismatch"
    case endpointNonIncreasingSequence = "endpoint_non_increasing_sequence"
    case endpointIncompleteCoverage = "endpoint_incomplete_coverage"
    case endpointUnavailable = "endpoint_unavailable"
    case endpointLocationChangedWithoutStableIdentity = "endpoint_location_changed_without_stable_identity"
    case endpointLocationChangedWithoutTwoPresentEndpoints = "endpoint_location_changed_without_two_present_endpoints"
    case stableIdentityEvidenceMissing = "stable_identity_evidence_missing"
    case stableIdentityReuseGuardMismatch = "stable_identity_reuse_guard_mismatch"
    case stableIdentityNodeKindMismatch = "stable_identity_node_kind_mismatch"
    case stableIdentityLinkSetNotUnique = "stable_identity_link_set_not_unique"
    case moveParentEvidenceIncomplete = "move_parent_evidence_incomplete"
    case rankingIncompleteDirectChildren = "ranking_incomplete_direct_children"
    case rankingIncompleteChildMeasurement = "ranking_incomplete_child_measurement"
    case rankingKindIneligible = "ranking_kind_ineligible"
    case rankingNonPositiveContribution = "ranking_non_positive_contribution"
    case collapsedImplicitDescendantMove = "collapsed_implicit_descendant_move"
    case collapsedInheritedMoveFacet = "collapsed_inherited_move_facet"
    case coveredByAncestorAppearance = "covered_by_ancestor_appearance"
    case coveredByAncestorDisappearance = "covered_by_ancestor_disappearance"
}

private enum HistoricalFindingReasonCategory {
    case findingSuppression
    case rankingExclusion
    case collapse
}

private extension HistoricalFindingReason {
    var category: HistoricalFindingReasonCategory {
        switch self {
        case .rankingIncompleteDirectChildren,
             .rankingIncompleteChildMeasurement,
             .rankingKindIneligible,
             .rankingNonPositiveContribution:
            .rankingExclusion
        case .collapsedImplicitDescendantMove,
             .collapsedInheritedMoveFacet,
             .coveredByAncestorAppearance,
             .coveredByAncestorDisappearance:
            .collapse
        default:
            .findingSuppression
        }
    }

    var isFrameIncompatibility: Bool {
        switch self {
        case .frameRootSubjectMismatch,
             .frameScopeMismatch,
             .frameVolumeMismatch,
             .frameMountGenerationMismatch,
             .frameCoverageEpochMismatch,
             .frameMetricMismatch,
             .framePathSemanticsMismatch,
             .frameMeasurementSemanticsMismatch,
             .frameNonIncreasingSequence:
            true
        default:
            false
        }
    }
}

public struct HistoricalFindingReasonCount: Sendable, Equatable, Hashable, Codable {
    public let reason: HistoricalFindingReason
    public let count: Int

    init(reason: HistoricalFindingReason, count: Int) {
        precondition(count > 0)
        self.reason = reason
        self.count = count
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: ["reason", "count"],
            typeName: "HistoricalFindingReasonCount"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decode(HistoricalFindingReason.self, forKey: .reason)
        count = try container.decode(Int.self, forKey: .count)
        guard count > 0 else {
            throw historicalFindingDecodingError(
                decoder,
                "Historical finding reason counts must be positive."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard count > 0 else {
            throw historicalFindingEncodingError(
                self,
                encoder,
                "Historical finding reason counts must be positive."
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encode(count, forKey: .count)
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case count
    }
}

public struct HistoricalFindingSuppressionSummary: Sendable, Equatable, Hashable, Codable {
    public let findingSuppressions: [HistoricalFindingReasonCount]
    public let rankingExclusions: [HistoricalFindingReasonCount]
    public let collapses: [HistoricalFindingReasonCount]
    public let truncatedPositiveCount: Int

    init(
        findingSuppressions: [HistoricalFindingReasonCount],
        rankingExclusions: [HistoricalFindingReasonCount],
        collapses: [HistoricalFindingReasonCount],
        truncatedPositiveCount: Int
    ) {
        precondition(
            Self.hasCanonicalCounts(
                findingSuppressions,
                category: .findingSuppression
            )
        )
        precondition(
            Self.hasCanonicalCounts(
                rankingExclusions,
                category: .rankingExclusion
            )
        )
        precondition(Self.hasCanonicalCounts(collapses, category: .collapse))
        precondition(truncatedPositiveCount >= 0)
        self.findingSuppressions = findingSuppressions
        self.rankingExclusions = rankingExclusions
        self.collapses = collapses
        self.truncatedPositiveCount = truncatedPositiveCount
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: [
                "findingSuppressions",
                "rankingExclusions",
                "collapses",
                "truncatedPositiveCount",
            ],
            typeName: "HistoricalFindingSuppressionSummary"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        findingSuppressions = try container.decode(
            [HistoricalFindingReasonCount].self,
            forKey: .findingSuppressions
        )
        rankingExclusions = try container.decode(
            [HistoricalFindingReasonCount].self,
            forKey: .rankingExclusions
        )
        collapses = try container.decode(
            [HistoricalFindingReasonCount].self,
            forKey: .collapses
        )
        truncatedPositiveCount = try container.decode(
            Int.self,
            forKey: .truncatedPositiveCount
        )
        guard hasValidDurableShape else {
            throw historicalFindingDecodingError(
                decoder,
                "Historical finding suppression summary is non-canonical or miscategorized."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard hasValidDurableShape else {
            throw historicalFindingEncodingError(
                self,
                encoder,
                "Historical finding suppression summary is non-canonical or miscategorized."
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(findingSuppressions, forKey: .findingSuppressions)
        try container.encode(rankingExclusions, forKey: .rankingExclusions)
        try container.encode(collapses, forKey: .collapses)
        try container.encode(truncatedPositiveCount, forKey: .truncatedPositiveCount)
    }

    fileprivate var hasValidDurableShape: Bool {
        truncatedPositiveCount >= 0
            && Self.hasCanonicalCounts(
                findingSuppressions,
                category: .findingSuppression
            )
            && Self.hasCanonicalCounts(
                rankingExclusions,
                category: .rankingExclusion
            )
            && Self.hasCanonicalCounts(collapses, category: .collapse)
    }

    private static func hasCanonicalCounts(
        _ values: [HistoricalFindingReasonCount],
        category: HistoricalFindingReasonCategory
    ) -> Bool {
        guard values.allSatisfy({ $0.count > 0 && $0.reason.category == category }) else {
            return false
        }
        return zip(values, values.dropFirst()).allSatisfy { lhs, rhs in
            binaryPrecedes(lhs.reason.rawValue, rhs.reason.rawValue)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case findingSuppressions
        case rankingExclusions
        case collapses
        case truncatedPositiveCount
    }
}

public struct HistoricalFindingBatch: Sendable, Equatable, Hashable, Codable {
    public let baselineRootEndpointID: ObservationEndpointID
    public let comparisonRootEndpointID: ObservationEndpointID
    public let baselineSequence: ObservationCommitSequence
    public let comparisonSequence: ObservationCommitSequence
    public let algorithmVersion: HistoricalFindingAlgorithmVersion
    public let rankingPolicyVersion: HistoricalFindingRankingPolicyVersion
    public let positiveLimit: Int
    public let findings: [HistoricalFindingDraft]
    public let rankedPositiveFindingKeys: [HistoricalFindingKey]

    init(
        baselineRootEndpointID: ObservationEndpointID,
        comparisonRootEndpointID: ObservationEndpointID,
        baselineSequence: ObservationCommitSequence,
        comparisonSequence: ObservationCommitSequence,
        algorithmVersion: HistoricalFindingAlgorithmVersion,
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion,
        positiveLimit: Int,
        findings: [HistoricalFindingDraft],
        rankedPositiveFindingKeys: [HistoricalFindingKey]
    ) {
        self.baselineRootEndpointID = baselineRootEndpointID
        self.comparisonRootEndpointID = comparisonRootEndpointID
        self.baselineSequence = baselineSequence
        self.comparisonSequence = comparisonSequence
        self.algorithmVersion = algorithmVersion
        self.rankingPolicyVersion = rankingPolicyVersion
        self.positiveLimit = positiveLimit
        self.findings = findings
        self.rankedPositiveFindingKeys = rankedPositiveFindingKeys
        precondition(hasValidEmbeddedShape)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, allowNonIncreasingSequence: false)
    }

    fileprivate init(embeddedFrom decoder: any Decoder) throws {
        try self.init(from: decoder, allowNonIncreasingSequence: true)
    }

    private init(
        from decoder: any Decoder,
        allowNonIncreasingSequence: Bool
    ) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: [
                "baselineRootEndpointID",
                "comparisonRootEndpointID",
                "baselineSequence",
                "comparisonSequence",
                "algorithmVersion",
                "rankingPolicyVersion",
                "positiveLimit",
                "findings",
                "rankedPositiveFindingKeys",
            ],
            typeName: "HistoricalFindingBatch"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baselineRootEndpointID = try container.decode(
            ObservationEndpointID.self,
            forKey: .baselineRootEndpointID
        )
        comparisonRootEndpointID = try container.decode(
            ObservationEndpointID.self,
            forKey: .comparisonRootEndpointID
        )
        baselineSequence = try container.decode(
            ObservationCommitSequence.self,
            forKey: .baselineSequence
        )
        comparisonSequence = try container.decode(
            ObservationCommitSequence.self,
            forKey: .comparisonSequence
        )
        algorithmVersion = try container.decode(
            HistoricalFindingAlgorithmVersion.self,
            forKey: .algorithmVersion
        )
        rankingPolicyVersion = try container.decode(
            HistoricalFindingRankingPolicyVersion.self,
            forKey: .rankingPolicyVersion
        )
        positiveLimit = try container.decode(Int.self, forKey: .positiveLimit)
        findings = try container.decode([HistoricalFindingDraft].self, forKey: .findings)
        rankedPositiveFindingKeys = try container.decode(
            [HistoricalFindingKey].self,
            forKey: .rankedPositiveFindingKeys
        )
        guard hasValidShape(allowNonIncreasingSequence: allowNonIncreasingSequence) else {
            throw historicalFindingDecodingError(
                decoder,
                "Historical finding batch is internally inconsistent or non-canonical."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try encode(to: encoder, allowNonIncreasingSequence: false)
    }

    fileprivate func encodeEmbedded(to encoder: any Encoder) throws {
        try encode(to: encoder, allowNonIncreasingSequence: true)
    }

    private func encode(
        to encoder: any Encoder,
        allowNonIncreasingSequence: Bool
    ) throws {
        guard hasValidShape(allowNonIncreasingSequence: allowNonIncreasingSequence) else {
            throw historicalFindingEncodingError(
                self,
                encoder,
                "Historical finding batch is internally inconsistent or non-canonical."
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baselineRootEndpointID, forKey: .baselineRootEndpointID)
        try container.encode(comparisonRootEndpointID, forKey: .comparisonRootEndpointID)
        try container.encode(baselineSequence, forKey: .baselineSequence)
        try container.encode(comparisonSequence, forKey: .comparisonSequence)
        try container.encode(algorithmVersion, forKey: .algorithmVersion)
        try container.encode(rankingPolicyVersion, forKey: .rankingPolicyVersion)
        try container.encode(positiveLimit, forKey: .positiveLimit)
        try container.encode(findings, forKey: .findings)
        try container.encode(rankedPositiveFindingKeys, forKey: .rankedPositiveFindingKeys)
    }

    fileprivate var hasValidDurableShape: Bool {
        hasValidShape(allowNonIncreasingSequence: false)
    }

    fileprivate var hasValidEmbeddedShape: Bool {
        hasValidShape(allowNonIncreasingSequence: true)
    }

    private func hasValidShape(allowNonIncreasingSequence: Bool) -> Bool {
        guard baselineRootEndpointID != comparisonRootEndpointID,
              comparisonSequence > baselineSequence
                || (
                    allowNonIncreasingSequence
                        && findings.isEmpty
                        && rankedPositiveFindingKeys.isEmpty
                ),
              algorithmVersion.rawValue == 1,
              rankingPolicyVersion.rawValue == 1,
              (1...100).contains(positiveLimit),
              zip(findings, findings.dropFirst()).allSatisfy({ pair in
                  pair.0.key < pair.1.key
              }),
              findings.allSatisfy({ finding in
                  finding.hasValidDurableShape
                      && finding.evidence.algorithmVersion == algorithmVersion
                      && finding.evidence.rankingPolicyVersion == rankingPolicyVersion
                      && finding.evidence.baselineSequence == baselineSequence
                      && finding.evidence.comparisonSequence == comparisonSequence
              })
        else {
            return false
        }


        if let firstEvidence = findings.first?.evidence {
            guard findings.dropFirst().allSatisfy({ finding in
                let evidence = finding.evidence
                return evidence.scopeID == firstEvidence.scopeID
                    && evidence.volumeID == firstEvidence.volumeID
                    && evidence.mountGenerationID == firstEvidence.mountGenerationID
                    && evidence.coverageEpochID == firstEvidence.coverageEpochID
                    && evidence.metric == firstEvidence.metric
            }) else {
                return false
            }
        }

        let baselineFindingEndpointIDs = findings.map(\.evidence.baselineEndpointID)
        let comparisonFindingEndpointIDs = findings.map(\.evidence.comparisonEndpointID)
        guard Set(baselineFindingEndpointIDs).count == baselineFindingEndpointIDs.count,
              Set(comparisonFindingEndpointIDs).count == comparisonFindingEndpointIDs.count
        else {
            return false
        }
        let baselineAbsenceParentIDs = findings.compactMap(
            \.evidence.baselineAbsenceReference?.parentEndpointID
        )
        let comparisonAbsenceParentIDs = findings.compactMap(
            \.evidence.comparisonAbsenceReference?.parentEndpointID
        )
        let baselineEndpointIDs = Set(
            baselineFindingEndpointIDs + baselineAbsenceParentIDs + [baselineRootEndpointID]
        )
        let comparisonEndpointIDs = Set(
            comparisonFindingEndpointIDs
                + comparisonAbsenceParentIDs
                + [comparisonRootEndpointID]
        )
        guard baselineEndpointIDs.isDisjoint(with: comparisonEndpointIDs) else {
            return false
        }

        let findingsByKey = Dictionary(uniqueKeysWithValues: findings.map { ($0.key, $0) })
        for finding in findings {
            guard case .inheritedFromAncestor(let ancestorKey) = finding.movementContext else {
                continue
            }
            guard let ancestor = findingsByKey[ancestorKey],
                  ancestor.kind == .move,
                  let baselineSuffix = relativeHistoricalFindingPathBytes(
                      finding.evidence.baselinePath,
                      below: ancestor.evidence.baselinePath
                  ),
                  let comparisonSuffix = relativeHistoricalFindingPathBytes(
                      finding.evidence.comparisonPath,
                      below: ancestor.evidence.comparisonPath
                  ),
                  baselineSuffix == comparisonSuffix
            else {
                return false
            }
        }

        let expectedRankedKeys = findings
            .filter(\.isEligiblePositiveFinding)
            .sorted(by: stablePositiveFindingOrder)
            .prefix(positiveLimit)
            .map(\.key)
        return rankedPositiveFindingKeys == expectedRankedKeys
    }

    fileprivate var eligiblePositiveFindingCount: Int {
        findings.lazy.filter(\.isEligiblePositiveFinding).count
    }

    private enum CodingKeys: String, CodingKey {
        case baselineRootEndpointID
        case comparisonRootEndpointID
        case baselineSequence
        case comparisonSequence
        case algorithmVersion
        case rankingPolicyVersion
        case positiveLimit
        case findings
        case rankedPositiveFindingKeys
    }
}

public struct HistoricalFindingGenerationResult: Sendable, Equatable, Hashable, Codable {
    public let batch: HistoricalFindingBatch
    public let suppressionSummary: HistoricalFindingSuppressionSummary

    init(
        batch: HistoricalFindingBatch,
        suppressionSummary: HistoricalFindingSuppressionSummary
    ) {
        self.batch = batch
        self.suppressionSummary = suppressionSummary
        precondition(hasValidDurableShape)
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownHistoricalFindingKeys(
            in: decoder,
            allowed: ["batch", "suppressionSummary"],
            typeName: "HistoricalFindingGenerationResult"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batch = try HistoricalFindingBatch(
            embeddedFrom: container.superDecoder(forKey: .batch)
        )
        suppressionSummary = try container.decode(
            HistoricalFindingSuppressionSummary.self,
            forKey: .suppressionSummary
        )
        guard hasValidDurableShape else {
            throw historicalFindingDecodingError(
                decoder,
                "Historical finding result summary contradicts its retained batch."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard hasValidDurableShape else {
            throw historicalFindingEncodingError(
                self,
                encoder,
                "Historical finding result summary contradicts its retained batch."
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try batch.encodeEmbedded(to: container.superEncoder(forKey: .batch))
        try container.encode(suppressionSummary, forKey: .suppressionSummary)
    }

    private var hasValidDurableShape: Bool {
        guard batch.hasValidEmbeddedShape, suppressionSummary.hasValidDurableShape else {
            return false
        }
        let eligibleCount = batch.eligiblePositiveFindingCount
        guard suppressionSummary.truncatedPositiveCount
                == eligibleCount - batch.rankedPositiveFindingKeys.count
        else {
            return false
        }

        let frameSuppressions = suppressionSummary.findingSuppressions.filter {
            $0.reason.isFrameIncompatibility
        }
        if frameSuppressions.isEmpty == false {
            guard batch.findings.isEmpty,
                  batch.rankedPositiveFindingKeys.isEmpty,
                  suppressionSummary.findingSuppressions.count == 1,
                  frameSuppressions.count == 1,
                  frameSuppressions[0].count == 1,
                  suppressionSummary.rankingExclusions.isEmpty,
                  suppressionSummary.collapses.isEmpty,
                  suppressionSummary.truncatedPositiveCount == 0
            else {
                return false
            }
            if frameSuppressions[0].reason == .frameNonIncreasingSequence,
               batch.comparisonSequence > batch.baselineSequence {
                return false
            }
        } else if batch.comparisonSequence <= batch.baselineSequence {
            return false
        }

        let collapseCount: (HistoricalFindingReason) -> Int = { reason in
            suppressionSummary.collapses.first { $0.reason == reason }?.count ?? 0
        }
        let inheritedDraftCount = batch.findings.lazy.filter {
            $0.movementContext != nil
        }.count
        guard collapseCount(.collapsedInheritedMoveFacet) == inheritedDraftCount else {
            return false
        }
        if collapseCount(.collapsedImplicitDescendantMove) > 0,
           batch.findings.contains(where: { $0.kind == .move }) == false {
            return false
        }
        if collapseCount(.coveredByAncestorAppearance) > 0,
           batch.findings.contains(where: { $0.kind == .appearance }) == false {
            return false
        }
        if collapseCount(.coveredByAncestorDisappearance) > 0,
           batch.findings.contains(where: { $0.kind == .disappearance }) == false {
            return false
        }

        let rankingCount: (HistoricalFindingReason) -> Int = { reason in
            suppressionSummary.rankingExclusions.first { $0.reason == reason }?.count ?? 0
        }
        var expectedKindIneligible = 0
        var expectedNonPositive = 0
        var expectedIncompleteEvidence = 0
        for finding in batch.findings {
            if finding.kind == .move {
                expectedKindIneligible += 1
                continue
            }
            guard let contribution = finding.rankingContribution else {
                guard finding.kind == .growth || finding.kind == .decrease else {
                    return false
                }
                expectedIncompleteEvidence += 1
                continue
            }
            if finding.kind == .growth || finding.kind == .appearance {
                if contribution.bytes <= 0 {
                    expectedNonPositive += 1
                }
            } else if contribution.bytes > 0 {
                expectedKindIneligible += 1
            } else {
                expectedNonPositive += 1
            }
        }
        let (actualIncompleteEvidence, incompleteOverflow) = rankingCount(
            .rankingIncompleteDirectChildren
        ).addingReportingOverflow(rankingCount(.rankingIncompleteChildMeasurement))
        guard incompleteOverflow == false,
              rankingCount(.rankingKindIneligible) == expectedKindIneligible,
              rankingCount(.rankingNonPositiveContribution) == expectedNonPositive,
              actualIncompleteEvidence == expectedIncompleteEvidence
        else {
            return false
        }

        var exclusionCount = 0
        for reasonCount in suppressionSummary.rankingExclusions {
            let (updated, overflow) = exclusionCount.addingReportingOverflow(reasonCount.count)
            guard overflow == false else { return false }
            exclusionCount = updated
        }
        return exclusionCount == batch.findings.count - eligibleCount
    }

    private enum CodingKeys: String, CodingKey {
        case batch
        case suppressionSummary
    }
}

public enum HistoricalFindingGenerationError: Error, Sendable, Equatable {
    case invalidPositiveLimit(Int)
    case endpointIDReusedAcrossFrames(ObservationEndpointID)
    case arithmeticOverflow
}

fileprivate extension HistoricalFindingDraft {
    var isEligiblePositiveFinding: Bool {
        (kind == .growth || kind == .appearance)
            && (rankingContribution?.bytes ?? 0) > 0
    }
}

private func canonicalHistoricalFindingNodeOrder(
    _ lhs: HistoricalFindingNode,
    _ rhs: HistoricalFindingNode
) -> Bool {
    let lhsLocation = lhs.endpoint.locationID.rawValue
    let rhsLocation = rhs.endpoint.locationID.rawValue
    if binaryEqual(lhsLocation, rhsLocation) == false {
        return binaryPrecedes(lhsLocation, rhsLocation)
    }
    return binaryPrecedes(lhs.endpoint.id.rawValue, rhs.endpoint.id.rawValue)
}

private func isCanonicalHistoricalFindingPath(_ path: String) -> Bool {
    guard path.utf8.first == UInt8(ascii: "/"),
          path.utf8.contains(0) == false
    else {
        return false
    }
    if path == "/" {
        return true
    }
    guard path.hasSuffix("/") == false else {
        return false
    }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    return components.isEmpty == false
        && components.allSatisfy { component in
            component.isEmpty == false && component != "." && component != ".."
        }
}

private func isValidHistoricalFindingDisplayName(_ displayName: String) -> Bool {
    displayName.isEmpty == false
        && displayName != "."
        && displayName != ".."
        && displayName.contains("/") == false
        && displayName.utf8.contains(0) == false
}

private func isHistoricalFindingPath(_ path: String, containedIn rootPath: String) -> Bool {
    if binaryEqual(path, rootPath) {
        return true
    }
    if rootPath == "/" {
        return path.hasPrefix("/")
    }
    return Array(path.utf8).starts(with: Array((rootPath + "/").utf8))
}

/// Returns the opaque UTF-8 relative suffix only for a strict component-wise
/// descendant. This deliberately avoids Swift's canonically-equivalent String
/// prefix semantics because paths are filesystem identities in this model.
private func relativeHistoricalFindingPathBytes(
    _ descendantPath: String,
    below ancestorPath: String
) -> [UInt8]? {
    let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
    let descendantBytes = Array(descendantPath.utf8)
    let prefixBytes = Array(prefix.utf8)
    guard descendantBytes.count > prefixBytes.count,
          descendantBytes.starts(with: prefixBytes)
    else {
        return nil
    }
    return Array(descendantBytes.dropFirst(prefixBytes.count))
}

private func directParentPath(of path: String) -> String {
    guard path != "/", let separator = path.lastIndex(of: "/") else {
        return path
    }
    if separator == path.startIndex {
        return "/"
    }
    return String(path[..<separator])
}

func binaryEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

func binaryPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private extension ObservationEndpointState {
    var findingEvidenceCoverage: ObservationCoverage {
        switch self {
        case .present(_, let coverage):
            coverage
        case .absent:
            .complete
        case .unknown:
            .unknown
        }
    }

    var findingAbsenceReference: ParentAbsenceReference? {
        guard case .absent(let reference) = self else { return nil }
        return reference
    }
}

private func rejectUnknownHistoricalFindingKeys(
    in decoder: any Decoder,
    allowed: Set<String>,
    typeName: String
) throws {
    let container = try decoder.container(keyedBy: HistoricalFindingDynamicCodingKey.self)
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

private func historicalFindingDecodingError(
    _ decoder: any Decoder,
    _ debugDescription: String
) -> DecodingError {
    DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: debugDescription
        )
    )
}

private func historicalFindingEncodingError<Value>(
    _ value: Value,
    _ encoder: any Encoder,
    _ debugDescription: String
) -> EncodingError {
    EncodingError.invalidValue(
        value,
        EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: debugDescription
        )
    )
}

private extension KeyedDecodingContainer {
    /// Decodes the canonical optional representation used by immutable
    /// finding evidence: absent keys mean nil, while explicit JSON null is
    /// rejected so decode/re-encode cannot silently normalize the payload.
    func decodeCanonicalOptional<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Value? {
        guard contains(key) else { return nil }
        return try decode(Value.self, forKey: key)
    }
}

private struct HistoricalFindingDynamicCodingKey: CodingKey {
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
