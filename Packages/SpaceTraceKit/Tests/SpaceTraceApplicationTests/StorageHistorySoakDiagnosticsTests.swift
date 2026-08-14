import Foundation
import SpaceTraceApplication
import Testing

struct StorageHistorySoakDiagnosticsTests {
    @Test("A complete bounded run satisfies its qualification policy")
    func qualifiesHealthyRun() {
        let records = healthyRecords()

        let report = StorageHistorySoakQualificationAnalyzer().analyze(
            records,
            policy: StorageHistorySoakQualificationPolicy(
                maximumAwakeHeartbeatGap: 90 * 60
            )
        )

        #expect(report.passed)
        #expect(report.issues.isEmpty)
        #expect(report.metrics.observedDurationMilliseconds >= 86_400_000)
        #expect(report.metrics.maximumDatabaseBytes == 52_000_000)
        #expect(report.metrics.maximumResidentMemoryBytes == 82_000_000)
        #expect(report.metrics.maximumWakeRecoveryMilliseconds == 2_000)
        #expect(report.metrics.p95CPURatio < 0.02)
    }

    @Test("Sequence rollback, resource budgets, and missing retention fail closed")
    func rejectsUnreliableRun() {
        var records = healthyRecords().map { item in
            StorageHistorySoakDiagnosticRecord(
                sessionID: item.sessionID,
                recordedAtMilliseconds: item.recordedAtMilliseconds,
                continuousTimeMilliseconds:
                    item.continuousTimeMilliseconds,
                reason: item.reason,
                background: StorageHistorySoakBackgroundSnapshot(
                    phase: item.background.phase,
                    processedEventCount:
                        item.background.processedEventCount,
                    lastSampleTrigger:
                        item.background.lastSampleTrigger,
                    sampleFailureCount:
                        item.background.sampleFailureCount,
                    consecutiveSampleFailureCount:
                        item.background.consecutiveSampleFailureCount,
                    retentionFailureCount:
                        item.background.retentionFailureCount,
                    hasSuccessfulRetention: false,
                    wakeRecoveryMilliseconds:
                        item.background.wakeRecoveryMilliseconds
                ),
                resource: item.resource,
                capacity: item.capacity
            )
        }
        records[records.count - 1] = record(
            atHour: 24,
            sequence: 7,
            residentMemoryBytes: 200_000_000,
            databaseBytes: 300_000_000,
            retained: false,
            qualification: .collecting,
            cpuMilliseconds: 900_000
        )

        let report = StorageHistorySoakQualificationAnalyzer().analyze(
            records,
            policy: StorageHistorySoakQualificationPolicy(
                maximumAwakeHeartbeatGap: 90 * 60
            )
        )

        #expect(report.passed == false)
        #expect(report.issues.contains(.capacitySequenceRegression))
        #expect(report.issues.contains(.residentMemoryBudgetExceeded))
        #expect(report.issues.contains(.databaseBudgetExceeded))
        #expect(report.issues.contains(.retentionNotObserved))
        #expect(report.issues.contains(.finalCapacityNotQualified))
        #expect(report.issues.contains(.averageCPUBudgetExceeded))
    }

    @Test("A sleep-bracketed heartbeat gap is allowed but an awake gap is not")
    func distinguishesSleepFromAwakeGap() {
        let start = record(atHour: 0, sequence: 1)
        let sleeping = record(
            atHour: 1,
            sequence: 2,
            reason: .stateChanged,
            phase: .sleeping
        )
        let wake = record(
            atHour: 10,
            sequence: 3,
            reason: .stateChanged,
            trigger: .wake,
            wakeRecoveryMilliseconds: 1_000
        )
        let awakeGap = record(atHour: 11, sequence: 4)
        let awakeAfterGap = record(atHour: 12, sequence: 5)
        let policy = StorageHistorySoakQualificationPolicy.smoke(
            minimumDuration: 1
        )

        let sleepReport = StorageHistorySoakQualificationAnalyzer().analyze(
            [start, sleeping, wake],
            policy: policy
        )
        let awakeReport = StorageHistorySoakQualificationAnalyzer().analyze(
            [awakeGap, awakeAfterGap],
            policy: policy
        )

        #expect(sleepReport.issues.contains(.awakeHeartbeatGap) == false)
        #expect(awakeReport.issues.contains(.awakeHeartbeatGap))
    }

    @Test("Encoded records cannot contain paths, volume identities, or byte values")
    func encodedSchemaIsPathFree() throws {
        let encoded = try JSONEncoder().encode(
            record(atHour: 0, sequence: 1)
        )
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(text.contains("/Users/") == false)
        #expect(text.contains("volumeUUID") == false)
        #expect(text.contains("availableBytes") == false)
        #expect(text.contains("bookmark") == false)
    }

    @Test("Millisecond lifecycle bursts do not corrupt interval CPU percentiles")
    func ignoresUnmeasurableCPUBursts() {
        let start = record(atHour: 0, sequence: 1, cpuMilliseconds: 0)
        let burst = StorageHistorySoakDiagnosticRecord(
            sessionID: start.sessionID,
            recordedAtMilliseconds: start.recordedAtMilliseconds + 1,
            continuousTimeMilliseconds: 1,
            reason: .stateChanged,
            background: start.background,
            resource: StorageHistorySoakResourceSnapshot(
                cumulativeCPUMilliseconds: 2,
                residentMemoryBytes: 80_000_000,
                databaseBytes: 50_000_000
            ),
            capacity: start.capacity
        )
        let heartbeat = StorageHistorySoakDiagnosticRecord(
            sessionID: start.sessionID,
            recordedAtMilliseconds: start.recordedAtMilliseconds + 60_000,
            continuousTimeMilliseconds: 60_000,
            reason: .heartbeat,
            background: start.background,
            resource: StorageHistorySoakResourceSnapshot(
                cumulativeCPUMilliseconds: 30,
                residentMemoryBytes: 80_000_000,
                databaseBytes: 50_000_000
            ),
            capacity: start.capacity
        )

        let report = StorageHistorySoakQualificationAnalyzer().analyze(
            [start, burst, heartbeat],
            policy: .smoke(minimumDuration: 1)
        )

        #expect(report.metrics.p95CPURatio < 0.001)
    }

    @Test("Wake recovery is emitted once and is not inherited by later events")
    func recordsWakeRecoveryOnce() async throws {
        let wakeAt = Date(timeIntervalSince1970: 2_000_000_000)
        let observer = SoakStateObserverFake()
        let writer = SoakLogWriterFake()
        let recorder = StorageHistorySoakDiagnosticRecorder(
            stateObserver: observer,
            statusLoader: SoakStatusLoaderFake(),
            writer: writer,
            resourceProvider: SoakResourceProviderFake(),
            now: { wakeAt.addingTimeInterval(2) }
        )
        let runTask = Task {
            await recorder.run(heartbeatInterval: .seconds(3_600))
        }
        try await waitForRecordCount(1, writer: writer)

        await observer.yield(
            backgroundState(
                phase: .awake,
                processedEventCount: 1,
                lastSampleTrigger: .wake,
                sampleAt: wakeAt
            )
        )
        try await waitForRecordCount(2, writer: writer)
        await observer.yield(
            backgroundState(
                phase: .sleeping,
                processedEventCount: 2,
                lastSampleTrigger: .wake,
                sampleAt: wakeAt,
                hasSuccessfulRetention: true
            )
        )
        try await waitForRecordCount(3, writer: writer)
        await observer.finish()
        await runTask.value

        let records = await writer.records
        let recoveries = records
            .filter { $0.reason == .stateChanged }
            .map(\.background.wakeRecoveryMilliseconds)
        #expect(recoveries == [2_000, nil])
    }
}

private func healthyRecords() -> [StorageHistorySoakDiagnosticRecord] {
    var records: [StorageHistorySoakDiagnosticRecord] = []
    for hour in 0...24 {
        let item = record(
            atHour: hour,
            sequence: Int64(hour + 1),
            reason: hour == 0 ? .started : .heartbeat,
            residentMemoryBytes: 70_000_000 + Int64(hour * 500_000),
            databaseBytes: 40_000_000 + Int64(hour * 500_000),
            retained: hour >= 1,
            qualification: hour == 24 ? .qualified : .collecting,
            cpuMilliseconds: Int64(hour * 10_000),
            wakeRecoveryMilliseconds: hour == 12 ? 2_000 : nil
        )
        records.append(item)
    }
    return records
}

private func record(
    atHour hour: Int,
    sequence: Int64,
    reason: StorageHistorySoakRecordReason = .heartbeat,
    phase: StorageHistorySoakBackgroundPhase = .awake,
    trigger: StorageHistorySoakSampleTrigger = .periodic,
    residentMemoryBytes: Int64 = 80_000_000,
    databaseBytes: Int64 = 50_000_000,
    retained: Bool = true,
    qualification: StorageHistorySoakCapacityQualification = .qualified,
    cpuMilliseconds: Int64 = 10_000,
    wakeRecoveryMilliseconds: Int64? = nil
) -> StorageHistorySoakDiagnosticRecord {
    let milliseconds = Int64(hour) * 3_600_000
    return StorageHistorySoakDiagnosticRecord(
        sessionID: diagnosticSessionID,
        recordedAtMilliseconds: 2_000_000_000_000 + milliseconds,
        continuousTimeMilliseconds: milliseconds,
        reason: reason,
        background: StorageHistorySoakBackgroundSnapshot(
            phase: phase,
            processedEventCount: hour,
            lastSampleTrigger: trigger,
            sampleFailureCount: 0,
            consecutiveSampleFailureCount: 0,
            retentionFailureCount: 0,
            hasSuccessfulRetention: retained,
            wakeRecoveryMilliseconds: wakeRecoveryMilliseconds
        ),
        resource: StorageHistorySoakResourceSnapshot(
            cumulativeCPUMilliseconds: cpuMilliseconds,
            residentMemoryBytes: residentMemoryBytes,
            databaseBytes: databaseBytes
        ),
        capacity: StorageHistorySoakCapacitySnapshot(
            sequence: sequence,
            qualification: qualification
        )
    )
}

private let diagnosticSessionID = UUID(
    uuid: (
        0x73, 0x6f, 0x61, 0x6b,
        0x00, 0x00,
        0x40, 0x00,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    )
)

private actor SoakStateObserverFake:
    StorageHistoryBackgroundStateObserving
{
    private var continuation:
        AsyncStream<StorageHistoryBackgroundState>.Continuation?

    func updates() -> AsyncStream<StorageHistoryBackgroundState> {
        let pair = AsyncStream<StorageHistoryBackgroundState>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        return pair.stream
    }

    func yield(_ state: StorageHistoryBackgroundState) {
        continuation?.yield(state)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private actor SoakLogWriterFake: StorageHistorySoakLogWriting {
    private(set) var records: [StorageHistorySoakDiagnosticRecord] = []

    func append(_ record: StorageHistorySoakDiagnosticRecord) {
        records.append(record)
    }
}

private struct SoakStatusLoaderFake:
    StartupVolume24HourStatusLoading
{
    func load(through end: Date) -> StartupVolume24HourStatus {
        _ = end
        return .unavailable
    }
}

private struct SoakResourceProviderFake:
    StorageHistorySoakResourceSnapshotProviding
{
    func snapshot() -> (
        continuousTimeMilliseconds: Int64,
        resource: StorageHistorySoakResourceSnapshot
    ) {
        (
            1_000,
            StorageHistorySoakResourceSnapshot(
                cumulativeCPUMilliseconds: 1,
                residentMemoryBytes: 1,
                databaseBytes: 1
            )
        )
    }
}

private func backgroundState(
    phase: StorageHistoryBackgroundPhase,
    processedEventCount: Int,
    lastSampleTrigger: StorageHistorySampleTrigger,
    sampleAt: Date,
    hasSuccessfulRetention: Bool = false
) -> StorageHistoryBackgroundState {
    StorageHistoryBackgroundState(
        phase: phase,
        processedEventCount: processedEventCount,
        lastSampleTrigger: lastSampleTrigger,
        lastSampleAttemptAt: sampleAt,
        lastSuccessfulSampleAt: sampleAt,
        sampleFailureCount: 0,
        consecutiveSampleFailureCount: 0,
        lastRetentionAttemptAt:
            hasSuccessfulRetention ? sampleAt : nil,
        lastSuccessfulRetentionAt:
            hasSuccessfulRetention ? sampleAt : nil,
        retentionFailureCount: 0
    )
}

private func waitForRecordCount(
    _ expected: Int,
    writer: SoakLogWriterFake
) async throws {
    for _ in 0..<100 {
        if await writer.records.count >= expected {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(expected) soak records.")
    throw SoakDiagnosticsFixtureError.timeout
}

private enum SoakDiagnosticsFixtureError: Error {
    case timeout
}
