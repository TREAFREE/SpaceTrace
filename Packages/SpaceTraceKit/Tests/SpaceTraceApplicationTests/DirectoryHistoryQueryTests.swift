import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct DirectoryHistoryQueryTests {
    @Test("History requests reject missing, duplicate, and unbounded presentation inputs")
    func validatesRequests() async throws {
        let query = DirectoryHistoryOverviewQuery(
            repository: HistoryRepositoryFake()
        )
        let end = Date(timeIntervalSince1970: 86_400)

        await expectHistoryError(.emptyContexts) {
            _ = try await query.loadOverview(
                contexts: [],
                window: .last24Hours,
                through: end,
                growthLimit: 10
            )
        }

        let context = try makeContext(
            scope: "scope-duplicate",
            root: "/Duplicate",
            stream: "stream-duplicate"
        )
        await expectHistoryError(.duplicateScope) {
            _ = try await query.loadOverview(
                contexts: [context, context],
                window: .last24Hours,
                through: end,
                growthLimit: 10
            )
        }

        await expectHistoryError(.invalidGrowthLimit) {
            _ = try await query.loadOverview(
                contexts: [context],
                window: .last24Hours,
                through: end,
                growthLimit: 0
            )
        }
    }

    @Test("A complete UTC window remains ordered and keeps each scope as its own series")
    func buildsCompleteIndependentSeries() async throws {
        let end = Date(timeIntervalSince1970: 24 * 3_600)
        let firstContext = try makeContext(
            scope: "scope-a",
            root: "/Volumes/A",
            stream: "stream-a"
        )
        let secondContext = try makeContext(
            scope: "scope-b",
            root: "/Volumes/B",
            stream: "stream-b"
        )
        let repository = HistoryRepositoryFake(
            histories: [
                firstContext.streamID: try hourlySamples(
                    context: firstContext,
                    startHour: 0,
                    endHour: 24,
                    baseBytes: 1_000
                ),
                secondContext.streamID: try hourlySamples(
                    context: secondContext,
                    startHour: 0,
                    endHour: 24,
                    baseBytes: 2_000
                ),
            ],
            growth: [
                firstContext.streamID: [
                    DirectoryGrowthSample(
                        streamID: firstContext.streamID,
                        path: try DirtyRegionPath("/Volumes/A/Cache"),
                        logicalByteDelta: 500,
                        firstObservedAt: end.addingTimeInterval(-3_600),
                        lastObservedAt: end,
                        coverage: .complete
                    ),
                ],
                secondContext.streamID: [
                    DirectoryGrowthSample(
                        streamID: secondContext.streamID,
                        path: try DirtyRegionPath("/Volumes/B/Models"),
                        logicalByteDelta: 900,
                        firstObservedAt: end.addingTimeInterval(-3_600),
                        lastObservedAt: end,
                        coverage: .complete
                    ),
                ],
            ]
        )

        let overview = try await DirectoryHistoryOverviewQuery(repository: repository)
            .loadOverview(
                contexts: [secondContext, firstContext],
                window: .last24Hours,
                through: end,
                growthLimit: 10
            )

        #expect(overview.coverage == .complete)
        #expect(overview.series.map(\.scopeID) == [
            firstContext.scopeID,
            secondContext.scopeID,
        ])
        #expect(overview.series.allSatisfy { $0.points.count == 25 })
        #expect(overview.series[0].points.first?.observedAt == Date(timeIntervalSince1970: 0))
        #expect(overview.series[0].points.last?.observedAt == end)
        #expect(overview.growthSources.map(\.logicalByteDelta) == [900, 500])
        #expect(
            await repository.requestedRoots == [
                firstContext.root,
                secondContext.root,
            ]
        )
    }

    @Test("Missing buckets stay unavailable and make the window partial instead of zero")
    func preservesGapsAndPartialCoverage() async throws {
        let end = Date(timeIntervalSince1970: 24 * 3_600)
        let context = try makeContext(
            scope: "scope-partial",
            root: "/Partial",
            stream: "stream-partial"
        )
        let sample = DirectoryHistorySample(
            streamID: context.streamID,
            path: context.root,
            bucket: .hourly,
            bucketStart: end,
            logicalBytes: try ByteCount(4_096),
            allocatedBytes: try ByteCount(8_192),
            descendantCount: 4,
            coverage: .partial
        )
        let repository = HistoryRepositoryFake(
            histories: [context.streamID: [sample]]
        )

        let overview = try await DirectoryHistoryOverviewQuery(repository: repository)
            .loadOverview(
                contexts: [context],
                window: .last24Hours,
                through: end,
                growthLimit: 10
            )

        let series = try #require(overview.series.first)
        #expect(overview.coverage == .partial)
        #expect(series.coverage == .partial)
        #expect(series.points.filter { $0.coverage == .unavailable }.count == 24)
        let expectedBytes = try ByteCount(4_096)
        #expect(series.points.last?.logicalBytes == expectedBytes)
        #expect(overview.hasMeasurements)
    }

    @Test("No stored samples is an unavailable history window")
    func reportsUnavailableHistory() async throws {
        let context = try makeContext(
            scope: "scope-empty",
            root: "/Empty",
            stream: "stream-empty"
        )
        let repository = HistoryRepositoryFake()

        let overview = try await DirectoryHistoryOverviewQuery(repository: repository)
            .loadOverview(
                contexts: [context],
                window: .last7Days,
                through: Date(timeIntervalSince1970: 8 * 86_400),
                growthLimit: 10
            )

        #expect(overview.coverage == .unavailable)
        #expect(overview.hasMeasurements == false)
        #expect(overview.growthSources.isEmpty)
        #expect(overview.series.first?.points.allSatisfy {
            $0.logicalBytes == nil && $0.coverage == .unavailable
        } == true)
    }

    @Test("A repository result outside the requested authorized root fails closed")
    func rejectsCrossScopeGrowth() async throws {
        let context = try makeContext(
            scope: "scope-private",
            root: "/Authorized",
            stream: "stream-shared"
        )
        let end = Date(timeIntervalSince1970: 8 * 86_400)
        let repository = HistoryRepositoryFake(
            growth: [
                context.streamID: [
                    DirectoryGrowthSample(
                        streamID: context.streamID,
                        path: try DirtyRegionPath("/Revoked/Private"),
                        logicalByteDelta: 10,
                        firstObservedAt: end.addingTimeInterval(-86_400),
                        lastObservedAt: end,
                        coverage: .complete
                    ),
                ],
            ]
        )

        do {
            _ = try await DirectoryHistoryOverviewQuery(repository: repository)
                .loadOverview(
                    contexts: [context],
                    window: .last7Days,
                    through: end,
                    growthLimit: 10
                )
            Issue.record("Expected a cross-scope result to fail closed.")
        } catch let error as DirectoryHistoryQueryError {
            #expect(error == .inconsistentRepositoryResult)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private func expectHistoryError(
    _ expected: DirectoryHistoryQueryError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected history query error \(expected).")
    } catch let error as DirectoryHistoryQueryError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private actor HistoryRepositoryFake: DirectoryHistoryRepository {
    let histories: [EventStreamID: [DirectoryHistorySample]]
    let growth: [EventStreamID: [DirectoryGrowthSample]]
    private(set) var requestedRoots: [DirtyRegionPath] = []

    init(
        histories: [EventStreamID: [DirectoryHistorySample]] = [:],
        growth: [EventStreamID: [DirectoryGrowthSample]] = [:]
    ) {
        self.histories = histories
        self.growth = growth
    }

    func directoryHistory(
        for streamID: EventStreamID,
        path: DirtyRegionPath,
        bucket: DirectoryHistoryBucket,
        from start: Date,
        through end: Date
    ) -> [DirectoryHistorySample] {
        _ = path
        _ = bucket
        _ = start
        _ = end
        return histories[streamID] ?? []
    }

    func topDirectoryGrowth(
        for streamID: EventStreamID,
        under root: DirtyRegionPath,
        bucket: DirectoryHistoryBucket,
        from start: Date,
        through end: Date,
        limit: Int
    ) -> [DirectoryGrowthSample] {
        _ = bucket
        _ = start
        _ = end
        requestedRoots.append(root)
        return Array((growth[streamID] ?? []).prefix(limit))
    }
}

private func makeContext(
    scope: String,
    root: String,
    stream: String
) throws -> AuthorizedBaselineScanContext {
    AuthorizedBaselineScanContext(
        scopeID: try WatchedScopeID(scope),
        root: try DirtyRegionPath(root),
        streamID: try EventStreamID(stream)
    )
}

private func hourlySamples(
    context: AuthorizedBaselineScanContext,
    startHour: Int,
    endHour: Int,
    baseBytes: Int64
) throws -> [DirectoryHistorySample] {
    try (startHour...endHour).map { hour in
        DirectoryHistorySample(
            streamID: context.streamID,
            path: context.root,
            bucket: .hourly,
            bucketStart: Date(timeIntervalSince1970: TimeInterval(hour * 3_600)),
            logicalBytes: try ByteCount(baseBytes + Int64(hour)),
            allocatedBytes: try ByteCount(baseBytes + Int64(hour)),
            descendantCount: 1,
            coverage: .complete
        )
    }
}
