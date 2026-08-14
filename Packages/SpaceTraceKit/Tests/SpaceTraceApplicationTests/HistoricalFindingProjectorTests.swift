import Testing
import SpaceTraceAttribution
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct HistoricalFindingProjectorTests {
    @Test("One pending frame pair is projected and committed through the public lifecycle seam")
    func projectsOnePendingFramePair() async throws {
        let baseline = try projectorFrame(sequence: 1, endpointPrefix: "baseline", bytes: 10)
        let comparison = try projectorFrame(sequence: 2, endpointPrefix: "comparison", bytes: 20)
        let work = try projectorWork(id: 1, baseline: 1, comparison: 2)
        let repository = ProjectorRepositoryStub(
            frames: [baseline, comparison],
            pending: [work]
        )
        let projector = HistoricalFindingProjector(repository: repository)

        let result = try await projector.projectPending(limit: 1)

        #expect(result.processedCount == 1)
        #expect(result.newlyCommittedCount == 1)
        #expect(result.alreadyCommittedCount == 0)
        let commits = await repository.commits
        #expect(commits.map(\.work) == [work])
        #expect(commits.first?.result.batch.findings.map(\.kind) == [.growth])
    }

    @Test("A repository that repeats committed work is rejected instead of spinning")
    func rejectsRepeatedWork() async throws {
        let baseline = try projectorFrame(sequence: 1, endpointPrefix: "baseline", bytes: 10)
        let comparison = try projectorFrame(sequence: 2, endpointPrefix: "comparison", bytes: 20)
        let work = try projectorWork(id: 7, baseline: 1, comparison: 2)
        let repository = ProjectorRepositoryStub(
            frames: [baseline, comparison],
            pending: [work],
            advanceAfterCommit: false,
            commitDisposition: .alreadyCommitted(try HistoricalProjectionRecordID(9))
        )
        let projector = HistoricalFindingProjector(repository: repository)

        await #expect(
            throws: HistoricalFindingProjectorError.repositoryDidNotAdvance(work.recordID)
        ) {
            try await projector.projectPending(limit: 2)
        }
        #expect(await repository.commits.count == 1)
    }

    @Test("Projection drains reject unbounded caller limits")
    func rejectsUnboundedLimit() async throws {
        let repository = ProjectorRepositoryStub(frames: [], pending: [])
        let projector = HistoricalFindingProjector(repository: repository)

        await #expect(throws: HistoricalFindingProjectorError.invalidLimit(101)) {
            try await projector.projectPending(limit: 101)
        }
    }

    @Test("Missing immutable frames fail closed without committing work")
    func rejectsMissingFrame() async throws {
        let work = try projectorWork(id: 3, baseline: 1, comparison: 2)
        let repository = ProjectorRepositoryStub(
            frames: [try projectorFrame(sequence: 1, endpointPrefix: "baseline", bytes: 10)],
            pending: [work]
        )
        let projector = HistoricalFindingProjector(repository: repository)

        await #expect(
            throws: HistoricalFindingProjectorError.missingFrame(
                try ObservationCommitSequence(2)
            )
        ) {
            try await projector.projectPending(limit: 1)
        }
        #expect(await repository.commits.isEmpty)
    }

    @Test("A bounded drain leaves later durable work for the next lifecycle pass")
    func respectsDrainLimit() async throws {
        let frames = try (1...4).map { sequence in
            try projectorFrame(
                sequence: Int64(sequence),
                endpointPrefix: "endpoint-\(sequence)",
                bytes: Int64(sequence * 10)
            )
        }
        let first = try projectorWork(id: 1, baseline: 1, comparison: 2)
        let second = try projectorWork(id: 2, baseline: 3, comparison: 4)
        let repository = ProjectorRepositoryStub(
            frames: frames,
            pending: [first, second]
        )
        let projector = HistoricalFindingProjector(repository: repository)

        let firstPass = try await projector.projectPending(limit: 1)
        let secondPass = try await projector.projectPending(limit: 1)

        #expect(firstPass.processedCount == 1)
        #expect(secondPass.processedCount == 1)
        #expect(await repository.commits.map(\.work.recordID) == [first.recordID, second.recordID])
    }
}

private actor ProjectorRepositoryStub: HistoricalFindingProjectionRepository {
    struct Commit: Sendable {
        let result: HistoricalFindingGenerationResult
        let work: HistoricalProjectionWork
    }

    private let framesBySequence: [ObservationCommitSequence: HistoricalFindingObservationFrame]
    private var pending: [HistoricalProjectionWork]
    private let advanceAfterCommit: Bool
    private let commitDisposition: HistoricalProjectionCommitOutcome?
    private(set) var commits: [Commit] = []

    init(
        frames: [HistoricalFindingObservationFrame],
        pending: [HistoricalProjectionWork],
        advanceAfterCommit: Bool = true,
        commitDisposition: HistoricalProjectionCommitOutcome? = nil
    ) {
        framesBySequence = Dictionary(uniqueKeysWithValues: frames.map { ($0.sequence, $0) })
        self.pending = pending
        self.advanceAfterCommit = advanceAfterCommit
        self.commitDisposition = commitDisposition
    }

    func historicalObservationFrame(
        sequence: ObservationCommitSequence
    ) -> HistoricalFindingObservationFrame? {
        framesBySequence[sequence]
    }

    func nextHistoricalProjectionWork() -> HistoricalProjectionWork? {
        pending.first
    }

    func commitHistoricalProjection(
        _ result: HistoricalFindingGenerationResult,
        for work: HistoricalProjectionWork
    ) throws -> HistoricalProjectionCommitOutcome {
        commits.append(Commit(result: result, work: work))
        if advanceAfterCommit, pending.first?.recordID == work.recordID {
            pending.removeFirst()
        }
        return try commitDisposition ?? .newlyCommitted(
            HistoricalProjectionRecordID(work.recordID.rawValue)
        )
    }
}

private func projectorWork(
    id: Int64,
    baseline: Int64,
    comparison: Int64,
    positiveLimit: Int = 10
) throws -> HistoricalProjectionWork {
    try HistoricalProjectionWork(
        recordID: HistoricalProjectionWorkID(id),
        baselineSequence: ObservationCommitSequence(baseline),
        comparisonSequence: ObservationCommitSequence(comparison),
        algorithmVersion: HistoricalFindingAlgorithmVersion(1),
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
        positiveLimit: positiveLimit
    )
}

private func projectorFrame(
    sequence: Int64,
    endpointPrefix: String,
    bytes: Int64
) throws -> HistoricalFindingObservationFrame {
    let endpoint = try ObservationEndpoint(
        id: ObservationEndpointID("\(endpointPrefix)-root"),
        scopeID: ScopeID("scope-a"),
        volumeID: ObservationVolumeID("volume-a"),
        mountGenerationID: ObservationMountGenerationID("mount-a"),
        coverageEpochID: ObservationCoverageEpochID("coverage-a"),
        subjectID: SubjectID("root"),
        identityBasis: .normalizedPath,
        locationID: ObservationLocationID("location-root"),
        metric: .logical,
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1),
        sequence: ObservationCommitSequence(sequence),
        observedAt: ObservationInstant(millisecondsSince1970: sequence * 1_000),
        state: .present(bytes: try ByteCount(bytes), coverage: .complete)
    )
    let classification = try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(1),
        result: .unknown(.noMatchingRule)
    )
    let root = try HistoricalFindingNode(
        endpoint: endpoint,
        parentSubjectID: nil,
        path: "/Fixtures",
        displayName: "Fixtures",
        directChildrenCoverage: .complete,
        classification: classification,
        stableIdentityEvidence: nil
    )
    return try HistoricalFindingObservationFrame(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Fixtures",
        nodes: [root]
    )
}
