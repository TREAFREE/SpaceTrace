import Foundation

/// Opaque, user-granted identity for one watched directory. Platform code is
/// solely responsible for creating and resolving `bookmarkData`; application
/// and persistence layers must never inspect or log it.
public struct WatchedScopeBookmark: Sendable, Equatable {
    public static let maximumBookmarkByteCount = 1_048_576

    public let scopeID: WatchedScopeID
    public let bookmarkData: Data
    public let expectedRoot: DirtyRegionPath
    public let expectedVolumeUUID: UUID

    public init(
        scopeID: WatchedScopeID,
        bookmarkData: Data,
        expectedRoot: DirtyRegionPath,
        expectedVolumeUUID: UUID
    ) throws(WatchedScopeBookmarkError) {
        guard bookmarkData.isEmpty == false else {
            throw .emptyBookmark
        }
        guard bookmarkData.count <= Self.maximumBookmarkByteCount else {
            throw .bookmarkTooLarge
        }
        self.scopeID = scopeID
        self.bookmarkData = bookmarkData
        self.expectedRoot = expectedRoot
        self.expectedVolumeUUID = expectedVolumeUUID
    }
}

public protocol WatchedScopeBookmarkRepository: Sendable {
    func watchedScopeBookmarks() async throws -> [WatchedScopeBookmark]
    func upsertWatchedScopeBookmark(_ bookmark: WatchedScopeBookmark) async throws
    func removeWatchedScopeBookmark(for scopeID: WatchedScopeID) async throws
}

public enum WatchedScopeRestorationFailureCode: String, Sendable, Equatable, Codable {
    case staleBookmark
    case resourceUnavailable
    case accessDenied
    case invalidResource
    case rootIdentityChanged
    case volumeIdentityChanged
}

public struct WatchedScopeRestorationFailure: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let code: WatchedScopeRestorationFailureCode

    public init(scopeID: WatchedScopeID, code: WatchedScopeRestorationFailureCode) {
        self.scopeID = scopeID
        self.code = code
    }
}

/// Privacy-safe outcome of one catalog restoration pass. The report carries
/// stable IDs and failure codes only; it never includes paths or bookmark data.
public struct WatchedScopeRestorationReport: Sendable, Equatable {
    public let configuredScopeCount: Int
    public let scopes: [WatchedScope]
    public let failures: [WatchedScopeRestorationFailure]

    public init(
        configuredScopeCount: Int,
        scopes: [WatchedScope],
        failures: [WatchedScopeRestorationFailure]
    ) {
        self.configuredScopeCount = configuredScopeCount
        self.scopes = scopes.sorted { $0.id.rawValue < $1.id.rawValue }
        self.failures = failures.sorted { $0.scopeID.rawValue < $1.scopeID.rawValue }
    }
}

/// Catalog lifecycle owned by the application process. `restore()` activates
/// exact grants; `releaseAll()` balances all active security-scope leases.
public protocol RestorableWatchedScopeCatalog: WatchedScopeCatalog {
    func restore() async throws -> WatchedScopeRestorationReport
    func releaseAll() async
}

public enum WatchedScopeBookmarkError: Error, Sendable, Equatable {
    case emptyBookmark
    case bookmarkTooLarge
}
