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
