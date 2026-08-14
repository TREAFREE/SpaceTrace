import Foundation
import SpaceTraceDomain

public struct AuthorizedBaselineID: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) throws(AuthorizedBaselineSnapshotError) {
        guard rawValue.isEmpty == false,
              rawValue.utf8.contains(0) == false,
              rawValue.first?.isWhitespace == false,
              rawValue.last?.isWhitespace == false else {
            throw .invalidBaselineID
        }
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }
}

public struct AuthorizedBaselineBuildMetadata: Sendable, Equatable {
    public let appVersion: String
    public let schemaVersion: Int

    public init(
        appVersion: String,
        schemaVersion: Int
    ) throws(AuthorizedBaselineSnapshotError) {
        guard appVersion.isEmpty == false,
              appVersion.utf8.contains(0) == false,
              appVersion.count <= 128 else {
            throw .invalidAppVersion
        }
        guard schemaVersion > 0 else {
            throw .invalidSchemaVersion
        }
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
    }
}

/// A point-in-time sample for the data volume that contains SpaceTrace's
/// Application Support directory. Missing API values remain `nil`; unknown
/// capacity is never represented as zero.
public struct StartupVolumeCapacitySnapshot: Sendable, Equatable {
    public let observedAt: Date
    public let volumeUUID: UUID?
    public let totalBytes: ByteCount?
    public let availableBytes: ByteCount?
    public let availableForImportantUsageBytes: ByteCount?

    public init(
        observedAt: Date,
        volumeUUID: UUID?,
        totalBytes: ByteCount?,
        availableBytes: ByteCount?,
        availableForImportantUsageBytes: ByteCount?
    ) {
        self.observedAt = observedAt
        self.volumeUUID = volumeUUID
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
    }
}

public protocol StartupVolumeCapacitySnapshotProviding: Sendable {
    func snapshot() async -> StartupVolumeCapacitySnapshot
}

/// One completely published authorized root. The collection shape on the
/// parent snapshot deliberately supports a future multi-root scheduler even
/// though the current authorization UI activates one root at a time.
public struct AuthorizedBaselineRootSnapshot: Sendable, Equatable {
    public let context: AuthorizedBaselineScanContext
    public let logicalBytes: ByteCount
    public let allocatedBytes: ByteCount
    public let descendantCount: Int64
    public let entriesVisited: Int64
    public let directoriesObserved: Int64

    public init(
        context: AuthorizedBaselineScanContext,
        logicalBytes: ByteCount,
        allocatedBytes: ByteCount,
        descendantCount: Int64,
        entriesVisited: Int64,
        directoriesObserved: Int64
    ) throws(AuthorizedBaselineSnapshotError) {
        guard descendantCount >= 0 else { throw .negativeDescendantCount }
        guard entriesVisited >= 0 else { throw .negativeEntriesVisited }
        guard directoriesObserved > 0 else { throw .invalidDirectoryCount }

        self.context = context
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.descendantCount = descendantCount
        self.entriesVisited = entriesVisited
        self.directoriesObserved = directoriesObserved
    }
}

public struct AuthorizedBaselineSnapshot: Sendable, Equatable {
    public let id: AuthorizedBaselineID
    public let startedAt: Date
    public let committedAt: Date
    public let build: AuthorizedBaselineBuildMetadata
    public let startupVolume: StartupVolumeCapacitySnapshot
    public let roots: [AuthorizedBaselineRootSnapshot]

    public init(
        id: AuthorizedBaselineID,
        startedAt: Date,
        committedAt: Date,
        build: AuthorizedBaselineBuildMetadata,
        startupVolume: StartupVolumeCapacitySnapshot,
        roots: [AuthorizedBaselineRootSnapshot]
    ) throws(AuthorizedBaselineSnapshotError) {
        guard committedAt >= startedAt else { throw .commitPredatesStart }
        guard roots.isEmpty == false else { throw .emptyRoots }
        guard Set(roots.map(\.context.scopeID)).count == roots.count else {
            throw .duplicateScope
        }

        self.id = id
        self.startedAt = startedAt
        self.committedAt = committedAt
        self.build = build
        self.startupVolume = startupVolume
        self.roots = roots
    }

    public func root(for scopeID: WatchedScopeID) -> AuthorizedBaselineRootSnapshot? {
        roots.first { $0.context.scopeID == scopeID }
    }
}

public protocol AuthorizedBaselineSnapshotRepository: Sendable {
    func saveAuthorizedBaseline(_ snapshot: AuthorizedBaselineSnapshot) async throws
    func latestAuthorizedBaseline(
        for scopeID: WatchedScopeID
    ) async throws -> AuthorizedBaselineSnapshot?
}

public enum AuthorizedBaselineSnapshotError: Error, Sendable, Equatable {
    case invalidBaselineID
    case invalidAppVersion
    case invalidSchemaVersion
    case negativeDescendantCount
    case negativeEntriesVisited
    case invalidDirectoryCount
    case commitPredatesStart
    case emptyRoots
    case duplicateScope
    case requestedScopeMissing
}
