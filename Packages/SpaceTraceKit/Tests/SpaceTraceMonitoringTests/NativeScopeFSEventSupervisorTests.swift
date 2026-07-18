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

private final class ScriptedStreamHarness: Sendable {
    enum Outcome: Sendable {
        case success
        case failure(FSEventStreamError)
    }

    private struct State {
        var outcomes: [Outcome]
        var configurations: [FSEventStreamConfiguration] = []
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

    fileprivate func record(_ configuration: FSEventStreamConfiguration) {
        state.withLock { $0.configurations.append(configuration) }
    }
}

private final class ScriptedFSEventStreamClient: FSEventStreamControlling {
    private let outcome: ScriptedStreamHarness.Outcome
    private let harness: ScriptedStreamHarness
    private let continuation = Mutex<FSEventStreamClient.ObservationStream.Continuation?>(nil)

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
        case let .failure(error):
            throw error
        }
    }

    func stop() {
        let saved = continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
        saved?.finish()
    }
}

private enum SupervisorFixtureError: Error {
    case unsafeTemporaryPath
}
