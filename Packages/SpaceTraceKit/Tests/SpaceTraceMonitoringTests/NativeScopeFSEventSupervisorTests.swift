import Foundation
import SpaceTraceApplication
@testable import SpaceTraceFileSystem
import SpaceTracePersistence
import Synchronization
import Testing

@Suite("Native scope FSEvents supervisor", .serialized)
struct NativeScopeFSEventSupervisorTests {
    @Test("Activation starts the best available stream and schedules mount calibration")
    func startsPersistentStreamAndCalibration() async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            latency: 0.01,
            excludeEventsFromThisProcess: false
        )
        let evidence = try fixture.mountEvidence()
        let scope = try WatchedScope(
            id: WatchedScopeID("native-supervisor-scope"),
            root: DirtyRegionPath(fixture.watchedRoot.path),
            mountPath: evidence.mountPath
        )
        let activation = try await repository.activateScopeMount(
            scopeID: scope.id,
            evidence: evidence,
            proposedGenerationID: MountGenerationID("native-generation")
        )

        try await supervisor.restart(scope: scope, activation: activation)
        let status = try #require(await supervisor.activeStatus(for: scope.id))
        let dirty = try await repository.dirtyRegions(for: status.streamID)

        #expect(status.generationID == activation.current.generationID)
        if let identity = status.persistentIdentity {
            #expect(status.streamID == identity.streamID)
            #expect(identity.volumeUUID == evidence.volumeUUID)
        } else {
            #expect(status.streamID.rawValue.hasPrefix("fsevents-live/v1/"))
        }
        #expect(dirty.map(\.path) == [scope.root])
        #expect(dirty.first?.reasons.contains(.mountChanged) == true)
        #expect(dirty.first?.reasons.contains(.requiresCalibration) == true)

        await supervisor.stop(
            scopeID: scope.id,
            matching: activation.current.generationID
        )
        #expect(await supervisor.activeStatus(for: scope.id) == nil)
    }

    @Test(
        "A rejected persistent replay invalidates history before live recovery",
        arguments: [
            FSEventStreamError.creationFailed,
            FSEventStreamError.startFailed,
        ]
    )
    func rejectedReplayFallsBackToCalibratedLiveMonitoring(
        replayFailure: FSEventStreamError
    ) async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let setup = try await fixture.persistentSetup(repository: repository)
        let harness = ScriptedStreamHarness(outcomes: [
            .failure(replayFailure),
            .success,
        ])
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            resolver: FixedFSEventDeviceScopeResolver(resolved: setup.resolved),
            makeStreamClient: { harness.makeClient() }
        )
        try await supervisor.restart(scope: setup.scope, activation: setup.activation)

        let configurations = harness.configurations()
        #expect(configurations.map(\.replayPosition) == [
            .after(FSEventID(rawValue: 42)),
            .sinceNow,
        ])
        #expect(try await repository.checkpoint(for: setup.identity.streamID) == nil)
        let dirty = try #require(
            try await repository.dirtyRegions(for: setup.identity.streamID).first
        )
        #expect(dirty.path == setup.scope.root)
        #expect(dirty.maximumCursor == nil)
        #expect(dirty.reasons.contains(.droppedEvents))
        #expect(dirty.reasons.contains(.mustScanSubdirectories))
        #expect(dirty.reasons.contains(.requiresCalibration))
        #expect(await supervisor.activeStatus(for: setup.scope.id)?.streamID == setup.identity.streamID)
        await supervisor.stopAll()
    }

    @Test("A failed live recovery remains inactive for the runtime retry loop")
    func failedLiveRecoveryDoesNotPublishAnActiveStream() async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let setup = try await fixture.persistentSetup(repository: repository)
        let harness = ScriptedStreamHarness(outcomes: [
            .failure(.startFailed),
            .failure(.creationFailed),
        ])
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            resolver: FixedFSEventDeviceScopeResolver(resolved: setup.resolved),
            makeStreamClient: { harness.makeClient() }
        )

        do {
            try await supervisor.restart(scope: setup.scope, activation: setup.activation)
            Issue.record("Expected the live recovery stream to fail.")
        } catch FSEventStreamError.creationFailed {
            // The non-UI runtime classifies this as transient and retries with
            // its existing fixed attempt bound.
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }

        #expect(harness.configurations().map(\.replayPosition) == [
            .after(FSEventID(rawValue: 42)),
            .sinceNow,
        ])
        #expect(try await repository.checkpoint(for: setup.identity.streamID) == nil)
        #expect(await supervisor.activeStatus(for: setup.scope.id) == nil)
    }

    @Test("An unexpected post-start failure automatically restores live monitoring")
    func unexpectedTerminationAutomaticallyRecovers() async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let setup = try await fixture.persistentSetup(repository: repository)
        let harness = ScriptedStreamHarness(outcomes: [
            .terminalFailure,
            .success,
        ])
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            resolver: FixedFSEventDeviceScopeResolver(resolved: setup.resolved),
            makeStreamClient: { harness.makeClient() },
            recoveryPolicy: try FSEventStreamRecoveryPolicy(
                maximumAttempts: 3,
                initialBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                stabilityThresholdMilliseconds: 60_000
            )
        )

        try await supervisor.restart(scope: setup.scope, activation: setup.activation)
        await harness.waitForConfigurationCount(2)

        #expect(harness.configurations().map(\.replayPosition) == [
            .after(FSEventID(rawValue: 42)),
            .sinceNow,
        ])
        #expect(await supervisor.activeStatus(for: setup.scope.id)?.generationID == setup.activation.current.generationID)
        #expect(await supervisor.recoveryStatus(for: setup.scope.id) == nil)
        #expect(await supervisor.lastFailure(for: setup.scope.id) == nil)
        #expect(try await repository.checkpoint(for: setup.identity.streamID) == nil)
        let dirty = try #require(
            try await repository.dirtyRegions(for: setup.identity.streamID).first
        )
        #expect(dirty.maximumCursor == nil)
        #expect(dirty.reasons.contains(.droppedEvents))
        #expect(dirty.reasons.contains(.requiresCalibration))
        await supervisor.stopAll()
    }

    @Test("Repeated recovery start failures exhaust the circuit breaker")
    func repeatedRecoveryFailuresAreBounded() async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let setup = try await fixture.persistentSetup(repository: repository)
        let harness = ScriptedStreamHarness(outcomes: [
            .terminalFailure,
            .failure(.startFailed),
            .failure(.creationFailed),
            .failure(.startFailed),
        ])
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            resolver: FixedFSEventDeviceScopeResolver(resolved: setup.resolved),
            makeStreamClient: { harness.makeClient() },
            recoveryPolicy: try FSEventStreamRecoveryPolicy(
                maximumAttempts: 3,
                initialBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                stabilityThresholdMilliseconds: 60_000
            )
        )

        try await supervisor.restart(scope: setup.scope, activation: setup.activation)
        await harness.waitForConfigurationCount(4)

        #expect(harness.configurations().map(\.replayPosition) == [
            .after(FSEventID(rawValue: 42)),
            .sinceNow,
            .sinceNow,
            .sinceNow,
        ])
        #expect(await supervisor.activeStatus(for: setup.scope.id) == nil)
        #expect(await supervisor.recoveryStatus(for: setup.scope.id) == nil)
        let failure = await supervisor.lastFailure(for: setup.scope.id)
        #expect(failure?.contains("exhausted after 3 attempts") == true)
        #expect(try await repository.checkpoint(for: setup.identity.streamID) == nil)
    }

    @Test("Repeated post-start terminations also exhaust the circuit breaker")
    func repeatedTerminationsAreBounded() async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let setup = try await fixture.persistentSetup(repository: repository)
        let harness = ScriptedStreamHarness(outcomes: [
            .terminalFailure,
            .terminalFailure,
            .terminalFailure,
            .terminalFailure,
        ])
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            resolver: FixedFSEventDeviceScopeResolver(resolved: setup.resolved),
            makeStreamClient: { harness.makeClient() },
            recoveryPolicy: try FSEventStreamRecoveryPolicy(
                maximumAttempts: 3,
                initialBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                stabilityThresholdMilliseconds: 60_000
            )
        )

        try await supervisor.restart(scope: setup.scope, activation: setup.activation)
        await harness.waitForConfigurationCount(4)
        await harness.waitForStopCount(4)
        await supervisor.waitForRecoveryCompletion(for: setup.scope.id)

        #expect(harness.configurations().count == 4)
        #expect(await supervisor.activeStatus(for: setup.scope.id) == nil)
        #expect(await supervisor.recoveryStatus(for: setup.scope.id) == nil)
        let failure = await supervisor.lastFailure(for: setup.scope.id)
        #expect(failure?.contains("exhausted after 3 attempts") == true)
    }

    @Test(
        "Recovery refuses missing or replacement volume identity",
        arguments: [
            RecoveryVolumeMismatch.missingIdentity,
            RecoveryVolumeMismatch.replacementVolume,
        ]
    )
    func recoveryRefusesUnprovenVolumeContinuity(
        mismatch: RecoveryVolumeMismatch
    ) async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let setup = try await fixture.persistentSetup(repository: repository)
        let mismatched = ResolvedFSEventDeviceScope(
            deviceTarget: setup.resolved.deviceTarget,
            volumeUUID: mismatch == .missingIdentity ? nil : UUID(),
            journalUUID: nil
        )
        let resolver = ScriptedFSEventDeviceScopeResolver(
            outcomes: [setup.resolved, mismatched]
        )
        let harness = ScriptedStreamHarness(outcomes: [.terminalFailure])
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            resolver: resolver,
            makeStreamClient: { harness.makeClient() },
            recoveryPolicy: try FSEventStreamRecoveryPolicy(
                maximumAttempts: 1,
                initialBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                stabilityThresholdMilliseconds: 60_000
            )
        )

        try await supervisor.restart(scope: setup.scope, activation: setup.activation)
        await harness.waitForStopCount(1)
        await supervisor.waitForRecoveryCompletion(for: setup.scope.id)

        #expect(harness.configurations().count == 1)
        #expect(await supervisor.activeStatus(for: setup.scope.id) == nil)
        let failure = await supervisor.lastFailure(for: setup.scope.id)
        #expect(failure?.contains("resolvedVolumeChanged") == true)
    }

    @Test("Stopping a mount generation cancels an in-flight recovery backoff")
    func stopCancelsRecovery() async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.remove() }
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let setup = try await fixture.persistentSetup(repository: repository)
        let harness = ScriptedStreamHarness(outcomes: [
            .terminalFailure,
            .failure(.startFailed),
            .success,
        ])
        let supervisor = NativeScopeFSEventSupervisor(
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            resolver: FixedFSEventDeviceScopeResolver(resolved: setup.resolved),
            makeStreamClient: { harness.makeClient() },
            recoveryPolicy: try FSEventStreamRecoveryPolicy(
                maximumAttempts: 3,
                initialBackoffMilliseconds: 60_000,
                maximumBackoffMilliseconds: 60_000,
                stabilityThresholdMilliseconds: 60_000
            )
        )

        try await supervisor.restart(scope: setup.scope, activation: setup.activation)
        await harness.waitForConfigurationCount(2)
        let recovery = try #require(await supervisor.recoveryStatus(for: setup.scope.id))
        #expect(recovery.attempt == 2)

        await supervisor.stop(
            scopeID: setup.scope.id,
            matching: setup.activation.current.generationID
        )

        #expect(harness.configurations().count == 2)
        #expect(await supervisor.activeStatus(for: setup.scope.id) == nil)
        #expect(await supervisor.recoveryStatus(for: setup.scope.id) == nil)
    }

    @Test(
        "Recovery policy rejects invalid bounds",
        arguments: [
            RecoveryPolicyInvalidCase(
                expected: .maximumAttemptsMustBePositive,
                maximumAttempts: 0
            ),
            RecoveryPolicyInvalidCase(
                expected: .initialBackoffMustBeNonnegative,
                initialBackoffMilliseconds: -1
            ),
            RecoveryPolicyInvalidCase(
                expected: .maximumBackoffMustCoverInitialBackoff,
                initialBackoffMilliseconds: 2,
                maximumBackoffMilliseconds: 1
            ),
            RecoveryPolicyInvalidCase(
                expected: .stabilityThresholdMustBeNonnegative,
                stabilityThresholdMilliseconds: -1
            ),
        ]
    )
    func recoveryPolicyRejectsInvalidBounds(
        testCase: RecoveryPolicyInvalidCase
    ) {
        do {
            _ = try FSEventStreamRecoveryPolicy(
                maximumAttempts: testCase.maximumAttempts,
                initialBackoffMilliseconds: testCase.initialBackoffMilliseconds,
                maximumBackoffMilliseconds: testCase.maximumBackoffMilliseconds,
                stabilityThresholdMilliseconds: testCase.stabilityThresholdMilliseconds
            )
            Issue.record("Expected recovery policy validation to fail.")
        } catch {
            #expect(error == testCase.expected)
        }
    }
}

private struct SupervisorFixture {
    let root: URL
    let watchedRoot: URL
    let databaseURL: URL
    private let temporaryRoot: URL

    init() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = temporaryRoot
            .appendingPathComponent("SpaceTraceSupervisorTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        guard root.path.hasPrefix(temporaryRoot.path + "/") else {
            throw SupervisorFixtureError.unsafeTemporaryPath
        }
        let watchedRoot = root.appendingPathComponent("Watched", isDirectory: true)
        try fileManager.createDirectory(at: watchedRoot, withIntermediateDirectories: true)
        self.root = root
        self.watchedRoot = watchedRoot
        self.databaseURL = root.appendingPathComponent("journal.sqlite", isDirectory: false)
        self.temporaryRoot = temporaryRoot
    }

    func mountEvidence() throws -> VolumeMountEvidence {
        let values = try watchedRoot.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
        let mountURL = try #require(values.volume)
        let volumeUUID = try #require(values.volumeUUIDString.flatMap(UUID.init(uuidString:)))
        return try VolumeMountEvidence(
            mountPath: DirtyRegionPath(mountURL.path),
            volumeUUID: volumeUUID
        )
    }

    func persistentSetup(
        repository: SQLiteEventJournalRepository
    ) async throws -> PersistentSupervisorSetup {
        let evidence = try mountEvidence()
        let volumeUUID = try #require(evidence.volumeUUID)
        let journalUUID = UUID()
        let identity = PersistentEventStreamIdentity(
            volumeUUID: volumeUUID,
            journalUUID: journalUUID
        )
        let scope = try WatchedScope(
            id: WatchedScopeID("fault-injected-supervisor-scope"),
            root: DirtyRegionPath(watchedRoot.path),
            mountPath: evidence.mountPath
        )
        let relativeRoot: String
        if evidence.mountPath.rawValue == "/" {
            relativeRoot = String(watchedRoot.path.dropFirst())
        } else {
            relativeRoot = String(
                watchedRoot.path.dropFirst(evidence.mountPath.rawValue.count + 1)
            )
        }
        let resolved = ResolvedFSEventDeviceScope(
            deviceTarget: FSEventDeviceTarget(
                deviceID: 1,
                mountPath: evidence.mountPath.rawValue,
                relativePaths: [relativeRoot]
            ),
            volumeUUID: volumeUUID,
            journalUUID: journalUUID
        )
        let seededRegion = try DirtyRegion(
            path: scope.root,
            reasons: .contentModified,
            maximumCursor: EventJournalCursor(42)
        )
        try await repository.commit(
            EventJournalBatch(
                streamID: identity.streamID,
                checkpoint: EventJournalCursor(42),
                dirtyRegions: [seededRegion]
            )
        )
        let activation = try await repository.activateScopeMount(
            scopeID: scope.id,
            evidence: evidence,
            proposedGenerationID: MountGenerationID("fault-injected-generation")
        )
        return PersistentSupervisorSetup(
            scope: scope,
            activation: activation,
            resolved: resolved,
            identity: identity
        )
    }

    func remove() {
        let fileManager = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let temporaryPath = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard rootPath.hasPrefix(temporaryPath + "/"), rootPath != "/" else { return }
        try? fileManager.removeItem(at: root)
    }
}

private struct PersistentSupervisorSetup {
    let scope: WatchedScope
    let activation: ScopeMountActivation
    let resolved: ResolvedFSEventDeviceScope
    let identity: PersistentEventStreamIdentity
}

private struct FixedFSEventDeviceScopeResolver: FSEventDeviceScopeResolving {
    let resolved: ResolvedFSEventDeviceScope

    func resolve(watchedURLs: [URL]) throws -> ResolvedFSEventDeviceScope {
        resolved
    }
}

private final class ScriptedFSEventDeviceScopeResolver: FSEventDeviceScopeResolving {
    private let outcomes: Mutex<[ResolvedFSEventDeviceScope]>

    init(outcomes: [ResolvedFSEventDeviceScope]) {
        self.outcomes = Mutex(outcomes)
    }

    func resolve(watchedURLs: [URL]) throws -> ResolvedFSEventDeviceScope {
        outcomes.withLock { outcomes in
            precondition(outcomes.isEmpty == false, "Missing scripted resolver outcome.")
            return outcomes.removeFirst()
        }
    }
}

enum RecoveryVolumeMismatch: Sendable, CustomTestStringConvertible {
    case missingIdentity
    case replacementVolume

    var testDescription: String {
        switch self {
        case .missingIdentity:
            "missing identity"
        case .replacementVolume:
            "replacement volume"
        }
    }
}

struct RecoveryPolicyInvalidCase: Sendable, CustomTestStringConvertible {
    let expected: FSEventStreamRecoveryPolicyError
    let maximumAttempts: Int
    let initialBackoffMilliseconds: Int
    let maximumBackoffMilliseconds: Int
    let stabilityThresholdMilliseconds: Int

    init(
        expected: FSEventStreamRecoveryPolicyError,
        maximumAttempts: Int = 1,
        initialBackoffMilliseconds: Int = 0,
        maximumBackoffMilliseconds: Int = 0,
        stabilityThresholdMilliseconds: Int = 0
    ) {
        self.expected = expected
        self.maximumAttempts = maximumAttempts
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.stabilityThresholdMilliseconds = stabilityThresholdMilliseconds
    }

    var testDescription: String {
        String(describing: expected)
    }
}

private final class ScriptedStreamHarness: Sendable {
    enum Outcome: Sendable {
        case success
        case terminalFailure
        case failure(FSEventStreamError)
    }

    private struct CountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var outcomes: [Outcome]
        var configurations: [FSEventStreamConfiguration] = []
        var configurationWaiters: [CountWaiter] = []
        var stopCount = 0
        var stopWaiters: [CountWaiter] = []
    }

    private let state: Mutex<State>

    init(outcomes: [Outcome]) {
        state = Mutex(State(outcomes: outcomes))
    }

    func makeClient() -> any FSEventStreamControlling {
        let outcome = state.withLock { state in
            precondition(state.outcomes.isEmpty == false, "Missing scripted stream outcome.")
            return state.outcomes.removeFirst()
        }
        return ScriptedFSEventStreamClient(outcome: outcome, harness: self)
    }

    func configurations() -> [FSEventStreamConfiguration] {
        state.withLock { $0.configurations }
    }

    func waitForConfigurationCount(_ count: Int) async {
        guard configurations().count < count else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.configurations.count < count else { return true }
                state.configurationWaiters.append(
                    CountWaiter(count: count, continuation: continuation)
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func waitForStopCount(_ count: Int) async {
        let currentCount = state.withLock { $0.stopCount }
        guard currentCount < count else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.stopCount < count else { return true }
                state.stopWaiters.append(
                    CountWaiter(count: count, continuation: continuation)
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    fileprivate func record(_ configuration: FSEventStreamConfiguration) {
        let continuations = state.withLock { state in
            state.configurations.append(configuration)
            let currentCount = state.configurations.count
            let ready = state.configurationWaiters.filter { $0.count <= currentCount }
            state.configurationWaiters.removeAll { $0.count <= currentCount }
            return ready.map(\.continuation)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    fileprivate func recordStop() {
        let continuations = state.withLock { state in
            state.stopCount += 1
            let ready = state.stopWaiters.filter { $0.count <= state.stopCount }
            state.stopWaiters.removeAll { $0.count <= state.stopCount }
            return ready.map(\.continuation)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class ScriptedFSEventStreamClient: FSEventStreamControlling {
    private let outcome: ScriptedStreamHarness.Outcome
    private let harness: ScriptedStreamHarness
    private let continuation = Mutex<FSEventStreamClient.ObservationStream.Continuation?>(nil)
    private let didStop = Mutex(false)

    init(
        outcome: ScriptedStreamHarness.Outcome,
        harness: ScriptedStreamHarness
    ) {
        self.outcome = outcome
        self.harness = harness
    }

    func start(
        configuration: FSEventStreamConfiguration
    ) throws -> FSEventStreamClient.ObservationStream {
        harness.record(configuration)
        switch outcome {
        case .success:
            let pair = FSEventStreamClient.ObservationStream.makeStream()
            continuation.withLock { $0 = pair.continuation }
            return pair.stream
        case .terminalFailure:
            let pair = FSEventStreamClient.ObservationStream.makeStream()
            continuation.withLock { $0 = pair.continuation }
            pair.continuation.finish(throwing: ScriptedStreamTerminalError())
            return pair.stream
        case let .failure(error):
            throw error
        }
    }

    func stop() {
        let shouldRecord = didStop.withLock { didStop in
            guard didStop == false else { return false }
            didStop = true
            return true
        }
        if shouldRecord {
            harness.recordStop()
        }
        let saved = continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
        saved?.finish()
    }
}

private struct ScriptedStreamTerminalError: Error, Sendable {}

private enum SupervisorFixtureError: Error {
    case unsafeTemporaryPath
}
