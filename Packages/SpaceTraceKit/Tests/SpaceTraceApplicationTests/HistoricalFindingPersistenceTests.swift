import Foundation
import Testing
import SpaceTraceAttribution
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct HistoricalFindingPersistenceTests {
    @Test("Paired candidates canonicalize one sequence-free shared tree")
    func canonicalizesSequenceFreeCandidate() throws {
        let root = try node(
            subject: "root",
            parent: nil,
            location: "location-root",
            path: "/Fixtures",
            displayName: "Fixtures",
            state: .present(
                logicalBytes: ByteCount(100),
                allocatedBytes: ByteCount(80),
                measurementCoverage: .complete
            ),
            childrenCoverage: .complete
        )
        let child = try node(
            subject: "child",
            parent: "root",
            location: "location-child",
            path: "/Fixtures/Child",
            displayName: "Child",
            state: .present(
                logicalBytes: ByteCount(40),
                allocatedBytes: ByteCount(32),
                measurementCoverage: .partial
            ),
            childrenCoverage: .partial
        )

        let candidate = try observation(nodes: [root, child].reversed())

        #expect(candidate.nodes.map(\.subjectID.rawValue) == ["child", "root"])
        #expect(candidate.nodes[0].state == child.state)
        #expect(candidate.nodes[1].state == root.state)

        let labels = Set(Mirror(reflecting: candidate).children.compactMap(\.label))
        #expect(labels.contains("sequence") == false)
        #expect(labels.contains("endpointID") == false)
        #expect(labels.contains("nodeID") == false)
        #expect(HistoricalPairedObservationCandidate.self is any Encodable.Type == false)
        #expect(HistoricalPairedObservationCandidate.self is any Decodable.Type == false)
    }

    @Test("Canonical-equivalent UTF-8 identities and paths remain byte distinct")
    func preservesByteDistinctUnicode() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(composed == decomposed)

        let candidate = try observation(nodes: [
            try node(
                subject: "root",
                parent: nil,
                location: "location-root",
                path: "/Fixtures",
                displayName: "Fixtures",
                state: present(100, 80),
                childrenCoverage: .complete
            ),
            try node(
                subject: composed,
                parent: "root",
                location: "location-\(composed)",
                path: "/Fixtures/\(composed)",
                displayName: composed,
                state: present(10, 8),
                childrenCoverage: .complete
            ),
            try node(
                subject: decomposed,
                parent: "root",
                location: "location-\(decomposed)",
                path: "/Fixtures/\(decomposed)",
                displayName: decomposed,
                state: present(12, 9),
                childrenCoverage: .complete
            ),
        ])

        #expect(candidate.nodes.count == 3)
        #expect(candidate.nodes[0].subjectID.rawValue == decomposed)
        #expect(candidate.nodes[1].subjectID.rawValue == "root")
        #expect(candidate.nodes[2].subjectID.rawValue == composed)
        #expect(candidate.nodes[0].path.utf8.elementsEqual("/Fixtures/\(decomposed)".utf8))
        #expect(candidate.nodes[2].path.utf8.elementsEqual("/Fixtures/\(composed)".utf8))
    }

    @Test("Candidate construction rejects invalid roots and trees")
    func rejectsInvalidTrees() throws {
        let absentRoot = try node(
            subject: "root",
            parent: nil,
            location: "location-root",
            path: "/Fixtures",
            displayName: "Fixtures",
            state: .absent,
            childrenCoverage: .unknown,
            classification: nil
        )
        #expect(throws: HistoricalFindingPersistenceModelError.rootCannotBeAbsent) {
            try observation(nodes: [absentRoot])
        }

        let missingRoot = try node(
            subject: "child",
            parent: "root",
            location: "location-child",
            path: "/Fixtures/Child",
            displayName: "Child",
            state: present(1, 1),
            childrenCoverage: .complete
        )
        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(.missingRootNode)
        ) {
            try observation(nodes: [missingRoot])
        }

        let root = try node(
            subject: "root",
            parent: nil,
            location: "location-root",
            path: "/Fixtures",
            displayName: "Fixtures",
            state: present(100, 100),
            childrenCoverage: .complete
        )
        let nonDirectChild = try node(
            subject: "child",
            parent: "root",
            location: "location-child",
            path: "/Fixtures/Nested/Child",
            displayName: "Child",
            state: present(1, 1),
            childrenCoverage: .complete
        )
        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(.nonDirectParent)
        ) {
            try observation(nodes: [root, nonDirectChild])
        }

        let duplicateRoot = try node(
            subject: "root",
            parent: nil,
            location: "location-root-duplicate",
            path: "/Fixtures/Duplicate",
            displayName: "Duplicate",
            state: present(1, 1),
            childrenCoverage: .complete
        )
        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(
                .duplicateSubjectID
            )
        ) {
            try observation(nodes: [root, duplicateRoot])
        }
    }

    @Test("Node candidates reject state, classification, and stable-evidence contradictions")
    func rejectsNodeContradictions() throws {
        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(
                .presentNodeRequiresClassification
            )
        ) {
            try node(
                subject: "node",
                parent: "root",
                location: "location-node",
                path: "/Fixtures/Node",
                displayName: "Node",
                state: present(1, 1),
                childrenCoverage: .complete,
                classification: nil
            )
        }

        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(
                .unavailableNodeCannotContainClassification
            )
        ) {
            try node(
                subject: "node",
                parent: "root",
                location: "location-node",
                path: "/Fixtures/Node",
                displayName: "Node",
                state: .unknown(.permissionDenied),
                childrenCoverage: .unknown
            )
        }

        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(
                .unavailableNodeRequiresUnknownDirectChildrenCoverage
            )
        ) {
            try node(
                subject: "node",
                parent: "root",
                location: "location-node",
                path: "/Fixtures/Node",
                displayName: "Node",
                state: .absent,
                childrenCoverage: .complete,
                classification: nil
            )
        }

        #expect(
            throws: HistoricalFindingPersistenceModelError.invalidObservationModel(
                .stableIdentityEvidenceRequiresStableObjectBasis
            )
        ) {
            try node(
                subject: "node",
                parent: "root",
                location: "location-node",
                path: "/Fixtures/Node",
                displayName: "Node",
                state: present(1, 1),
                childrenCoverage: .complete,
                stableEvidence: stableEvidence()
            )
        }

        #expect(throws: HistoricalFindingPersistenceModelError.presentCannotUseUnknownCoverage) {
            try node(
                subject: "node",
                parent: "root",
                location: "location-node",
                path: "/Fixtures/Node",
                displayName: "Node",
                state: .present(
                    logicalBytes: ByteCount(1),
                    allocatedBytes: ByteCount(1),
                    measurementCoverage: .unknown
                ),
                childrenCoverage: .complete
            )
        }
    }

    @Test("Commit materialization derives exact paired endpoints and absence parents")
    func materializesExactPairedFrames() throws {
        let candidate = try observation(nodes: [
            try node(
                subject: "root",
                parent: nil,
                location: "location-root",
                path: "/Fixtures",
                displayName: "Fixtures",
                state: present(100, 80),
                childrenCoverage: .complete
            ),
            try node(
                subject: "present",
                parent: "root",
                location: "location-present",
                path: "/Fixtures/Present",
                displayName: "Present",
                state: present(40, 31),
                childrenCoverage: .complete
            ),
            try node(
                subject: "absent",
                parent: "root",
                location: "location-absent",
                path: "/Fixtures/Absent",
                displayName: "Absent",
                state: .absent,
                childrenCoverage: .unknown,
                classification: nil
            ),
            try node(
                subject: "unknown",
                parent: "root",
                location: "location-unknown",
                path: "/Fixtures/Unknown",
                displayName: "Unknown",
                state: .unknown(.continuityGap),
                childrenCoverage: .unknown,
                classification: nil
            ),
        ])
        let materializer = HistoricalPairedObservationCommitMaterializer(candidate: candidate)
        let materialized = try materializer.materialize(
            storeGeneration: HistoricalStoreGeneration(
                bytes: Array(0x00...0x0f)
            ),
            nodeIDs: [
                try SubjectID("root"): 1,
                try SubjectID("present"): 2,
                try SubjectID("absent"): 3,
                try SubjectID("unknown"): 4,
            ],
            logicalSequence: ObservationCommitSequence(41),
            allocatedSequence: ObservationCommitSequence(42)
        )

        #expect(materialized.logical.metric == .logical)
        #expect(materialized.allocated.metric == .allocated)
        #expect(materialized.logical.nodes.count == candidate.nodes.count)
        #expect(materialized.allocated.nodes.count == candidate.nodes.count)
        #expect(
            materialized.logical.rootEndpointID.rawValue
                == "st11:000102030405060708090a0b0c0d0e0f:0000000000000001:01"
        )
        #expect(
            materialized.allocated.rootEndpointID.rawValue
                == "st11:000102030405060708090a0b0c0d0e0f:0000000000000001:02"
        )

        let logicalPresent = try endpoint(subject: "present", in: materialized.logical)
        let allocatedPresent = try endpoint(subject: "present", in: materialized.allocated)
        let expectedLogicalBytes = try ByteCount(40)
        let expectedAllocatedBytes = try ByteCount(31)
        #expect(
            logicalPresent.state == .present(
                bytes: expectedLogicalBytes,
                coverage: .complete
            )
        )
        #expect(
            allocatedPresent.state == .present(
                bytes: expectedAllocatedBytes,
                coverage: .complete
            )
        )

        let logicalAbsent = try endpoint(subject: "absent", in: materialized.logical)
        let allocatedAbsent = try endpoint(subject: "absent", in: materialized.allocated)
        #expect(
            logicalAbsent.state == .absent(
                ParentAbsenceReference(
                    parentEndpointID: materialized.logical.rootEndpointID,
                    parentSubjectID: try SubjectID("root")
                )
            )
        )
        #expect(
            allocatedAbsent.state == .absent(
                ParentAbsenceReference(
                    parentEndpointID: materialized.allocated.rootEndpointID,
                    parentSubjectID: try SubjectID("root")
                )
            )
        )
    }

    @Test("Commit materialization rejects incomplete, reused, or invalid assignments")
    func rejectsInvalidMaterializationAssignments() throws {
        let candidate = try observation(nodes: [
            try node(
                subject: "root",
                parent: nil,
                location: "location-root",
                path: "/Fixtures",
                displayName: "Fixtures",
                state: present(10, 8),
                childrenCoverage: .complete
            ),
            try node(
                subject: "child",
                parent: "root",
                location: "location-child",
                path: "/Fixtures/Child",
                displayName: "Child",
                state: present(2, 1),
                childrenCoverage: .complete
            ),
        ])
        let materializer = HistoricalPairedObservationCommitMaterializer(candidate: candidate)
        let generation = try HistoricalStoreGeneration(bytes: Array(repeating: 7, count: 16))
        let logical = try ObservationCommitSequence(10)
        let allocated = try ObservationCommitSequence(11)

        #expect(throws: HistoricalFindingPersistenceModelError.incompleteNodeIDAssignment) {
            try materializer.materialize(
                storeGeneration: generation,
                nodeIDs: [try SubjectID("root"): 1],
                logicalSequence: logical,
                allocatedSequence: allocated
            )
        }
        #expect(throws: HistoricalFindingPersistenceModelError.unexpectedNodeIDAssignment) {
            try materializer.materialize(
                storeGeneration: generation,
                nodeIDs: [
                    try SubjectID("root"): 1,
                    try SubjectID("child"): 2,
                    try SubjectID("extra"): 3,
                ],
                logicalSequence: logical,
                allocatedSequence: allocated
            )
        }
        #expect(throws: HistoricalFindingPersistenceModelError.reusedNodeID(1)) {
            try materializer.materialize(
                storeGeneration: generation,
                nodeIDs: [try SubjectID("root"): 1, try SubjectID("child"): 1],
                logicalSequence: logical,
                allocatedSequence: allocated
            )
        }
        #expect(throws: HistoricalFindingPersistenceModelError.invalidNodeID(0)) {
            try materializer.materialize(
                storeGeneration: generation,
                nodeIDs: [try SubjectID("root"): 1, try SubjectID("child"): 0],
                logicalSequence: logical,
                allocatedSequence: allocated
            )
        }
        #expect(throws: HistoricalFindingPersistenceModelError.nonConsecutiveCommitSequences) {
            try materializer.materialize(
                storeGeneration: generation,
                nodeIDs: [try SubjectID("root"): 1, try SubjectID("child"): 2],
                logicalSequence: logical,
                allocatedSequence: ObservationCommitSequence(12)
            )
        }
        #expect(throws: HistoricalFindingPersistenceModelError.invalidStoreGeneration) {
            try HistoricalStoreGeneration(bytes: Array(repeating: 0, count: 16))
        }
    }

    @Test("Paired finalization accepts only canonical lowercase UUID run IDs")
    func validatesPairedRunIDAndReceiptBytes() throws {
        let request = try finalizationRequest(
            runID: "123e4567-e89b-12d3-a456-426614174000"
        )
        #expect(
            request.disabledReceiptIDBytes
                == [
                    0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3,
                    0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00,
                ]
        )

        for invalid in [
            "123E4567-E89B-12D3-A456-426614174000",
            "123e4567e89b12d3a456426614174000",
            "not-a-uuid",
        ] {
            #expect(throws: HistoricalFindingPersistenceModelError.invalidCanonicalRunID) {
                try finalizationRequest(runID: invalid)
            }
        }
    }

    @Test("Finalization, availability, and commit dispositions remain typed")
    func keepsOutcomesTyped() throws {
        let logical = try HistoricalObservationFrameCommit(
            sequence: ObservationCommitSequence(1),
            rootEndpointID: ObservationEndpointID("logical-root"),
            endpointCount: 2
        )
        let allocated = try HistoricalObservationFrameCommit(
            sequence: ObservationCommitSequence(2),
            rootEndpointID: ObservationEndpointID("allocated-root"),
            endpointCount: 2
        )
        let commit = HistoricalCalibrationCommit(
            disposition: .newlyCommitted,
            logical: logical,
            allocated: allocated
        )

        #expect(HistoricalCalibrationFinalizationOutcome.published(commit) != .superseded)
        #expect(HistoricalCalibrationFinalizationOutcome.historyDisabled == .historyDisabled)
        #expect(HistoricalPathHistoryAvailability.historyDisabled != .baselineUnavailable)
        #expect(HistoricalPathHistoryAvailability.baselineUnavailable != .available)
    }

    @Test("History policy and query limit enforce their released bounds")
    func validatesPolicyAndQueryBounds() throws {
        #expect(try HistoricalPathHistoryPolicy(retentionDays: 0).retentionDays == 0)
        #expect(try HistoricalPathHistoryPolicy(retentionDays: 30).retentionDays == 30)
        for value in [-1, 31] {
            #expect(throws: HistoricalFindingPersistenceModelError.invalidRetentionDays(value)) {
                try HistoricalPathHistoryPolicy(retentionDays: value)
            }
        }

        #expect(try HistoricalFindingQueryLimit(1).rawValue == 1)
        #expect(try HistoricalFindingQueryLimit(1_000).rawValue == 1_000)
        for value in [0, 1_001] {
            #expect(throws: HistoricalFindingPersistenceModelError.invalidQueryLimit(value)) {
                try HistoricalFindingQueryLimit(value)
            }
        }
    }

    @Test("The source keeps evidence invalidation outside the public repository")
    func auditsAuthorizationAndSerializationSurface() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SpaceTraceApplication/History/HistoricalFindingPersistence.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let publicRepository = try sourceSlice(
            from: "public protocol HistoricalFindingPersistenceRepository",
            through: "package protocol HistoricalFindingIntegrityReconciliationRepository",
            in: source
        )
        #expect(publicRepository.contains("commitEvidenceInvalidation") == false)

        let command = try sourceSlice(
            from: "public struct HistoricalFindingEvidenceInvalidationCommand",
            through: "public struct EffectiveHistoricalFinding",
            in: source
        )
        #expect(command.contains("fileprivate init(") == true)
        #expect(command.contains("public init(") == false)
        #expect(command.contains("package init(") == false)
        #expect(command.contains("Codable") == false)

        let reconciliationPort = try sourceSlice(
            from: "package protocol HistoricalFindingIntegrityReconciliationRepository",
            through: "// MARK: - Validation",
            in: source
        )
        #expect(reconciliationPort.contains("commitEvidenceInvalidation") == true)
        #expect(reconciliationPort.contains("HistoricalFindingEvidenceInvalidationCommand") == true)
    }
}

private func observation(
    nodes: [HistoricalPairedObservationNodeCandidate]
) throws -> HistoricalPairedObservationCandidate {
    try HistoricalPairedObservationCandidate(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Fixtures",
        nodes: nodes,
        scopeID: ScopeID("scope-fixture"),
        volumeID: ObservationVolumeID("volume-fixture"),
        mountGenerationID: ObservationMountGenerationID("mount-fixture"),
        coverageEpochID: ObservationCoverageEpochID("coverage-fixture"),
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1)
    )
}

private func node(
    subject: String,
    parent: String?,
    location: String,
    path: String,
    displayName: String,
    state: HistoricalPairedObservationStateCandidate,
    childrenCoverage: ObservationCoverage,
    classification: VersionedAttributionDecision? = try? decision(),
    identityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
    stableEvidence: HistoricalFindingStableIdentityEvidence? = nil
) throws -> HistoricalPairedObservationNodeCandidate {
    try HistoricalPairedObservationNodeCandidate(
        subjectID: SubjectID(subject),
        identityBasis: identityBasis,
        parentSubjectID: try parent.map { try SubjectID($0) },
        locationID: ObservationLocationID(location),
        path: path,
        displayName: displayName,
        observedAt: ObservationInstant(millisecondsSince1970: 1_000),
        state: state,
        directChildrenCoverage: childrenCoverage,
        classification: classification,
        stableIdentityEvidence: stableEvidence
    )
}

private func present(
    _ logical: Int64,
    _ allocated: Int64
) throws -> HistoricalPairedObservationStateCandidate {
    .present(
        logicalBytes: try ByteCount(logical),
        allocatedBytes: try ByteCount(allocated),
        measurementCoverage: .complete
    )
}

private func decision() throws -> VersionedAttributionDecision {
    try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(1),
        result: .unknown(.noMatchingRule)
    )
}

private func stableEvidence() throws -> HistoricalFindingStableIdentityEvidence {
    try HistoricalFindingStableIdentityEvidence(
        reuseGuard: .generationToken("generation-fixture"),
        nodeKind: .directory,
        linkStatus: .unique
    )
}

private func endpoint(
    subject: String,
    in frame: HistoricalFindingObservationFrame
) throws -> ObservationEndpoint {
    try #require(
        frame.nodes.first { $0.endpoint.subjectID == (try? SubjectID(subject)) }?.endpoint
    )
}

private func finalizationRequest(
    runID: String
) throws -> HistoricalCalibrationFinalizationRequest {
    let region = try DirtyRegion(
        path: DirtyRegionPath("/Fixtures"),
        reasons: [.requiresCalibration],
        maximumCursor: EventJournalCursor(7)
    )
    return try HistoricalCalibrationFinalizationRequest(
        runID: CalibrationRunID(runID),
        report: CalibrationReport(
            coverage: .complete,
            entriesVisited: 1,
            directoriesStaged: 1,
            gaps: []
        ),
        workItem: DirtyRegionWorkItem(
            region: region,
            revision: DirtyRegionRevision(1)
        ),
        streamID: EventStreamID("stream-fixture"),
        observation: observation(nodes: [
            try node(
                subject: "root",
                parent: nil,
                location: "location-root",
                path: "/Fixtures",
                displayName: "Fixtures",
                state: present(1, 1),
                childrenCoverage: .complete
            ),
        ])
    )
}

private func sourceSlice(
    from start: String,
    through end: String,
    in source: String
) throws -> Substring {
    let startIndex = try #require(source.range(of: start)?.lowerBound)
    let endIndex = try #require(
        source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound
    )
    return source[startIndex..<endIndex]
}
