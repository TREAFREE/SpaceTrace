public struct CalibrationRequest: Sendable, Equatable {
    public let streamID: EventStreamID
    public let workItem: DirtyRegionWorkItem
    public let budget: CalibrationScanBudget

    public init(
        streamID: EventStreamID,
        workItem: DirtyRegionWorkItem,
        budget: CalibrationScanBudget = .incremental
    ) {
        self.streamID = streamID
        self.workItem = workItem
        self.budget = budget
    }
}

public enum CalibrationCoverage: Sendable, Equatable {
    /// Every descendant in the requested region was enumerated successfully.
    case complete
    /// Cancellation, permission denial, or an enumeration failure left gaps.
    case partial
}

public protocol CalibrationScanner: Sendable {
    func scan(
        _ request: CalibrationRequest,
        stage: @escaping @Sendable ([DirectoryMetadataAggregate]) async throws -> Void
    ) async throws -> CalibrationReport
}

public actor FileSystemCalibrationPipeline {
    private let streamID: EventStreamID
    private let watchRoot: DirtyRegionPath
    private let repository: any EventJournalRepository
    private let scanner: any CalibrationScanner
    private let planner: DirtyRegionPlanner
    private let scanBudget: CalibrationScanBudget

    public init(
        streamID: EventStreamID,
        watchRoot: DirtyRegionPath,
        repository: any EventJournalRepository,
        scanner: any CalibrationScanner,
        planner: DirtyRegionPlanner = DirtyRegionPlanner(),
        scanBudget: CalibrationScanBudget = .incremental
    ) {
        self.streamID = streamID
        self.watchRoot = watchRoot
        self.repository = repository
        self.scanner = scanner
        self.planner = planner
        self.scanBudget = scanBudget
    }

    public func ingest(_ invalidations: [FileSystemInvalidation]) async throws {
        guard invalidations.isEmpty == false else { return }

        let checkpoint = try await repository.checkpoint(for: streamID)
        let plan = try planner.plan(
            watchRoot: watchRoot,
            invalidations: invalidations,
            after: checkpoint
        )

        if plan.invalidatesCheckpoint {
            try await repository.invalidateCheckpointAndMarkDirty(
                streamID: streamID,
                regions: plan.outOfBandRegions
            )
            return
        }

        if plan.outOfBandRegions.isEmpty == false {
            try await repository.markDirty(
                streamID: streamID,
                regions: plan.outOfBandRegions
            )
        }
        if let checkpoint = plan.checkpoint, plan.journaledRegions.isEmpty == false {
            try await repository.commit(
                EventJournalBatch(
                    streamID: streamID,
                    checkpoint: checkpoint,
                    dirtyRegions: plan.journaledRegions
                )
            )
        }
    }

    /// Processes a bounded snapshot. New events can safely arrive during a
    /// scan because `resolve` compares the revision captured before scanning.
    @discardableResult
    public func calibratePending(limit: Int) async throws -> Int {
        guard limit > 0 else { return 0 }
        let workItems = try await repository.pendingDirtyWork(for: streamID, limit: limit)
        var resolvedCount = 0

        for workItem in workItems {
            try Task.checkCancellation()
            let request = CalibrationRequest(
                streamID: streamID,
                workItem: workItem,
                budget: scanBudget
            )
            let runID = try await repository.beginCalibration(request)
            do {
                let report = try await scanner.scan(request) { [repository] batch in
                    try await repository.stageCalibration(batch, in: runID)
                }
                guard report.coverage == .complete else {
                    try await repository.discardCalibration(
                        runID,
                        disposition: .partial,
                        report: report
                    )
                    continue
                }
                if try await repository.finalizeCalibration(
                    runID,
                    report: report,
                    workItem: workItem,
                    streamID: streamID
                ) {
                    resolvedCount += 1
                }
            } catch is CancellationError {
                try? await repository.discardCalibration(
                    runID,
                    disposition: .cancelled,
                    report: nil
                )
                throw CancellationError()
            } catch {
                try? await repository.discardCalibration(
                    runID,
                    disposition: .failed,
                    report: nil
                )
                throw error
            }
        }
        return resolvedCount
    }
}
