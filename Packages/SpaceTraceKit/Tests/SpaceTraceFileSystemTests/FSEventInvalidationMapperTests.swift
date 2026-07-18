import Testing
import SpaceTraceApplication
@testable import SpaceTraceFileSystem

struct FSEventInvalidationMapperTests {
    private let mapper = FSEventInvalidationMapper()

    @Test("A file modification retains its cursor and item classification")
    func mapsFileModification() throws {
        let mapped = try mapper.map(
            FSEventObservation(
                path: "/Users/example/file.txt",
                eventID: FSEventID(rawValue: 42),
                reasons: [.itemContentModified, .itemIsFile],
                rawFlags: 0
            )
        )
        let result = try #require(mapped)
        #expect(result.cursor == EventJournalCursor(42))
        #expect(result.reasons == [.contentModified])
        #expect(result.itemKind == .file)
    }

    @Test("RootChanged zero is a sentinel and schedules cursor-free calibration")
    func suppressesRootChangedSentinel() throws {
        let mapped = try mapper.map(
            FSEventObservation(
                path: "/Users/example",
                eventID: FSEventID(rawValue: 0),
                reasons: [.watchedRootChanged],
                rawFlags: 0
            )
        )
        let result = try #require(mapped)
        #expect(result.cursor == nil)
        #expect(result.reasons == [.rootChanged, .requiresCalibration])
    }

    @Test("History completion alone does not manufacture dirty work")
    func ignoresHistoryDone() throws {
        let result = try mapper.map(
            FSEventObservation(
                path: nil,
                eventID: FSEventID(rawValue: 100),
                reasons: [.historicalReplayCompleted],
                rawFlags: 0
            )
        )
        #expect(result == nil)
    }
}
