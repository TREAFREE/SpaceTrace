import CoreServices
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Minimal lifecycle surface used by the application-owned supervisor.
/// Keeping native construction behind this port makes startup and history
/// recovery deterministic under fault injection without exposing callbacks to
/// higher layers.
public protocol FSEventStreamControlling: Sendable {
    func start(
        configuration: FSEventStreamConfiguration
    ) throws -> FSEventStreamClient.ObservationStream
    func stop()
}

/// A single-active-subscription bridge from the native FSEvents callback API
/// to Swift concurrency.
///
/// Each returned stream is intended for exactly one consumer. Events are
/// invalidation hints only: callers must measure filesystem metadata in a
/// separate, bounded calibration scan before deriving storage changes.
public final class FSEventStreamClient: Sendable {
    public typealias ObservationStream = AsyncThrowingStream<FSEventObservation, any Error>

    private let state = Mutex(State())
    private let onNativeObservationYielded: (@Sendable () -> Void)?

    public init() {
        onNativeObservationYielded = nil
    }

    /// Internal observation seam used by integration tests to wait on native
    /// callback completion without consuming the bounded application stream.
    init(onNativeObservationYielded: @escaping @Sendable () -> Void) {
        self.onNativeObservationYielded = onNativeObservationYielded
    }

    deinit {
        stop()
    }

    /// Creates, schedules, and starts one native FSEvents stream. Durable
    /// replay configurations are restricted to resolved per-device targets.
    ///
    /// The method throws a concrete ``FSEventStreamError`` before returning if
    /// native creation or start fails. Cancelling iteration invokes the
    /// continuation's termination handler, which synchronously stops,
    /// invalidates, and releases the matching native stream.
    public func start(configuration: FSEventStreamConfiguration) throws -> ObservationStream {
        if let validationError = configuration.validationError {
            throw FSEventStreamError.invalidConfiguration(validationError)
        }

        let streamPair = ObservationStream.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.bufferCapacity)
        )

        let generation: UInt64
        do {
            generation = try state.withLock { state in
                guard state.nativeStream == nil else {
                    throw FSEventStreamError.alreadyRunning
                }

                state.generation &+= 1
                let generation = state.generation
                let callbackBox = FSEventCallbackBox(
                    continuation: streamPair.continuation,
                    pathTransform: configuration.callbackPathTransform,
                    onNativeObservationYielded: onNativeObservationYielded
                )
                let callbackInfo = Unmanaged.passUnretained(callbackBox).toOpaque()
                var context = FSEventStreamContext(
                    version: 0,
                    info: callbackInfo,
                    retain: retainFSEventCallbackInfo,
                    release: releaseFSEventCallbackInfo,
                    copyDescription: nil
                )

                let createFlags = configuration.nativeCreateFlags
                let sinceWhen = configuration.nativeReplayPosition
                let paths = configuration.nativeWatchedPaths as CFArray
                let nativeStream: FSEventStreamRef?
                switch configuration.target {
                case .host:
                    nativeStream = FSEventStreamCreate(
                        kCFAllocatorDefault,
                        receiveFSEvents,
                        &context,
                        paths,
                        sinceWhen,
                        configuration.latency,
                        createFlags
                    )
                case let .device(target):
                    guard let deviceID = dev_t(exactly: target.deviceID) else {
                        throw FSEventStreamError.invalidConfiguration(
                            .deviceIdentifierMustBePositiveAndRepresentable
                        )
                    }
                    nativeStream = FSEventStreamCreateRelativeToDevice(
                        kCFAllocatorDefault,
                        receiveFSEvents,
                        &context,
                        deviceID,
                        paths,
                        sinceWhen,
                        configuration.latency,
                        createFlags
                    )
                }

                guard let nativeStream else {
                    throw FSEventStreamError.creationFailed
                }

                let callbackQueue = DispatchQueue(
                    label: "com.treafree.SpaceTrace.fsevents.callback.\(generation)",
                    qos: .utility
                )
                FSEventStreamSetDispatchQueue(nativeStream, callbackQueue)

                state.nativeStream = nativeStream
                state.callbackQueue = callbackQueue
                state.continuation = streamPair.continuation
                state.started = false

                guard FSEventStreamStart(nativeStream) else {
                    state.releaseNativeStream()
                    throw FSEventStreamError.startFailed
                }

                state.started = true
                return generation
            }
        } catch {
            streamPair.continuation.finish(throwing: error)
            throw error
        }

        streamPair.continuation.onTermination = { [weak self] _ in
            self?.stop(generation: generation)
        }
        return streamPair.stream
    }

    /// Stops the current subscription, if any. This operation is idempotent.
    public func stop() {
        stop(generation: nil)
    }

    /// Synchronizes native callbacks for events that occurred before this
    /// call. This blocking boundary is internal so integration tests can avoid
    /// timing sleeps without exposing native stream control to the app layer.
    /// It must never run on a UI-bound executor.
    func flushSynchronously() -> Bool {
        state.withLock { state in
            guard state.started, let nativeStream = state.nativeStream else {
                return false
            }
            FSEventStreamFlushSync(nativeStream)
            return true
        }
    }

    private func stop(generation expectedGeneration: UInt64?) {
        let continuation = state.withLock { state -> ObservationStream.Continuation? in
            if let expectedGeneration, expectedGeneration != state.generation {
                return nil
            }

            let continuation = state.continuation
            state.releaseNativeStream()
            return continuation
        }

        // Finish after releasing the mutex because finishing invokes the
        // termination callback synchronously on some code paths.
        continuation?.finish()
    }
}

extension FSEventStreamClient: FSEventStreamControlling {}

private extension FSEventStreamClient {
    struct State {
        var generation: UInt64 = 0
        var nativeStream: FSEventStreamRef?
        var callbackQueue: DispatchQueue?
        var continuation: ObservationStream.Continuation?
        var started = false

        mutating func releaseNativeStream() {
            guard let nativeStream else {
                callbackQueue = nil
                continuation = nil
                started = false
                return
            }

            if started {
                FSEventStreamStop(nativeStream)
            }
            FSEventStreamInvalidate(nativeStream)
            FSEventStreamRelease(nativeStream)

            self.nativeStream = nil
            callbackQueue = nil
            continuation = nil
            started = false
        }
    }
}

private final class FSEventCallbackBox: Sendable {
    private let continuation: FSEventStreamClient.ObservationStream.Continuation
    private let pathTransform: FSEventCallbackPathTransform
    private let onNativeObservationYielded: (@Sendable () -> Void)?

    init(
        continuation: FSEventStreamClient.ObservationStream.Continuation,
        pathTransform: FSEventCallbackPathTransform,
        onNativeObservationYielded: (@Sendable () -> Void)?
    ) {
        self.continuation = continuation
        self.pathTransform = pathTransform
        self.onNativeObservationYielded = onNativeObservationYielded
    }

    func receive(
        eventCount: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) {
        let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)

        for index in 0..<eventCount {
            guard let pathBytes = paths[index] else {
                continue
            }

            let observation = FSEventObservationFactory.make(
                pathTransform.absolutePath(for: String(cString: pathBytes)),
                eventID: eventIDs[index],
                rawFlags: eventFlags[index]
            )
            FSEventCallbackBridge.yield(observation, to: continuation)
            onNativeObservationYielded?()
        }
    }
}

enum FSEventCallbackPathTransform: Sendable, Equatable {
    case host
    case device(mountPath: String)

    func absolutePath(for callbackPath: String) -> String {
        let path: String
        switch self {
        case .host:
            path = callbackPath
        case let .device(mountPath):
            guard callbackPath.isEmpty == false else {
                return URL(fileURLWithPath: mountPath).standardizedFileURL.path
            }
            let relative = callbackPath.first == "/"
                ? String(callbackPath.dropFirst())
                : callbackPath
            guard relative.isEmpty == false else {
                return URL(fileURLWithPath: mountPath).standardizedFileURL.path
            }
            path = mountPath == "/" ? "/\(relative)" : "\(mountPath)/\(relative)"
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum FSEventObservationFactory {
    private static let invalidCursorReasons: Set<FSEventReason> = [
        .eventsDroppedByUserSpace,
        .eventsDroppedByKernel,
        .eventIdentifiersWrapped,
        .watchedRootChanged,
        .unrecognizedFlags,
    ]

    static func make(
        _ path: String,
        eventID: FSEventStreamEventId,
        rawFlags: FSEventStreamEventFlags
    ) -> FSEventObservation {
        let interpretation = FSEventFlagInterpreter.interpret(rawFlags)
        let reasons = interpretation.reasons

        return FSEventObservation(
            path: meaningfulPath(path, reasons: reasons),
            eventID: meaningfulEventID(eventID, reasons: reasons),
            reasons: reasons,
            rawFlags: UInt32(rawFlags),
            unrecognizedFlags: interpretation.unrecognizedFlags
        )
    }

    private static func meaningfulPath(
        _ path: String,
        reasons: Set<FSEventReason>
    ) -> String? {
        let pathIsSentinel = reasons.contains(.historicalReplayCompleted)
            || reasons.contains(.eventsDroppedByUserSpace)
            || reasons.contains(.eventsDroppedByKernel)
            || reasons.contains(.eventIdentifiersWrapped)
        return pathIsSentinel ? nil : path
    }

    private static func meaningfulEventID(
        _ eventID: FSEventStreamEventId,
        reasons: Set<FSEventReason>
    ) -> FSEventID? {
        // FSEvents documents ID zero on RootChanged as a sentinel rather than
        // a replayable journal cursor. Exposing it as a real cursor could
        // regress the durable checkpoint or restart replay from the beginning.
        guard reasons.isDisjoint(with: invalidCursorReasons) else {
            return nil
        }
        return FSEventID(rawValue: eventID)
    }
}

enum FSEventCallbackBridge {
    static func yield(
        _ observation: FSEventObservation,
        to continuation: FSEventStreamClient.ObservationStream.Continuation
    ) {
        switch continuation.yield(observation) {
        case .enqueued, .terminated:
            return
        case .dropped:
            // bufferingNewest guarantees this newest marker replaces an older
            // buffered value. If a later callback replaces the marker, that
            // yield also reports a drop and refreshes the marker again.
            _ = continuation.yield(
                FSEventObservation(
                    path: nil,
                    eventID: nil,
                    reasons: [.callbackBridgeOverflow],
                    rawFlags: 0
                )
            )
        @unknown default:
            return
        }
    }
}

private func receiveFSEvents(
    _ stream: ConstFSEventStreamRef,
    _ callbackInfo: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let callbackInfo else {
        return
    }

    Unmanaged<FSEventCallbackBox>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
        .receive(
            eventCount: eventCount,
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIDs: eventIDs
        )
}

private func retainFSEventCallbackInfo(
    _ callbackInfo: UnsafeRawPointer?
) -> UnsafeRawPointer? {
    guard let callbackInfo else {
        return nil
    }

    _ = Unmanaged<FSEventCallbackBox>
        .fromOpaque(callbackInfo)
        .retain()
    return callbackInfo
}

private func releaseFSEventCallbackInfo(_ callbackInfo: UnsafeRawPointer?) {
    guard let callbackInfo else {
        return
    }

    Unmanaged<FSEventCallbackBox>
        .fromOpaque(callbackInfo)
        .release()
}

extension FSEventStreamConfiguration {
    var validationError: FSEventStreamConfigurationError? {
        switch target {
        case let .host(absolutePaths):
            guard absolutePaths.isEmpty == false else {
                return .noWatchedPaths
            }
            for (index, path) in absolutePaths.enumerated() where path.first != "/" {
                return .watchedPathMustBeAbsolute(index: index)
            }
            if case .after = replayPosition {
                return .persistentReplayRequiresDeviceTarget
            }
        case let .device(target):
            guard target.relativePaths.isEmpty == false else {
                return .noWatchedPaths
            }
            guard target.deviceID > 0, dev_t(exactly: target.deviceID) != nil else {
                return .deviceIdentifierMustBePositiveAndRepresentable
            }
            guard Self.isNormalizedAbsolutePath(target.mountPath) else {
                return .deviceMountPathMustBeNormalizedAbsolute
            }
            for (index, path) in target.relativePaths.enumerated()
            where Self.isNormalizedRelativeDevicePath(path) == false {
                return .devicePathMustBeNormalizedRelative(index: index)
            }
        }

        guard latency.isFinite, latency >= 0 else {
            return .latencyMustBeFiniteAndNonnegative
        }
        guard bufferCapacity > 0 else {
            return .bufferCapacityMustBePositive
        }
        return nil
    }

    var nativeWatchedPaths: [String] {
        switch target {
        case let .host(absolutePaths):
            return absolutePaths
        case let .device(target):
            return target.relativePaths
        }
    }

    var callbackPathTransform: FSEventCallbackPathTransform {
        switch target {
        case .host:
            return .host
        case let .device(target):
            return .device(mountPath: target.mountPath)
        }
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

    private static func isNormalizedRelativeDevicePath(_ path: String) -> Bool {
        guard path.utf8.contains(0) == false, path.first != "/" else {
            return false
        }
        if path.isEmpty {
            return true
        }
        return path.last != "/"
            && path.contains("//") == false
            && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }

    var nativeReplayPosition: FSEventStreamEventId {
        switch replayPosition {
        case .sinceNow:
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        case let .after(eventID):
            eventID.rawValue
        }
    }

    var nativeCreateFlags: FSEventStreamCreateFlags {
        var flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFullHistory
        )
        if excludeEventsFromThisProcess {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)
        }
        return flags
    }
}
