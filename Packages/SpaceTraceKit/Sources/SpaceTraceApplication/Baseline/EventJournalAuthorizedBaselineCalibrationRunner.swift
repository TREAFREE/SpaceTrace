import Foundation

public actor EventJournalAuthorizedBaselineCalibrationRunner: AuthorizedBaselineCalibrationRunning {
    private let repository: any EventJournalRepository
    private let scanner: any CalibrationScanner
    private let scanBudget: CalibrationScanBudget
    private let historicalFindingProjector: (any HistoricalFindingProjecting)?

    public init(
        repository: any EventJournalRepository,
        scanner: any CalibrationScanner,
        historicalFindingProjector: (any HistoricalFindingProjecting)? = nil,
        scanBudget: CalibrationScanBudget = .incremental
    ) {
        self.repository = repository
        self.scanner = scanner
        self.historicalFindingProjector = historicalFindingProjector
        self.scanBudget = scanBudget
    }

    public func run(
        context: AuthorizedBaselineScanContext,
        onProgress: @escaping @Sendable (AuthorizedBaselineCalibrationProgress) async -> Void
    ) async throws -> AuthorizedBaselineCalibrationOutcome {
        let region = try DirtyRegion(
            path: context.root,
            reasons: [.mustScanSubdirectories, .requiresCalibration],
            maximumCursor: nil
        )
        try await repository.markDirty(
            streamID: context.streamID,
            regions: [region]
        )

        let historicalContext: HistoricalCalibrationContext?
        if let volumeUUID = context.volumeUUID,
           let mountGenerationID = context.mountGenerationID,
           repository is any HistoricalCalibrationFinalizationRepository,
           scanner is any HistoricalCalibrationScanner {
            historicalContext = try HistoricalCalibrationContext(
                watchedScopeID: context.scopeID,
                volumeUUID: volumeUUID,
                mountGenerationID: mountGenerationID,
                homeDirectoryPath: NSHomeDirectory()
            )
        } else {
            historicalContext = nil
        }
        let pipeline = FileSystemCalibrationPipeline(
            streamID: context.streamID,
            watchRoot: context.root,
            repository: repository,
            scanner: scanner,
            historicalContext: historicalContext,
            historicalFindingProjector: historicalFindingProjector,
            scanBudget: scanBudget
        )
        let attempts = try await pipeline.calibratePendingResults(limit: 1) { update in
            switch update {
            case .scanning:
                await onProgress(.scanning(context))
            case let .publishing(_, report):
                await onProgress(.publishing(context, report))
            }
        }
        guard let attempt = attempts.first,
              attempt.workItem.region.path == context.root else {
            throw AuthorizedBaselineCalibrationRunnerError.missingAttempt
        }

        switch attempt.disposition {
        case .partialCoverage:
            return .incomplete(attempt.report, .partialCoverage)
        case .superseded:
            return .incomplete(attempt.report, .changedDuringScan)
        case .published:
            let aggregate = try await repository
                .currentDirectoryAggregates(for: context.streamID)
                .first { $0.path == context.root }
            guard let aggregate,
                  aggregate.coverage == .complete,
                  aggregate.logicalBytes != nil,
                  aggregate.allocatedBytes != nil else {
                throw AuthorizedBaselineCalibrationRunnerError.publishedRootMissing
            }
            return .published(aggregate, attempt.report)
        }
    }
}

public enum AuthorizedBaselineCalibrationRunnerError: Error, Sendable, Equatable {
    case missingAttempt
    case publishedRootMissing
}
