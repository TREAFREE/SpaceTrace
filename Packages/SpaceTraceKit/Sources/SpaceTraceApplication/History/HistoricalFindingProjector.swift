import SpaceTraceDomain

/// Bounded evidence describing one projection-drain attempt.
public struct HistoricalFindingProjectionRun: Sendable, Equatable {
    public let processedCount: Int
    public let newlyCommittedCount: Int
    public let alreadyCommittedCount: Int

    public init(
        processedCount: Int,
        newlyCommittedCount: Int,
        alreadyCommittedCount: Int
    ) {
        self.processedCount = processedCount
        self.newlyCommittedCount = newlyCommittedCount
        self.alreadyCommittedCount = alreadyCommittedCount
    }

    public static let empty = HistoricalFindingProjectionRun(
        processedCount: 0,
        newlyCommittedCount: 0,
        alreadyCommittedCount: 0
    )
}

public protocol HistoricalFindingProjecting: Sendable {
    func projectPending(limit: Int) async throws -> HistoricalFindingProjectionRun
}

/// Resumes durable projection work after launch or a successful paired frame
/// commit. The repository owns idempotency; this actor only loads immutable
/// frames, invokes the pure generator, and commits a bounded number of results.
public actor HistoricalFindingProjector {
    private let repository: any HistoricalFindingProjectionRepository
    private let generator: HistoricalFindingGenerator

    public init(
        repository: any HistoricalFindingProjectionRepository,
        generator: HistoricalFindingGenerator = HistoricalFindingGenerator()
    ) {
        self.repository = repository
        self.generator = generator
    }

    public func projectPending(limit: Int) async throws -> HistoricalFindingProjectionRun {
        guard limit > 0 else { return .empty }
        guard limit <= 100 else {
            throw HistoricalFindingProjectorError.invalidLimit(limit)
        }

        var processedCount = 0
        var newlyCommittedCount = 0
        var alreadyCommittedCount = 0
        var observedWorkIDs: Set<HistoricalProjectionWorkID> = []

        while processedCount < limit {
            try Task.checkCancellation()
            guard let work = try await repository.nextHistoricalProjectionWork() else {
                break
            }
            guard observedWorkIDs.insert(work.recordID).inserted else {
                throw HistoricalFindingProjectorError.repositoryDidNotAdvance(work.recordID)
            }
            guard let baseline = try await repository.historicalObservationFrame(
                sequence: work.baselineSequence
            ) else {
                throw HistoricalFindingProjectorError.missingFrame(work.baselineSequence)
            }
            guard let comparison = try await repository.historicalObservationFrame(
                sequence: work.comparisonSequence
            ) else {
                throw HistoricalFindingProjectorError.missingFrame(work.comparisonSequence)
            }

            try Task.checkCancellation()
            let result = try generator.generate(
                baseline: baseline,
                comparison: comparison,
                positiveLimit: work.positiveLimit
            )
            switch try await repository.commitHistoricalProjection(result, for: work) {
            case .newlyCommitted:
                newlyCommittedCount += 1
            case .alreadyCommitted:
                alreadyCommittedCount += 1
            }
            processedCount += 1
        }

        return HistoricalFindingProjectionRun(
            processedCount: processedCount,
            newlyCommittedCount: newlyCommittedCount,
            alreadyCommittedCount: alreadyCommittedCount
        )
    }
}

extension HistoricalFindingProjector: HistoricalFindingProjecting {}

public enum HistoricalFindingProjectorError: Error, Sendable, Equatable {
    case invalidLimit(Int)
    case missingFrame(ObservationCommitSequence)
    case repositoryDidNotAdvance(HistoricalProjectionWorkID)
}
