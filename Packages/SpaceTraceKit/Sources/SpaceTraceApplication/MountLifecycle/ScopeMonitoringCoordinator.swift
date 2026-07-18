import Foundation

/// One user-approved directory that may be observed while its containing
/// volume is mounted. The root remains the configured scope; a volume event
/// must never broaden it to the whole mount.
public struct WatchedScope: Sendable, Equatable, Hashable {
    public let id: WatchedScopeID
    public let root: DirtyRegionPath
    public let mountPath: DirtyRegionPath

    public init(
        id: WatchedScopeID,
        root: DirtyRegionPath,
        mountPath: DirtyRegionPath
    ) throws(ScopeMonitoringError) {
        guard Self.contains(root, beneath: mountPath) else {
            throw .scopeOutsideMountPath
        }
        self.id = id
        self.root = root
        self.mountPath = mountPath
    }

    private static func contains(
        _ root: DirtyRegionPath,
        beneath mountPath: DirtyRegionPath
    ) -> Bool {
        if mountPath.rawValue == "/" {
            return true
        }
        return root.rawValue == mountPath.rawValue
            || root.rawValue.hasPrefix(mountPath.rawValue + "/")
    }
}

public protocol WatchedScopeCatalog: Sendable {
    func watchedScopes() async throws -> [WatchedScope]
}

public struct ConfiguredWatchedScopeCatalog: WatchedScopeCatalog {
    private let scopes: [WatchedScope]

    public init(scopes: [WatchedScope]) throws(ScopeMonitoringError) {
        guard Set(scopes.map(\.id)).count == scopes.count else {
            throw .duplicateScopeID
        }
        self.scopes = scopes.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func watchedScopes() async throws -> [WatchedScope] {
        scopes
    }
}

/// Runtime-only identity used to correlate Disk Arbitration callbacks. It is
/// deliberately excluded from every persistence model.
public struct RuntimeVolumeID: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ScopeMonitoringError) {
        guard rawValue.isEmpty == false,
              rawValue.allSatisfy(\.isWhitespace) == false,
              rawValue.utf8.contains(0) == false else {
            throw .invalidRuntimeVolumeID
        }
        self.rawValue = rawValue
    }
}

/// Application-owned projection of one native volume callback.
public struct VolumeMountObservation: Sendable, Equatable, Hashable {
    public let runtimeID: RuntimeVolumeID?
    public let evidence: VolumeMountEvidence?
    public let volumeUUID: UUID?

    public init(
        runtimeID: RuntimeVolumeID?,
        evidence: VolumeMountEvidence?,
        volumeUUID: UUID?
    ) {
        self.runtimeID = runtimeID
        self.evidence = evidence
        self.volumeUUID = evidence?.volumeUUID ?? volumeUUID
    }
}

public enum VolumeLifecycleSignal: Sendable, Equatable, Hashable {
    case available(VolumeMountObservation)
    case changed(VolumeMountObservation)
    case unavailable(VolumeMountObservation)
    case continuityLost
}

/// Owns the native stream lifecycle while the application coordinator owns
/// mount-generation decisions.
public protocol ScopeEventStreamSupervisor: Sendable {
    func restart(
        scope: WatchedScope,
        activation: ScopeMountActivation
    ) async throws

    func stop(
        scopeID: WatchedScopeID,
        matching generationID: MountGenerationID
    ) async
}

/// Enriches incomplete native mount observations using only the already
/// approved scope. Implementations must not broaden resolution to another
/// directory or volume.
public protocol ScopeMountEvidenceResolver: Sendable {
    func resolve(
        _ evidence: VolumeMountEvidence,
        for scope: WatchedScope
    ) async throws -> VolumeMountEvidence
}

public struct ObservedScopeMountEvidenceResolver: ScopeMountEvidenceResolver {
    public init() {}

    public func resolve(
        _ evidence: VolumeMountEvidence,
        for scope: WatchedScope
    ) async throws -> VolumeMountEvidence {
        _ = scope
        return evidence
    }
}

public struct ScopeMonitoringResult: Sendable, Equatable {
    public let activations: [ScopeMountActivation]
    public let deactivatedScopeIDs: [WatchedScopeID]
    public let requiresVolumeEventSourceRestart: Bool

    public init(
        activations: [ScopeMountActivation] = [],
        deactivatedScopeIDs: [WatchedScopeID] = [],
        requiresVolumeEventSourceRestart: Bool = false
    ) {
        self.activations = activations
        self.deactivatedScopeIDs = deactivatedScopeIDs
        self.requiresVolumeEventSourceRestart = requiresVolumeEventSourceRestart
    }
}

/// Serial application-layer orchestration for volume callbacks. Callers must
/// feed one source stream sequentially; overlapping calls fail instead of
/// silently reordering mount and unmount evidence across suspension points.
public actor ScopeMonitoringCoordinator {
    private struct Binding: Sendable {
        let runtimeID: RuntimeVolumeID?
        let generationID: MountGenerationID
        let mountPath: DirtyRegionPath
        let volumeUUID: UUID?
    }

    private let catalog: any WatchedScopeCatalog
    private let repository: any ScopeMountGenerationRepository
    private let supervisor: any ScopeEventStreamSupervisor
    private let evidenceResolver: any ScopeMountEvidenceResolver
    private let makeGenerationID: @Sendable () -> MountGenerationID
    private var bindings: [WatchedScopeID: Binding] = [:]
    private var isProcessing = false

    public init(
        catalog: any WatchedScopeCatalog,
        repository: any ScopeMountGenerationRepository,
        supervisor: any ScopeEventStreamSupervisor,
        evidenceResolver: any ScopeMountEvidenceResolver = ObservedScopeMountEvidenceResolver(),
        makeGenerationID: @escaping @Sendable () -> MountGenerationID = {
            MountGenerationID()
        }
    ) {
        self.catalog = catalog
        self.repository = repository
        self.supervisor = supervisor
        self.evidenceResolver = evidenceResolver
        self.makeGenerationID = makeGenerationID
    }

    public func process(
        _ signal: VolumeLifecycleSignal
    ) async throws -> ScopeMonitoringResult {
        guard isProcessing == false else {
            throw ScopeMonitoringError.concurrentSignalProcessing
        }
        isProcessing = true
        defer { isProcessing = false }

        switch signal {
        case let .available(observation):
            guard let evidence = observation.evidence else {
                return ScopeMonitoringResult()
            }
            return try await activateScopes(
                for: evidence,
                runtimeID: observation.runtimeID
            )
        case let .changed(observation):
            if let evidence = observation.evidence {
                return try await activateScopes(for: evidence, runtimeID: observation.runtimeID)
            }
            return try await deactivateScopes(matching: observation)
        case let .unavailable(observation):
            return try await deactivateScopes(matching: observation)
        case .continuityLost:
            let deactivated = try await deactivateAllScopes()
            return ScopeMonitoringResult(
                deactivatedScopeIDs: deactivated,
                requiresVolumeEventSourceRestart: true
            )
        }
    }

    public func shutdown() async throws {
        guard isProcessing == false else {
            throw ScopeMonitoringError.concurrentSignalProcessing
        }
        isProcessing = true
        defer { isProcessing = false }
        _ = try await deactivateAllScopes()
    }

    public func activeGeneration(
        for scopeID: WatchedScopeID
    ) -> MountGenerationID? {
        bindings[scopeID]?.generationID
    }

    private func activateScopes(
        for evidence: VolumeMountEvidence,
        runtimeID: RuntimeVolumeID?
    ) async throws -> ScopeMonitoringResult {
        let scopes = try await catalog.watchedScopes()
            .filter { $0.mountPath == evidence.mountPath }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        var activations: [ScopeMountActivation] = []

        for scope in scopes {
            let resolvedEvidence = try await evidenceResolver.resolve(evidence, for: scope)
            let activation = try await repository.activateScopeMount(
                scopeID: scope.id,
                evidence: resolvedEvidence,
                proposedGenerationID: makeGenerationID()
            )

            if activation.reason != .duplicateNotification {
                do {
                    try await supervisor.restart(scope: scope, activation: activation)
                } catch {
                    _ = try? await repository.deactivateScopeMount(
                        scopeID: scope.id,
                        matching: activation.current.generationID
                    )
                    bindings.removeValue(forKey: scope.id)
                    throw error
                }
            }

            bindings[scope.id] = Binding(
                runtimeID: runtimeID,
                generationID: activation.current.generationID,
                mountPath: resolvedEvidence.mountPath,
                volumeUUID: activation.current.volumeUUID
            )
            activations.append(activation)
        }

        return ScopeMonitoringResult(activations: activations)
    }

    private func deactivateScopes(
        matching observation: VolumeMountObservation
    ) async throws -> ScopeMonitoringResult {
        let matches = bindings
            .filter { _, binding in Self.matches(binding, observation: observation) }
            .sorted { $0.key.rawValue < $1.key.rawValue }
        var deactivated: [WatchedScopeID] = []

        for (scopeID, binding) in matches {
            await supervisor.stop(
                scopeID: scopeID,
                matching: binding.generationID
            )
            if try await repository.deactivateScopeMount(
                scopeID: scopeID,
                matching: binding.generationID
            ) {
                deactivated.append(scopeID)
            }
            if bindings[scopeID]?.generationID == binding.generationID {
                bindings.removeValue(forKey: scopeID)
            }
        }

        return ScopeMonitoringResult(deactivatedScopeIDs: deactivated)
    }

    private func deactivateAllScopes() async throws -> [WatchedScopeID] {
        let active = bindings.sorted { $0.key.rawValue < $1.key.rawValue }
        var deactivated: [WatchedScopeID] = []
        for (scopeID, binding) in active {
            await supervisor.stop(scopeID: scopeID, matching: binding.generationID)
            if try await repository.deactivateScopeMount(
                scopeID: scopeID,
                matching: binding.generationID
            ) {
                deactivated.append(scopeID)
            }
            if bindings[scopeID]?.generationID == binding.generationID {
                bindings.removeValue(forKey: scopeID)
            }
        }
        return deactivated
    }

    private static func matches(
        _ binding: Binding,
        observation: VolumeMountObservation
    ) -> Bool {
        if let runtimeID = observation.runtimeID {
            return binding.runtimeID == runtimeID
        }
        if let volumeUUID = observation.volumeUUID {
            return binding.volumeUUID == volumeUUID
        }
        if let mountPath = observation.evidence?.mountPath {
            return binding.mountPath == mountPath
        }
        return false
    }
}

public enum ScopeMonitoringError: Error, Sendable, Equatable {
    case invalidRuntimeVolumeID
    case duplicateScopeID
    case scopeOutsideMountPath
    case concurrentSignalProcessing
}
