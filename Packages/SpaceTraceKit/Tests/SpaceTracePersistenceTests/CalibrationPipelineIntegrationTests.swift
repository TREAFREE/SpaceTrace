import Foundation
import Testing
import SpaceTraceApplication
import SpaceTraceFileSystem
@testable import SpaceTracePersistence

struct CalibrationPipelineIntegrationTests {
    @Test("FSEvents mapping flows through durable dirty work into calibration")
    func endToEndPipeline() async throws {
        let fixture = try PipelineTemporaryDatabase()
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        defer { fixture.remove() }

        let streamID = try EventStreamID("volume-integration:generation-1")
        let scanner = IntegrationScanner()
        let pipeline = try FileSystemCalibrationPipeline(
            streamID: streamID,
            watchRoot: DirtyRegionPath("/Users/example"),
            repository: repository,
            scanner: scanner
        )
        let observation = FSEventObservation(
            path: "/Users/example/Documents/report.pdf",
            eventID: FSEventID(rawValue: 88),
            reasons: [.itemContentModified, .itemIsFile],
            rawFlags: 0
        )
        let mapped = try FSEventInvalidationMapper().map(observation)
        let invalidation = try #require(mapped)

        try await pipeline.ingest([invalidation])
        #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(88))
        let durable = try #require(
            try await repository.dirtyRegions(for: streamID).first
        )
        #expect(durable.path.rawValue == "/Users/example/Documents")

        #expect(try await pipeline.calibratePending(limit: 1) == 1)
        #expect(try await repository.dirtyRegions(for: streamID).isEmpty)
        let request = try #require(await scanner.requests.first)
        #expect(request.workItem.region.path.rawValue == "/Users/example/Documents")
        try await repository.close()
    }
}

private actor IntegrationScanner: CalibrationScanner {
    private(set) var requests: [CalibrationRequest] = []

    func scan(_ request: CalibrationRequest) -> CalibrationCoverage {
        requests.append(request)
        return .complete
    }
}

private struct PipelineTemporaryDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceTracePipelineTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("SpaceTrace.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
