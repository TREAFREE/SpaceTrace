import Foundation
import SpaceTraceApplication

public struct ActiveScopeFSEventStatus: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let generationID: MountGenerationID
    public let streamID: EventStreamID
    public let persistentIdentity: PersistentEventStreamIdentity?

    public init(
        scopeID: WatchedScopeID,
        generationID: MountGenerationID,
        streamID: EventStreamID,
        persistentIdentity: PersistentEventStreamIdentity?
    ) {
        self.scopeID = scopeID
        self.generationID = generationID
        self.streamID = streamID
        self.persistentIdentity = persistentIdentity
    }
}

/// Native implementation of the application-owned stream lifecycle port.
/// One scope owns one client and one consumer task; replacement is conditional
/// on the mount generation selected transactionally by the repository.
public actor NativeScopeFSEventSupervisor: ScopeEventStreamSupervisor {
    private struct ActiveStream {
        let status: ActiveScopeFSEventStatus
        let client: any FSEventStreamControlling
        let task: Task<Void, Never>
    }

    private struct OpenedStream {
        let client: any FSEventStreamControlling
        let observations: FSEventStreamClient.ObservationStream
    }

    private let repository: any EventJournalRepository
    private let scanner: any CalibrationScanner
    private let resolver: any FSEventDeviceScopeResolving
    private let makeStreamClient: @Sendable () -> any FSEventStreamControlling
    private let mapper: FSEventInvalidationMapper
    private let latency: TimeInterval
    private let bufferCapacity: Int
    private let excludeEventsFromThisProcess: Bool
    private var streams: [WatchedScopeID: ActiveStream] = [:]
    private var revisions: [WatchedScopeID: UInt64] = [:]
    private var failures: [WatchedScopeID: String] = [:]

    public init(
        repository: any EventJournalRepository,
        scanner: any CalibrationScanner,
        resolver: any FSEventDeviceScopeResolving = FSEventDeviceScopeResolver(),
        makeStreamClient: @escaping @Sendable () -> any FSEventStreamControlling = {
            FSEventStreamClient()
        },
        mapper: FSEventInvalidationMapper = FSEventInvalidationMapper(),
        latency: TimeInterval = 1,
        bufferCapacity: Int = 512,
        excludeEventsFromThisProcess: Bool = true
    ) {
        self.repository = repository
        self.scanner = scanner
        self.resolver = resolver
        self.makeStreamClient = makeStreamClient
        self.mapper = mapper
        self.latency = latency
        self.bufferCapacity = bufferCapacity
        self.excludeEventsFromThisProcess = excludeEventsFromThisProcess
    }

    public func restart(
        scope: WatchedScope,
        activation: ScopeMountActivation
    ) async throws {
        guard activation.current.scopeID == scope.id,
              activation.current.isActive,
              activation.current.mountPath == scope.mountPath else {
            throw NativeScopeFSEventSupervisorError.invalidActivation
        }

        let revision = nextRevision(for: scope.id)
        await stopCurrent(scopeID: scope.id)

        let resolved = try resolver.resolve(
            watchedURLs: [URL(fileURLWithPath: scope.root.rawValue, isDirectory: true)]
        )
        let resolvedMountPath = Self.applicationPath(resolved.deviceTarget.mountPath)
        guard resolvedMountPath == activation.current.mountPath.rawValue else {
            throw NativeScopeFSEventSupervisorError.resolvedMountPathChanged(
                expected: activation.current.mountPath.rawValue,
                actual: resolvedMountPath
            )
        }
        if let expected = activation.current.volumeUUID,
           let actual = resolved.volumeUUID,
           expected != actual {
            throw NativeScopeFSEventSupervisorError.resolvedVolumeChanged
        }

        let identity = resolved.persistentIdentity
        let streamID = try identity?.streamID ?? EventStreamID(
            "fsevents-live/v1/\(scope.id.rawValue)/\(activation.current.generationID.rawValue)"
        )
        let checkpoint = identity == nil
            ? nil
            : try await repository.checkpoint(for: streamID)
        let replayPosition = checkpoint.map {
            FSEventReplayPosition.after(FSEventID(rawValue: $0.rawValue))
        } ?? .sinceNow

        try ensureCurrent(revision, for: scope.id)
        let opened = try await openStream(
            scope: scope,
            resolved: resolved,
            streamID: streamID,
            replayPosition: replayPosition,
            hasStoredCheckpoint: checkpoint != nil,
            revision: revision
        )
        let pipeline = FileSystemCalibrationPipeline(
            streamID: streamID,
            watchRoot: scope.root,
            repository: repository,
            scanner: scanner
        )

        do {
            if activation.requiresCalibration {
                let invalidation = try FileSystemInvalidation(
                    path: scope.root.rawValue,
                    cursor: nil,
                    reasons: [
                        .mountChanged,
                        .mustScanSubdirectories,
                        .requiresCalibration,
                    ],
                    itemKind: .directory
                )
                try await pipeline.ingest([invalidation])
            }
            try ensureCurrent(revision, for: scope.id)
        } catch {
            opened.client.stop()
            throw error
        }

        let generationID = activation.current.generationID
        let mapping = mapper
        let task = Task { @concurrent [weak self] in
            let failure = await Self.consume(
                opened.observations,
                mapper: mapping,
                pipeline: pipeline
            )
            await self?.streamTerminated(
                scopeID: scope.id,
                generationID: generationID,
                failure: failure
            )
        }
        let status = ActiveScopeFSEventStatus(
            scopeID: scope.id,
            generationID: generationID,
            streamID: streamID,
            persistentIdentity: identity
        )
        streams[scope.id] = ActiveStream(
            status: status,
            client: opened.client,
            task: task
        )
        failures.removeValue(forKey: scope.id)
    }

    public func stop(
        scopeID: WatchedScopeID,
        matching generationID: MountGenerationID
    ) async {
        _ = nextRevision(for: scopeID)
        guard streams[scopeID]?.status.generationID == generationID else { return }
        await stopCurrent(scopeID: scopeID)
    }

    public func stopAll() async {
        for scopeID in streams.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            _ = nextRevision(for: scopeID)
            await stopCurrent(scopeID: scopeID)
        }
    }

    public func activeStatus(
        for scopeID: WatchedScopeID
    ) -> ActiveScopeFSEventStatus? {
        streams[scopeID]?.status
    }

    public func lastFailure(for scopeID: WatchedScopeID) -> String? {
        failures[scopeID]
    }

    private func nextRevision(for scopeID: WatchedScopeID) -> UInt64 {
        let next = (revisions[scopeID] ?? 0) &+ 1
        revisions[scopeID] = next
        return next
    }

    private func ensureCurrent(
        _ revision: UInt64,
        for scopeID: WatchedScopeID
    ) throws {
        guard revisions[scopeID] == revision else {
            throw NativeScopeFSEventSupervisorError.operationSuperseded
        }
    }

    /// A stored cursor is useful only while the native daemon accepts the
    /// corresponding replay request. If that request cannot be created or
    /// started, conservatively invalidate its history in the same transaction
    /// as scope-level recovery work, then attempt one live stream. Further
    /// live-start failures are left to the runtime's bounded readiness retry.
    private func openStream(
        scope: WatchedScope,
        resolved: ResolvedFSEventDeviceScope,
        streamID: EventStreamID,
        replayPosition: FSEventReplayPosition,
        hasStoredCheckpoint: Bool,
        revision: UInt64
    ) async throws -> OpenedStream {
        do {
            return try startClient(
                configuration: configuration(
                    scope: scope,
                    resolved: resolved,
                    replayPosition: replayPosition
                )
            )
        } catch where hasStoredCheckpoint && Self.isRecoverableStartFailure(error) {
            let recoveryRegion = try DirtyRegion(
                path: scope.root,
                reasons: [
                    .mustScanSubdirectories,
                    .droppedEvents,
                    .requiresCalibration,
                ],
                maximumCursor: nil
            )
            try await repository.invalidateCheckpointAndMarkDirty(
                streamID: streamID,
                regions: [recoveryRegion]
            )
            try ensureCurrent(revision, for: scope.id)
            return try startClient(
                configuration: configuration(
                    scope: scope,
                    resolved: resolved,
                    replayPosition: .sinceNow
                )
            )
        }
    }

    private func configuration(
        scope: WatchedScope,
        resolved: ResolvedFSEventDeviceScope,
        replayPosition: FSEventReplayPosition
    ) throws -> FSEventStreamConfiguration {
        if resolved.persistentIdentity != nil {
            return try resolved.configuration(
                replayPosition: replayPosition,
                latency: latency,
                bufferCapacity: bufferCapacity,
                excludeEventsFromThisProcess: excludeEventsFromThisProcess
            )
        }
        return FSEventStreamConfiguration(
            watchedPaths: [scope.root.rawValue],
            replayPosition: .sinceNow,
            latency: latency,
            bufferCapacity: bufferCapacity,
            excludeEventsFromThisProcess: excludeEventsFromThisProcess
        )
    }

    private func startClient(
        configuration: FSEventStreamConfiguration
    ) throws -> OpenedStream {
        let client = makeStreamClient()
        do {
            return OpenedStream(
                client: client,
                observations: try client.start(configuration: configuration)
            )
        } catch {
            client.stop()
            throw error
        }
    }

    private func stopCurrent(scopeID: WatchedScopeID) async {
        guard let active = streams.removeValue(forKey: scopeID) else { return }
        active.client.stop()
        active.task.cancel()
        await active.task.value
    }

    private func streamTerminated(
        scopeID: WatchedScopeID,
        generationID: MountGenerationID,
        failure: String?
    ) {
        guard streams[scopeID]?.status.generationID == generationID else { return }
        streams.removeValue(forKey: scopeID)
        failures[scopeID] = failure ?? "FSEvents stream ended unexpectedly."
    }

    private nonisolated static func consume(
        _ observations: FSEventStreamClient.ObservationStream,
        mapper: FSEventInvalidationMapper,
        pipeline: FileSystemCalibrationPipeline
    ) async -> String? {
        do {
            for try await observation in observations {
                try Task.checkCancellation()
                if let invalidation = try mapper.map(observation) {
                    try await pipeline.ingest([invalidation])
                }
            }
            return Task.isCancelled ? nil : "FSEvents stream ended unexpectedly."
        } catch is CancellationError {
            return nil
        } catch {
            return String(reflecting: error)
        }
    }

    private nonisolated static func applicationPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private nonisolated static func isRecoverableStartFailure(
        _ error: any Error
    ) -> Bool {
        guard let error = error as? FSEventStreamError else { return false }
        switch error {
        case .creationFailed, .startFailed:
            return true
        default:
            return false
        }
    }
}

public enum NativeScopeFSEventSupervisorError: Error, Sendable, Equatable {
    case invalidActivation
    case resolvedMountPathChanged(expected: String, actual: String)
    case resolvedVolumeChanged
    case operationSuperseded
}
