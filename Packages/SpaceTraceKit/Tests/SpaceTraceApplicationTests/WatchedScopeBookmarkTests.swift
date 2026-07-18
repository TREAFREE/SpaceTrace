import Foundation
import Testing
@testable import SpaceTraceApplication

struct WatchedScopeBookmarkTests {
    @Test("Bookmark records reject empty and oversized opaque data", arguments: [0, 1_048_577])
    func rejectsInvalidBookmarkSize(byteCount: Int) throws {
        let scopeID = try WatchedScopeID("scope-bookmark-size")
        let volumeUUID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )

        do {
            _ = try WatchedScopeBookmark(
                scopeID: scopeID,
                bookmarkData: Data(repeating: 0x01, count: byteCount),
                expectedRoot: DirtyRegionPath("/Volumes/Projects/Selected"),
                expectedVolumeUUID: volumeUUID
            )
            Issue.record("Expected invalid bookmark data to be rejected.")
        } catch let error as WatchedScopeBookmarkError {
            #expect(error == (byteCount == 0 ? .emptyBookmark : .bookmarkTooLarge))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Restoration reports have deterministic scope and failure ordering")
    func restorationReportOrdering() throws {
        let scopeA = try WatchedScope(
            id: WatchedScopeID("scope-a"),
            root: DirtyRegionPath("/Volumes/A/Selected"),
            mountPath: DirtyRegionPath("/Volumes/A")
        )
        let scopeB = try WatchedScope(
            id: WatchedScopeID("scope-b"),
            root: DirtyRegionPath("/Volumes/B/Selected"),
            mountPath: DirtyRegionPath("/Volumes/B")
        )
        let report = WatchedScopeRestorationReport(
            configuredScopeCount: 4,
            scopes: [scopeB, scopeA],
            failures: [
                WatchedScopeRestorationFailure(scopeID: scopeB.id, code: .accessDenied),
                WatchedScopeRestorationFailure(scopeID: scopeA.id, code: .staleBookmark),
            ]
        )

        #expect(report.scopes.map(\.id) == [scopeA.id, scopeB.id])
        #expect(report.failures.map(\.scopeID) == [scopeA.id, scopeB.id])
    }
}
