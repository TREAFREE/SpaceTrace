import DiskArbitration
import Dispatch
import Foundation
import SpaceTraceApplication
import Synchronization

/// Owned values copied synchronously from one Disk Arbitration callback.
/// `bsdName` is useful only for matching callbacks in the current process and
/// must not be used as durable volume identity.
public struct DiskArbitrationVolumeSnapshot: Sendable, Equatable, Hashable {
    public let bsdName: String?
    public let mountPath: String?
    public let volumeUUID: UUID?

    public init(bsdName: String?, mountPath: String?, volumeUUID: UUID?) {
        self.bsdName = bsdName
        self.mountPath = mountPath
        self.volumeUUID = volumeUUID
    }

    /// Converts a currently mounted snapshot into application-owned evidence.
    /// An unmounted snapshot has no path and therefore cannot activate a scope.
    public func mountEvidence() throws -> VolumeMountEvidence? {
        guard let mountPath else { return nil }
        return try VolumeMountEvidence(
            mountPath: DirtyRegionPath(mountPath),
            volumeUUID: volumeUUID
        )
    }
}

public enum DiskArbitrationVolumeEvent: Sendable, Equatable, Hashable {
    case appeared(DiskArbitrationVolumeSnapshot)
    case descriptionChanged(DiskArbitrationVolumeSnapshot)
    case disappeared(DiskArbitrationVolumeSnapshot)
    /// The callback-to-async bridge discarded at least one precise event.
    /// Consumers must re-resolve affected scopes instead of inferring order.
    case callbackBridgeOverflow
}

/// Single-active-subscription bridge for public Disk Arbitration volume and
/// mount-path notifications. It observes only; it never approves, mounts,
/// unmounts, claims, or otherwise mutates disks.
public final class DiskArbitrationVolumeEventSource: Sendable {
    public typealias EventStream = AsyncStream<DiskArbitrationVolumeEvent>

    private let state = Mutex(State())

    public init() {}

    deinit {
        stop()
    }

    public func start(bufferCapacity: Int = 128) throws -> EventStream {
        guard bufferCapacity > 0 else {
            throw DiskArbitrationVolumeEventSourceError.invalidBufferCapacity
        }

        let streamPair = EventStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferCapacity)
        )
        let generation: UInt64
        do {
            generation = try state.withLock { state in
                guard state.session == nil else {
                    throw DiskArbitrationVolumeEventSourceError.alreadyRunning
                }
                guard let session = DASessionCreate(kCFAllocatorDefault) else {
                    throw DiskArbitrationVolumeEventSourceError.sessionCreationFailed
                }

                state.generation &+= 1
                let generation = state.generation
                let callbackBox = DiskArbitrationCallbackBox(
                    continuation: streamPair.continuation
                )
                let callbackContext = Unmanaged.passUnretained(callbackBox).toOpaque()
                // Construct the documented predefined match/watch values from
                // immutable keys. The SDK imports the predefined convenience
                // globals as mutable C variables, which is unnecessarily
                // unsafe under complete Swift concurrency checking.
                let mountableVolumes = [
                    kDADiskDescriptionVolumeMountableKey as String: true,
                ] as CFDictionary
                let mountPathWatch = [
                    kDADiskDescriptionVolumePathKey as String,
                ] as CFArray

                DARegisterDiskAppearedCallback(
                    session,
                    mountableVolumes,
                    receiveDiskAppeared,
                    callbackContext
                )
                DARegisterDiskDescriptionChangedCallback(
                    session,
                    mountableVolumes,
                    mountPathWatch,
                    receiveDiskDescriptionChanged,
                    callbackContext
                )
                DARegisterDiskDisappearedCallback(
                    session,
                    mountableVolumes,
                    receiveDiskDisappeared,
                    callbackContext
                )

                let callbackQueue = DispatchQueue(
                    label: "com.treafree.SpaceTrace.disk-arbitration.callback.\(generation)",
                    qos: .utility
                )
                state.session = session
                state.callbackQueue = callbackQueue
                state.callbackBox = callbackBox
                state.continuation = streamPair.continuation
                DASessionSetDispatchQueue(session, callbackQueue)
                return generation
            }
        } catch {
            streamPair.continuation.finish()
            throw error
        }

        streamPair.continuation.onTermination = { [weak self] _ in
            self?.stop(generation: generation)
        }
        return streamPair.stream
    }

    /// Stops the matching session and drains callbacks before releasing their
    /// context. Repeated calls are harmless.
    public func stop() {
        stop(generation: nil)
    }

    private func stop(generation expectedGeneration: UInt64?) {
        let continuation = state.withLock { state -> EventStream.Continuation? in
            if let expectedGeneration, expectedGeneration != state.generation {
                return nil
            }
            let continuation = state.continuation
            state.releaseSession()
            return continuation
        }

        // `finish()` may synchronously call `onTermination`; never invoke it
        // while the state mutex is held.
        continuation?.finish()
    }
}

private extension DiskArbitrationVolumeEventSource {
    struct State {
        var generation: UInt64 = 0
        var session: DASession?
        var callbackQueue: DispatchQueue?
        var callbackBox: DiskArbitrationCallbackBox?
        var continuation: EventStream.Continuation?

        mutating func releaseSession() {
            guard let session else {
                callbackQueue = nil
                callbackBox = nil
                continuation = nil
                return
            }

            // Apple's contract defines a nil queue as unscheduling. Draining
            // the serial callback queue keeps the unretained callback context
            // alive until every already-enqueued callback has returned.
            DASessionSetDispatchQueue(session, nil)
            callbackQueue?.sync {}

            self.session = nil
            callbackQueue = nil
            callbackBox = nil
            continuation = nil
        }
    }
}

private final class DiskArbitrationCallbackBox: Sendable {
    private let continuation: DiskArbitrationVolumeEventSource.EventStream.Continuation

    init(continuation: DiskArbitrationVolumeEventSource.EventStream.Continuation) {
        self.continuation = continuation
    }

    func receive(_ disk: DADisk, kind: DiskArbitrationObservationKind) {
        let description = (DADiskCopyDescription(disk) as NSDictionary?) ?? [:]
        let bsdName = DADiskGetBSDName(disk).map(String.init(cString:))
        let event = DiskArbitrationObservationFactory.make(
            kind: kind,
            bsdName: bsdName,
            description: description
        )
        DiskArbitrationCallbackBridge.yield(event, to: continuation)
    }
}

enum DiskArbitrationObservationKind {
    case appeared
    case descriptionChanged
    case disappeared
}

enum DiskArbitrationObservationFactory {
    static func make(
        kind: DiskArbitrationObservationKind,
        bsdName: String?,
        description: NSDictionary
    ) -> DiskArbitrationVolumeEvent {
        let snapshot = DiskArbitrationVolumeSnapshot(
            bsdName: meaningfulBSDName(bsdName),
            mountPath: mountPath(from: description),
            volumeUUID: volumeUUID(from: description)
        )
        switch kind {
        case .appeared:
            return .appeared(snapshot)
        case .descriptionChanged:
            return .descriptionChanged(snapshot)
        case .disappeared:
            return .disappeared(snapshot)
        }
    }

    private static func meaningfulBSDName(_ name: String?) -> String? {
        guard let name, name.isEmpty == false, name.utf8.contains(0) == false else {
            return nil
        }
        return name
    }

    private static func mountPath(from description: NSDictionary) -> String? {
        let value = description[kDADiskDescriptionVolumePathKey as String]
        let path: String?
        if let url = value as? URL, url.isFileURL {
            path = url.path
        } else if let url = value as? NSURL, url.isFileURL {
            path = url.path
        } else {
            path = nil
        }
        guard let path, isNormalizedAbsolutePath(path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func volumeUUID(from description: NSDictionary) -> UUID? {
        let value = description[kDADiskDescriptionVolumeUUIDKey as String]
        if let uuid = value as? UUID {
            return uuid
        }
        if let uuid = value as? NSUUID {
            return uuid as UUID
        }
        return nil
    }

    private static func isNormalizedAbsolutePath(_ path: String) -> Bool {
        guard path.first == "/", path.utf8.contains(0) == false else {
            return false
        }
        if path == "/" {
            return true
        }
        return path.last != "/"
            && path.contains("//") == false
            && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }
}

enum DiskArbitrationCallbackBridge {
    static func yield(
        _ event: DiskArbitrationVolumeEvent,
        to continuation: DiskArbitrationVolumeEventSource.EventStream.Continuation
    ) {
        switch continuation.yield(event) {
        case .enqueued, .terminated:
            return
        case .dropped:
            _ = continuation.yield(.callbackBridgeOverflow)
        @unknown default:
            return
        }
    }
}

private func receiveDiskAppeared(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) {
    callbackBox(from: context)?.receive(disk, kind: .appeared)
}

private func receiveDiskDescriptionChanged(
    _ disk: DADisk,
    _ changedKeys: CFArray,
    _ context: UnsafeMutableRawPointer?
) {
    _ = changedKeys
    callbackBox(from: context)?.receive(disk, kind: .descriptionChanged)
}

private func receiveDiskDisappeared(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) {
    callbackBox(from: context)?.receive(disk, kind: .disappeared)
}

private func callbackBox(
    from context: UnsafeMutableRawPointer?
) -> DiskArbitrationCallbackBox? {
    guard let context else { return nil }
    return Unmanaged<DiskArbitrationCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
}

public enum DiskArbitrationVolumeEventSourceError: Error, Sendable, Equatable {
    case invalidBufferCapacity
    case alreadyRunning
    case sessionCreationFailed
}
