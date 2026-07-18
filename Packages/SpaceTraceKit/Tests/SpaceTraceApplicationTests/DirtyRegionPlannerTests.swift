import Testing
@testable import SpaceTraceApplication

struct DirtyRegionPlannerTests {
    private let planner = DirtyRegionPlanner()

    @Test("File events collapse to their parent and union reasons")
    func coalescesFileEvents() throws {
        let plan = try planner.plan(
            watchRoot: DirtyRegionPath("/Users/example"),
            invalidations: [
                invalidation("/Users/example/Documents/a.txt", 11, [.created], .file),
                invalidation("/Users/example/Documents/b.txt", 12, [.contentModified], .file),
            ],
            after: EventJournalCursor(10)
        )

        let region = try #require(plan.journaledRegions.first)
        #expect(plan.checkpoint == EventJournalCursor(12))
        #expect(plan.journaledRegions.count == 1)
        #expect(region.path.rawValue == "/Users/example/Documents")
        #expect(region.reasons == [.created, .contentModified])
        #expect(region.maximumCursor == EventJournalCursor(12))
    }

    @Test("Ordinary overlap replay at or before the checkpoint is ignored")
    func ignoresReplayOverlap() throws {
        let plan = try planner.plan(
            watchRoot: DirtyRegionPath("/Users/example"),
            invalidations: [
                invalidation("/Users/example/a.txt", 10, [.contentModified], .file),
            ],
            after: EventJournalCursor(10)
        )
        #expect(plan.journaledRegions.isEmpty)
        #expect(plan.outOfBandRegions.isEmpty)
        #expect(plan.checkpoint == nil)
    }

    @Test("A replayed continuity gap still schedules root calibration without moving the cursor")
    func preservesReplayedGap() throws {
        let plan = try planner.plan(
            watchRoot: DirtyRegionPath("/Users/example"),
            invalidations: [
                invalidation(
                    "/Users/example/Documents",
                    9,
                    [.droppedEvents, .requiresCalibration],
                    .directory
                ),
            ],
            after: EventJournalCursor(10)
        )
        let region = try #require(plan.outOfBandRegions.first)
        #expect(plan.checkpoint == nil)
        #expect(region.path.rawValue == "/Users/example")
        #expect(region.maximumCursor == nil)
    }

    @Test("MustScanSubdirectories retains a known safe directory boundary")
    func retainsNarrowRecursiveRegion() throws {
        let plan = try planner.plan(
            watchRoot: DirtyRegionPath("/Users/example"),
            invalidations: [
                invalidation(
                    "/Users/example/Documents/Project",
                    22,
                    [.mustScanSubdirectories, .requiresCalibration],
                    .directory
                ),
            ],
            after: nil
        )
        let region = try #require(plan.journaledRegions.first)
        #expect(region.path.rawValue == "/Users/example/Documents/Project")
    }

    @Test("Unknown and outside paths fall back to the watched root")
    func safelyFallsBackToRoot() throws {
        let plan = try planner.plan(
            watchRoot: DirtyRegionPath("/Users/example"),
            invalidations: [
                invalidation("/tmp/other", 21, [.created], .unknown),
            ],
            after: nil
        )
        let region = try #require(plan.journaledRegions.first)
        #expect(region.path.rawValue == "/Users/example")
        #expect(region.reasons.contains(.requiresCalibration))
    }

    private func invalidation(
        _ path: String?,
        _ cursor: UInt64?,
        _ reasons: DirtyRegionReason,
        _ kind: FileSystemItemKind
    ) throws -> FileSystemInvalidation {
        try FileSystemInvalidation(
            path: path,
            cursor: cursor.map(EventJournalCursor.init),
            reasons: reasons,
            itemKind: kind
        )
    }
}
