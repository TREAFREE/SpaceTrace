import Testing
@testable import SpaceTraceApplication

struct EventJournalModelTests {
    @Test(
        "Stream identities reject empty, untrimmed, and null-containing values",
        arguments: ["", " ", "\n\t", " leading", "trailing ", "volume\0generation"]
    )
    func rejectsInvalidStreamIdentity(rawValue: String) {
        #expect(throws: EventJournalModelError.invalidStreamID) {
            try EventStreamID(rawValue)
        }
    }

    @Test("A dirty region requires at least one durable reason")
    func rejectsEmptyDirtyRegionReasons() throws {
        let path = try DirtyRegionPath("/Users/example/Library")

        #expect(throws: EventJournalModelError.emptyDirtyRegionReasons) {
            try DirtyRegion(
                path: path,
                reasons: [],
                maximumCursor: EventJournalCursor(1)
            )
        }
    }

    @Test("A checkpoint cannot advance without durable dirty work")
    func rejectsEmptyBatch() throws {
        let streamID = try EventStreamID("volume-a:generation-1")

        #expect(throws: EventJournalModelError.emptyBatch) {
            try EventJournalBatch(
                streamID: streamID,
                checkpoint: EventJournalCursor(42),
                dirtyRegions: []
            )
        }
    }

    @Test("Dirty work cannot claim an event newer than its checkpoint")
    func rejectsDirtyRegionBeyondCheckpoint() throws {
        let streamID = try EventStreamID("volume-a:generation-1")
        let region = try DirtyRegion(
            path: DirtyRegionPath("/Users/example/Documents"),
            reasons: [.contentModified],
            maximumCursor: EventJournalCursor(43)
        )

        #expect(throws: EventJournalModelError.dirtyRegionCursorExceedsCheckpoint) {
            try EventJournalBatch(
                streamID: streamID,
                checkpoint: EventJournalCursor(42),
                dirtyRegions: [region]
            )
        }
    }
}
