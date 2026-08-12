import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTracePersistence

@Suite("SQLite registered historical projection corrections", .serialized)
struct SQLiteHistoricalProjectionCorrectionTests {
    @Test("A registered same-frame correction commits a complete checkpointed projection")
    func commitsRegisteredCorrection() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        let outcome = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x11),
            input: try correctionPersistenceInput("correction-one"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(outcome == .newlyCommitted(try HistoricalCorrectingProjectionRecordID(1)))
        #expect(try fixture.count("historical_correction_input") == 1)
        #expect(try fixture.count("historical_projection_correction_work") == 1)
        #expect(try fixture.count("historical_correcting_projection") == 1)
        #expect(try fixture.count("historical_projection_correction_checkpoint") == 1)
        #expect(try fixture.count("historical_corrected_finding") > 0)
        #expect(try fixture.count("historical_finding_projection") == 1)
        try await repository.close()
    }

    @Test("Commit acknowledgement loss retries byte-identically without another edge")
    func acknowledgementLossIsIdempotent() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        var repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry,
            failurePoint: .afterHistoricalCorrectionCommitBeforeReturningReceipt
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let requestID = try correctionRequestID(0x22)
        let input = try correctionPersistenceInput("correction-retry")
        var service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await service.correct(
                rootProjectionID: rootProjectionID,
                requestID: requestID,
                input: input,
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(try fixture.count("historical_correcting_projection") == 1)
        try await repository.close()

        repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        let retry = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: requestID,
            input: input,
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )
        #expect(retry == .alreadyCommitted(try HistoricalCorrectingProjectionRecordID(1)))
        #expect(try fixture.count("historical_projection_correction_work") == 1)
        #expect(try fixture.count("historical_correcting_projection") == 1)
        #expect(try fixture.count("historical_projection_correction_checkpoint") == 1)
        try await repository.close()
    }

    @Test("A changed field under one request ID is an immutable conflict")
    func requestConflict() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )
        let requestID = try correctionRequestID(0x33)
        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: requestID,
            input: correctionPersistenceInput("first-input"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        await #expect(
            throws: HistoricalProjectionCorrectionServiceError.immutableRequestConflict
        ) {
            _ = try await service.correct(
                rootProjectionID: rootProjectionID,
                requestID: requestID,
                input: correctionPersistenceInput("changed-input"),
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(try fixture.count("historical_projection_correction_work") == 1)
        try await repository.close()
    }

    @Test("Checkpoint failure rolls every correction row back")
    func checkpointFailureRollsBack() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry,
            failurePoint: .beforeHistoricalCorrectionCheckpoint
        )
        let rootProjectionID = try await correctionRootProjection(repository: repository)
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        await #expect(throws: SQLiteEventJournalError.injectedFailure) {
            _ = try await service.correct(
                rootProjectionID: rootProjectionID,
                requestID: correctionRequestID(0x44),
                input: correctionPersistenceInput("rollback-input"),
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(try fixture.count("historical_correction_input") == 0)
        #expect(try fixture.count("historical_projection_correction_work") == 0)
        #expect(try fixture.count("historical_correcting_projection") == 0)
        #expect(try fixture.count("historical_corrected_finding") == 0)
        #expect(try fixture.count("historical_projection_correction_checkpoint") == 0)
        #expect(try fixture.count("historical_finding_projection") == 1)
        try await repository.close()
    }

    @Test("An empty deterministic replacement is committed without a fabricated finding")
    func commitsEmptyReplacement() async throws {
        let fixture = try HistoricalLedgerTestFixture()
        defer { fixture.remove() }
        let registry = try correctionPersistenceRegistry()
        let repository = try correctionPersistenceRepository(
            fixture: fixture,
            registry: registry
        )
        let rootProjectionID = try await correctionRootProjection(
            repository: repository,
            changedBytes: false
        )
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: registry
        )

        _ = try await service.correct(
            rootProjectionID: rootProjectionID,
            requestID: correctionRequestID(0x55),
            input: correctionPersistenceInput("empty-input"),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(try fixture.count("historical_correcting_projection") == 1)
        #expect(try fixture.count("historical_corrected_finding") == 0)
        #expect(try fixture.int(
            "SELECT finding_count FROM historical_correcting_projection"
        ) == 0)
        try await repository.close()
    }
}

private func correctionPersistenceRegistry() throws -> HistoricalProjectionCorrectionRegistry {
    try HistoricalProjectionCorrectionRegistry(
        implementations: [
            HistoricalProjectionCorrectionImplementation(
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(1)
            ) { input, baseline, comparison, positiveLimit in
                guard input.isEmpty == false else {
                    throw HistoricalProjectionCorrectionRegistryError.invalidCanonicalInput
                }
                return try HistoricalFindingGenerator().generate(
                    baseline: baseline,
                    comparison: comparison,
                    positiveLimit: positiveLimit
                )
            },
        ]
    )
}

private func correctionPersistenceRepository(
    fixture: HistoricalLedgerTestFixture,
    registry: HistoricalProjectionCorrectionRegistry,
    failurePoint: SQLiteEventJournalTestFailurePoint? = nil
) throws -> SQLiteEventJournalRepository {
    try SQLiteEventJournalRepository(
        databaseURL: fixture.databaseURL,
        failurePoint: failurePoint,
        historicalProjectionCorrectionRegistry: registry
    )
}

private func correctionRootProjection(
    repository: SQLiteEventJournalRepository,
    changedBytes: Bool = true
) async throws -> HistoricalProjectionRecordID {
    let first = try await prepareHistoricalLedgerRun(
        repository: repository,
        streamName: "correction-stream",
        logicalRootBytes: 100,
        allocatedRootBytes: 80,
        child: .present(logical: 40, allocated: 32),
        observedAtMilliseconds: 2_000_000_000_000
    )
    _ = try await repository.finalizeCalibrationWithHistoricalFrames(first.request)
    let second = try await prepareHistoricalLedgerRun(
        repository: repository,
        streamName: "correction-stream",
        logicalRootBytes: changedBytes ? 120 : 100,
        allocatedRootBytes: changedBytes ? 96 : 80,
        child: .present(
            logical: changedBytes ? 50 : 40,
            allocated: changedBytes ? 40 : 32
        ),
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
    switch outcome {
    case .newlyCommitted(let projectionID), .alreadyCommitted(let projectionID):
        return projectionID
    }
}

private func correctionRequestID(
    _ byte: UInt8
) throws -> HistoricalProjectionCorrectionRequestID {
    try HistoricalProjectionCorrectionRequestID(bytes: Array(repeating: byte, count: 16))
}

private func correctionPersistenceInput(
    _ value: String
) throws -> HistoricalProjectionCorrectionInput {
    try HistoricalProjectionCorrectionInput(
        formatVersion: HistoricalCorrectionInputFormatVersion(1),
        canonicalBytes: Data(value.utf8)
    )
}
