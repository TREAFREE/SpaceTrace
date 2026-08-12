import Foundation
import Testing
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct FileSystemCalibrationPipelineTests {
    @Test("Complete calibration conditionally resolves durable work")
    func resolvesCompleteCalibration() async throws {
        let repository = InMemoryEventJournalRepository()
        let scanner = FakeCalibrationScanner(coverage: .complete)
        let pipeline = try makePipeline(repository: repository, scanner: scanner)

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        #expect(try await pipeline.calibratePending(limit: 10) == 1)
        #expect(try await repository.dirtyRegions(for: streamID()).isEmpty)
        #expect(await scanner.requestCount == 1)
    }

    @Test("Typed progress distinguishes scanning, atomic publication, and the final result")
    func reportsTypedPublicationProgress() async throws {
        let repository = InMemoryEventJournalRepository()
        let scanner = FakeCalibrationScanner(coverage: .complete)
        let pipeline = try makePipeline(repository: repository, scanner: scanner)
        let progress = ProgressRecorder()

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        let results = try await pipeline.calibratePendingResults(limit: 1) { update in
            await progress.record(update)
        }

        let result = try #require(results.first)
        #expect(result.disposition == .published)
        #expect(result.report.coverage == .complete)
        #expect(await progress.phases == [.scanning, .publishing])
    }

    @Test("Partial calibration never clears work")
    func preservesPartialCalibration() async throws {
        let repository = InMemoryEventJournalRepository()
        let pipeline = try makePipeline(
            repository: repository,
            scanner: FakeCalibrationScanner(coverage: .partial)
        )

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        #expect(try await pipeline.calibratePending(limit: 10) == 0)
        #expect(try await repository.dirtyRegions(for: streamID()).count == 1)
    }

    @Test("Partial evidence is returned without entering the publication phase")
    func reportsPartialAttemptWithoutPublishing() async throws {
        let repository = InMemoryEventJournalRepository()
        let pipeline = try makePipeline(
            repository: repository,
            scanner: FakeCalibrationScanner(coverage: .partial)
        )
        let progress = ProgressRecorder()

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        let results = try await pipeline.calibratePendingResults(limit: 1) { update in
            await progress.record(update)
        }

        #expect(results.map(\.disposition) == [.partialCoverage])
        #expect(await progress.phases == [.scanning])
        #expect(try await repository.currentDirectoryAggregates(for: streamID()).isEmpty)
    }

    @Test("A newer event arriving during a scan defeats the stale resolution token")
    func newerEventWinsRace() async throws {
        let repository = InMemoryEventJournalRepository()
        let streamID = try streamID()
        let scanner = FakeCalibrationScanner(coverage: .complete) { request in
            let newer = try DirtyRegion(
                path: request.workItem.region.path,
                reasons: [.removed],
                maximumCursor: nil
            )
            try await repository.markDirty(streamID: streamID, regions: [newer])
        }
        let pipeline = try makePipeline(repository: repository, scanner: scanner)

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        #expect(try await pipeline.calibratePending(limit: 1) == 0)
        let regions = await repository.dirtyRegions(for: streamID)
        let remaining = try #require(regions.first)
        #expect(remaining.reasons == [.contentModified, .removed])
    }

    @Test("Cancellation discards staged data and preserves durable dirty work")
    func cancellationRollsBackStaging() async throws {
        let repository = InMemoryEventJournalRepository()
        let scanner = FakeCalibrationScanner(coverage: .complete) { _ in
            throw CancellationError()
        }
        let pipeline = try makePipeline(repository: repository, scanner: scanner)

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        do {
            _ = try await pipeline.calibratePending(limit: 1)
            Issue.record("Expected cancellation to escape the pipeline.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try await repository.dirtyRegions(for: streamID()).count == 1)
        #expect(try await repository.currentDirectoryAggregates(for: streamID()).isEmpty)
        #expect(await repository.discardedDispositions == [.cancelled])
    }

    @Test("A wrapped journal atomically clears its checkpoint and preserves recovery work")
    func wrappedJournalResetsCheckpoint() async throws {
        let repository = InMemoryEventJournalRepository()
        let pipeline = try makePipeline(
            repository: repository,
            scanner: FakeCalibrationScanner(coverage: .complete)
        )

        try await pipeline.ingest([try fileInvalidation(cursor: 10)])
        #expect(try await repository.checkpoint(for: streamID()) == EventJournalCursor(10))
        try await pipeline.ingest([
            try FileSystemInvalidation(
                path: nil,
                cursor: nil,
                reasons: [.droppedEvents, .requiresCalibration],
                invalidatesStoredCursor: true
            ),
        ])

        #expect(try await repository.checkpoint(for: streamID()) == nil)
        let recovery = try #require(
            try await repository.dirtyRegions(for: streamID()).first
        )
        #expect(recovery.path.rawValue == "/Users/example")
        #expect(recovery.maximumCursor == nil)
        #expect(recovery.reasons.contains(.requiresCalibration))
    }

    @Test("Complete historical evidence uses paired v11 finalization and triggers projection")
    func publishesPairedHistoricalFrames() async throws {
        let repository = InMemoryEventJournalRepository()
        let root = try DirtyRegionPath("/Users/example")
        let scanner = FakeHistoricalCalibrationScanner(root: root)
        let projector = ProjectionTriggerRecorder()
        let pipeline = FileSystemCalibrationPipeline(
            streamID: try streamID(),
            watchRoot: root,
            repository: repository,
            scanner: scanner,
            historicalContext: try historicalContext(),
            historicalFindingProjector: projector
        )

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        let results = try await pipeline.calibratePendingResults(limit: 1)

        #expect(results.map(\.disposition) == [.published])
        let request = try #require(await repository.historicalRequests.first)
        #expect(request.observation.rootPath == root.rawValue)
        #expect(request.observation.nodes.count == 1)
        #expect(request.observation.nodes[0].classification != nil)
        #expect(await projector.requestedLimits == [100])
    }

    @Test("A deferred projection cannot roll back an already published frame pair")
    func projectionFailureDoesNotMisreportPublication() async throws {
        let repository = InMemoryEventJournalRepository()
        let root = try DirtyRegionPath("/Users/example")
        let projector = ProjectionTriggerRecorder(shouldFail: true)
        let pipeline = FileSystemCalibrationPipeline(
            streamID: try streamID(),
            watchRoot: root,
            repository: repository,
            scanner: FakeHistoricalCalibrationScanner(root: root),
            historicalContext: try historicalContext(),
            historicalFindingProjector: projector
        )

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        let result = try #require(
            try await pipeline.calibratePendingResults(limit: 1).first
        )

        #expect(result.disposition == .published)
        #expect(try await repository.dirtyRegions(for: streamID()).isEmpty)
        #expect(await repository.historicalRequests.count == 1)
        #expect(await projector.requestedLimits == [100])
    }

    @Test("Explicit historical mode fails closed when the scanner lacks evidence")
    func historicalModeRequiresRichScanner() async throws {
        let repository = InMemoryEventJournalRepository()
        let pipeline = try FileSystemCalibrationPipeline(
            streamID: streamID(),
            watchRoot: DirtyRegionPath("/Users/example"),
            repository: repository,
            scanner: FakeCalibrationScanner(coverage: .complete),
            historicalContext: historicalContext()
        )

        try await pipeline.ingest([try fileInvalidation(cursor: 1)])
        await #expect(throws: CalibrationPipelineError.historicalCapabilityUnavailable) {
            _ = try await pipeline.calibratePending(limit: 1)
        }
        #expect(try await repository.dirtyRegions(for: streamID()).count == 1)
        #expect(await repository.historicalRequests.isEmpty)
    }

    private func makePipeline(
        repository: InMemoryEventJournalRepository,
        scanner: FakeCalibrationScanner
    ) throws -> FileSystemCalibrationPipeline {
        try FileSystemCalibrationPipeline(
            streamID: streamID(),
            watchRoot: DirtyRegionPath("/Users/example"),
            repository: repository,
            scanner: scanner
        )
    }

    private func fileInvalidation(cursor: UInt64) throws -> FileSystemInvalidation {
        try FileSystemInvalidation(
            path: "/Users/example/Documents/file.txt",
            cursor: EventJournalCursor(cursor),
            reasons: [.contentModified],
            itemKind: .file
        )
    }

    private func streamID() throws -> EventStreamID {
        try EventStreamID("volume-a:generation-1")
    }

    private func historicalContext() throws -> HistoricalCalibrationContext {
        HistoricalCalibrationContext(
            scopeID: try ScopeID("scope-fixture"),
            volumeID: try ObservationVolumeID("volume-fixture"),
            mountGenerationID: try ObservationMountGenerationID("mount-fixture"),
            coverageEpochID: try ObservationCoverageEpochID("coverage-fixture"),
            homeDirectoryPath: "/Users/example"
        )
    }
}

private actor ProgressRecorder {
    enum Phase: Sendable, Equatable {
        case scanning
        case publishing
    }

    private(set) var phases: [Phase] = []

    func record(_ progress: CalibrationPipelineProgress) {
        switch progress {
        case .scanning:
            phases.append(.scanning)
        case .publishing:
            phases.append(.publishing)
        }
    }
}

private actor FakeCalibrationScanner: CalibrationScanner {
    private let coverage: CalibrationCoverage
    private let beforeReturn: @Sendable (CalibrationRequest) async throws -> Void
    private(set) var requestCount = 0

    init(
        coverage: CalibrationCoverage,
        beforeReturn: @escaping @Sendable (CalibrationRequest) async throws -> Void = { _ in }
    ) {
        self.coverage = coverage
        self.beforeReturn = beforeReturn
    }

    func scan(
        _ request: CalibrationRequest,
        stage: @escaping @Sendable ([DirectoryMetadataAggregate]) async throws -> Void
    ) async throws -> CalibrationReport {
        requestCount += 1
        let aggregate = try DirectoryMetadataAggregate(
            path: request.workItem.region.path,
            logicalBytes: .zero,
            allocatedBytes: .zero,
            descendantCount: 0,
            coverage: coverage
        )
        try await stage([aggregate])
        try await beforeReturn(request)
        return try CalibrationReport(
            coverage: coverage,
            entriesVisited: 1,
            directoriesStaged: 1,
            gaps: coverage == .complete
                ? []
                : [CalibrationGap(path: request.workItem.region.path, reason: .metadataUnavailable)]
        )
    }
}

private struct FakeHistoricalCalibrationScanner: HistoricalCalibrationScanner {
    let root: DirtyRegionPath

    func scan(
        _ request: CalibrationRequest,
        stage: @escaping @Sendable ([DirectoryMetadataAggregate]) async throws -> Void
    ) async throws -> CalibrationReport {
        try await scanHistorical(request, stage: stage).report
    }

    func scanHistorical(
        _ request: CalibrationRequest,
        stage: @escaping @Sendable ([DirectoryMetadataAggregate]) async throws -> Void
    ) async throws -> HistoricalCalibrationScanResult {
        let aggregate = try DirectoryMetadataAggregate(
            path: root,
            logicalBytes: try ByteCount(10),
            allocatedBytes: try ByteCount(16),
            descendantCount: 0,
            coverage: .complete
        )
        try await stage([aggregate])
        let report = try CalibrationReport(
            coverage: .complete,
            entriesVisited: 1,
            directoriesStaged: 1,
            gaps: []
        )
        let evidence = try HistoricalCalibrationScanEvidence(
            rootPath: root,
            directories: [
                try HistoricalDirectoryScanObservation(
                    path: root,
                    parentPath: nil,
                    logicalBytes: try ByteCount(10),
                    allocatedBytes: try ByteCount(16),
                    directChildrenCoverage: .complete,
                    observedAt: try ObservationInstant(
                        millisecondsSince1970: 1_800_000_000_000
                    ),
                    objectIdentity: nil
                ),
            ]
        )
        return try HistoricalCalibrationScanResult(report: report, evidence: evidence)
    }
}

private actor ProjectionTriggerRecorder: HistoricalFindingProjecting {
    enum Failure: Error {
        case injected
    }

    private let shouldFail: Bool
    private(set) var requestedLimits: [Int] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func projectPending(limit: Int) throws -> HistoricalFindingProjectionRun {
        requestedLimits.append(limit)
        if shouldFail { throw Failure.injected }
        return .empty
    }
}

private actor InMemoryEventJournalRepository: HistoricalCalibrationFinalizationRepository {
    private var savedCheckpoint: EventJournalCursor?
    private var work: [DirtyRegionPath: DirtyRegionWorkItem] = [:]
    private var nextRunID = 1
    private var runs: [CalibrationRunID: CalibrationRequest] = [:]
    private var staged: [CalibrationRunID: [DirectoryMetadataAggregate]] = [:]
    private var current: [DirtyRegionPath: DirectoryMetadataAggregate] = [:]
    private(set) var discardedDispositions: [CalibrationRunDisposition] = []
    private(set) var historicalRequests: [HistoricalCalibrationFinalizationRequest] = []

    func commit(_ batch: EventJournalBatch) throws {
        if let savedCheckpoint, batch.checkpoint < savedCheckpoint {
            return
        }
        try merge(batch.dirtyRegions)
        savedCheckpoint = batch.checkpoint
    }

    func markDirty(streamID: EventStreamID, regions: [DirtyRegion]) throws {
        try merge(regions)
    }

    func invalidateCheckpointAndMarkDirty(
        streamID: EventStreamID,
        regions: [DirtyRegion]
    ) throws {
        guard regions.isEmpty == false else { throw EventJournalModelError.emptyBatch }
        savedCheckpoint = nil
        for (path, item) in work {
            work[path] = DirtyRegionWorkItem(
                region: try DirtyRegion(
                    path: item.region.path,
                    reasons: item.region.reasons,
                    maximumCursor: nil
                ),
                revision: try DirtyRegionRevision(item.revision.rawValue + 1)
            )
        }
        try merge(regions)
    }

    func checkpoint(for streamID: EventStreamID) -> EventJournalCursor? {
        savedCheckpoint
    }

    func dirtyRegions(for streamID: EventStreamID) -> [DirtyRegion] {
        work.values.map(\.region).sorted { $0.path.rawValue < $1.path.rawValue }
    }

    func pendingDirtyWork(
        for streamID: EventStreamID,
        limit: Int
    ) -> [DirtyRegionWorkItem] {
        Array(
            work.values.sorted { $0.region.path.rawValue < $1.region.path.rawValue }
                .prefix(max(0, limit))
        )
    }

    func beginCalibration(_ request: CalibrationRequest) throws -> CalibrationRunID {
        let runID = try CalibrationRunID(
            String(format: "00000000-0000-0000-0000-%012d", nextRunID)
        )
        nextRunID += 1
        runs[runID] = request
        staged[runID] = []
        return runID
    }

    func stageCalibration(
        _ aggregates: [DirectoryMetadataAggregate],
        in runID: CalibrationRunID
    ) {
        staged[runID, default: []].append(contentsOf: aggregates)
    }

    func finalizeCalibration(
        _ runID: CalibrationRunID,
        report: CalibrationReport,
        workItem: DirtyRegionWorkItem,
        streamID: EventStreamID
    ) -> Bool {
        guard work[workItem.region.path]?.revision == workItem.revision,
              report.coverage == .complete else {
            staged[runID] = nil
            runs[runID] = nil
            return false
        }
        for aggregate in staged[runID] ?? [] {
            current[aggregate.path] = aggregate
        }
        work[workItem.region.path] = nil
        staged[runID] = nil
        runs[runID] = nil
        return true
    }

    func finalizeCalibrationWithHistoricalFrames(
        _ request: HistoricalCalibrationFinalizationRequest
    ) throws -> HistoricalCalibrationFinalizationOutcome {
        historicalRequests.append(request)
        guard finalizeCalibration(
            request.runID,
            report: request.report,
            workItem: request.workItem,
            streamID: request.streamID
        ) else {
            return .superseded
        }
        let ordinal = Int64(historicalRequests.count * 2)
        return .published(
            HistoricalCalibrationCommit(
                disposition: .newlyCommitted,
                logical: try HistoricalObservationFrameCommit(
                    sequence: try ObservationCommitSequence(ordinal - 1),
                    rootEndpointID: try ObservationEndpointID("logical-fixture-\(ordinal)"),
                    endpointCount: request.observation.nodes.count
                ),
                allocated: try HistoricalObservationFrameCommit(
                    sequence: try ObservationCommitSequence(ordinal),
                    rootEndpointID: try ObservationEndpointID("allocated-fixture-\(ordinal)"),
                    endpointCount: request.observation.nodes.count
                )
            )
        )
    }

    func discardCalibration(
        _ runID: CalibrationRunID,
        disposition: CalibrationRunDisposition,
        report: CalibrationReport?
    ) {
        discardedDispositions.append(disposition)
        staged[runID] = nil
        runs[runID] = nil
    }

    func currentDirectoryAggregates(
        for streamID: EventStreamID
    ) -> [DirectoryMetadataAggregate] {
        current.values.sorted { $0.path.rawValue < $1.path.rawValue }
    }

    private func merge(_ regions: [DirtyRegion]) throws {
        for region in regions {
            let existing = work[region.path]
            let nextRevision = (existing?.revision.rawValue ?? 0) + 1
            let merged = try DirtyRegion(
                path: region.path,
                reasons: region.reasons.union(existing?.region.reasons ?? []),
                maximumCursor: [region.maximumCursor, existing?.region.maximumCursor]
                    .compactMap { $0 }
                    .max()
            )
            work[region.path] = DirtyRegionWorkItem(
                region: merged,
                revision: try DirtyRegionRevision(nextRevision)
            )
        }
    }
}
