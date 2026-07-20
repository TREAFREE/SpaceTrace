import Foundation
import SpaceTraceDomain
import Testing
@testable import SpaceTraceApplication

struct AuthorizedBaselineScanCoordinatorTests {
    @Test("A complete scan publishes a coverage-aware baseline after typed phases")
    func publishesCompleteBaseline() async throws {
        let fixture = try Fixture()
        let runner = BaselineCalibrationRunnerFake(
            outcome: .published(
                try DirectoryMetadataAggregate(
                    path: fixture.context.root,
                    logicalBytes: ByteCount(4_096),
                    allocatedBytes: ByteCount(8_192),
                    descendantCount: 7,
                    coverage: .complete
                ),
                fixture.completeReport
            )
        )
        let snapshotRepository = BaselineSnapshotRepositoryFake()
        let coordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: BaselineContextProviderFake(context: fixture.context),
            calibrationRunner: runner,
            snapshotRepository: snapshotRepository,
            volumeCapacityProvider: BaselineVolumeCapacityProviderFake(
                snapshot: fixture.volumeSnapshot
            ),
            buildMetadata: fixture.buildMetadata,
            makeBaselineID: { fixture.baselineID },
            now: { fixture.timestamp }
        )
        let recorder = BaselineStateRecorder()
        let updates = await coordinator.updates()
        let observation = Task {
            for await state in updates {
                await recorder.record(state)
                if case .completed = state { return }
            }
        }

        #expect(await coordinator.start(scopeID: fixture.scopeID))
        await coordinator.waitForCurrentScan()
        await observation.value

        guard case let .completed(result) = await coordinator.state() else {
            Issue.record("Expected a completed baseline.")
            return
        }
        #expect(result.logicalBytes.value == 4_096)
        #expect(result.allocatedBytes.value == 8_192)
        #expect(result.descendantCount == 7)
        #expect(result.root.entriesVisited == 8)
        #expect(result.snapshot.startupVolume == fixture.volumeSnapshot)
        #expect(result.origin == .completedScan)
        #expect(await snapshotRepository.savedSnapshots == [result.snapshot])
        #expect(
            await recorder.phases == [.idle, .preparing, .scanning, .publishing, .completed]
        )
    }

    @Test("Partial coverage remains explicit and never fabricates byte results")
    func preservesPartialCoverage() async throws {
        let fixture = try Fixture()
        let partialReport = try CalibrationReport(
            coverage: .partial,
            entriesVisited: 12,
            directoriesStaged: 3,
            gaps: [
                CalibrationGap(path: fixture.context.root, reason: .permissionDenied),
            ]
        )
        let coordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: BaselineContextProviderFake(context: fixture.context),
            calibrationRunner: BaselineCalibrationRunnerFake(
                outcome: .incomplete(partialReport, .partialCoverage)
            ),
            snapshotRepository: BaselineSnapshotRepositoryFake(),
            volumeCapacityProvider: BaselineVolumeCapacityProviderFake(
                snapshot: fixture.volumeSnapshot
            ),
            buildMetadata: fixture.buildMetadata,
            makeBaselineID: { fixture.baselineID },
            now: { fixture.timestamp }
        )

        #expect(await coordinator.start(scopeID: fixture.scopeID))
        await coordinator.waitForCurrentScan()

        guard case let .incomplete(result) = await coordinator.state() else {
            Issue.record("Expected an incomplete baseline.")
            return
        }
        #expect(result.reason == .partialCoverage)
        #expect(result.report.entriesVisited == 12)
        #expect(result.report.gaps.count == 1)
    }

    @Test("Cancellation waits for scan shutdown and publishes a typed cancelled state")
    func cancelsInFlightScan() async throws {
        let fixture = try Fixture()
        let runner = BlockingBaselineCalibrationRunnerFake()
        let coordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: BaselineContextProviderFake(context: fixture.context),
            calibrationRunner: runner,
            snapshotRepository: BaselineSnapshotRepositoryFake(),
            volumeCapacityProvider: BaselineVolumeCapacityProviderFake(
                snapshot: fixture.volumeSnapshot
            ),
            buildMetadata: fixture.buildMetadata,
            makeBaselineID: { fixture.baselineID },
            now: { fixture.timestamp }
        )

        #expect(await coordinator.start(scopeID: fixture.scopeID))
        await runner.waitUntilStarted()
        await coordinator.cancel()

        guard case let .cancelled(cancellation) = await coordinator.state() else {
            Issue.record("Expected a cancelled baseline.")
            return
        }
        #expect(cancellation.scopeID == fixture.scopeID)
        #expect(cancellation.context == fixture.context)
        #expect(await runner.observedCancellation)
    }

    @Test("A missing active stream is a retryable typed failure")
    func reportsMonitoringNotReady() async throws {
        let fixture = try Fixture()
        let coordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: BaselineContextProviderFake(
                error: AuthorizedBaselineScanContextError.monitoringNotReady
            ),
            calibrationRunner: BaselineCalibrationRunnerFake(
                outcome: .published(
                    try DirectoryMetadataAggregate(
                        path: fixture.context.root,
                        logicalBytes: .zero,
                        allocatedBytes: .zero,
                        descendantCount: 0,
                        coverage: .complete
                    ),
                    fixture.completeReport
                )
            ),
            snapshotRepository: BaselineSnapshotRepositoryFake(),
            volumeCapacityProvider: BaselineVolumeCapacityProviderFake(
                snapshot: fixture.volumeSnapshot
            ),
            buildMetadata: fixture.buildMetadata,
            makeBaselineID: { fixture.baselineID },
            now: { fixture.timestamp }
        )

        #expect(await coordinator.start(scopeID: fixture.scopeID))
        await coordinator.waitForCurrentScan()

        guard case let .failed(failure) = await coordinator.state() else {
            Issue.record("Expected a typed failure.")
            return
        }
        #expect(failure.code == .monitoringNotReady)
    }

    @Test("A committed baseline restores after restart without rerunning the scanner")
    func restoresCommittedBaseline() async throws {
        let fixture = try Fixture()
        let root = try AuthorizedBaselineRootSnapshot(
            context: fixture.context,
            logicalBytes: ByteCount(1_024),
            allocatedBytes: ByteCount(2_048),
            descendantCount: 4,
            entriesVisited: 5,
            directoriesObserved: 2
        )
        let snapshot = try AuthorizedBaselineSnapshot(
            id: fixture.baselineID,
            startedAt: fixture.timestamp,
            committedAt: fixture.timestamp,
            build: fixture.buildMetadata,
            startupVolume: fixture.volumeSnapshot,
            roots: [root]
        )
        let repository = BaselineSnapshotRepositoryFake(initialSnapshot: snapshot)
        let coordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: BaselineContextProviderFake(context: fixture.context),
            calibrationRunner: BaselineCalibrationRunnerFake(
                outcome: .published(
                    try DirectoryMetadataAggregate(
                        path: fixture.context.root,
                        logicalBytes: .zero,
                        allocatedBytes: .zero,
                        descendantCount: 0,
                        coverage: .complete
                    ),
                    fixture.completeReport
                )
            ),
            snapshotRepository: repository,
            volumeCapacityProvider: BaselineVolumeCapacityProviderFake(
                snapshot: fixture.volumeSnapshot
            ),
            buildMetadata: fixture.buildMetadata,
            makeBaselineID: { fixture.baselineID },
            now: { fixture.timestamp }
        )

        await coordinator.restoreLatest(scopeID: fixture.scopeID)

        guard case let .completed(result) = await coordinator.state() else {
            Issue.record("Expected the committed baseline to be restored.")
            return
        }
        #expect(result.snapshot == snapshot)
        #expect(result.origin == .restoredAfterRestart)
    }

    @Test("A snapshot write failure never claims a durable completed baseline")
    func reportsSnapshotPersistenceFailure() async throws {
        let fixture = try Fixture()
        let coordinator = AuthorizedBaselineScanCoordinator(
            contextProvider: BaselineContextProviderFake(context: fixture.context),
            calibrationRunner: BaselineCalibrationRunnerFake(
                outcome: .published(
                    try DirectoryMetadataAggregate(
                        path: fixture.context.root,
                        logicalBytes: ByteCount(100),
                        allocatedBytes: ByteCount(200),
                        descendantCount: 1,
                        coverage: .complete
                    ),
                    fixture.completeReport
                )
            ),
            snapshotRepository: BaselineSnapshotRepositoryFake(failsOnSave: true),
            volumeCapacityProvider: BaselineVolumeCapacityProviderFake(
                snapshot: fixture.volumeSnapshot
            ),
            buildMetadata: fixture.buildMetadata,
            makeBaselineID: { fixture.baselineID },
            now: { fixture.timestamp }
        )

        #expect(await coordinator.start(scopeID: fixture.scopeID))
        await coordinator.waitForCurrentScan()

        guard case let .failed(failure) = await coordinator.state() else {
            Issue.record("Expected a persistence failure instead of completed state.")
            return
        }
        #expect(failure.code == .baselinePersistenceFailed)
    }
}

private struct Fixture: Sendable {
    let scopeID: WatchedScopeID
    let context: AuthorizedBaselineScanContext
    let completeReport: CalibrationReport
    let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
    let baselineID: AuthorizedBaselineID
    let buildMetadata: AuthorizedBaselineBuildMetadata
    let volumeSnapshot: StartupVolumeCapacitySnapshot

    init() throws {
        scopeID = try WatchedScopeID("scope-primary")
        let root = try DirtyRegionPath("/Users/example/Selected")
        context = AuthorizedBaselineScanContext(
            scopeID: scopeID,
            root: root,
            streamID: try EventStreamID("stream-primary")
        )
        completeReport = try CalibrationReport(
            coverage: .complete,
            entriesVisited: 8,
            directoriesStaged: 2,
            gaps: []
        )
        baselineID = try AuthorizedBaselineID("baseline-primary")
        buildMetadata = try AuthorizedBaselineBuildMetadata(
            appVersion: "0.1.0 (1)",
            schemaVersion: 6
        )
        volumeSnapshot = StartupVolumeCapacitySnapshot(
            observedAt: timestamp,
            volumeUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            totalBytes: try ByteCount(1_000_000),
            availableBytes: try ByteCount(400_000),
            availableForImportantUsageBytes: try ByteCount(500_000)
        )
    }
}

private struct BaselineVolumeCapacityProviderFake: StartupVolumeCapacitySnapshotProviding {
    let value: StartupVolumeCapacitySnapshot

    init(snapshot: StartupVolumeCapacitySnapshot) {
        value = snapshot
    }

    func snapshot() -> StartupVolumeCapacitySnapshot {
        value
    }
}

private actor BaselineSnapshotRepositoryFake: AuthorizedBaselineSnapshotRepository {
    private let initialSnapshot: AuthorizedBaselineSnapshot?
    private let failsOnSave: Bool
    private(set) var savedSnapshots: [AuthorizedBaselineSnapshot] = []

    init(
        initialSnapshot: AuthorizedBaselineSnapshot? = nil,
        failsOnSave: Bool = false
    ) {
        self.initialSnapshot = initialSnapshot
        self.failsOnSave = failsOnSave
    }

    func saveAuthorizedBaseline(_ snapshot: AuthorizedBaselineSnapshot) throws {
        if failsOnSave { throw BaselineSnapshotRepositoryFakeError.writeFailed }
        savedSnapshots.append(snapshot)
    }

    func latestAuthorizedBaseline(
        for scopeID: WatchedScopeID
    ) -> AuthorizedBaselineSnapshot? {
        savedSnapshots.reversed().first { $0.root(for: scopeID) != nil }
            ?? initialSnapshot.flatMap { $0.root(for: scopeID) == nil ? nil : $0 }
    }
}

private enum BaselineSnapshotRepositoryFakeError: Error {
    case writeFailed
}

private struct BaselineContextProviderFake: AuthorizedBaselineScanContextProviding {
    let context: AuthorizedBaselineScanContext?
    let error: AuthorizedBaselineScanContextError?

    init(context: AuthorizedBaselineScanContext) {
        self.context = context
        error = nil
    }

    init(error: AuthorizedBaselineScanContextError) {
        context = nil
        self.error = error
    }

    func context(for scopeID: WatchedScopeID) throws -> AuthorizedBaselineScanContext {
        _ = scopeID
        if let error { throw error }
        return try #require(context)
    }
}

private struct BaselineCalibrationRunnerFake: AuthorizedBaselineCalibrationRunning {
    let outcome: AuthorizedBaselineCalibrationOutcome

    func run(
        context: AuthorizedBaselineScanContext,
        onProgress: @escaping @Sendable (AuthorizedBaselineCalibrationProgress) async -> Void
    ) async -> AuthorizedBaselineCalibrationOutcome {
        await onProgress(.scanning(context))
        if case let .published(_, report) = outcome {
            await onProgress(.publishing(context, report))
        }
        return outcome
    }
}

private actor BlockingBaselineCalibrationRunnerFake: AuthorizedBaselineCalibrationRunning {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var observedCancellation = false

    func run(
        context: AuthorizedBaselineScanContext,
        onProgress: @escaping @Sendable (AuthorizedBaselineCalibrationProgress) async -> Void
    ) async throws -> AuthorizedBaselineCalibrationOutcome {
        await onProgress(.scanning(context))
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(3_600))
            preconditionFailure("The blocking fixture must be cancelled.")
        } catch is CancellationError {
            observedCancellation = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor BaselineStateRecorder {
    enum Phase: Sendable, Equatable {
        case idle
        case preparing
        case scanning
        case publishing
        case completed
        case incomplete
        case cancelled
        case failed
    }

    private(set) var phases: [Phase] = []

    func record(_ state: AuthorizedBaselineScanState) {
        switch state {
        case .idle: phases.append(.idle)
        case .preparing: phases.append(.preparing)
        case .scanning: phases.append(.scanning)
        case .publishing: phases.append(.publishing)
        case .completed: phases.append(.completed)
        case .incomplete: phases.append(.incomplete)
        case .cancelled: phases.append(.cancelled)
        case .failed: phases.append(.failed)
        }
    }
}
