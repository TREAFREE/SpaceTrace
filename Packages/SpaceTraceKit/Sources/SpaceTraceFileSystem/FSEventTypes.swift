import Foundation

/// The opaque, monotonically increasing identifier assigned by FSEvents.
///
/// An event identifier is a cursor, not a timestamp. Callers must not infer
/// wall-clock time, elapsed time, or byte changes from its value.
public struct FSEventID: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Where a newly-created stream should begin replaying the FSEvents journal.
public enum FSEventReplayPosition: Hashable, Codable, Sendable {
    /// Observe only events that occur after the stream starts.
    case sinceNow

    /// Replay events after the supplied cursor before switching to live events.
    case after(FSEventID)
}

/// A semantic interpretation of one or more public FSEvents flags.
///
/// These values remain invalidation hints. They do not identify the process
/// responsible for a change and do not contain measured storage deltas.
public enum FSEventReason: String, CaseIterable, Hashable, Codable, Sendable {
    case pathChanged
    case descendantsMustBeScanned
    case eventsDroppedByUserSpace
    case eventsDroppedByKernel
    case eventIdentifiersWrapped
    case historicalReplayCompleted
    case watchedRootChanged
    case volumeMounted
    case volumeUnmounted
    case itemCreated
    case itemRemoved
    case itemMetadataModified
    case itemRenamed
    case itemContentModified
    case itemFinderInfoModified
    case itemOwnershipChanged
    case itemExtendedAttributesModified
    case itemIsFile
    case itemIsDirectory
    case itemIsSymbolicLink
    case eventOriginatedFromThisProcess
    case itemIsHardLink
    case itemWasLastHardLink
    case itemCloned
    case callbackBridgeOverflow
    case unrecognizedFlags
}

/// One immutable invalidation observation emitted by the FSEvents adapter.
public struct FSEventObservation: Hashable, Codable, Sendable {
    /// The affected path when FSEvents identifies a meaningful path.
    ///
    /// This is `nil` for stream-wide continuity gaps and history sentinels.
    public let path: String?

    /// The native journal identifier, when one accompanies the observation.
    public let eventID: FSEventID?

    /// Semantic reasons derived from the public FSEvents flag word.
    public let reasons: Set<FSEventReason>

    /// The original public FSEvents flag word for forward-compatible evidence.
    public let rawFlags: UInt32

    /// Bits not understood by this version of SpaceTrace.
    public let unrecognizedFlags: UInt32

    public init(
        path: String?,
        eventID: FSEventID?,
        reasons: Set<FSEventReason>,
        rawFlags: UInt32,
        unrecognizedFlags: UInt32 = 0
    ) {
        self.path = path
        self.eventID = eventID
        self.reasons = reasons
        self.rawFlags = rawFlags
        self.unrecognizedFlags = unrecognizedFlags
    }

    /// Whether measured state must be reconciled with a bounded calibration scan.
    public var requiresCalibration: Bool {
        reasons.isDisjoint(with: Self.calibrationReasons) == false
    }

    /// Whether the event stream can no longer prove uninterrupted detail.
    public var indicatesContinuityGap: Bool {
        reasons.isDisjoint(with: Self.continuityGapReasons) == false
    }

    private static let calibrationReasons: Set<FSEventReason> = [
        .descendantsMustBeScanned,
        .eventsDroppedByUserSpace,
        .eventsDroppedByKernel,
        .eventIdentifiersWrapped,
        .watchedRootChanged,
        .callbackBridgeOverflow,
        .unrecognizedFlags,
    ]

    private static let continuityGapReasons: Set<FSEventReason> = [
        .descendantsMustBeScanned,
        .eventsDroppedByUserSpace,
        .eventsDroppedByKernel,
        .eventIdentifiersWrapped,
        .callbackBridgeOverflow,
        .unrecognizedFlags,
    ]
}

/// One volume-relative target for `FSEventStreamCreateRelativeToDevice`.
public struct FSEventDeviceTarget: Hashable, Sendable {
    /// Ephemeral device identifier used only for the current native stream.
    public let deviceID: UInt64

    /// Absolute root where the volume is currently mounted. Native callback
    /// paths are relative to the device and are restored beneath this root.
    public let mountPath: String

    /// Paths relative to the device root. The empty string watches the root.
    public let relativePaths: [String]

    init(deviceID: UInt64, mountPath: String, relativePaths: [String]) {
        self.deviceID = deviceID
        self.mountPath = mountPath
        self.relativePaths = relativePaths
    }
}

/// Native FSEvents stream kind. Host streams are restricted to live,
/// non-persistent observation; durable replay requires a per-device target.
public enum FSEventStreamTarget: Hashable, Sendable {
    case host(absolutePaths: [String])
    case device(FSEventDeviceTarget)
}

/// Immutable inputs for one FSEvents stream.
public struct FSEventStreamConfiguration: Hashable, Sendable {
    public let target: FSEventStreamTarget

    public let replayPosition: FSEventReplayPosition

    /// Coalescing latency passed to FSEvents, measured in seconds.
    public let latency: TimeInterval

    /// Maximum number of observations awaiting the single consumer.
    public let bufferCapacity: Int

    /// Whether events produced by SpaceTrace itself are excluded.
    public let excludeEventsFromThisProcess: Bool

    public init(
        watchedPaths: [String],
        replayPosition: FSEventReplayPosition = .sinceNow,
        latency: TimeInterval = 1,
        bufferCapacity: Int = 512,
        excludeEventsFromThisProcess: Bool = true
    ) {
        self.target = .host(absolutePaths: watchedPaths)
        self.replayPosition = replayPosition
        self.latency = latency
        self.bufferCapacity = bufferCapacity
        self.excludeEventsFromThisProcess = excludeEventsFromThisProcess
    }

    init(
        deviceTarget: FSEventDeviceTarget,
        replayPosition: FSEventReplayPosition = .sinceNow,
        latency: TimeInterval = 1,
        bufferCapacity: Int = 512,
        excludeEventsFromThisProcess: Bool = true
    ) {
        self.target = .device(deviceTarget)
        self.replayPosition = replayPosition
        self.latency = latency
        self.bufferCapacity = bufferCapacity
        self.excludeEventsFromThisProcess = excludeEventsFromThisProcess
    }
}

public enum FSEventStreamConfigurationError: Error, Equatable, Sendable {
    case noWatchedPaths
    case watchedPathMustBeAbsolute(index: Int)
    case persistentReplayRequiresDeviceTarget
    case deviceIdentifierMustBePositiveAndRepresentable
    case deviceMountPathMustBeNormalizedAbsolute
    case devicePathMustBeNormalizedRelative(index: Int)
    case latencyMustBeFiniteAndNonnegative
    case bufferCapacityMustBePositive
}

/// Failures that prevent the native observation stream from starting.
public enum FSEventStreamError: Error, Equatable, Sendable {
    case invalidConfiguration(FSEventStreamConfigurationError)
    case alreadyRunning
    case creationFailed
    case startFailed
}
