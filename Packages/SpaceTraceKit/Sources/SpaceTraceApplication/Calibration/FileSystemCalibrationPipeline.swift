public struct CalibrationRequest: Sendable, Equatable {
    public let streamID: EventStreamID
    public let workItem: DirtyRegionWorkItem

    public init(streamID: EventStreamID, workItem: DirtyRegionWorkItem) {
        self.streamID = streamID
        self.workItem = workItem
    }
}

public enum CalibrationCoverage: Sendable, Equatable {
    /// Every descendant in the requested region was enumerated successfully.
    case complete
    /// Cancellation, permission denial, or an enumeration failure left gaps.
    case partial
}

public protocol CalibrationScanner: Sendable {
    func scan(_ request: CalibrationRequest) async throws -> CalibrationCoverage
}

public actor FileSystemCalibrationPipeline {
    private let streamID: EventStreamID
    private let watchRoot: DirtyRegionPath
    private let repository: any EventJournalRepository
    private let scanner: any CalibrationScanner
    private let planner: DirtyRegionPlanner

    public init(
        streamID: EventStreamID,
        watchRoot: DirtyRegionPath,
        repository: any EventJournalRepository,
        scanner: any CalibrationScanner,
        planner: DirtyRegionPlanner = DirtyRegionPlanner()
    ) {
        self.streamID = streamID
        self.watchRoot = watchRoot
        self.repository = repository
        self.scanner = scanner
        self.planner = planner
    }

    public func ingest(_ invalidations: [FileSystemInvalidation]) async throws {
        guard invalidations.isEmpty == false else { return }

        let checkpoint = try await repository.checkpoint(for: streamID)
        let plan = try planner.plan(
            watchRoot: watchRoot,
            invalidations: invalidations,
            after: checkpoint
        )

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
            let coverage = try await scanner.scan(
                CalibrationRequest(streamID: streamID, workItem: workItem)
            )
            guard coverage == .complete else { continue }
            if try await repository.resolve(workItem, for: streamID) {
                resolvedCount += 1
            }
        }
        return resolvedCount
    }
}
