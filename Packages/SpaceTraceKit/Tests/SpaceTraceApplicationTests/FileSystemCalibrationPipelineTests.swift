import Testing
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

private actor InMemoryEventJournalRepository: EventJournalRepository {
    private var savedCheckpoint: EventJournalCursor?
    private var work: [DirtyRegionPath: DirtyRegionWorkItem] = [:]
    private var nextRunID = 1
    private var runs: [CalibrationRunID: CalibrationRequest] = [:]
    private var staged: [CalibrationRunID: [DirectoryMetadataAggregate]] = [:]
    private var current: [DirtyRegionPath: DirectoryMetadataAggregate] = [:]
    private(set) var discardedDispositions: [CalibrationRunDisposition] = []

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
        let runID = try CalibrationRunID("run-\(nextRunID)")
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
