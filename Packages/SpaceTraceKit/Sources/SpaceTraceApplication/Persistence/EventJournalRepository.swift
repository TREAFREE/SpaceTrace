/// Stable identity for one event-journal stream, normally one volume
/// generation. The validation prevents unusable SQLite keys from crossing the
/// application boundary.
public struct EventStreamID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws(EventJournalModelError) {
        guard rawValue.isEmpty == false,
              rawValue.allSatisfy(\.isWhitespace) == false,
              rawValue.utf8.contains(0) == false,
              rawValue.first?.isWhitespace == false,
              rawValue.last?.isWhitespace == false else {
            throw .invalidStreamID
        }

        self.rawValue = rawValue
    }

    init(validatedRawValue rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "EventStreamID must be non-empty, trimmed, and free of null bytes."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The full-width event ID reported by the filesystem journal. It is not a
/// timestamp and must never be narrowed to SQLite's signed integer range.
public struct EventJournalCursor: Sendable, Equatable, Hashable, Comparable, Codable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: EventJournalCursor, rhs: EventJournalCursor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A normalized absolute directory path that is safe to use as a durable
/// dirty-region key. Filesystem adapters are responsible for mapping file
/// events to their narrowest safe directory before constructing this value.
public struct DirtyRegionPath: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws(EventJournalModelError) {
        guard rawValue.isEmpty == false,
              rawValue.utf8.contains(0) == false,
              rawValue.first == "/" else {
            throw .invalidDirtyRegionPath(rawValue)
        }

        if rawValue != "/" {
            guard rawValue.last != "/",
                  rawValue.contains("//") == false else {
                throw .invalidDirtyRegionPath(rawValue)
            }

            let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
            guard components.dropFirst().allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw .invalidDirtyRegionPath(rawValue)
            }
        }

        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "DirtyRegionPath must be a normalized absolute path."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Reasons are deliberately a bit set: multiple coalesced filesystem events
/// must retain all safety-relevant causes instead of choosing one label.
public struct DirtyRegionReason: OptionSet, Sendable, Equatable, Hashable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let created = DirtyRegionReason(rawValue: 1 << 0)
    public static let removed = DirtyRegionReason(rawValue: 1 << 1)
    public static let renamed = DirtyRegionReason(rawValue: 1 << 2)
    public static let contentModified = DirtyRegionReason(rawValue: 1 << 3)
    public static let metadataChanged = DirtyRegionReason(rawValue: 1 << 4)
    public static let mustScanSubdirectories = DirtyRegionReason(rawValue: 1 << 5)
    public static let droppedEvents = DirtyRegionReason(rawValue: 1 << 6)
    public static let rootChanged = DirtyRegionReason(rawValue: 1 << 7)
    public static let mountChanged = DirtyRegionReason(rawValue: 1 << 8)
    public static let requiresCalibration = DirtyRegionReason(rawValue: 1 << 9)
}

/// Durable work derived from one or more filesystem events for a directory.
public struct DirtyRegion: Sendable, Equatable, Hashable, Codable {
    public let path: DirtyRegionPath
    public let reasons: DirtyRegionReason
    /// The newest journal cursor represented by this work, when one exists.
    /// Out-of-band continuity failures such as `RootChanged` may create
    /// durable calibration work without advancing or inventing a cursor.
    public let maximumCursor: EventJournalCursor?

    public init(
        path: DirtyRegionPath,
        reasons: DirtyRegionReason,
        maximumCursor: EventJournalCursor?
    ) throws(EventJournalModelError) {
        guard reasons.isEmpty == false else {
            throw .emptyDirtyRegionReasons
        }

        self.path = path
        self.reasons = reasons
        self.maximumCursor = maximumCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(DirtyRegionPath.self, forKey: .path)
        let reasons = try container.decode(DirtyRegionReason.self, forKey: .reasons)
        let maximumCursor = try container.decodeIfPresent(
            EventJournalCursor.self,
            forKey: .maximumCursor
        )

        do {
            try self.init(path: path, reasons: reasons, maximumCursor: maximumCursor)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .reasons,
                in: container,
                debugDescription: "A dirty region must contain at least one reason."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case reasons
        case maximumCursor
    }
}

/// The atomic unit accepted by the event journal repository. Requiring at
/// least one covered dirty region prevents a checkpoint from advancing past
/// event work that was never made durable.
public struct EventJournalBatch: Sendable, Equatable, Codable {
    public let streamID: EventStreamID
    public let checkpoint: EventJournalCursor
    public let dirtyRegions: [DirtyRegion]

    public init(
        streamID: EventStreamID,
        checkpoint: EventJournalCursor,
        dirtyRegions: [DirtyRegion]
    ) throws(EventJournalModelError) {
        guard dirtyRegions.isEmpty == false else {
            throw .emptyBatch
        }
        for region in dirtyRegions {
            guard let maximumCursor = region.maximumCursor else {
                throw .eventBatchRequiresCursors
            }
            guard maximumCursor <= checkpoint else {
                throw .dirtyRegionCursorExceedsCheckpoint
            }
        }

        self.streamID = streamID
        self.checkpoint = checkpoint
        self.dirtyRegions = dirtyRegions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let streamID = try container.decode(EventStreamID.self, forKey: .streamID)
        let checkpoint = try container.decode(EventJournalCursor.self, forKey: .checkpoint)
        let dirtyRegions = try container.decode([DirtyRegion].self, forKey: .dirtyRegions)

        do {
            try self.init(
                streamID: streamID,
                checkpoint: checkpoint,
                dirtyRegions: dirtyRegions
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .dirtyRegions,
                in: container,
                debugDescription: "EventJournalBatch does not satisfy its cursor coverage invariant."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case streamID
        case checkpoint
        case dirtyRegions
    }
}

public enum EventJournalModelError: Error, Sendable, Equatable {
    case invalidStreamID
    case invalidDirtyRegionPath(String)
    case emptyDirtyRegionReasons
    case emptyBatch
    case eventBatchRequiresCursors
    case dirtyRegionCursorExceedsCheckpoint
    case invalidDirtyRegionRevision(UInt64)
}

/// A monotonic row token used to prevent an older calibration result from
/// clearing dirty work that changed while the scan was in flight.
public struct DirtyRegionRevision: Sendable, Equatable, Hashable, Comparable, Codable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws(EventJournalModelError) {
        guard rawValue > 0 else {
            throw .invalidDirtyRegionRevision(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(UInt64.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "DirtyRegionRevision must be greater than zero."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: DirtyRegionRevision, rhs: DirtyRegionRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct DirtyRegionWorkItem: Sendable, Equatable, Hashable, Codable {
    public let region: DirtyRegion
    public let revision: DirtyRegionRevision

    public init(region: DirtyRegion, revision: DirtyRegionRevision) {
        self.region = region
        self.revision = revision
    }
}

/// Application-owned persistence port. Implementations may use SQLite, an
/// in-memory fake, or a future reviewed adapter without leaking database types
/// into filesystem or application logic.
public protocol EventJournalRepository: Sendable {
    func commit(_ batch: EventJournalBatch) async throws
    func markDirty(streamID: EventStreamID, regions: [DirtyRegion]) async throws
    /// Atomically invalidates an unusable journal generation and persists the
    /// recovery work that makes the loss explicit. Existing dirty cursors must
    /// also be cleared and their revisions advanced.
    func invalidateCheckpointAndMarkDirty(
        streamID: EventStreamID,
        regions: [DirtyRegion]
    ) async throws
    func checkpoint(for streamID: EventStreamID) async throws -> EventJournalCursor?
    func dirtyRegions(for streamID: EventStreamID) async throws -> [DirtyRegion]
    func pendingDirtyWork(
        for streamID: EventStreamID,
        limit: Int
    ) async throws -> [DirtyRegionWorkItem]
    func beginCalibration(_ request: CalibrationRequest) async throws -> CalibrationRunID
    func stageCalibration(
        _ aggregates: [DirectoryMetadataAggregate],
        in runID: CalibrationRunID
    ) async throws
    func finalizeCalibration(
        _ runID: CalibrationRunID,
        report: CalibrationReport,
        workItem: DirtyRegionWorkItem,
        streamID: EventStreamID
    ) async throws -> Bool
    func discardCalibration(
        _ runID: CalibrationRunID,
        disposition: CalibrationRunDisposition,
        report: CalibrationReport?
    ) async throws
    func currentDirectoryAggregates(
        for streamID: EventStreamID
    ) async throws -> [DirectoryMetadataAggregate]
}
