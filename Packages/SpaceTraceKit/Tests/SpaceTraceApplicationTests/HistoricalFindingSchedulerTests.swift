import SpaceTraceAttribution
import SpaceTraceDomain
import Testing
@testable import SpaceTraceApplication

struct HistoricalFindingSchedulerTests {
    @Test(
        "A 2,000-node parent-first move dependency chain stays within its generation budget",
        .timeLimit(.minutes(1))
    )
    func deepMoveDependencyChainStaysWithinBudget() throws {
        let depth = 2_000
        let generationBudget = Duration.seconds(10)
        let frames = try makeDeepMoveFrames(depth: depth, reverseNodeInput: false)
        let generator = HistoricalFindingGenerator()
        let clock = ContinuousClock()

        let start = clock.now
        let result = try generator.generate(
            baseline: frames.baseline,
            comparison: frames.comparison
        )
        let elapsed = start.duration(to: clock.now)

        #expect(
            elapsed < generationBudget,
            "The dependency scheduler should not scan the complete pending set once per depth."
        )
        try expectDeepMoveProjection(result, depth: depth)
    }

    @Test("Move dependency output is deterministic across frame node input order")
    func moveDependencyOutputIsDeterministic() throws {
        let depth = 300
        let ordered = try makeDeepMoveFrames(depth: depth, reverseNodeInput: false)
        let reversed = try makeDeepMoveFrames(depth: depth, reverseNodeInput: true)
        let generator = HistoricalFindingGenerator()

        let orderedResult = try generator.generate(
            baseline: ordered.baseline,
            comparison: ordered.comparison
        )
        let reversedResult = try generator.generate(
            baseline: reversed.baseline,
            comparison: reversed.comparison
        )

        #expect(reversedResult == orderedResult)
        try expectDeepMoveProjection(orderedResult, depth: depth)
    }

    @Test("A decreasing parent with positive exclusive bytes remains ineligible for positive rank")
    func positiveExclusiveContributionDoesNotChangeDecreaseKind() throws {
        let baseline = try makeSchedulerFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            specs: [
                .init(subjectID: "parent", parentSubjectID: "root", path: "/Fixtures/Parent", bytes: 50),
                .init(subjectID: "child", parentSubjectID: "parent", path: "/Fixtures/Parent/Child", bytes: 20),
            ]
        )
        let comparison = try makeSchedulerFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            specs: [
                .init(subjectID: "parent", parentSubjectID: "root", path: "/Fixtures/Parent", bytes: 45),
                .init(subjectID: "child", parentSubjectID: "parent", path: "/Fixtures/Parent/Child", bytes: 10),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        let parent = try requireFinding(subjectID: "parent", in: result)
        #expect(parent.kind == .decrease)
        #expect(parent.inclusiveDelta == .logical(bytes: -5))
        #expect(parent.rankingContribution == .logical(bytes: 5))
        #expect(result.batch.rankedPositiveFindingKeys.isEmpty)
        expectReasonCounts(
            result.suppressionSummary.rankingExclusions,
            equal: [
                (.rankingKindIneligible, 1),
                (.rankingNonPositiveContribution, 1),
            ]
        )
    }

    @Test("An unchanged parent is not synthesized from a decreasing child")
    func unchangedParentWithPositiveExclusiveBytesDoesNotBecomeFinding() throws {
        let baseline = try makeSchedulerFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            specs: [
                .init(subjectID: "parent", parentSubjectID: "root", path: "/Fixtures/Parent", bytes: 50),
                .init(subjectID: "child", parentSubjectID: "parent", path: "/Fixtures/Parent/Child", bytes: 20),
            ]
        )
        let comparison = try makeSchedulerFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            specs: [
                .init(subjectID: "parent", parentSubjectID: "root", path: "/Fixtures/Parent", bytes: 50),
                .init(subjectID: "child", parentSubjectID: "parent", path: "/Fixtures/Parent/Child", bytes: 10),
            ]
        )

        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison
        )

        #expect(result.batch.findings.count == 1)
        #expect(
            result.batch.findings.contains {
                $0.evidence.comparisonEndpointID.rawValue == "comparison-parent"
            } == false
        )
        let child = try requireFinding(subjectID: "child", in: result)
        #expect(child.kind == .decrease)
        #expect(child.inclusiveDelta == .logical(bytes: -10))
        #expect(child.rankingContribution == .logical(bytes: -10))
        #expect(result.batch.rankedPositiveFindingKeys.isEmpty)
        expectReasonCounts(
            result.suppressionSummary.rankingExclusions,
            equal: [(.rankingNonPositiveContribution, 1)]
        )
    }

    @Test("Composed and decomposed location ties use UTF-8 binary order")
    func unicodeLocationTieUsesBinaryOrder() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{301}"
        let baselineSpecs = [
            SchedulerNodeSpec(
                subjectID: "composed",
                parentSubjectID: "root",
                path: "/Fixtures/Composed",
                bytes: 10,
                locationID: composed
            ),
            SchedulerNodeSpec(
                subjectID: "decomposed",
                parentSubjectID: "root",
                path: "/Fixtures/Decomposed",
                bytes: 10,
                locationID: decomposed
            ),
        ]
        let comparisonSpecs = [
            SchedulerNodeSpec(
                subjectID: "composed",
                parentSubjectID: "root",
                path: "/Fixtures/Composed",
                bytes: 20,
                locationID: composed
            ),
            SchedulerNodeSpec(
                subjectID: "decomposed",
                parentSubjectID: "root",
                path: "/Fixtures/Decomposed",
                bytes: 20,
                locationID: decomposed
            ),
        ]
        let generator = HistoricalFindingGenerator()

        let ordered = try generator.generate(
            baseline: makeSchedulerFrame(
                sequence: 1,
                endpointPrefix: "baseline",
                specs: baselineSpecs
            ),
            comparison: makeSchedulerFrame(
                sequence: 2,
                endpointPrefix: "comparison",
                specs: comparisonSpecs
            ),
            positiveLimit: 1
        )
        let reversed = try generator.generate(
            baseline: makeSchedulerFrame(
                sequence: 1,
                endpointPrefix: "baseline",
                specs: baselineSpecs.reversed()
            ),
            comparison: makeSchedulerFrame(
                sequence: 2,
                endpointPrefix: "comparison",
                specs: comparisonSpecs.reversed()
            ),
            positiveLimit: 1
        )

        #expect(reversed == ordered)
        let rankedKey = try #require(ordered.batch.rankedPositiveFindingKeys.first)
        let rankedFinding = try #require(
            ordered.batch.findings.first { $0.key == rankedKey }
        )
        #expect(rankedFinding.evidence.destinationLocationID.rawValue == decomposed)
    }
}

private struct SchedulerNodeSpec {
    let subjectID: String
    let parentSubjectID: String
    let path: String
    let bytes: Int64
    let locationID: String
    let identityBasis: ObservationSubjectIdentityBasis
    let stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?

    init(
        subjectID: String,
        parentSubjectID: String,
        path: String,
        bytes: Int64,
        locationID: String? = nil,
        identityBasis: ObservationSubjectIdentityBasis = .normalizedPath,
        stableIdentityEvidence: HistoricalFindingStableIdentityEvidence? = nil
    ) {
        self.subjectID = subjectID
        self.parentSubjectID = parentSubjectID
        self.path = path
        self.bytes = bytes
        self.locationID = locationID ?? "location-\(subjectID)"
        self.identityBasis = identityBasis
        self.stableIdentityEvidence = stableIdentityEvidence
    }
}

private func makeDeepMoveFrames(
    depth: Int,
    reverseNodeInput: Bool
) throws -> (
    baseline: HistoricalFindingObservationFrame,
    comparison: HistoricalFindingObservationFrame
) {
    var baselineSpecs: [SchedulerNodeSpec] = []
    var comparisonSpecs: [SchedulerNodeSpec] = []
    baselineSpecs.reserveCapacity(depth)
    comparisonSpecs.reserveCapacity(depth)

    var baselinePath = "/Fixtures/Old"
    var comparisonPath = "/Fixtures/New"
    for index in 0..<depth {
        if index > 0 {
            baselinePath += "/n\(index)"
            comparisonPath += "/n\(index)"
        }
        let subjectID = "moving-\(index)"
        let parentSubjectID = index == 0 ? "root" : "moving-\(index - 1)"
        let evidence = try HistoricalFindingStableIdentityEvidence(
            reuseGuard: .generationToken("generation-\(index)"),
            nodeKind: .directory,
            linkStatus: .unique
        )
        let bytes = Int64(depth - index)
        baselineSpecs.append(
            SchedulerNodeSpec(
                subjectID: subjectID,
                parentSubjectID: parentSubjectID,
                path: baselinePath,
                bytes: bytes,
                locationID: "old-location-\(index)",
                identityBasis: .stableFileSystemObject,
                stableIdentityEvidence: evidence
            )
        )
        comparisonSpecs.append(
            SchedulerNodeSpec(
                subjectID: subjectID,
                parentSubjectID: parentSubjectID,
                path: comparisonPath,
                bytes: bytes,
                locationID: "new-location-\(index)",
                identityBasis: .stableFileSystemObject,
                stableIdentityEvidence: evidence
            )
        )
    }

    if reverseNodeInput {
        baselineSpecs.reverse()
        comparisonSpecs.reverse()
    }

    return try (
        baseline: makeSchedulerFrame(
            sequence: 1,
            endpointPrefix: "baseline",
            rootBytes: Int64(depth + 1),
            specs: baselineSpecs
        ),
        comparison: makeSchedulerFrame(
            sequence: 2,
            endpointPrefix: "comparison",
            rootBytes: Int64(depth + 1),
            specs: comparisonSpecs
        )
    )
}

private func makeSchedulerFrame<S: Sequence>(
    sequence: Int64,
    endpointPrefix: String,
    rootBytes: Int64 = 1_000,
    specs: S
) throws -> HistoricalFindingObservationFrame where S.Element == SchedulerNodeSpec {
    let classification = try schedulerClassification()
    let root = try makeSchedulerNode(
        endpointID: "\(endpointPrefix)-root",
        subjectID: "root",
        parentSubjectID: nil,
        path: "/Fixtures",
        displayName: "Fixtures",
        bytes: rootBytes,
        locationID: "location-root",
        identityBasis: .normalizedPath,
        stableIdentityEvidence: nil,
        classification: classification,
        sequence: sequence
    )
    let children = try specs.map { spec in
        try makeSchedulerNode(
            endpointID: "\(endpointPrefix)-\(spec.subjectID)",
            subjectID: spec.subjectID,
            parentSubjectID: spec.parentSubjectID,
            path: spec.path,
            displayName: String(spec.path.split(separator: "/").last ?? "Fixtures"),
            bytes: spec.bytes,
            locationID: spec.locationID,
            identityBasis: spec.identityBasis,
            stableIdentityEvidence: spec.stableIdentityEvidence,
            classification: classification,
            sequence: sequence
        )
    }

    return try HistoricalFindingObservationFrame(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Fixtures",
        nodes: [root] + children
    )
}

private func makeSchedulerNode(
    endpointID: String,
    subjectID: String,
    parentSubjectID: String?,
    path: String,
    displayName: String,
    bytes: Int64,
    locationID: String,
    identityBasis: ObservationSubjectIdentityBasis,
    stableIdentityEvidence: HistoricalFindingStableIdentityEvidence?,
    classification: VersionedAttributionDecision,
    sequence: Int64
) throws -> HistoricalFindingNode {
    let endpoint = try ObservationEndpoint(
        id: ObservationEndpointID(endpointID),
        scopeID: ScopeID("scope-a"),
        volumeID: ObservationVolumeID("volume-a"),
        mountGenerationID: ObservationMountGenerationID("mount-a"),
        coverageEpochID: ObservationCoverageEpochID("coverage-a"),
        subjectID: SubjectID(subjectID),
        identityBasis: identityBasis,
        locationID: ObservationLocationID(locationID),
        metric: .logical,
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1),
        sequence: ObservationCommitSequence(sequence),
        observedAt: ObservationInstant(millisecondsSince1970: sequence * 1_000),
        state: .present(bytes: ByteCount(bytes), coverage: .complete)
    )
    return try HistoricalFindingNode(
        endpoint: endpoint,
        parentSubjectID: try parentSubjectID.map(SubjectID.init),
        path: path,
        displayName: displayName,
        directChildrenCoverage: .complete,
        classification: classification,
        stableIdentityEvidence: stableIdentityEvidence
    )
}

private func schedulerClassification() throws -> VersionedAttributionDecision {
    try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(1),
        result: .unknown(.noMatchingRule)
    )
}

private func expectDeepMoveProjection(
    _ result: HistoricalFindingGenerationResult,
    depth: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(result.batch.findings.count == 1, sourceLocation: sourceLocation)
    let finding = try #require(
        result.batch.findings.first,
        sourceLocation: sourceLocation
    )
    #expect(finding.kind == .move, sourceLocation: sourceLocation)
    #expect(
        finding.evidence.baselinePath == "/Fixtures/Old",
        sourceLocation: sourceLocation
    )
    #expect(
        finding.evidence.comparisonPath == "/Fixtures/New",
        sourceLocation: sourceLocation
    )
    #expect(
        result.batch.rankedPositiveFindingKeys.isEmpty,
        sourceLocation: sourceLocation
    )
    #expect(
        result.suppressionSummary.findingSuppressions.isEmpty,
        sourceLocation: sourceLocation
    )
    expectReasonCounts(
        result.suppressionSummary.rankingExclusions,
        equal: [(.rankingKindIneligible, 1)],
        sourceLocation: sourceLocation
    )
    expectReasonCounts(
        result.suppressionSummary.collapses,
        equal: [(.collapsedImplicitDescendantMove, depth - 1)],
        sourceLocation: sourceLocation
    )
}

private func requireFinding(
    subjectID: String,
    in result: HistoricalFindingGenerationResult
) throws -> HistoricalFindingDraft {
    try #require(
        result.batch.findings.first {
            $0.evidence.comparisonEndpointID.rawValue == "comparison-\(subjectID)"
        }
    )
}

private func expectReasonCounts(
    _ actual: [HistoricalFindingReasonCount],
    equal expected: [(HistoricalFindingReason, Int)],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(actual.map(\.reason) == expected.map(\.0), sourceLocation: sourceLocation)
    #expect(actual.map(\.count) == expected.map(\.1), sourceLocation: sourceLocation)
}
