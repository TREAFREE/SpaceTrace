import Foundation
import Synchronization
import Testing
@testable import SpaceTraceApplication

@Suite("Scope monitoring coordinator")
struct ScopeMonitoringCoordinatorTests {
    @Test("A mounted volume activates only scopes for its mount root and duplicate callbacks do not restart")
    func activatesContainedScopesOnce() async throws {
        let included = try scope("included", root: "/Volumes/Work/Projects")
        let excluded = try scope("excluded", root: "/Volumes/Other")
        let repository = ScopeGenerationRepositorySpy()
        let supervisor = ScopeSupervisorSpy()
        let coordinator = ScopeMonitoringCoordinator(
            catalog: FixedScopeCatalog(scopes: [excluded, included]),
            repository: repository,
            supervisor: supervisor,
            makeGenerationID: try generationFactory(["generation-1", "unused-2"])
        )
        let volumeUUID = UUID()
        let observation = try mountedObservation(
            runtimeID: "disk9s1",
            mountPath: "/Volumes/Work",
            volumeUUID: volumeUUID
        )

        let first = try await coordinator.process(.available(observation))
        let duplicate = try await coordinator.process(.changed(observation))

        #expect(first.activations.map(\.current.scopeID) == [included.id])
        #expect(first.activations.first?.reason == .firstMount)
        #expect(duplicate.activations.first?.reason == .duplicateNotification)
        #expect(await supervisor.restarts().count == 1)
        #expect(await supervisor.stops().isEmpty)
        #expect(try await repository.scopeMountGeneration(for: excluded.id) == nil)
    }

    @Test("Unmount closes only the generation correlated to the runtime disk")
    func deactivatesMatchingRuntimeDisk() async throws {
        let first = try scope("first", root: "/Volumes/First/Scope")
        let second = try scope("second", root: "/Volumes/Second/Scope")
        let repository = ScopeGenerationRepositorySpy()
        let supervisor = ScopeSupervisorSpy()
        let coordinator = ScopeMonitoringCoordinator(
            catalog: FixedScopeCatalog(scopes: [first, second]),
            repository: repository,
            supervisor: supervisor,
            makeGenerationID: try generationFactory(["first-generation", "second-generation"])
        )
        let firstVolume = UUID()
        let secondVolume = UUID()
        _ = try await coordinator.process(
            .available(try mountedObservation(
                runtimeID: "disk9s1",
                mountPath: "/Volumes/First",
                volumeUUID: firstVolume
            ))
        )
        _ = try await coordinator.process(
            .available(try mountedObservation(
                runtimeID: "disk10s1",
                mountPath: "/Volumes/Second",
                volumeUUID: secondVolume
            ))
        )

        let result = try await coordinator.process(
            .unavailable(try unmountedObservation(runtimeID: "disk9s1", volumeUUID: firstVolume))
        )

        #expect(result.deactivatedScopeIDs == [first.id])
        #expect(try await repository.scopeMountGeneration(for: first.id)?.isActive == false)
        #expect(try await repository.scopeMountGeneration(for: second.id)?.isActive == true)
        #expect(await supervisor.stops().map(\.scopeID) == [first.id])
    }

    @Test("Remount and same-path replacement both open new generations")
    func remountAndReplacementOpenGenerations() async throws {
        let watched = try scope("watched", root: "/Volumes/Exchange/Scope")
        let repository = ScopeGenerationRepositorySpy()
        let supervisor = ScopeSupervisorSpy()
        let coordinator = ScopeMonitoringCoordinator(
            catalog: FixedScopeCatalog(scopes: [watched]),
            repository: repository,
            supervisor: supervisor,
            makeGenerationID: try generationFactory(["g1", "g2", "g3"])
        )
        let firstVolume = UUID()
        let replacementVolume = UUID()
        let firstMount = try mountedObservation(
            runtimeID: "disk9s1",
            mountPath: "/Volumes/Exchange",
            volumeUUID: firstVolume
        )

        let initial = try await coordinator.process(.available(firstMount))
        _ = try await coordinator.process(
            .unavailable(try unmountedObservation(runtimeID: "disk9s1", volumeUUID: firstVolume))
        )
        let remount = try await coordinator.process(.available(firstMount))
        let replacement = try await coordinator.process(
            .changed(try mountedObservation(
                runtimeID: "disk10s1",
                mountPath: "/Volumes/Exchange",
                volumeUUID: replacementVolume
            ))
        )

        #expect(initial.activations.first?.current.generationID.rawValue == "g1")
        #expect(remount.activations.first?.reason == .remountedSameVolume)
        #expect(remount.activations.first?.current.generationID.rawValue == "g2")
        #expect(replacement.activations.first?.reason == .replacementVolume)
        #expect(replacement.activations.first?.current.generationID.rawValue == "g3")
        #expect(await supervisor.restarts().count == 3)
    }

    @Test("Callback continuity loss closes every generation and requests source recreation")
    func continuityLossClosesAll() async throws {
        let watched = try scope("watched", root: "/Volumes/Work/Scope")
        let repository = ScopeGenerationRepositorySpy()
        let supervisor = ScopeSupervisorSpy()
        let coordinator = ScopeMonitoringCoordinator(
            catalog: FixedScopeCatalog(scopes: [watched]),
            repository: repository,
            supervisor: supervisor,
            makeGenerationID: try generationFactory(["generation-1"])
        )
        _ = try await coordinator.process(
            .available(try mountedObservation(
                runtimeID: "disk9s1",
                mountPath: "/Volumes/Work",
                volumeUUID: UUID()
            ))
        )

        let result = try await coordinator.process(.continuityLost)

        #expect(result.requiresVolumeEventSourceRestart)
        #expect(result.deactivatedScopeIDs == [watched.id])
        #expect(await coordinator.activeGeneration(for: watched.id) == nil)
        #expect(try await repository.scopeMountGeneration(for: watched.id)?.isActive == false)
    }

    @Test("A parent-volume callback cannot activate a scope configured for another mount root")
    func rejectsParentVolumeCallback() async throws {
        let watched = try scope("external", root: "/Volumes/External/Scope")
        let repository = ScopeGenerationRepositorySpy()
        let supervisor = ScopeSupervisorSpy()
        let coordinator = ScopeMonitoringCoordinator(
            catalog: FixedScopeCatalog(scopes: [watched]),
            repository: repository,
            supervisor: supervisor
        )
        let rootEvidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/"),
            volumeUUID: UUID()
        )

        let result = try await coordinator.process(
            .available(
                VolumeMountObservation(
                    runtimeID: nil,
                    evidence: rootEvidence,
                    volumeUUID: rootEvidence.volumeUUID
                )
            )
        )

        #expect(result.activations.isEmpty)
        #expect(try await repository.scopeMountGeneration(for: watched.id) == nil)
        #expect(await supervisor.restarts().isEmpty)
    }

    @Test("Scope evidence is enriched before the generation is activated")
    func enrichesEvidenceBeforeActivation() async throws {
        let watched = try scope("external", root: "/Volumes/External/Scope")
        let repository = ScopeGenerationRepositorySpy()
        let supervisor = ScopeSupervisorSpy()
        let resolvedUUID = UUID()
        let coordinator = ScopeMonitoringCoordinator(
            catalog: FixedScopeCatalog(scopes: [watched]),
            repository: repository,
            supervisor: supervisor,
            evidenceResolver: EvidenceResolverStub(volumeUUID: resolvedUUID),
            makeGenerationID: try generationFactory(["resolved-generation"])
        )
        let incompleteEvidence = try VolumeMountEvidence(
            mountPath: watched.mountPath,
            volumeUUID: nil
        )

        let result = try await coordinator.process(
            .changed(
                VolumeMountObservation(
                    runtimeID: nil,
                    evidence: incompleteEvidence,
                    volumeUUID: nil
                )
            )
        )

        #expect(result.activations.first?.current.volumeUUID == resolvedUUID)
        #expect(try await repository.scopeMountGeneration(for: watched.id)?.volumeUUID == resolvedUUID)
    }

    @Test("Scope configuration rejects an unrelated mount root and duplicate IDs")
    func validatesScopeConfiguration() throws {
        #expect(throws: ScopeMonitoringError.scopeOutsideMountPath) {
            try WatchedScope(
                id: WatchedScopeID("invalid"),
                root: DirtyRegionPath("/Volumes/First/Scope"),
                mountPath: DirtyRegionPath("/Volumes/Second")
            )
        }
        let watched = try scope("duplicate", root: "/Volumes/First/Scope")
        #expect(throws: ScopeMonitoringError.duplicateScopeID) {
            try ConfiguredWatchedScopeCatalog(scopes: [watched, watched])
        }
    }

    private func scope(_ id: String, root: String) throws -> WatchedScope {
        let components = root.split(separator: "/")
        let mountPath = "/" + components.prefix(2).joined(separator: "/")
        return try WatchedScope(
            id: WatchedScopeID(id),
            root: DirtyRegionPath(root),
            mountPath: DirtyRegionPath(mountPath)
        )
    }

    private func mountedObservation(
        runtimeID: String,
        mountPath: String,
        volumeUUID: UUID
    ) throws -> VolumeMountObservation {
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath(mountPath),
            volumeUUID: volumeUUID
        )
        return try VolumeMountObservation(
            runtimeID: RuntimeVolumeID(runtimeID),
            evidence: evidence,
            volumeUUID: volumeUUID
        )
    }

    private func unmountedObservation(
        runtimeID: String,
        volumeUUID: UUID
    ) throws -> VolumeMountObservation {
        try VolumeMountObservation(
            runtimeID: RuntimeVolumeID(runtimeID),
            evidence: nil,
            volumeUUID: volumeUUID
        )
    }

    private func generationFactory(
        _ values: [String]
    ) throws -> @Sendable () -> MountGenerationID {
        let state = GenerationFactoryState(values: try values.map(MountGenerationID.init))
        return { state.next() }
    }
}

private struct FixedScopeCatalog: WatchedScopeCatalog {
    let scopes: [WatchedScope]

    func watchedScopes() async throws -> [WatchedScope] {
        scopes
    }
}

private struct EvidenceResolverStub: ScopeMountEvidenceResolver {
    let volumeUUID: UUID

    func resolve(
        _ evidence: VolumeMountEvidence,
        for scope: WatchedScope
    ) async throws -> VolumeMountEvidence {
        _ = scope
        return try VolumeMountEvidence(
            mountPath: evidence.mountPath,
            volumeUUID: volumeUUID
        )
    }
}

private final class GenerationFactoryState: Sendable {
    private let values: Mutex<[MountGenerationID]>

    init(values: [MountGenerationID]) {
        self.values = Mutex(values)
    }

    func next() -> MountGenerationID {
        values.withLock { values in
            values.removeFirst()
        }
    }
}

private actor ScopeSupervisorSpy: ScopeEventStreamSupervisor {
    struct Restart: Sendable {
        let scope: WatchedScope
        let activation: ScopeMountActivation
    }

    struct Stop: Sendable {
        let scopeID: WatchedScopeID
        let generationID: MountGenerationID
    }

    private var recordedRestarts: [Restart] = []
    private var recordedStops: [Stop] = []

    func restart(scope: WatchedScope, activation: ScopeMountActivation) async throws {
        recordedRestarts.append(Restart(scope: scope, activation: activation))
    }

    func stop(scopeID: WatchedScopeID, matching generationID: MountGenerationID) async {
        recordedStops.append(Stop(scopeID: scopeID, generationID: generationID))
    }

    func restarts() -> [Restart] { recordedRestarts }
    func stops() -> [Stop] { recordedStops }
}

private actor ScopeGenerationRepositorySpy: ScopeMountGenerationRepository {
    private var rows: [WatchedScopeID: ScopeMountGeneration] = [:]

    func activateScopeMount(
        scopeID: WatchedScopeID,
        evidence: VolumeMountEvidence,
        proposedGenerationID: MountGenerationID
    ) async throws -> ScopeMountActivation {
        let activation = ScopeMountGenerationStateMachine.activate(
            previous: rows[scopeID],
            scopeID: scopeID,
            evidence: evidence,
            proposedGenerationID: proposedGenerationID
        )
        rows[scopeID] = activation.current
        return activation
    }

    func deactivateScopeMount(
        scopeID: WatchedScopeID,
        matching generationID: MountGenerationID
    ) async throws -> Bool {
        guard let current = rows[scopeID],
              current.isActive,
              current.generationID == generationID else { return false }
        rows[scopeID] = ScopeMountGeneration(
            scopeID: current.scopeID,
            generationID: current.generationID,
            mountPath: current.mountPath,
            volumeUUID: current.volumeUUID,
            isActive: false
        )
        return true
    }

    func scopeMountGeneration(
        for scopeID: WatchedScopeID
    ) async throws -> ScopeMountGeneration? {
        rows[scopeID]
    }
}
