/// Application-level item classification. It intentionally contains no
/// FSEvents or Foundation types so other observation adapters can reuse it.
public enum FileSystemItemKind: Sendable, Equatable, Hashable, Codable {
    case file
    case directory
    case symbolicLink
    case unknown
}

/// One lossy filesystem invalidation hint after adapter-specific flags have
/// been translated into application semantics.
public struct FileSystemInvalidation: Sendable, Equatable, Hashable, Codable {
    public let path: String?
    public let cursor: EventJournalCursor?
    public let reasons: DirtyRegionReason
    public let itemKind: FileSystemItemKind

    public init(
        path: String?,
        cursor: EventJournalCursor?,
        reasons: DirtyRegionReason,
        itemKind: FileSystemItemKind = .unknown
    ) throws(EventJournalModelError) {
        guard reasons.isEmpty == false else {
            throw .emptyDirtyRegionReasons
        }

        self.path = path
        self.cursor = cursor
        self.reasons = reasons
        self.itemKind = itemKind
    }
}

/// Durable work split by whether it can safely advance the journal cursor.
public struct DirtyRegionPlan: Sendable, Equatable {
    public let checkpoint: EventJournalCursor?
    public let journaledRegions: [DirtyRegion]
    public let outOfBandRegions: [DirtyRegion]

    public init(
        checkpoint: EventJournalCursor?,
        journaledRegions: [DirtyRegion],
        outOfBandRegions: [DirtyRegion]
    ) {
        self.checkpoint = checkpoint
        self.journaledRegions = journaledRegions
        self.outOfBandRegions = outOfBandRegions
    }
}
