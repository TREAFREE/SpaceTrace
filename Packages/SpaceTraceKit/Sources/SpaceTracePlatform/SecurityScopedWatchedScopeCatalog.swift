import Foundation
import SpaceTraceApplication
import Synchronization

/// Selects whether the resolved bookmark must activate a sandbox extension.
/// The checked-in sandboxed app uses `.required`. A future direct-distribution
/// build may use `.bookmarkIdentityOnly` while preserving the same exact-root
/// identity validation.
public enum SecurityScopedResourceAccessMode: Sendable, Equatable {
    case required
    case bookmarkIdentityOnly
}

/// Native, non-UI boundary for acquiring and restoring user-selected folders.
/// Callers pass the URL returned by the system selection surface; this type
/// never opens a panel itself.
public actor SecurityScopedWatchedScopeCatalog: RestorableWatchedScopeCatalog {
    private let repository: any WatchedScopeBookmarkRepository
    private let codec: any SecurityScopedBookmarkCodec
    private var records: [WatchedScopeID: WatchedScopeBookmark] = [:]
    private var activeScopes: [WatchedScopeID: ActiveSecurityScopedWatchedScope] = [:]
    private var failures: [WatchedScopeID: WatchedScopeRestorationFailureCode] = [:]
    private var operationEpoch: UInt64 = 0
    private var isUpdating = false

    public init(
        repository: any WatchedScopeBookmarkRepository,
        accessMode: SecurityScopedResourceAccessMode = .required
    ) {
        self.repository = repository
        self.codec = NativeSecurityScopedBookmarkCodec(accessMode: accessMode)
    }

    init(
        repository: any WatchedScopeBookmarkRepository,
        codec: any SecurityScopedBookmarkCodec
    ) {
        self.repository = repository
        self.codec = codec
    }

    /// Persists a read-only bookmark for an already user-selected directory.
    /// The resulting root and mount path are both derived from the selected URL.
    @discardableResult
    public func acquire(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) async throws -> WatchedScope {
        guard isUpdating == false else {
            throw SecurityScopedWatchedScopeError.concurrentOperation
        }
        isUpdating = true
        defer { isUpdating = false }
        operationEpoch &+= 1
        let epoch = operationEpoch
        let acquisition = try codec.acquire(selectedURL: selectedURL, scopeID: scopeID)

        do {
            try await repository.upsertWatchedScopeBookmark(acquisition.bookmark)
        } catch {
            acquisition.active.lease.release()
            throw error
        }

        guard operationEpoch == epoch, Task.isCancelled == false else {
            acquisition.active.lease.release()
            throw SecurityScopedWatchedScopeError.operationCancelled
        }

        activeScopes.removeValue(forKey: scopeID)?.lease.release()
        records[scopeID] = acquisition.bookmark
        activeScopes[scopeID] = acquisition.active
        failures.removeValue(forKey: scopeID)
        return acquisition.active.scope
    }

    public func restore() async throws -> WatchedScopeRestorationReport {
        guard isUpdating == false else {
            throw SecurityScopedWatchedScopeError.concurrentOperation
        }
        isUpdating = true
        defer { isUpdating = false }
        operationEpoch &+= 1
        let epoch = operationEpoch
        let loaded = try await repository.watchedScopeBookmarks()
        try Task.checkCancellation()
        guard operationEpoch == epoch else {
            throw SecurityScopedWatchedScopeError.operationCancelled
        }

        var nextRecords: [WatchedScopeID: WatchedScopeBookmark] = [:]
        var nextActive: [WatchedScopeID: ActiveSecurityScopedWatchedScope] = [:]
        var nextFailures: [WatchedScopeID: WatchedScopeRestorationFailureCode] = [:]

        for record in loaded.sorted(by: { $0.scopeID.rawValue < $1.scopeID.rawValue }) {
            nextRecords[record.scopeID] = record
            do {
                nextActive[record.scopeID] = try codec.restore(record)
            } catch let error as SecurityScopedWatchedScopeError {
                nextFailures[record.scopeID] = error.restorationFailureCode
            } catch {
                nextFailures[record.scopeID] = .invalidResource
            }
        }

        guard operationEpoch == epoch, Task.isCancelled == false else {
            nextActive.values.forEach { $0.lease.release() }
            throw SecurityScopedWatchedScopeError.operationCancelled
        }

        activeScopes.values.forEach { $0.lease.release() }
        records = nextRecords
        activeScopes = nextActive
        failures = nextFailures
        return restorationReport()
    }

    public func watchedScopes() async throws -> [WatchedScope] {
        guard isUpdating == false else {
            throw SecurityScopedWatchedScopeError.concurrentOperation
        }
        retryTemporarilyUnavailableScopes()
        return activeScopes.values
            .map(\.scope)
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func restorationReport() -> WatchedScopeRestorationReport {
        WatchedScopeRestorationReport(
            configuredScopeCount: records.count,
            scopes: activeScopes.values.map(\.scope),
            failures: failures.map {
                WatchedScopeRestorationFailure(scopeID: $0.key, code: $0.value)
            }
        )
    }

    public func releaseAll() async {
        operationEpoch &+= 1
        activeScopes.values.forEach { $0.lease.release() }
        activeScopes.removeAll()
    }

    private func retryTemporarilyUnavailableScopes() {
        let retryIDs = failures
            .filter { $0.value == .resourceUnavailable }
            .map(\.key)
            .sorted { $0.rawValue < $1.rawValue }

        for scopeID in retryIDs {
            guard let record = records[scopeID] else { continue }
            do {
                activeScopes[scopeID] = try codec.restore(record)
                failures.removeValue(forKey: scopeID)
            } catch let error as SecurityScopedWatchedScopeError {
                failures[scopeID] = error.restorationFailureCode
            } catch {
                failures[scopeID] = .invalidResource
            }
        }
    }
}

protocol SecurityScopedResourceAccessLease: Sendable {
    func release()
}

private final class NativeSecurityScopedResourceAccessLease: SecurityScopedResourceAccessLease {
    private let accessedURL: Mutex<URL?>

    init(accessedURL: URL) {
        self.accessedURL = Mutex(accessedURL)
    }

    deinit {
        release()
    }

    func release() {
        accessedURL.withLock { url in
            url?.stopAccessingSecurityScopedResource()
            url = nil
        }
    }
}

private struct BookmarkIdentityOnlyLease: SecurityScopedResourceAccessLease {
    func release() {}
}

struct ActiveSecurityScopedWatchedScope: Sendable {
    let scope: WatchedScope
    let lease: any SecurityScopedResourceAccessLease
}

struct SecurityScopedBookmarkAcquisition: Sendable {
    let bookmark: WatchedScopeBookmark
    let active: ActiveSecurityScopedWatchedScope
}

protocol SecurityScopedBookmarkCodec: Sendable {
    func acquire(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) throws -> SecurityScopedBookmarkAcquisition

    func restore(
        _ bookmark: WatchedScopeBookmark
    ) throws -> ActiveSecurityScopedWatchedScope
}

private struct NativeSecurityScopedBookmarkCodec: SecurityScopedBookmarkCodec {
    let accessMode: SecurityScopedResourceAccessMode

    func acquire(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) throws -> SecurityScopedBookmarkAcquisition {
        let bookmarkData: Data
        do {
            bookmarkData = try selectedURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SecurityScopedWatchedScopeError.bookmarkCreationFailed
        }

        let active = try resolve(bookmarkData: bookmarkData, scopeID: scopeID)
        do {
            let bookmark = try WatchedScopeBookmark(
                scopeID: scopeID,
                bookmarkData: bookmarkData,
                expectedRoot: active.scope.root,
                expectedVolumeUUID: try volumeUUID(for: selectedURL)
            )
            let resolvedVolumeUUID = try volumeUUID(for: active.scope.root)
            guard bookmark.expectedVolumeUUID == resolvedVolumeUUID else {
                active.lease.release()
                throw SecurityScopedWatchedScopeError.volumeIdentityChanged
            }
            return SecurityScopedBookmarkAcquisition(bookmark: bookmark, active: active)
        } catch {
            active.lease.release()
            throw error
        }
    }

    func restore(
        _ bookmark: WatchedScopeBookmark
    ) throws -> ActiveSecurityScopedWatchedScope {
        let active = try resolve(
            bookmarkData: bookmark.bookmarkData,
            scopeID: bookmark.scopeID
        )
        guard active.scope.root == bookmark.expectedRoot else {
            active.lease.release()
            throw SecurityScopedWatchedScopeError.rootIdentityChanged
        }
        guard try volumeUUID(for: active.scope.root) == bookmark.expectedVolumeUUID else {
            active.lease.release()
            throw SecurityScopedWatchedScopeError.volumeIdentityChanged
        }
        return active
    }

    private func resolve(
        bookmarkData: Data,
        scopeID: WatchedScopeID
    ) throws -> ActiveSecurityScopedWatchedScope {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SecurityScopedWatchedScopeError.resourceUnavailable
        }
        guard isStale == false else {
            throw SecurityScopedWatchedScopeError.staleBookmark
        }

        let lease: any SecurityScopedResourceAccessLease
        switch accessMode {
        case .required:
            guard url.startAccessingSecurityScopedResource() else {
                throw SecurityScopedWatchedScopeError.accessDenied
            }
            lease = NativeSecurityScopedResourceAccessLease(accessedURL: url)
        case .bookmarkIdentityOnly:
            lease = BookmarkIdentityOnlyLease()
        }

        do {
            return ActiveSecurityScopedWatchedScope(
                scope: try watchedScope(for: url, scopeID: scopeID),
                lease: lease
            )
        } catch {
            lease.release()
            throw error
        }
    }

    private func watchedScope(
        for url: URL,
        scopeID: WatchedScopeID
    ) throws -> WatchedScope {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .volumeURLKey,
                .volumeUUIDStringKey,
            ])
        } catch {
            throw SecurityScopedWatchedScopeError.invalidResource
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SecurityScopedWatchedScopeError.invalidResource
        }
        guard let volumeURL = values.volume else {
            throw SecurityScopedWatchedScopeError.invalidResource
        }

        do {
            return try WatchedScope(
                id: scopeID,
                root: normalizedPath(for: url),
                mountPath: normalizedPath(for: volumeURL)
            )
        } catch {
            throw SecurityScopedWatchedScopeError.invalidResource
        }
    }

    private func volumeUUID(for url: URL) throws -> UUID {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
        } catch {
            throw SecurityScopedWatchedScopeError.invalidResource
        }
        guard let rawValue = values.volumeUUIDString,
              let uuid = UUID(uuidString: rawValue) else {
            throw SecurityScopedWatchedScopeError.invalidResource
        }
        return uuid
    }

    private func volumeUUID(for path: DirtyRegionPath) throws -> UUID {
        try volumeUUID(for: URL(fileURLWithPath: path.rawValue, isDirectory: true))
    }

    private func normalizedPath(for url: URL) throws -> DirtyRegionPath {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL.path
        return try DirtyRegionPath(normalized)
    }
}

public enum SecurityScopedWatchedScopeError: Error, Sendable, Equatable {
    case bookmarkCreationFailed
    case staleBookmark
    case resourceUnavailable
    case accessDenied
    case invalidResource
    case rootIdentityChanged
    case volumeIdentityChanged
    case operationCancelled
    case concurrentOperation

    var restorationFailureCode: WatchedScopeRestorationFailureCode {
        switch self {
        case .staleBookmark:
            .staleBookmark
        case .resourceUnavailable, .bookmarkCreationFailed, .operationCancelled,
             .concurrentOperation:
            .resourceUnavailable
        case .accessDenied:
            .accessDenied
        case .invalidResource:
            .invalidResource
        case .rootIdentityChanged:
            .rootIdentityChanged
        case .volumeIdentityChanged:
            .volumeIdentityChanged
        }
    }
}
