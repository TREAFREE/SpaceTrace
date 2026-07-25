import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct StartupVolume24HourStatusQueryTests {
    @Test("Invalid qualification policy fails before accessing persistence")
    func rejectsInvalidPolicyBeforeQuery() async {
        let repository = RecentCapacityRepositoryFake(samples: [])
        let query = StartupVolume24HourStatusQuery(
            repository: repository,
            policy: StartupVolume24HourQualificationPolicy(
                recentSampleLimit: 1
            )
        )

        await #expect(
            throws: DirectoryHistoryQueryError.inconsistentRepositoryResult
        ) {
            try await query.load(through: hour(24))
        }
        #expect(await repository.requestedLimits.isEmpty)
    }

    @Test("Twenty-four gap-free hours produce a qualified signed available-space change")
    func qualifiesCompleteWindow() async throws {
        let now = hour(24)
        let repository = RecentCapacityRepositoryFake(
            samples: try hourlyCapacitySamples(
                hours: Array(0...24),
                availableAtHour: { 10_000 - Int64($0 * 100) }
            )
        )

        let status = try await StartupVolume24HourStatusQuery(
            repository: repository
        ).load(through: now)

        #expect(status.qualification == .qualified)
        #expect(status.currentSequence == 25)
        #expect(status.currentAvailableBytes?.value == 7_600)
        #expect(status.change == .volumeAvailable(bytes: -2_400))
        #expect(status.baselineObservedAt == hour(0))
        #expect(status.currentObservedAt == now)
    }

    @Test("Twelve hours of valid evidence remains collecting rather than becoming zero")
    func preservesCollectingState() async throws {
        let status = try await StartupVolume24HourStatusQuery(
            repository: RecentCapacityRepositoryFake(
                samples: try hourlyCapacitySamples(
                    hours: Array(12...24),
                    availableAtHour: { 10_000 - Int64($0) }
                )
            )
        ).load(through: hour(24))

        #expect(status.qualification == .collecting)
        #expect(status.currentSequence == 13)
        #expect(status.currentAvailableBytes?.value == 9_976)
        #expect(status.change == nil)
    }

    @Test("A two-hour sampling gap suppresses the 24-hour comparison")
    func rejectsSamplingGap() async throws {
        let hours = Array(0...24).filter { $0 != 12 }
        let status = try await StartupVolume24HourStatusQuery(
            repository: RecentCapacityRepositoryFake(
                samples: try hourlyCapacitySamples(
                    hours: hours,
                    availableAtHour: { 20_000 - Int64($0) }
                )
            )
        ).load(through: hour(24))

        #expect(status.qualification == .samplingGap)
        #expect(status.change == nil)
    }

    @Test("A volume replacement starts a new qualification epoch")
    func rejectsVolumeReplacement() async throws {
        let first = try #require(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let second = try #require(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )
        var samples = try hourlyCapacitySamples(
            hours: Array(0...24),
            volumeUUID: first,
            availableAtHour: { 30_000 - Int64($0) }
        )
        for index in 13..<samples.count {
            samples[index] = try capacitySample(
                sequence: Int64(index + 1),
                at: hour(index),
                volumeUUID: second,
                available: 30_000 - Int64(index)
            )
        }

        let status = try await StartupVolume24HourStatusQuery(
            repository: RecentCapacityRepositoryFake(samples: samples)
        ).load(through: hour(24))

        #expect(status.qualification == .volumeIdentityChanged)
        #expect(status.change == nil)
    }

    @Test("A replacement older than the comparison endpoint does not poison a valid epoch")
    func acceptsReplacementBeforeWindow() async throws {
        let oldVolume = try #require(
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )
        var samples = try hourlyCapacitySamples(
            hours: Array(-2...24),
            availableAtHour: { 30_000 - Int64($0) }
        )
        samples[0] = try capacitySample(
            sequence: 1,
            at: hour(-2),
            volumeUUID: oldVolume,
            available: 30_002
        )

        let status = try await StartupVolume24HourStatusQuery(
            repository: RecentCapacityRepositoryFake(samples: samples)
        ).load(through: hour(24))

        #expect(status.qualification == .qualified)
        #expect(status.baselineObservedAt == hour(0))
        #expect(status.change == .volumeAvailable(bytes: -24))
    }

    @Test("A wall-clock rollback is never hidden by monotonic commit order")
    func rejectsClockRollback() async throws {
        var samples = try hourlyCapacitySamples(
            hours: Array(0...24),
            availableAtHour: { 40_000 - Int64($0) }
        )
        samples[13] = try capacitySample(
            sequence: 14,
            at: hour(11).addingTimeInterval(1_800),
            volumeUUID: stableVolumeUUID,
            available: 39_987
        )

        let status = try await StartupVolume24HourStatusQuery(
            repository: RecentCapacityRepositoryFake(samples: samples)
        ).load(through: hour(24))

        #expect(status.qualification == .clockDiscontinuity)
        #expect(status.change == nil)
    }

    @Test("A stale last observation can be shown but cannot claim a current comparison")
    func rejectsStaleCurrentSample() async throws {
        let status = try await StartupVolume24HourStatusQuery(
            repository: RecentCapacityRepositoryFake(
                samples: try hourlyCapacitySamples(
                    hours: Array(0...24),
                    availableAtHour: { 50_000 - Int64($0) }
                )
            )
        ).load(through: hour(27))

        #expect(status.qualification == .stale)
        #expect(status.currentAvailableBytes?.value == 49_976)
        #expect(status.change == nil)
    }

    @Test("The latest unavailable observation stays unavailable instead of reusing stale bytes")
    func latestUnavailableRemainsUnknown() async throws {
        var samples = try hourlyCapacitySamples(
            hours: Array(0...23),
            availableAtHour: { 60_000 - Int64($0) }
        )
        samples.append(
            StartupVolumeCapacityHistorySample(
                sequence: 25,
                snapshot: StartupVolumeCapacitySnapshot(
                    observedAt: hour(24),
                    volumeUUID: nil,
                    totalBytes: nil,
                    availableBytes: nil,
                    availableForImportantUsageBytes: nil
                ),
                source: .lifecycle
            )
        )

        let status = try await StartupVolume24HourStatusQuery(
            repository: RecentCapacityRepositoryFake(samples: samples)
        ).load(through: hour(24))

        #expect(status.qualification == .unavailable)
        #expect(status.currentSequence == 25)
        #expect(status.currentAvailableBytes == nil)
        #expect(status.change == nil)
    }
}

private actor RecentCapacityRepositoryFake:
    StartupVolumeCapacityHistoryRepository
{
    let samples: [StartupVolumeCapacityHistorySample]
    private(set) var requestedLimits: [Int] = []

    init(samples: [StartupVolumeCapacityHistorySample]) {
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
        samples.filter {
            $0.snapshot.observedAt >= start && $0.snapshot.observedAt <= end
        }
    }

    func recentStartupVolumeCapacityHistory(
        limit: Int
    ) -> [StartupVolumeCapacityHistorySample] {
        requestedLimits.append(limit)
        return Array(samples.suffix(limit))
    }
}

private let stableVolumeUUID = UUID(
    uuid: (
        0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa,
        0xaa, 0xaa,
        0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa
    )
)

private func hourlyCapacitySamples(
    hours: [Int],
    volumeUUID: UUID = stableVolumeUUID,
    availableAtHour: (Int) -> Int64
) throws -> [StartupVolumeCapacityHistorySample] {
    try hours.enumerated().map { index, hourValue in
        try capacitySample(
            sequence: Int64(index + 1),
            at: hour(hourValue),
            volumeUUID: volumeUUID,
            available: availableAtHour(hourValue)
        )
    }
}

private func capacitySample(
    sequence: Int64,
    at date: Date,
    volumeUUID: UUID,
    available: Int64
) throws -> StartupVolumeCapacityHistorySample {
    StartupVolumeCapacityHistorySample(
        sequence: sequence,
        snapshot: StartupVolumeCapacitySnapshot(
            observedAt: date,
            volumeUUID: volumeUUID,
            totalBytes: try ByteCount(100_000),
            availableBytes: try ByteCount(available),
            availableForImportantUsageBytes: nil
        ),
        source: .lifecycle
    )
}

private func hour(_ value: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(value) * 3_600)
}
