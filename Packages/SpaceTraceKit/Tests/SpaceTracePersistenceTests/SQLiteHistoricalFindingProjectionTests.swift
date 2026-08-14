import Foundation
import SpaceTraceApplication
import SpaceTraceAttribution
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite deterministic historical finding projections", .serialized)
struct SQLiteHistoricalFindingProjectionTests {
    @Test("The application projector resumes and commits pending SQLite work")
    func applicationProjectorDrainsSQLiteWork() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)
        _ = try await prepareSimpleProjection(repository: repository)
        let projector = HistoricalFindingProjector(repository: repository)

        let run = try await projector.projectPending(limit: 10)

        #expect(run.processedCount == 2)
        #expect(run.newlyCommittedCount == 2)
        #expect(run.alreadyCommittedCount == 0)
        #expect(try fixture.count("historical_finding_projection") == 2)
        #expect(try fixture.count("historical_projection_checkpoint") == 2)
        #expect(try await repository.nextHistoricalProjectionWork() == nil)
        try await repository.close()
    }

    @Test("The lowest comparison sequence is projected and checkpointed atomically")
    func projectsLowestPendingWork() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)

        let first = try await prepareHistoricalLedgerRun(repository: repository)
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
        let second = try await prepareHistoricalLedgerRun(
            repository: repository,
            logicalRootBytes: 120,
            allocatedRootBytes: 96,
            child: .present(logical: 50, allocated: 40),
            observedAtMilliseconds: 2_000_000_100_000
        )
        _ = try await repository.finalizeCalibrationWithHistoricalFrames(second.request)

        let work = try #require(try await repository.nextHistoricalProjectionWork())
        let baseline = try #require(
            try await repository.historicalObservationFrame(sequence: work.baselineSequence)
        )
        let comparison = try #require(
            try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
        )
        let result = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison,
            positiveLimit: work.positiveLimit
        )

        let outcome = try await repository.commitHistoricalProjection(result, for: work)
        guard case .newlyCommitted = outcome else {
            Issue.record("Expected a newly committed projection.")
            return
        }
        #expect(try fixture.count("historical_finding_projection") == 1)
        #expect(try fixture.count("historical_projection_checkpoint") == 1)
        #expect(try await repository.nextHistoricalProjectionWork() != nil)
        try await repository.close()
    }

    @Test("A checkpoint failure rolls every projection row back and leaves the work pending")
    func checkpointFailureRollsBack() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(
            for: fixture,
            failurePoint: .beforeHistoricalProjectionCheckpoint
        )
        let (work, result) = try await prepareSimpleProjection(repository: repository)

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.commitHistoricalProjection(result, for: work)
        }
        #expect(try fixture.count("historical_finding_projection") == 0)
        #expect(try fixture.count("historical_finding") == 0)
        #expect(try fixture.count("historical_finding_positive_rank") == 0)
        #expect(try fixture.count("historical_finding_reason_count") == 0)
        #expect(try fixture.count("historical_projection_checkpoint") == 0)
        #expect(try await repository.nextHistoricalProjectionWork() == work)
        try await repository.close()
    }

    @Test("Commit success followed by response loss rehydrates the exact projection after reopen")
    func responseLossIsIdempotent() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        var repository = try projectionRepository(
            for: fixture,
            failurePoint: .afterHistoricalProjectionCommitBeforeReturningReceipt
        )
        let (work, result) = try await prepareSimpleProjection(repository: repository)

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await repository.commitHistoricalProjection(result, for: work)
        }
        #expect(try fixture.count("historical_finding_projection") == 1)
        #expect(try fixture.count("historical_projection_checkpoint") == 1)
        try await repository.close()

        repository = try projectionRepository(for: fixture)
        let retry = try await repository.commitHistoricalProjection(result, for: work)
        guard case .alreadyCommitted(let projectionID) = retry else {
            Issue.record("Expected the committed projection to rehydrate on retry.")
            return
        }
        #expect(projectionID.rawValue == 1)
        #expect(try fixture.count("historical_finding_projection") == 1)
        #expect(try fixture.count("historical_projection_checkpoint") == 1)
        let baseline = try #require(
            try await repository.historicalObservationFrame(sequence: work.baselineSequence)
        )
        let comparison = try #require(
            try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
        )
        let conflictingResult = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison,
            positiveLimit: 9
        )
        await #expect(
            throws: SQLiteEventJournalError.historicalProjectionImmutableConflict
        ) {
            _ = try await repository.commitHistoricalProjection(conflictingResult, for: work)
        }
        try await repository.close()
    }

    @Test("A valid but non-authoritative result cannot be committed for a work item")
    func regeneratedResultIsAuthoritative() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)
        let (work, _) = try await prepareSimpleProjection(repository: repository)
        let baseline = try #require(
            try await repository.historicalObservationFrame(sequence: work.baselineSequence)
        )
        let comparison = try #require(
            try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
        )
        let differentLimit = try HistoricalFindingGenerator().generate(
            baseline: baseline,
            comparison: comparison,
            positiveLimit: 9
        )

        await #expect(
            throws: SQLiteEventJournalError.historicalProjectionResultMismatch
        ) {
            _ = try await repository.commitHistoricalProjection(differentLimit, for: work)
        }
        #expect(try fixture.count("historical_finding_projection") == 0)
        #expect(try fixture.count("historical_projection_checkpoint") == 0)
        try await repository.close()
    }

    @Test("A moved descendant retains its byte change through a stored movement ancestor")
    func movementAncestryPersists() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)
        let stable = try projectionStableEvidence("stable-tree")

        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_000_000,
            nodes: [
                try .present("root", nil, "root", "/Projection", 500, 400),
                try .present(
                    "folder", "root", "folder-old", "/Projection/Folder", 200, 160,
                    stable: stable
                ),
                try .present(
                    "nested", "folder", "nested-old", "/Projection/Folder/Nested", 100, 80,
                    stable: try projectionStableEvidence("stable-nested")
                ),
            ]
        )
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000,
            nodes: [
                try .present("root", nil, "root", "/Projection", 550, 440),
                try .present(
                    "folder", "root", "folder-new", "/Projection/MovedFolder", 250, 200,
                    stable: stable
                ),
                try .present(
                    "nested", "folder", "nested-new", "/Projection/MovedFolder/Nested", 150, 120,
                    stable: try projectionStableEvidence("stable-nested")
                ),
            ]
        )

        let work = try #require(try await repository.nextHistoricalProjectionWork())
        let result = try await projectionResult(repository: repository, work: work)
        #expect(result.batch.findings.contains { $0.kind == .move })
        #expect(result.batch.findings.contains {
            $0.kind == .growth && $0.movementContext != nil
        })
        _ = try await repository.commitHistoricalProjection(result, for: work)

        #expect(
            try fixture.int(
                "SELECT count(*) FROM historical_finding WHERE movement_ancestor_finding_id IS NOT NULL"
            ) == 1
        )
        #expect(
            try fixture.int(
                "SELECT count(*) FROM historical_finding child JOIN historical_finding parent ON parent.finding_id=child.movement_ancestor_finding_id WHERE child.kind=4 AND parent.kind=5"
            ) == 1
        )
        try await repository.close()
    }

    @Test("All five finding kinds and frozen classifications survive normalized persistence")
    func allFindingKindsPersist() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)
        let stable = try projectionStableEvidence("stable-move")
        let classified = try projectionClassifiedDecision()

        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_000_000,
            nodes: try fiveKindNodes(
                appearance: .present(logical: 100, allocated: 80),
                disappearance: .present(logical: 100, allocated: 80),
                growth: (100, 80), decrease: (100, 80),
                moveLocation: "move-old", movePath: "/Projection/Move",
                stable: stable, classified: classified
            )
        )
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000,
            nodes: try fiveKindNodes(
                appearance: .absent,
                disappearance: .present(logical: 100, allocated: 80),
                growth: (100, 80), decrease: (100, 80),
                moveLocation: "move-old", movePath: "/Projection/Move",
                stable: stable, classified: classified
            )
        )
        _ = try await commitNextProjection(repository: repository)
        _ = try await commitNextProjection(repository: repository)
        let finalCommit = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_200_000,
            nodes: try fiveKindNodes(
                appearance: .present(logical: 100, allocated: 80),
                disappearance: .absent,
                growth: (150, 120), decrease: (50, 40),
                moveLocation: "move-new", movePath: "/Projection/Moved",
                stable: stable, classified: classified
            )
        )
        _ = try await commitNextProjection(repository: repository)
        _ = try await commitNextProjection(repository: repository)

        let kindCounts = try fixture.rows(
            "SELECT f.kind,count(*) FROM historical_finding f JOIN historical_finding_projection p ON p.projection_id=f.projection_id JOIN historical_projection_work w ON w.work_id=p.work_id WHERE w.comparison_sequence IN (\(finalCommit.logical.sequence.rawValue),\(finalCommit.allocated.sequence.rawValue)) GROUP BY f.kind ORDER BY f.kind"
        )
        #expect(kindCounts == [["1", "2"], ["2", "2"], ["3", "2"], ["4", "2"], ["5", "2"]])
        #expect(
            try fixture.int(
                "SELECT count(*) FROM frozen_attribution_decision WHERE decision_kind=1 AND category_code=1 AND confidence_code=1"
            ) == 1
        )
        #expect(try fixture.count("historical_finding_positive_rank") == 4)
        try await repository.close()
    }

    @Test("Top ten ranking truncates deterministically without discarding findings")
    func topTenPersists() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)
        var baseline = [try ProjectionNodeSpec.present("root", nil, "root", "/Projection", 1_000, 800)]
        var comparison = [try ProjectionNodeSpec.present("root", nil, "root", "/Projection", 1_000, 800)]
        for index in 0..<12 {
            baseline.append(
                try .present(
                    "growth-\(index)", "root", "growth-\(index)",
                    "/Projection/Growth-\(index)", 10, 8
                )
            )
            comparison.append(
                try .present(
                    "growth-\(index)", "root", "growth-\(index)",
                    "/Projection/Growth-\(index)", Int64(22 + index), Int64(18 + index)
                )
            )
        }
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_000_000,
            nodes: baseline
        )
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000,
            nodes: comparison
        )
        let (_, projectionID) = try await commitNextProjection(repository: repository)

        #expect(
            try fixture.int(
                "SELECT count(*) FROM historical_finding WHERE projection_id=\(projectionID.rawValue)"
            ) == 12
        )
        #expect(
            try fixture.int(
                "SELECT count(*) FROM historical_finding_positive_rank WHERE projection_id=\(projectionID.rawValue)"
            ) == 10
        )
        #expect(
            try fixture.int(
                "SELECT truncated_positive_count FROM historical_finding_projection WHERE projection_id=\(projectionID.rawValue)"
            ) == 2
        )
        try await repository.close()
    }

    @Test("A typed frame incompatibility is stored as an empty suppression projection")
    func frameSuppressionPersistsWithoutFindings() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)
        let nodes = [
            try ProjectionNodeSpec.present("root", nil, "root", "/Projection", 100, 80),
        ]
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_000_000,
            nodes: nodes,
            volumeID: "volume-a"
        )
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000,
            nodes: nodes,
            volumeID: "volume-b"
        )
        let (result, projectionID) = try await commitNextProjection(repository: repository)

        #expect(result.batch.findings.isEmpty)
        #expect(result.suppressionSummary.findingSuppressions.first?.reason == .frameVolumeMismatch)
        #expect(
            try fixture.int(
                "SELECT count(*) FROM historical_finding WHERE projection_id=\(projectionID.rawValue)"
            ) == 0
        )
        #expect(
            try fixture.rows(
                "SELECT category,reason_code,count FROM historical_finding_reason_count WHERE projection_id=\(projectionID.rawValue)"
            ) == [["1", "3", "1"]]
        )
        try await repository.close()
    }

    @Test("A new subject without explicit prior absence remains a typed missing-baseline suppression")
    func missingSubjectNeverBecomesAppearance() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(for: fixture)
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_000_000,
            nodes: [try .present("root", nil, "root", "/Projection", 100, 80)]
        )
        _ = try await prepareProjectionRun(
            repository: repository,
            observedAtMilliseconds: 2_000_000_100_000,
            nodes: [
                try .present("root", nil, "root", "/Projection", 100, 80),
                try .present("new", "root", "new", "/Projection/New", 20, 16),
            ]
        )
        let (result, projectionID) = try await commitNextProjection(repository: repository)

        #expect(result.batch.findings.contains { $0.kind == .appearance } == false)
        #expect(result.suppressionSummary.findingSuppressions.contains {
            $0.reason == .missingBaselineEndpoint && $0.count == 1
        })
        #expect(
            try fixture.rows(
                "SELECT category,reason_code,count FROM historical_finding_reason_count WHERE projection_id=\(projectionID.rawValue)"
            ).contains(["1", "10", "1"])
        )
        try await repository.close()
    }

    @Test("Unsupported projection versions fail before becoming durable work")
    func unsupportedVersionsFailClosed() throws {
        #expect(throws: HistoricalFindingPersistenceModelError.unsupportedProjectionVersion) {
            _ = try HistoricalProjectionWork(
                recordID: HistoricalProjectionWorkID(1),
                baselineSequence: ObservationCommitSequence(1),
                comparisonSequence: ObservationCommitSequence(2),
                algorithmVersion: HistoricalFindingAlgorithmVersion(2),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                positiveLimit: 10
            )
        }
    }

    @Test("A canonical finding-key digest collision is an immutable conflict, never success")
    func digestCollisionRollsBack() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let repository = try projectionRepository(
            for: fixture,
            failurePoint: .forceHistoricalFindingKeyDigestCollision
        )
        let (work, result) = try await prepareSimpleProjection(repository: repository)
        #expect(result.batch.findings.count >= 2)

        await #expect(
            throws: SQLiteEventJournalError.historicalProjectionImmutableConflict
        ) {
            _ = try await repository.commitHistoricalProjection(result, for: work)
        }
        #expect(try fixture.count("historical_finding_projection") == 0)
        #expect(try fixture.count("historical_finding") == 0)
        #expect(try fixture.count("historical_projection_checkpoint") == 0)
        try await repository.close()
    }

    @Test("Wrong-work, orphan-store and endpoint-reuse evidence never reaches SQL")
    func foreignEvidenceFailsBeforeInsertion() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        let otherFixture = try HistoricalLedgerTestFixture()
        defer {
            fixture.remove()
            otherFixture.remove()
        }
        let repository = try projectionRepository(for: fixture)
        let (work, result) = try await prepareSimpleProjection(repository: repository)
        _ = try await repository.commitHistoricalProjection(result, for: work)
        let allocatedWork = try #require(try await repository.nextHistoricalProjectionWork())

        await #expect(
            throws: SQLiteEventJournalError.historicalProjectionResultMismatch
        ) {
            _ = try await repository.commitHistoricalProjection(result, for: allocatedWork)
        }

        let otherRepository = try projectionRepository(
            for: otherFixture,
            generationByte: 0x22
        )
        let (_, foreignResult) = try await prepareSimpleProjection(repository: otherRepository)
        await #expect(
            throws: SQLiteEventJournalError.historicalProjectionResultMismatch
        ) {
            _ = try await repository.commitHistoricalProjection(foreignResult, for: allocatedWork)
        }

        let frame = try #require(
            try await repository.historicalObservationFrame(sequence: allocatedWork.baselineSequence)
        )
        #expect(throws: HistoricalFindingGenerationError.self) {
            _ = try HistoricalFindingGenerator().generate(
                baseline: frame,
                comparison: frame,
                positiveLimit: 10
            )
        }
        #expect(try fixture.count("historical_finding_projection") == 1)
        #expect(try fixture.count("historical_projection_checkpoint") == 1)
        try await otherRepository.close()
        try await repository.close()
    }
}

private func prepareSimpleProjection(
    repository: SQLiteEventJournalRepository
) async throws -> (HistoricalProjectionWork, HistoricalFindingGenerationResult) {
    let first = try await prepareHistoricalLedgerRun(repository: repository)
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
    let second = try await prepareHistoricalLedgerRun(
        repository: repository,
        logicalRootBytes: 120,
        allocatedRootBytes: 96,
        child: .present(logical: 50, allocated: 40),
        observedAtMilliseconds: 2_000_000_100_000
    )
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(second.request)
    let work = try #require(try await repository.nextHistoricalProjectionWork())
    let baseline = try #require(
        try await repository.historicalObservationFrame(sequence: work.baselineSequence)
    )
    let comparison = try #require(
        try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
    )
    let result = try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison,
        positiveLimit: work.positiveLimit
    )
    return (work, result)
}

private struct ProjectionNodeSpec {
    let subject: String
    let parent: String?
    let location: String
    let path: String
    let state: HistoricalPairedObservationStateCandidate
    let stable: HistoricalFindingStableIdentityEvidence?
    let classification: VersionedAttributionDecision?

    static func present(
        _ subject: String,
        _ parent: String?,
        _ location: String,
        _ path: String,
        _ logical: Int64,
        _ allocated: Int64,
        stable: HistoricalFindingStableIdentityEvidence? = nil,
        classification: VersionedAttributionDecision? = historicalLedgerNoMatchDecision()
    ) throws -> Self {
        try Self(
            subject: subject,
            parent: parent,
            location: location,
            path: path,
            state: .present(
                logicalBytes: ByteCount(logical),
                allocatedBytes: ByteCount(allocated),
                measurementCoverage: .complete
            ),
            stable: stable,
            classification: classification
        )
    }

    static func absent(
        _ subject: String,
        _ parent: String?,
        _ location: String,
        _ path: String
    ) -> Self {
        Self(
            subject: subject,
            parent: parent,
            location: location,
            path: path,
            state: .absent,
            stable: nil,
            classification: nil
        )
    }
}

private func prepareProjectionRun(
    repository: SQLiteEventJournalRepository,
    observedAtMilliseconds: Int64,
    nodes: [ProjectionNodeSpec],
    volumeID: String = "projection-volume"
) async throws -> HistoricalCalibrationCommit {
    let streamID = try EventStreamID("projection-stream")
    let rootPath = try DirtyRegionPath("/Projection")
    try await repository.markDirty(
        streamID: streamID,
        regions: [
            try DirtyRegion(
                path: rootPath,
                reasons: [.contentModified, .requiresCalibration],
                maximumCursor: EventJournalCursor(UInt64(observedAtMilliseconds))
            ),
        ]
    )
    let workItem = try #require(
        try await repository.pendingDirtyWork(for: streamID, limit: 1).first
    )
    let runID = try await repository.beginCalibration(
        CalibrationRequest(streamID: streamID, workItem: workItem)
    )
    let aggregates = try nodes.compactMap { node -> DirectoryMetadataAggregate? in
        guard case let .present(logical, allocated, coverage) = node.state else {
            return nil
        }
        let calibrationCoverage: CalibrationCoverage = switch coverage {
        case .complete: .complete
        case .partial: .partial
        case .unknown: .partial
        }
        return try DirectoryMetadataAggregate(
            path: DirtyRegionPath(node.path),
            logicalBytes: logical,
            allocatedBytes: allocated,
            descendantCount: 0,
            coverage: calibrationCoverage
        )
    }
    try await repository.stageCalibration(aggregates, in: runID)
    let report = try CalibrationReport(
        coverage: .complete,
        entriesVisited: Int64(aggregates.count),
        directoriesStaged: Int64(aggregates.count),
        gaps: []
    )
    let candidateNodes = try nodes.enumerated().map { offset, node in
        try HistoricalPairedObservationNodeCandidate(
            subjectID: SubjectID(node.subject),
            identityBasis: node.stable == nil ? .normalizedPath : .stableFileSystemObject,
            parentSubjectID: try node.parent.map(SubjectID.init),
            locationID: ObservationLocationID(node.location),
            path: node.path,
            displayName: node.path.split(separator: "/").last.map(String.init) ?? "Projection",
            observedAt: ObservationInstant(
                millisecondsSince1970: observedAtMilliseconds + Int64(offset)
            ),
            state: node.state,
            directChildrenCoverage: node.classification == nil ? .unknown : .complete,
            classification: node.classification,
            stableIdentityEvidence: node.stable
        )
    }
    let observation = try HistoricalPairedObservationCandidate(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Projection",
        nodes: candidateNodes,
        scopeID: ScopeID("projection-scope"),
        volumeID: ObservationVolumeID(volumeID),
        mountGenerationID: ObservationMountGenerationID("projection-mount"),
        coverageEpochID: ObservationCoverageEpochID("projection-coverage"),
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1)
    )
    let outcome = try await repository.finalizeCalibrationWithHistoricalFrames(
        try HistoricalCalibrationFinalizationRequest(
            runID: runID,
            report: report,
            workItem: workItem,
            streamID: streamID,
            observation: observation
        )
    )
    guard case .published(let commit) = outcome else {
        throw ProjectionTestError.expectedPublished
    }
    return commit
}

private func projectionResult(
    repository: SQLiteEventJournalRepository,
    work: HistoricalProjectionWork
) async throws -> HistoricalFindingGenerationResult {
    let baseline = try #require(
        try await repository.historicalObservationFrame(sequence: work.baselineSequence)
    )
    let comparison = try #require(
        try await repository.historicalObservationFrame(sequence: work.comparisonSequence)
    )
    return try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison,
        positiveLimit: work.positiveLimit
    )
}

private func commitNextProjection(
    repository: SQLiteEventJournalRepository
) async throws -> (HistoricalFindingGenerationResult, HistoricalProjectionRecordID) {
    let work = try #require(try await repository.nextHistoricalProjectionWork())
    let result = try await projectionResult(repository: repository, work: work)
    let outcome = try await repository.commitHistoricalProjection(result, for: work)
    switch outcome {
    case .newlyCommitted(let projectionID), .alreadyCommitted(let projectionID):
        return (result, projectionID)
    }
}

private enum ProjectionAvailability {
    case present(logical: Int64, allocated: Int64)
    case absent
}

private func fiveKindNodes(
    appearance: ProjectionAvailability,
    disappearance: ProjectionAvailability,
    growth: (logical: Int64, allocated: Int64),
    decrease: (logical: Int64, allocated: Int64),
    moveLocation: String,
    movePath: String,
    stable: HistoricalFindingStableIdentityEvidence,
    classified: VersionedAttributionDecision
) throws -> [ProjectionNodeSpec] {
    var result = [
        try ProjectionNodeSpec.present("root", nil, "root", "/Projection", 500, 400),
        try ProjectionNodeSpec.present(
            "growth", "root", "growth", "/Projection/Growth",
            growth.logical, growth.allocated,
            classification: classified
        ),
        try ProjectionNodeSpec.present(
            "decrease", "root", "decrease", "/Projection/Decrease",
            decrease.logical, decrease.allocated
        ),
        try ProjectionNodeSpec.present(
            "move", "root", moveLocation, movePath, 100, 80, stable: stable
        ),
    ]
    switch appearance {
    case .present(let logical, let allocated):
        result.append(
            try .present(
                "appearance", "root", "appearance", "/Projection/Appearance",
                logical, allocated
            )
        )
    case .absent:
        result.append(.absent("appearance", "root", "appearance", "/Projection/Appearance"))
    }
    switch disappearance {
    case .present(let logical, let allocated):
        result.append(
            try .present(
                "disappearance", "root", "disappearance", "/Projection/Disappearance",
                logical, allocated
            )
        )
    case .absent:
        result.append(
            .absent("disappearance", "root", "disappearance", "/Projection/Disappearance")
        )
    }
    return result
}

private func projectionClassifiedDecision() throws -> VersionedAttributionDecision {
    try VersionedAttributionDecision(
        catalogVersion: AttributionCatalogVersion(7),
        result: .classified(
            try StorageAttribution(
                category: .developerTools,
                confidence: .high,
                ruleID: AttributionRuleID("developer.fixture"),
                ruleVersion: AttributionRuleVersion(3),
                evidenceCode: AttributionEvidenceCode("fixture.developer")
            )
        )
    )
}

private func projectionStableEvidence(
    _ token: String
) throws -> HistoricalFindingStableIdentityEvidence {
    try HistoricalFindingStableIdentityEvidence(
        reuseGuard: .generationToken(token),
        nodeKind: .directory,
        linkStatus: .unique
    )
}

private enum ProjectionTestError: Error {
    case expectedPublished
}

private func projectionRepository(
    for fixture: HistoricalLedgerTestFixture,
    failurePoint: SQLiteEventJournalTestFailurePoint? = nil,
    generationByte: UInt8 = 0x11
) throws -> SQLiteEventJournalRepository {
    try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: failurePoint,
        now: { Date(timeIntervalSince1970: 2_000_000_010) },
        historicalStoreGenerationProvider: { Array(repeating: generationByte, count: 16) }
    )
}
