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

    @Test(
        "Every continuity-loss signal becomes durable root calibration work",
        arguments: ContinuityLossCase.all
    )
    func continuityLossSchedulesDurableRecovery(
        testCase: ContinuityLossCase
    ) async throws {
        let fixture = try PipelineTemporaryDatabase()
        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        defer { fixture.remove() }

        let streamID = try EventStreamID("continuity-loss-integration")
        let watchRoot = try DirtyRegionPath("/Users/example")
        let pipeline = FileSystemCalibrationPipeline(
            streamID: streamID,
            watchRoot: watchRoot,
            repository: repository,
            scanner: IntegrationScanner()
        )
        let ordinary = FSEventObservation(
            path: "/Users/example/seed.txt",
            eventID: FSEventID(rawValue: 42),
            reasons: [.itemContentModified, .itemIsFile],
            rawFlags: 0
        )
        try await pipeline.ingest([
            try #require(try FSEventInvalidationMapper().map(ordinary)),
        ])
        #expect(try await pipeline.calibratePending(limit: 1) == 1)
        #expect(try await repository.checkpoint(for: streamID) == EventJournalCursor(42))

        let continuityLoss = FSEventObservation(
            path: nil,
            eventID: FSEventID(rawValue: 99),
            reasons: [testCase.reason],
            rawFlags: 0
        )
        try await pipeline.ingest([
            try #require(try FSEventInvalidationMapper().map(continuityLoss)),
        ])

        let dirty = try #require(
            try await repository.dirtyRegions(for: streamID).first
        )
        #expect(dirty.path == watchRoot)
        #expect(dirty.maximumCursor == nil)
        #expect(dirty.reasons.contains(.droppedEvents))
        #expect(dirty.reasons.contains(.requiresCalibration))
        #expect(
            try await repository.checkpoint(for: streamID)
                == (testCase.invalidatesCheckpoint ? nil : EventJournalCursor(42))
        )
        #expect(try await pipeline.calibratePending(limit: 1) == 1)
        #expect(try await repository.dirtyRegions(for: streamID).isEmpty)
        try await repository.close()
    }
}

struct ContinuityLossCase: Sendable, CustomTestStringConvertible {
    let reason: FSEventReason
    let invalidatesCheckpoint: Bool

    static let all: [Self] = [
        Self(reason: .eventsDroppedByUserSpace, invalidatesCheckpoint: false),
        Self(reason: .eventsDroppedByKernel, invalidatesCheckpoint: false),
        Self(reason: .eventIdentifiersWrapped, invalidatesCheckpoint: true),
        Self(reason: .callbackBridgeOverflow, invalidatesCheckpoint: false),
    ]

    var testDescription: String {
        String(describing: reason)
    }
}

private actor IntegrationScanner: CalibrationScanner {
    private(set) var requests: [CalibrationRequest] = []

    func scan(
        _ request: CalibrationRequest,
        stage: @escaping @Sendable ([DirectoryMetadataAggregate]) async throws -> Void
    ) async throws -> CalibrationReport {
        requests.append(request)
        try await stage([
            try DirectoryMetadataAggregate(
                path: request.workItem.region.path,
                logicalBytes: .zero,
                allocatedBytes: .zero,
                descendantCount: 0,
                coverage: .complete
            ),
        ])
        return try CalibrationReport(
            coverage: .complete,
            entriesVisited: 1,
            directoriesStaged: 1,
            gaps: []
        )
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
