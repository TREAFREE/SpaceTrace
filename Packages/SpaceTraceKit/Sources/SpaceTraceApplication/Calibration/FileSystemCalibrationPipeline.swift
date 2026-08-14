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

/// Optional richer scanner seam used by the immutable historical pipeline.
/// Implementations must produce the legacy staged aggregates and historical
/// evidence from the same traversal so the two atomic-publication inputs
/// cannot drift.
public protocol HistoricalCalibrationScanner: CalibrationScanner {
    func scanHistorical(
        _ request: CalibrationRequest,
        stage: @escaping @Sendable ([DirectoryMetadataAggregate]) async throws -> Void
    ) async throws -> HistoricalCalibrationScanResult
}

public enum CalibrationPipelineProgress: Sendable, Equatable {
    case scanning(DirtyRegionWorkItem)
    case publishing(DirtyRegionWorkItem, CalibrationReport)
}

public enum CalibrationAttemptDisposition: Sendable, Equatable {
    case published
    case partialCoverage
    case superseded
}

public struct CalibrationAttemptResult: Sendable, Equatable {
    public let workItem: DirtyRegionWorkItem
    public let report: CalibrationReport
    public let disposition: CalibrationAttemptDisposition

    public init(
        workItem: DirtyRegionWorkItem,
        report: CalibrationReport,
        disposition: CalibrationAttemptDisposition
    ) {
        self.workItem = workItem
        self.report = report
        self.disposition = disposition
    }
}

public actor FileSystemCalibrationPipeline {
    private let streamID: EventStreamID
    private let watchRoot: DirtyRegionPath
    private let repository: any EventJournalRepository
    private let scanner: any CalibrationScanner
    private let planner: DirtyRegionPlanner
    private let scanBudget: CalibrationScanBudget
    private let historicalContext: HistoricalCalibrationContext?
    private let historicalFindingProjector: (any HistoricalFindingProjecting)?
    private let historicalCandidateBuilder = HistoricalCalibrationCandidateBuilder()

    public init(
        streamID: EventStreamID,
        watchRoot: DirtyRegionPath,
        repository: any EventJournalRepository,
        scanner: any CalibrationScanner,
        historicalContext: HistoricalCalibrationContext? = nil,
        historicalFindingProjector: (any HistoricalFindingProjecting)? = nil,
        planner: DirtyRegionPlanner = DirtyRegionPlanner(),
        scanBudget: CalibrationScanBudget = .incremental
    ) {
        self.streamID = streamID
        self.watchRoot = watchRoot
        self.repository = repository
        self.scanner = scanner
        self.historicalContext = historicalContext
        self.historicalFindingProjector = historicalFindingProjector
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
        try await calibratePendingResults(limit: limit)
            .filter { $0.disposition == .published }
            .count
    }

    /// Returns evidence for every attempted region without weakening the
    /// existing atomic-publication contract. Partial and superseded scans are
    /// reported to callers but never published as current complete truth.
    public func calibratePendingResults(
        limit: Int,
        onProgress: @escaping @Sendable (CalibrationPipelineProgress) async -> Void = { _ in }
    ) async throws -> [CalibrationAttemptResult] {
        guard limit > 0 else { return [] }
        let workItems = try await repository.pendingDirtyWork(for: streamID, limit: limit)
        var results: [CalibrationAttemptResult] = []

        for workItem in workItems {
            try Task.checkCancellation()
            await onProgress(.scanning(workItem))
            let request = CalibrationRequest(
                streamID: streamID,
                workItem: workItem,
                budget: scanBudget
            )
            let runID = try await repository.beginCalibration(request)
            do {
                let stage: @Sendable ([DirectoryMetadataAggregate]) async throws -> Void = {
                    [repository] batch in
                    try await repository.stageCalibration(batch, in: runID)
                }
                let report: CalibrationReport
                let historicalEvidence: HistoricalCalibrationScanEvidence?
                if historicalContext != nil {
                    guard let scanner = scanner as? any HistoricalCalibrationScanner,
                          repository is any HistoricalCalibrationFinalizationRepository else {
                        throw CalibrationPipelineError.historicalCapabilityUnavailable
                    }
                    let result = try await scanner.scanHistorical(request, stage: stage)
                    report = result.report
                    historicalEvidence = result.evidence
                } else {
                    report = try await scanner.scan(request, stage: stage)
                    historicalEvidence = nil
                }
                guard report.coverage == .complete else {
                    try await repository.discardCalibration(
                        runID,
                        disposition: .partial,
                        report: report
                    )
                    results.append(
                        CalibrationAttemptResult(
                            workItem: workItem,
                            report: report,
                            disposition: .partialCoverage
                        )
                    )
                    continue
                }
                await onProgress(.publishing(workItem, report))
                let didPublish: Bool
                var shouldTriggerProjection = false
                if let historicalContext {
                    guard let historicalRepository = repository
                        as? any HistoricalCalibrationFinalizationRepository,
                          let historicalEvidence else {
                        throw CalibrationPipelineError.historicalEvidenceMissing
                    }
                    let observation = try historicalCandidateBuilder.build(
                        historicalEvidence,
                        context: historicalContext
                    )
                    let outcome = try await historicalRepository
                        .finalizeCalibrationWithHistoricalFrames(
                            try HistoricalCalibrationFinalizationRequest(
                                runID: runID,
                                report: report,
                                workItem: workItem,
                                streamID: streamID,
                                observation: observation
                            )
                        )
                    switch outcome {
                    case .published:
                        didPublish = true
                        shouldTriggerProjection = true
                    case .historyDisabled:
                        didPublish = true
                    case .superseded:
                        didPublish = false
                    }
                } else {
                    didPublish = try await repository.finalizeCalibration(
                        runID,
                        report: report,
                        workItem: workItem,
                        streamID: streamID
                    )
                }
                results.append(
                    CalibrationAttemptResult(
                        workItem: workItem,
                        report: report,
                        disposition: didPublish ? .published : .superseded
                    )
                )
                if shouldTriggerProjection,
                   let historicalFindingProjector {
                    // The paired commit is already durable. Projection work is
                    // idempotent and recovered at launch, so a transient drain
                    // failure must not misreport the calibration as unpublished.
                    _ = try? await historicalFindingProjector.projectPending(limit: 100)
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
        return results
    }
}

public enum CalibrationPipelineError: Error, Sendable, Equatable {
    case historicalCapabilityUnavailable
    case historicalEvidenceMissing
}
