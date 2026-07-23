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

    @Test("Removing every context clears path-bearing history from the presentation model")
    func clearsWhenNoBaselineContextRemains() async throws {
        let context = try historyContext()
        let overview = makeOverview(
            window: .last24Hours,
            end: Date(timeIntervalSince1970: 1_800_000_000),
            context: context
        )
        let model = DirectoryHistoryViewModel(
            loader: HistoryOverviewLoaderFake(responses: [.success(overview)])
        )
        await model.load(contexts: [context])
        #expect(model.overview != nil)

        await model.load(contexts: [])

        #expect(model.state == .waitingForBaseline)
        #expect(model.overview == nil)
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
}

private actor HistoryOverviewLoaderFake: DirectoryHistoryOverviewLoading {
    enum Response: Sendable {
        case success(DirectoryHistoryOverview)
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
    ) throws -> DirectoryHistoryOverview {
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

private func makeOverview(
    window: DirectoryHistoryWindow,
    end: Date,
    context: AuthorizedBaselineScanContext
) -> DirectoryHistoryOverview {
    DirectoryHistoryOverview(
        window: window,
        start: end.addingTimeInterval(-window.duration),
        end: end,
        bucket: window.bucket,
        series: [
            DirectoryHistorySeries(
                scopeID: context.scopeID,
                root: context.root,
                points: [],
                coverage: .unavailable
            ),
        ],
        growthSources: [],
        coverage: .unavailable
    )
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
