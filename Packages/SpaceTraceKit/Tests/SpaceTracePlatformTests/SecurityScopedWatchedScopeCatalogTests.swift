import Foundation
import SpaceTraceApplication
import Synchronization
import Testing
@testable import SpaceTracePlatform

struct SecurityScopedWatchedScopeCatalogTests {
    @Test("Restoration activates valid grants and reports stale grants without paths")
    func restoresValidAndReportsStale() async throws {
        let valid = try makeBookmark(scopeID: "scope-valid", root: "/Volumes/Test/Valid")
        let stale = try makeBookmark(scopeID: "scope-stale", root: "/Volumes/Test/Stale")
        let repository = BookmarkRepositoryFake(bookmarks: [stale, valid])
        let leaseProbe = LeaseProbe()
        let codec = BookmarkCodecFake(
            outcomes: [
                valid.scopeID: [.success(try makeScope(from: valid))],
                stale.scopeID: [.failure(.staleBookmark)],
            ],
            leaseProbe: leaseProbe
        )
        let catalog = SecurityScopedWatchedScopeCatalog(
            repository: repository,
            codec: codec
        )

        let report = try await catalog.restore()

        #expect(report.configuredScopeCount == 2)
        #expect(report.scopes.map(\.id) == [valid.scopeID])
        #expect(
            report.failures == [
                WatchedScopeRestorationFailure(
                    scopeID: stale.scopeID,
                    code: .staleBookmark
                ),
            ]
        )
        #expect(try await catalog.watchedScopes().map(\.id) == [valid.scopeID])

        await catalog.releaseAll()
        #expect(leaseProbe.releaseCount == 1)
    }

    @Test("A temporarily unavailable external grant retries after a mount signal")
    func retriesUnavailableBookmark() async throws {
        let bookmark = try makeBookmark(
            scopeID: "scope-external",
            root: "/Volumes/External/Selected"
        )
        let repository = BookmarkRepositoryFake(bookmarks: [bookmark])
        let codec = BookmarkCodecFake(
            outcomes: [
                bookmark.scopeID: [
                    .failure(.resourceUnavailable),
                    .success(try makeScope(from: bookmark)),
                ],
            ]
        )
        let catalog = SecurityScopedWatchedScopeCatalog(
            repository: repository,
            codec: codec
        )

        let initial = try await catalog.restore()
        #expect(initial.scopes.isEmpty)
        #expect(initial.failures.first?.code == .resourceUnavailable)

        let retried = try await catalog.watchedScopes()
        #expect(retried.map(\.id) == [bookmark.scopeID])
        #expect(await catalog.restorationReport().failures.isEmpty)
    }

    @Test("A stale bookmark never auto-refreshes during catalog reads")
    func doesNotRetryStaleBookmark() async throws {
        let bookmark = try makeBookmark(scopeID: "scope-stale", root: "/Volumes/Test/Stale")
        let repository = BookmarkRepositoryFake(bookmarks: [bookmark])
        let codec = BookmarkCodecFake(
            outcomes: [
                bookmark.scopeID: [
                    .failure(.staleBookmark),
                    .success(try makeScope(from: bookmark)),
                ],
            ]
        )
        let catalog = SecurityScopedWatchedScopeCatalog(
            repository: repository,
            codec: codec
        )

        _ = try await catalog.restore()
        #expect(try await catalog.watchedScopes().isEmpty)
        #expect(try await catalog.watchedScopes().isEmpty)
        #expect(codec.restoreCallCount(for: bookmark.scopeID) == 1)
    }

    @Test("Acquisition persists the opaque grant and retains access until release")
    func acquiresAndPersistsSelection() async throws {
        let repository = BookmarkRepositoryFake()
        let leaseProbe = LeaseProbe()
        let codec = BookmarkCodecFake(leaseProbe: leaseProbe)
        let catalog = SecurityScopedWatchedScopeCatalog(
            repository: repository,
            codec: codec
        )
        let scopeID = try WatchedScopeID("scope-acquired")
        let selectedURL = URL(fileURLWithPath: "/Volumes/Test/Selected", isDirectory: true)

        let scope = try await catalog.acquire(selectedURL: selectedURL, scopeID: scopeID)

        #expect(scope.id == scopeID)
        #expect(scope.root.rawValue == "/Volumes/Test/Selected")
        #expect(await repository.bookmarks().map(\.scopeID) == [scopeID])
        #expect(leaseProbe.releaseCount == 0)

        await catalog.releaseAll()
        #expect(leaseProbe.releaseCount == 1)
    }

    @Test("The native codec round-trips an exact directory bookmark without UI")
    func nativeBookmarkRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceTraceBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = BookmarkRepositoryFake()
        let catalog = SecurityScopedWatchedScopeCatalog(
            repository: repository,
            accessMode: .bookmarkIdentityOnly
        )
        let scopeID = try WatchedScopeID("scope-native-round-trip")

        let acquired = try await catalog.acquire(selectedURL: directory, scopeID: scopeID)
        await catalog.releaseAll()
        let restored = try await catalog.restore()

        #expect(acquired.root.rawValue == directory.standardizedFileURL.path)
        #expect(restored.scopes.map(\.id) == [scopeID])
        #expect(restored.scopes.first?.root == acquired.root)
        #expect(restored.scopes.first?.mountPath == acquired.mountPath)
    }
}

private actor BookmarkRepositoryFake: WatchedScopeBookmarkRepository {
    private var storage: [WatchedScopeID: WatchedScopeBookmark]

    init(bookmarks: [WatchedScopeBookmark] = []) {
        storage = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.scopeID, $0) })
    }

    func watchedScopeBookmarks() -> [WatchedScopeBookmark] {
        storage.values.sorted { $0.scopeID.rawValue < $1.scopeID.rawValue }
    }

    func upsertWatchedScopeBookmark(_ bookmark: WatchedScopeBookmark) {
        storage[bookmark.scopeID] = bookmark
    }

    func removeWatchedScopeBookmark(for scopeID: WatchedScopeID) {
        storage.removeValue(forKey: scopeID)
    }

    func bookmarks() -> [WatchedScopeBookmark] {
        watchedScopeBookmarks()
    }
}

private final class LeaseProbe: Sendable {
    private let count = Mutex(0)

    var releaseCount: Int {
        count.withLock { $0 }
    }

    func recordRelease() {
        count.withLock { $0 += 1 }
    }
}

private final class AccessLeaseFake: SecurityScopedResourceAccessLease {
    private struct State {
        var wasReleased = false
    }

    private let state = Mutex(State())
    private let probe: LeaseProbe

    init(probe: LeaseProbe) {
        self.probe = probe
    }

    func release() {
        let shouldRecord = state.withLock { state in
            guard state.wasReleased == false else { return false }
            state.wasReleased = true
            return true
        }
        if shouldRecord {
            probe.recordRelease()
        }
    }
}

private final class BookmarkCodecFake: SecurityScopedBookmarkCodec {
    enum Outcome: Sendable {
        case success(WatchedScope)
        case failure(SecurityScopedWatchedScopeError)
    }

    private struct State {
        var outcomes: [WatchedScopeID: [Outcome]]
        var restoreCalls: [WatchedScopeID: Int] = [:]
    }

    private let state: Mutex<State>
    private let leaseProbe: LeaseProbe
    private let volumeUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    init(
        outcomes: [WatchedScopeID: [Outcome]] = [:],
        leaseProbe: LeaseProbe = LeaseProbe()
    ) {
        state = Mutex(State(outcomes: outcomes))
        self.leaseProbe = leaseProbe
    }

    func acquire(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) throws -> SecurityScopedBookmarkAcquisition {
        let scope = try WatchedScope(
            id: scopeID,
            root: DirtyRegionPath(selectedURL.standardizedFileURL.path),
            mountPath: DirtyRegionPath("/")
        )
        let bookmark = try WatchedScopeBookmark(
            scopeID: scopeID,
            bookmarkData: Data(selectedURL.path.utf8),
            expectedRoot: scope.root,
            expectedVolumeUUID: volumeUUID
        )
        return SecurityScopedBookmarkAcquisition(
            bookmark: bookmark,
            active: ActiveSecurityScopedWatchedScope(
                scope: scope,
                lease: AccessLeaseFake(probe: leaseProbe)
            )
        )
    }

    func restore(
        _ bookmark: WatchedScopeBookmark
    ) throws -> ActiveSecurityScopedWatchedScope {
        let outcome = state.withLock { state in
            state.restoreCalls[bookmark.scopeID, default: 0] += 1
            guard var outcomes = state.outcomes[bookmark.scopeID],
                  outcomes.isEmpty == false else {
                return Outcome.failure(.invalidResource)
            }
            let outcome = outcomes.removeFirst()
            state.outcomes[bookmark.scopeID] = outcomes
            return outcome
        }
        switch outcome {
        case let .success(scope):
            return ActiveSecurityScopedWatchedScope(
                scope: scope,
                lease: AccessLeaseFake(probe: leaseProbe)
            )
        case let .failure(error):
            throw error
        }
    }

    func restoreCallCount(for scopeID: WatchedScopeID) -> Int {
        state.withLock { $0.restoreCalls[scopeID, default: 0] }
    }
}

private func makeBookmark(
    scopeID: String,
    root: String
) throws -> WatchedScopeBookmark {
    try WatchedScopeBookmark(
        scopeID: WatchedScopeID(scopeID),
        bookmarkData: Data(root.utf8),
        expectedRoot: DirtyRegionPath(root),
        expectedVolumeUUID: UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
    )
}

private func makeScope(from bookmark: WatchedScopeBookmark) throws -> WatchedScope {
    let components = bookmark.expectedRoot.rawValue.split(separator: "/")
    let mountPath = components.count >= 2
        ? "/" + components.prefix(2).joined(separator: "/")
        : "/"
    return try WatchedScope(
        id: bookmark.scopeID,
        root: bookmark.expectedRoot,
        mountPath: DirtyRegionPath(mountPath)
    )
}
