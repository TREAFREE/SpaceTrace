import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct StorageHistoryOverviewQueryTests {
    @Test("The lifecycle recorder preserves an unavailable capacity observation")
    func recorderPreservesUnknownCapacity() async throws {
        let snapshot = StartupVolumeCapacitySnapshot(
            observedAt: Date(timeIntervalSince1970: 123),
            volumeUUID: nil,
            totalBytes: nil,
            availableBytes: nil,
            availableForImportantUsageBytes: nil
        )
        let repository = RecordingVolumeRepositoryFake()
        try await StartupVolumeCapacityRecorder(
            provider: FixedVolumeProvider(snapshot: snapshot),
            repository: repository
        ).record()

        let recorded = await repository.recorded
        #expect(recorded.count == 1)
        #expect(recorded.first?.snapshot == snapshot)
        #expect(recorded.first?.source == .lifecycle)
    }

    @Test("Lifecycle recorder persists explicit sleep and wake boundaries")
    func recorderPersistsSleepWakeSources() async throws {
        let snapshot = StartupVolumeCapacitySnapshot(
            observedAt: Date(timeIntervalSince1970: 456),
            volumeUUID: nil,
            totalBytes: nil,
            availableBytes: nil,
            availableForImportantUsageBytes: nil
        )
        let repository = RecordingVolumeRepositoryFake()
        let recorder = StartupVolumeCapacityRecorder(
            provider: FixedVolumeProvider(snapshot: snapshot),
            repository: repository
        )

        try await recorder.record(trigger: .sleep)
        try await recorder.record(trigger: .wake)

        #expect(await repository.recorded.map(\.source) == [
            .sleepBoundary,
            .wakeBoundary,
        ])
    }

    @Test("Startup-volume loss is reconciled with non-overlapping allocated growth")
    func reconcilesDiskLossWithVisibleAllocatedGrowth() async throws {
        let volumeUUID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let end = Date(timeIntervalSince1970: 24 * 3_600)
        let context = try storageContext(
            scope: "scope-startup",
            root: "/Users/example",
            stream: "stream-startup",
            volumeUUID: volumeUUID
        )
        let directoryRepository = StorageDirectoryRepositoryFake(
            histories: [
                context.streamID: try storageHourlySamples(
                    context: context,
                    startHour: 0,
                    endHour: 24,
                    logicalStart: 2_000,
                    allocatedStart: 1_000,
                    allocatedEnd: 1_600
                ),
            ]
        )
        let volumeRepository = StorageVolumeRepositoryFake(
            samples: try storageVolumeSamples(
                volumeUUID: volumeUUID,
                startHour: 0,
                endHour: 24,
                availableStart: 10_000,
                availableEnd: 9_000
            )
        )

        let overview = try await StorageHistoryOverviewQuery(
            directoryRepository: directoryRepository,
            volumeRepository: volumeRepository
        ).loadOverview(
            contexts: [context],
            window: .last24Hours,
            through: end,
            growthLimit: 10
        )

        let reconciliation = try #require(overview.reconciliation)
        #expect(reconciliation.diskSpaceLoss.value == 1_000)
        #expect(reconciliation.observedDirectoryAllocatedGrowth?.value == 600)
        #expect(reconciliation.explainedDiskSpaceLoss?.value == 600)
        #expect(reconciliation.unattributedDiskSpaceLoss?.value == 400)
        #expect(reconciliation.comparableScopeCount == 1)
        #expect(reconciliation.coverage == .complete)
    }

    @Test("A volume-only comparison never turns missing directory evidence into zero")
    func preservesUnknownDirectoryExplanation() async throws {
        let volumeUUID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let end = Date(timeIntervalSince1970: 24 * 3_600)
        let overview = try await StorageHistoryOverviewQuery(
            directoryRepository: StorageDirectoryRepositoryFake(),
            volumeRepository: StorageVolumeRepositoryFake(
                samples: try storageVolumeSamples(
                    volumeUUID: volumeUUID,
                    startHour: 0,
                    endHour: 24,
                    availableStart: 8_000,
                    availableEnd: 7_000
                )
            )
        ).loadOverview(
            contexts: [],
            window: .last24Hours,
            through: end,
            growthLimit: 10
        )

        let reconciliation = try #require(overview.reconciliation)
        #expect(reconciliation.diskSpaceLoss.value == 1_000)
        #expect(reconciliation.observedDirectoryAllocatedGrowth == nil)
        #expect(reconciliation.explainedDiskSpaceLoss == nil)
        #expect(reconciliation.unattributedDiskSpaceLoss == nil)
        #expect(reconciliation.coverage == .partial)
        #expect(overview.directories.series.isEmpty)
    }

    @Test("Nested watched roots are represented once in the reconciliation total")
    func avoidsNestedRootDoubleCounting() async throws {
        let volumeUUID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let end = Date(timeIntervalSince1970: 24 * 3_600)
        let parent = try storageContext(
            scope: "scope-parent",
            root: "/Users/example",
            stream: "stream-parent",
            volumeUUID: volumeUUID
        )
        let child = try storageContext(
            scope: "scope-child",
            root: "/Users/example/Library",
            stream: "stream-child",
            volumeUUID: volumeUUID
        )
        let histories = [
            parent.streamID: try storageHourlySamples(
                context: parent,
                startHour: 0,
                endHour: 24,
                logicalStart: 1_000,
                allocatedStart: 1_000,
                allocatedEnd: 1_400
            ),
            child.streamID: try storageHourlySamples(
                context: child,
                startHour: 0,
                endHour: 24,
                logicalStart: 500,
                allocatedStart: 500,
                allocatedEnd: 800
            ),
        ]

        let overview = try await StorageHistoryOverviewQuery(
            directoryRepository: StorageDirectoryRepositoryFake(histories: histories),
            volumeRepository: StorageVolumeRepositoryFake(
                samples: try storageVolumeSamples(
                    volumeUUID: volumeUUID,
                    startHour: 0,
                    endHour: 24,
                    availableStart: 5_000,
                    availableEnd: 4_000
                )
            )
        ).loadOverview(
            contexts: [child, parent],
            window: .last24Hours,
            through: end,
            growthLimit: 10
        )

        let reconciliation = try #require(overview.reconciliation)
        #expect(reconciliation.observedDirectoryAllocatedGrowth?.value == 400)
        #expect(reconciliation.explainedDiskSpaceLoss?.value == 400)
        #expect(reconciliation.unattributedDiskSpaceLoss?.value == 600)
        #expect(reconciliation.comparableScopeCount == 1)
        #expect(reconciliation.excludedNestedScopeCount == 1)
    }

    @Test("External-volume roots cannot explain startup-volume capacity loss")
    func excludesExternalVolumes() async throws {
        let startupUUID = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let externalUUID = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let end = Date(timeIntervalSince1970: 24 * 3_600)
        let external = try storageContext(
            scope: "scope-external",
            root: "/Volumes/External",
            stream: "stream-external",
            volumeUUID: externalUUID
        )

        let overview = try await StorageHistoryOverviewQuery(
            directoryRepository: StorageDirectoryRepositoryFake(
                histories: [
                    external.streamID: try storageHourlySamples(
                        context: external,
                        startHour: 0,
                        endHour: 24,
                        logicalStart: 1_000,
                        allocatedStart: 1_000,
                        allocatedEnd: 9_000
                    ),
                ]
            ),
            volumeRepository: StorageVolumeRepositoryFake(
                samples: try storageVolumeSamples(
                    volumeUUID: startupUUID,
                    startHour: 0,
                    endHour: 24,
                    availableStart: 10_000,
                    availableEnd: 9_000
                )
            )
        ).loadOverview(
            contexts: [external],
            window: .last24Hours,
            through: end,
            growthLimit: 10
        )

        let reconciliation = try #require(overview.reconciliation)
        #expect(reconciliation.observedDirectoryAllocatedGrowth == nil)
        #expect(reconciliation.unattributedDiskSpaceLoss == nil)
        #expect(reconciliation.excludedExternalScopeCount == 1)
        #expect(reconciliation.coverage == .partial)
    }

    @Test("A startup-volume identity change prevents a cross-volume comparison")
    func identityChangeBreaksComparison() async throws {
        let firstUUID = try #require(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let replacementUUID = try #require(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let end = Date(timeIntervalSince1970: 24 * 3_600)
        let samples = [
            StartupVolumeCapacityHistorySample(
                sequence: 1,
                snapshot: StartupVolumeCapacitySnapshot(
                    observedAt: Date(timeIntervalSince1970: 0),
                    volumeUUID: firstUUID,
                    totalBytes: try ByteCount(20_000),
                    availableBytes: try ByteCount(10_000),
                    availableForImportantUsageBytes: nil
                ),
                source: .lifecycle
            ),
            StartupVolumeCapacityHistorySample(
                sequence: 2,
                snapshot: StartupVolumeCapacitySnapshot(
                    observedAt: Date(timeIntervalSince1970: 12 * 3_600),
                    volumeUUID: replacementUUID,
                    totalBytes: try ByteCount(20_000),
                    availableBytes: try ByteCount(9_500),
                    availableForImportantUsageBytes: nil
                ),
                source: .lifecycle
            ),
            StartupVolumeCapacityHistorySample(
                sequence: 3,
                snapshot: StartupVolumeCapacitySnapshot(
                    observedAt: end,
                    volumeUUID: replacementUUID,
                    totalBytes: try ByteCount(20_000),
                    availableBytes: try ByteCount(9_000),
                    availableForImportantUsageBytes: nil
                ),
                source: .lifecycle
            ),
        ]

        let overview = try await StorageHistoryOverviewQuery(
            directoryRepository: StorageDirectoryRepositoryFake(),
            volumeRepository: StorageVolumeRepositoryFake(samples: samples)
        ).loadOverview(
            contexts: [],
            window: .last24Hours,
            through: end,
            growthLimit: 10
        )

        #expect(overview.reconciliation == nil)
        #expect(overview.volume.coverage == .partial)
        #expect(overview.volume.identityDiscontinuity)
    }

    @Test("A wall-clock rollback preserves sequence evidence but suppresses endpoint attribution")
    func clockRollbackSuppressesReconciliation() async throws {
        let volumeUUID = try #require(
            UUID(uuidString: "99999999-9999-9999-9999-999999999999")
        )
        let end = Date(timeIntervalSince1970: 12 * 3_600)
        let samples = [
            StartupVolumeCapacityHistorySample(
                sequence: 1,
                snapshot: StartupVolumeCapacitySnapshot(
                    observedAt: Date(timeIntervalSince1970: 10 * 3_600),
                    volumeUUID: volumeUUID,
                    totalBytes: try ByteCount(20_000),
                    availableBytes: try ByteCount(10_000),
                    availableForImportantUsageBytes: nil
                ),
                source: .lifecycle
            ),
            StartupVolumeCapacityHistorySample(
                sequence: 2,
                snapshot: StartupVolumeCapacitySnapshot(
                    observedAt: Date(timeIntervalSince1970: 9 * 3_600),
                    volumeUUID: volumeUUID,
                    totalBytes: try ByteCount(20_000),
                    availableBytes: try ByteCount(9_000),
                    availableForImportantUsageBytes: nil
                ),
                source: .lifecycle
            ),
        ]

        let overview = try await StorageHistoryOverviewQuery(
            directoryRepository: StorageDirectoryRepositoryFake(),
            volumeRepository: StorageVolumeRepositoryFake(samples: samples)
        ).loadOverview(
            contexts: [],
            window: .last24Hours,
            through: end,
            growthLimit: 10
        )

        #expect(overview.volume.clockDiscontinuity)
        #expect(overview.volume.coverage == .partial)
        #expect(overview.reconciliation == nil)
    }
}

private struct FixedVolumeProvider: StartupVolumeCapacitySnapshotProviding {
    let snapshotValue: StartupVolumeCapacitySnapshot

    init(snapshot: StartupVolumeCapacitySnapshot) {
        snapshotValue = snapshot
    }

    func snapshot() -> StartupVolumeCapacitySnapshot {
        snapshotValue
    }
}

private actor RecordingVolumeRepositoryFake:
    StartupVolumeCapacityHistoryRepository
{
    struct Recorded: Sendable {
        let snapshot: StartupVolumeCapacitySnapshot
        let source: StartupVolumeCapacitySampleSource
    }

    private(set) var recorded: [Recorded] = []

    func recordStartupVolumeCapacity(
        _ snapshot: StartupVolumeCapacitySnapshot,
        source: StartupVolumeCapacitySampleSource
    ) {
        recorded.append(Recorded(snapshot: snapshot, source: source))
    }

    func startupVolumeCapacityHistory(
        from start: Date,
        through end: Date
    ) -> [StartupVolumeCapacityHistorySample] {
        _ = start
        _ = end
        return []
    }

    func recentStartupVolumeCapacityHistory(
        limit: Int
    ) -> [StartupVolumeCapacityHistorySample] {
        _ = limit
        return []
    }
}

private actor StorageDirectoryRepositoryFake: DirectoryHistoryRepository {
    let histories: [EventStreamID: [DirectoryHistorySample]]

    init(histories: [EventStreamID: [DirectoryHistorySample]] = [:]) {
        self.histories = histories
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
        _ = streamID
        _ = root
        _ = bucket
        _ = start
        _ = end
        _ = limit
        return []
    }
}

private actor StorageVolumeRepositoryFake: StartupVolumeCapacityHistoryRepository {
    let samples: [StartupVolumeCapacityHistorySample]

    init(samples: [StartupVolumeCapacityHistorySample] = []) {
        self.samples = samples
    }

    func recordStartupVolumeCapacity(
        _ snapshot: StartupVolumeCapacitySnapshot,
        source: StartupVolumeCapacitySampleSource
    ) {
        _ = snapshot
        _ = source
    }

    func startupVolumeCapacityHistory(
        from start: Date,
        through end: Date
    ) -> [StartupVolumeCapacityHistorySample] {
        _ = start
        _ = end
        return samples
    }

    func recentStartupVolumeCapacityHistory(
        limit: Int
    ) -> [StartupVolumeCapacityHistorySample] {
        Array(samples.suffix(limit))
    }
}

private func storageContext(
    scope: String,
    root: String,
    stream: String,
    volumeUUID: UUID
) throws -> AuthorizedBaselineScanContext {
    AuthorizedBaselineScanContext(
        scopeID: try WatchedScopeID(scope),
        root: try DirtyRegionPath(root),
        streamID: try EventStreamID(stream),
        volumeUUID: volumeUUID
    )
}

private func storageHourlySamples(
    context: AuthorizedBaselineScanContext,
    startHour: Int,
    endHour: Int,
    logicalStart: Int64,
    allocatedStart: Int64,
    allocatedEnd: Int64
) throws -> [DirectoryHistorySample] {
    let hourCount = max(1, endHour - startHour)
    return try (startHour...endHour).map { hour in
        let offset = hour - startHour
        let allocated = allocatedStart
            + (allocatedEnd - allocatedStart) * Int64(offset) / Int64(hourCount)
        return DirectoryHistorySample(
            streamID: context.streamID,
            path: context.root,
            bucket: .hourly,
            bucketStart: Date(timeIntervalSince1970: TimeInterval(hour * 3_600)),
            logicalBytes: try ByteCount(logicalStart + Int64(offset)),
            allocatedBytes: try ByteCount(allocated),
            descendantCount: 1,
            coverage: .complete
        )
    }
}

private func storageVolumeSamples(
    volumeUUID: UUID,
    startHour: Int,
    endHour: Int,
    availableStart: Int64,
    availableEnd: Int64
) throws -> [StartupVolumeCapacityHistorySample] {
    let hourCount = max(1, endHour - startHour)
    return try (startHour...endHour).enumerated().map { index, hour in
        let available = availableStart
            + (availableEnd - availableStart) * Int64(index) / Int64(hourCount)
        return StartupVolumeCapacityHistorySample(
            sequence: Int64(index + 1),
            snapshot: StartupVolumeCapacitySnapshot(
                observedAt: Date(timeIntervalSince1970: TimeInterval(hour * 3_600)),
                volumeUUID: volumeUUID,
                totalBytes: try ByteCount(20_000),
                availableBytes: try ByteCount(available),
                availableForImportantUsageBytes: nil
            ),
            source: .lifecycle
        )
    }
}
