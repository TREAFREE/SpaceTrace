import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTrace

@MainActor
struct DirectoryHistoryViewModelTests {
    @Test("The view model loads a deterministic window and forwards selection changes")
    func loadsAndChangesWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = try historyContext()
        let first = makeOverview(
            window: .last24Hours,
            end: now,
            context: context
        )
        let second = makeOverview(
            window: .last7Days,
            end: now,
            context: context
        )
        let loader = HistoryOverviewLoaderFake(
            responses: [.success(first), .success(second)]
        )
        let model = DirectoryHistoryViewModel(loader: loader, now: { now })

        await model.load(contexts: [context])

        #expect(model.state == .loaded)
        #expect(model.overview == first)
        #expect(await loader.requestedWindows == [.last24Hours])
        #expect(await loader.requestedEnds == [now])

        await model.selectWindow(.last7Days)

        #expect(model.selectedWindow == .last7Days)
        #expect(model.overview == second)
        #expect(await loader.requestedWindows == [.last24Hours, .last7Days])
    }

    @Test("Removing every context still loads volume history without path evidence")
    func loadsVolumeHistoryWithoutBaselineContexts() async throws {
        let context = try historyContext()
        let overview = makeStorageOverview(
            window: .last24Hours,
            end: Date(timeIntervalSince1970: 1_800_000_000),
            context: context
        )
        let volumeOnly = makeStorageOverview(
            window: .last24Hours,
            end: Date(timeIntervalSince1970: 1_800_000_000),
            context: nil
        )
        let model = DirectoryHistoryViewModel(
            loader: HistoryOverviewLoaderFake(
                responses: [.success(overview), .success(volumeOnly)]
            )
        )
        await model.load(contexts: [context])
        #expect(model.overview != nil)

        await model.load(contexts: [])

        #expect(model.state == .loaded)
        #expect(model.overview == volumeOnly)
        #expect(model.overview?.directories.series.isEmpty == true)
    }

    @Test("A query failure exposes a retryable generic state without persistence details")
    func reportsFailure() async throws {
        let loader = HistoryOverviewLoaderFake(responses: [.failure])
        let model = DirectoryHistoryViewModel(loader: loader)

        await model.load(contexts: [try historyContext()])

        #expect(model.state == .failed)
        #expect(model.overview == nil)
    }

    @Test("A current query cancellation never leaves an indefinite loading state")
    func cancellationIsRetryable() async throws {
        let loader = HistoryOverviewLoaderFake(responses: [.cancelled])
        let model = DirectoryHistoryViewModel(loader: loader)

        await model.load(contexts: [try historyContext()])

        #expect(model.state == .failed)
        #expect(model.overview == nil)
    }

    @Test("An unavailable bucket breaks the rendered line instead of interpolating it")
    func chartProjectionBreaksAtEvidenceGaps() throws {
        let context = try historyContext()
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let overview = DirectoryHistoryOverview(
            window: .last24Hours,
            start: firstDate,
            end: firstDate.addingTimeInterval(10_800),
            bucket: .hourly,
            series: [
                DirectoryHistorySeries(
                    scopeID: context.scopeID,
                    root: context.root,
                    points: [
                        historyPoint(
                            at: firstDate,
                            logicalBytes: try ByteCount(1_000),
                            coverage: .complete
                        ),
                        historyPoint(
                            at: firstDate.addingTimeInterval(3_600),
                            logicalBytes: try ByteCount(2_000),
                            coverage: .partial
                        ),
                        historyPoint(
                            at: firstDate.addingTimeInterval(7_200),
                            logicalBytes: nil,
                            coverage: .unavailable
                        ),
                        historyPoint(
                            at: firstDate.addingTimeInterval(10_800),
                            logicalBytes: try ByteCount(3_000),
                            coverage: .complete
                        ),
                    ],
                    coverage: .partial
                ),
            ],
            growthSources: [],
            coverage: .partial
        )

        let points = DirectoryHistoryChartProjection.makePoints(from: overview)

        #expect(points.count == 3)
        #expect(points[0].segmentID == points[1].segmentID)
        #expect(points[1].segmentID != points[2].segmentID)
        #expect(points.map(\.logicalBytes) == [1_000, 2_000, 3_000])
        #expect(points.map(\.coverage) == [.complete, .partial, .complete])
    }

    @Test("A gap or volume identity replacement breaks the capacity line")
    func capacityChartBreaksAtGapsAndIdentityChanges() throws {
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let firstUUID = try #require(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let secondUUID = try #require(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )
        let series = StartupVolumeHistorySeries(
            points: [
                volumePoint(at: firstDate, uuid: firstUUID, bytes: 3_000),
                volumePoint(
                    at: firstDate.addingTimeInterval(3_600),
                    uuid: firstUUID,
                    bytes: 2_900
                ),
                volumePoint(
                    at: firstDate.addingTimeInterval(7_200),
                    uuid: nil,
                    bytes: nil
                ),
                volumePoint(
                    at: firstDate.addingTimeInterval(10_800),
                    uuid: firstUUID,
                    bytes: 2_800
                ),
                volumePoint(
                    at: firstDate.addingTimeInterval(14_400),
                    uuid: secondUUID,
                    bytes: 2_700
                ),
            ],
            coverage: .partial,
            identityDiscontinuity: true
        )

        let points = StartupVolumeChartProjection.makePoints(from: series)

        #expect(points.count == 4)
        #expect(points[0].segmentID == points[1].segmentID)
        #expect(points[1].segmentID != points[2].segmentID)
        #expect(points[2].segmentID != points[3].segmentID)
    }
}

private actor HistoryOverviewLoaderFake: StorageHistoryOverviewLoading {
    enum Response: Sendable {
        case success(StorageHistoryOverview)
        case failure
        case cancelled
    }

    private var responses: [Response]
    private(set) var requestedWindows: [DirectoryHistoryWindow] = []
    private(set) var requestedEnds: [Date] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func loadOverview(
        contexts: [AuthorizedBaselineScanContext],
        window: DirectoryHistoryWindow,
        through end: Date,
        growthLimit: Int
    ) throws -> StorageHistoryOverview {
        _ = contexts
        _ = growthLimit
        requestedWindows.append(window)
        requestedEnds.append(end)
        guard responses.isEmpty == false else {
            throw HistoryViewModelFixtureError.missingResponse
        }
        switch responses.removeFirst() {
        case let .success(overview):
            return overview
        case .failure:
            throw HistoryViewModelFixtureError.queryFailed
        case .cancelled:
            throw CancellationError()
        }
    }
}

private enum HistoryViewModelFixtureError: Error {
    case missingResponse
    case queryFailed
}

private func historyContext() throws -> AuthorizedBaselineScanContext {
    AuthorizedBaselineScanContext(
        scopeID: try WatchedScopeID("history-scope"),
        root: try DirtyRegionPath("/History"),
        streamID: try EventStreamID("history-stream")
    )
}

private func makeStorageOverview(
    window: DirectoryHistoryWindow,
    end: Date,
    context: AuthorizedBaselineScanContext?
) -> StorageHistoryOverview {
    let directories = DirectoryHistoryOverview(
        window: window,
        start: end.addingTimeInterval(-window.duration),
        end: end,
        bucket: window.bucket,
        series: context.map {
            DirectoryHistorySeries(
                scopeID: $0.scopeID,
                root: $0.root,
                points: [],
                coverage: .unavailable
            )
        }.map { [$0] } ?? [],
        growthSources: [],
        coverage: .unavailable
    )
    return StorageHistoryOverview(
        window: window,
        start: directories.start,
        end: end,
        bucket: window.bucket,
        volume: StartupVolumeHistorySeries(
            points: [],
            coverage: .unavailable,
            identityDiscontinuity: false
        ),
        directories: directories,
        reconciliation: nil
    )
}

private func makeOverview(
    window: DirectoryHistoryWindow,
    end: Date,
    context: AuthorizedBaselineScanContext
) -> StorageHistoryOverview {
    makeStorageOverview(window: window, end: end, context: context)
}

private func historyPoint(
    at date: Date,
    logicalBytes: ByteCount?,
    coverage: DirectoryHistoryEvidenceCoverage
) -> DirectoryHistoryPoint {
    DirectoryHistoryPoint(
        observedAt: date,
        logicalBytes: logicalBytes,
        allocatedBytes: logicalBytes,
        coverage: coverage
    )
}

private func volumePoint(
    at date: Date,
    uuid: UUID?,
    bytes: Int64?
) -> StartupVolumeHistoryPoint {
    StartupVolumeHistoryPoint(
        bucketStart: date,
        sampledAt: date,
        sequence: bytes,
        volumeUUID: uuid,
        totalBytes: try? ByteCount(10_000),
        availableBytes: bytes.flatMap { try? ByteCount($0) },
        availableForImportantUsageBytes: nil,
        coverage: bytes == nil ? .unavailable : .complete
    )
}
