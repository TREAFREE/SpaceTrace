import Foundation
import Testing
@testable import SpaceTraceApplication

struct EventJournalModelTests {
    @Test("Persistent stream identity binds a cursor to both volume and journal UUIDs")
    func derivesPersistentStreamIdentity() throws {
        let volumeUUID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let journalUUID = try #require(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        )
        let identity = PersistentEventStreamIdentity(
            volumeUUID: volumeUUID,
            journalUUID: journalUUID
        )

        #expect(
            identity.streamID.rawValue
                == "fsevents/v1/11111111-2222-3333-4444-555555555555/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        #expect(
            PersistentEventStreamIdentity(
                volumeUUID: volumeUUID,
                journalUUID: UUID()
            ).streamID != identity.streamID
        )
        #expect(
            PersistentEventStreamIdentity(
                volumeUUID: UUID(),
                journalUUID: journalUUID
            ).streamID != identity.streamID
        )
    }

    @Test("Persistent stream identity survives a Codable round trip")
    func persistentStreamIdentityCodableRoundTrip() throws {
        let identity = PersistentEventStreamIdentity(
            volumeUUID: UUID(),
            journalUUID: UUID()
        )

        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(
            PersistentEventStreamIdentity.self,
            from: data
        )

        #expect(decoded == identity)
        #expect(decoded.streamID == identity.streamID)
    }

    @Test("Volume and journal changes break cursor continuity for distinct reasons")
    func classifiesStreamContinuity() {
        let volumeUUID = UUID()
        let journalUUID = UUID()
        let original = PersistentEventStreamIdentity(
            volumeUUID: volumeUUID,
            journalUUID: journalUUID
        )

        #expect(original.continuity(from: original) == .continuous)
        #expect(
            PersistentEventStreamIdentity(
                volumeUUID: UUID(),
                journalUUID: journalUUID
            ).continuity(from: original) == .volumeChanged
        )
        #expect(
            PersistentEventStreamIdentity(
                volumeUUID: volumeUUID,
                journalUUID: UUID()
            ).continuity(from: original) == .journalGenerationChanged
        )
    }

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

    @Test("Cursor-free work cannot be used to advance a checkpoint")
    func rejectsCursorFreeBatch() throws {
        let streamID = try EventStreamID("volume-a:generation-1")
        let region = try DirtyRegion(
            path: DirtyRegionPath("/Users/example"),
            reasons: [.rootChanged, .requiresCalibration],
            maximumCursor: nil
        )

        #expect(throws: EventJournalModelError.eventBatchRequiresCursors) {
            try EventJournalBatch(
                streamID: streamID,
                checkpoint: EventJournalCursor(42),
                dirtyRegions: [region]
            )
        }
    }

    @Test("Dirty row revisions start above zero")
    func rejectsZeroRevision() {
        #expect(throws: EventJournalModelError.invalidDirtyRegionRevision(0)) {
            try DirtyRegionRevision(0)
        }
    }
}
