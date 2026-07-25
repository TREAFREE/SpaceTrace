import Foundation

public enum StorageHistorySoakRecordReason:
    String,
    Codable,
    Sendable,
    Equatable
{
    case started
    case stateChanged = "state_changed"
    case heartbeat
    case stopped
}

public enum StorageHistorySoakBackgroundPhase:
    String,
    Codable,
    Sendable,
    Equatable
{
    case stopped
    case awake
    case sleeping
}

public enum StorageHistorySoakSampleTrigger:
    String,
    Codable,
    Sendable,
    Equatable
{
    case startup
    case periodic
    case wake
    case significantTimeChange = "significant_time_change"
}

public enum StorageHistorySoakCapacityQualification:
    String,
    Codable,
    Sendable,
    Equatable
{
    case qualified
    case collecting
    case stale
    case samplingGap = "sampling_gap"
    case clockDiscontinuity = "clock_discontinuity"
    case volumeIdentityChanged = "volume_identity_changed"
    case unavailable
    case historyLimitReached = "history_limit_reached"
    case queryFailed = "query_failed"
}

public struct StorageHistorySoakBackgroundSnapshot:
    Codable,
    Sendable,
    Equatable
{
    public let phase: StorageHistorySoakBackgroundPhase
    public let processedEventCount: Int
    public let lastSampleTrigger: StorageHistorySoakSampleTrigger?
    public let sampleFailureCount: Int
    public let consecutiveSampleFailureCount: Int
    public let retentionFailureCount: Int
    public let hasSuccessfulRetention: Bool
    public let wakeRecoveryMilliseconds: Int64?

    public init(
        phase: StorageHistorySoakBackgroundPhase,
        processedEventCount: Int,
        lastSampleTrigger: StorageHistorySoakSampleTrigger?,
        sampleFailureCount: Int,
        consecutiveSampleFailureCount: Int,
        retentionFailureCount: Int,
        hasSuccessfulRetention: Bool,
        wakeRecoveryMilliseconds: Int64?
    ) {
        self.phase = phase
        self.processedEventCount = processedEventCount
        self.lastSampleTrigger = lastSampleTrigger
        self.sampleFailureCount = sampleFailureCount
        self.consecutiveSampleFailureCount = consecutiveSampleFailureCount
        self.retentionFailureCount = retentionFailureCount
        self.hasSuccessfulRetention = hasSuccessfulRetention
        self.wakeRecoveryMilliseconds = wakeRecoveryMilliseconds
    }

    public static let stopped = StorageHistorySoakBackgroundSnapshot(
        phase: .stopped,
        processedEventCount: 0,
        lastSampleTrigger: nil,
        sampleFailureCount: 0,
        consecutiveSampleFailureCount: 0,
        retentionFailureCount: 0,
        hasSuccessfulRetention: false,
        wakeRecoveryMilliseconds: nil
    )
}

public struct StorageHistorySoakResourceSnapshot:
    Codable,
    Sendable,
    Equatable
{
    public let cumulativeCPUMilliseconds: Int64
    public let residentMemoryBytes: Int64
    public let databaseBytes: Int64

    public init(
        cumulativeCPUMilliseconds: Int64,
        residentMemoryBytes: Int64,
        databaseBytes: Int64
    ) {
        self.cumulativeCPUMilliseconds = max(0, cumulativeCPUMilliseconds)
        self.residentMemoryBytes = max(0, residentMemoryBytes)
        self.databaseBytes = max(0, databaseBytes)
    }
}

public struct StorageHistorySoakCapacitySnapshot:
    Codable,
    Sendable,
    Equatable
{
    public let sequence: Int64?
    public let qualification: StorageHistorySoakCapacityQualification

    public init(
        sequence: Int64?,
        qualification: StorageHistorySoakCapacityQualification
    ) {
        self.sequence = sequence
        self.qualification = qualification
    }
}

/// Privacy-bounded schema: it intentionally has no path, name, bookmark,
/// volume identity, capacity value, command line, or environment fields.
public struct StorageHistorySoakDiagnosticRecord:
    Codable,
    Sendable,
    Equatable
{
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: UUID
    public let recordedAtMilliseconds: Int64
    public let continuousTimeMilliseconds: Int64
    public let reason: StorageHistorySoakRecordReason
    public let background: StorageHistorySoakBackgroundSnapshot
    public let resource: StorageHistorySoakResourceSnapshot
    public let capacity: StorageHistorySoakCapacitySnapshot

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sessionID: UUID,
        recordedAtMilliseconds: Int64,
        continuousTimeMilliseconds: Int64,
        reason: StorageHistorySoakRecordReason,
        background: StorageHistorySoakBackgroundSnapshot,
        resource: StorageHistorySoakResourceSnapshot,
        capacity: StorageHistorySoakCapacitySnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.recordedAtMilliseconds = recordedAtMilliseconds
        self.continuousTimeMilliseconds = continuousTimeMilliseconds
        self.reason = reason
        self.background = background
        self.resource = resource
        self.capacity = capacity
    }
}

public protocol StorageHistorySoakLogWriting: Sendable {
    func append(_ record: StorageHistorySoakDiagnosticRecord) async throws
}

public protocol StorageHistorySoakResourceSnapshotProviding: Sendable {
    func snapshot() throws -> (
        continuousTimeMilliseconds: Int64,
        resource: StorageHistorySoakResourceSnapshot
    )
}

public enum StorageHistorySoakQualificationIssue:
    String,
    Codable,
    Sendable,
    Equatable,
    CaseIterable
{
    case insufficientDuration = "insufficient_duration"
    case unsupportedSchema = "unsupported_schema"
    case continuousTimeRegression = "continuous_time_regression"
    case awakeHeartbeatGap = "awake_heartbeat_gap"
    case capacitySequenceRegression = "capacity_sequence_regression"
    case finalCapacityNotQualified = "final_capacity_not_qualified"
    case samplingFailuresRemain = "sampling_failures_remain"
    case retentionNotObserved = "retention_not_observed"
    case wakeRecoveryBudgetExceeded = "wake_recovery_budget_exceeded"
    case residentMemoryBudgetExceeded = "resident_memory_budget_exceeded"
    case databaseBudgetExceeded = "database_budget_exceeded"
    case averageCPUBudgetExceeded = "average_cpu_budget_exceeded"
    case p95CPUBudgetExceeded = "p95_cpu_budget_exceeded"
}

public struct StorageHistorySoakQualificationMetrics:
    Codable,
    Sendable,
    Equatable
{
    public let recordCount: Int
    public let sessionCount: Int
    public let observedDurationMilliseconds: Int64
    public let maximumAwakeGapMilliseconds: Int64
    public let maximumWakeRecoveryMilliseconds: Int64?
    public let maximumResidentMemoryBytes: Int64
    public let maximumDatabaseBytes: Int64
    public let averageCPURatio: Double
    public let p95CPURatio: Double
}

public struct StorageHistorySoakQualificationReport:
    Codable,
    Sendable,
    Equatable
{
    public let passed: Bool
    public let issues: [StorageHistorySoakQualificationIssue]
    public let metrics: StorageHistorySoakQualificationMetrics
}

public struct StorageHistorySoakQualificationPolicy: Sendable, Equatable {
    public let minimumDuration: TimeInterval
    public let maximumAwakeHeartbeatGap: TimeInterval
    public let maximumWakeRecovery: TimeInterval
    public let maximumResidentMemoryBytes: Int64
    public let maximumDatabaseBytes: Int64
    public let maximumAverageCPURatio: Double?
    public let maximumP95CPURatio: Double?
    public let requiresQualifiedCapacity: Bool
    public let requiresSuccessfulRetention: Bool

    public init(
        minimumDuration: TimeInterval = 24 * 3_600,
        maximumAwakeHeartbeatGap: TimeInterval = 5 * 60,
        maximumWakeRecovery: TimeInterval = 10,
        maximumResidentMemoryBytes: Int64 = 150 * 1_000_000,
        maximumDatabaseBytes: Int64 = 250 * 1_000_000,
        maximumAverageCPURatio: Double? = 0.005,
        maximumP95CPURatio: Double? = 0.02,
        requiresQualifiedCapacity: Bool = true,
        requiresSuccessfulRetention: Bool = true
    ) {
        self.minimumDuration = minimumDuration
        self.maximumAwakeHeartbeatGap = maximumAwakeHeartbeatGap
        self.maximumWakeRecovery = maximumWakeRecovery
        self.maximumResidentMemoryBytes = maximumResidentMemoryBytes
        self.maximumDatabaseBytes = maximumDatabaseBytes
        self.maximumAverageCPURatio = maximumAverageCPURatio
        self.maximumP95CPURatio = maximumP95CPURatio
        self.requiresQualifiedCapacity = requiresQualifiedCapacity
        self.requiresSuccessfulRetention = requiresSuccessfulRetention
    }

    public static func smoke(
        minimumDuration: TimeInterval
    ) -> StorageHistorySoakQualificationPolicy {
        StorageHistorySoakQualificationPolicy(
            minimumDuration: minimumDuration,
            maximumAwakeHeartbeatGap: 5 * 60,
            maximumWakeRecovery: 10,
            maximumResidentMemoryBytes: 150 * 1_000_000,
            maximumDatabaseBytes: 250 * 1_000_000,
            maximumAverageCPURatio: nil,
            maximumP95CPURatio: nil,
            requiresQualifiedCapacity: false,
            requiresSuccessfulRetention: false
        )
    }
}

public struct StorageHistorySoakQualificationAnalyzer: Sendable {
    private static let minimumCPUIntervalMilliseconds: Int64 = 10_000

    public init() {}

    public func analyze(
        _ records: [StorageHistorySoakDiagnosticRecord],
        policy: StorageHistorySoakQualificationPolicy = .init()
    ) -> StorageHistorySoakQualificationReport {
        let metrics = makeMetrics(records)
        var issues: [StorageHistorySoakQualificationIssue] = []

        if metrics.observedDurationMilliseconds
            < milliseconds(policy.minimumDuration) {
            issues.append(.insufficientDuration)
        }
        if records.contains(where: {
            $0.schemaVersion
                != StorageHistorySoakDiagnosticRecord.currentSchemaVersion
        }) {
            issues.append(.unsupportedSchema)
        }
        if hasContinuousTimeRegression(records) {
            issues.append(.continuousTimeRegression)
        }
        if metrics.maximumAwakeGapMilliseconds
            > milliseconds(policy.maximumAwakeHeartbeatGap) {
            issues.append(.awakeHeartbeatGap)
        }
        if hasCapacitySequenceRegression(records) {
            issues.append(.capacitySequenceRegression)
        }
        if policy.requiresQualifiedCapacity,
           records.last?.capacity.qualification != .qualified {
            issues.append(.finalCapacityNotQualified)
        }
        if records.last?.background.consecutiveSampleFailureCount ?? 1 > 0 {
            issues.append(.samplingFailuresRemain)
        }
        if policy.requiresSuccessfulRetention,
           records.contains(where: {
               $0.background.hasSuccessfulRetention
           }) == false {
            issues.append(.retentionNotObserved)
        }
        if let wake = metrics.maximumWakeRecoveryMilliseconds,
           wake > milliseconds(policy.maximumWakeRecovery) {
            issues.append(.wakeRecoveryBudgetExceeded)
        }
        if metrics.maximumResidentMemoryBytes
            > policy.maximumResidentMemoryBytes {
            issues.append(.residentMemoryBudgetExceeded)
        }
        if metrics.maximumDatabaseBytes > policy.maximumDatabaseBytes {
            issues.append(.databaseBudgetExceeded)
        }
        if let limit = policy.maximumAverageCPURatio,
           metrics.averageCPURatio > limit {
            issues.append(.averageCPUBudgetExceeded)
        }
        if let limit = policy.maximumP95CPURatio,
           metrics.p95CPURatio > limit {
            issues.append(.p95CPUBudgetExceeded)
        }

        return StorageHistorySoakQualificationReport(
            passed: issues.isEmpty,
            issues: issues,
            metrics: metrics
        )
    }

    private func makeMetrics(
        _ records: [StorageHistorySoakDiagnosticRecord]
    ) -> StorageHistorySoakQualificationMetrics {
        var observedDuration: Int64 = 0
        var maximumAwakeGap: Int64 = 0
        var cpuRatios: [Double] = []
        var totalCPU: Int64 = 0
        var totalContinuous: Int64 = 0

        for (first, second) in zip(records, records.dropFirst()) {
            let continuousDelta = second.continuousTimeMilliseconds
                - first.continuousTimeMilliseconds
            guard continuousDelta >= 0 else { continue }
            observedDuration += continuousDelta
            if isAwakeGap(first, second) {
                maximumAwakeGap = max(maximumAwakeGap, continuousDelta)
            }
            guard first.sessionID == second.sessionID else { continue }
            let cpuDelta = second.resource.cumulativeCPUMilliseconds
                - first.resource.cumulativeCPUMilliseconds
            guard continuousDelta >= Self.minimumCPUIntervalMilliseconds,
                  cpuDelta >= 0 else {
                continue
            }
            cpuRatios.append(
                Double(cpuDelta) / Double(continuousDelta)
            )
            totalCPU += cpuDelta
            totalContinuous += continuousDelta
        }

        let sortedRatios = cpuRatios.sorted()
        let p95Index = sortedRatios.isEmpty
            ? 0
            : min(
                sortedRatios.count - 1,
                Int(ceil(Double(sortedRatios.count) * 0.95)) - 1
            )
        return StorageHistorySoakQualificationMetrics(
            recordCount: records.count,
            sessionCount: Set(records.map(\.sessionID)).count,
            observedDurationMilliseconds: observedDuration,
            maximumAwakeGapMilliseconds: maximumAwakeGap,
            maximumWakeRecoveryMilliseconds: records.compactMap {
                $0.background.wakeRecoveryMilliseconds
            }.max(),
            maximumResidentMemoryBytes: records.map {
                $0.resource.residentMemoryBytes
            }.max() ?? 0,
            maximumDatabaseBytes: records.map {
                $0.resource.databaseBytes
            }.max() ?? 0,
            averageCPURatio: totalContinuous > 0
                ? Double(totalCPU) / Double(totalContinuous)
                : 0,
            p95CPURatio: sortedRatios.isEmpty
                ? 0
                : sortedRatios[p95Index]
        )
    }

    private func isAwakeGap(
        _ first: StorageHistorySoakDiagnosticRecord,
        _ second: StorageHistorySoakDiagnosticRecord
    ) -> Bool {
        first.background.phase == .awake
            && second.background.phase == .awake
            && first.reason != .stopped
            && second.reason != .started
    }

    private func hasContinuousTimeRegression(
        _ records: [StorageHistorySoakDiagnosticRecord]
    ) -> Bool {
        zip(records, records.dropFirst()).contains { first, second in
            second.continuousTimeMilliseconds
                < first.continuousTimeMilliseconds
        }
    }

    private func hasCapacitySequenceRegression(
        _ records: [StorageHistorySoakDiagnosticRecord]
    ) -> Bool {
        var previous: Int64?
        for sequence in records.compactMap({ $0.capacity.sequence }) {
            if let previous, sequence < previous {
                return true
            }
            previous = sequence
        }
        return false
    }

    private func milliseconds(_ interval: TimeInterval) -> Int64 {
        let scaled = interval * 1_000
        guard scaled.isFinite else { return .max }
        if scaled >= Double(Int64.max) { return .max }
        if scaled <= Double(Int64.min) { return .min }
        return Int64(scaled.rounded())
    }
}

public actor StorageHistorySoakDiagnosticRecorder {
    private let sessionID: UUID
    private let stateObserver: any StorageHistoryBackgroundStateObserving
    private let statusLoader: any StartupVolume24HourStatusLoading
    private let writer: any StorageHistorySoakLogWriting
    private let resourceProvider:
        any StorageHistorySoakResourceSnapshotProviding
    private let now: @Sendable () -> Date
    private var latestState = StorageHistoryBackgroundState.stopped

    public init(
        sessionID: UUID = UUID(),
        stateObserver: any StorageHistoryBackgroundStateObserving,
        statusLoader: any StartupVolume24HourStatusLoading,
        writer: any StorageHistorySoakLogWriting,
        resourceProvider: any StorageHistorySoakResourceSnapshotProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionID = sessionID
        self.stateObserver = stateObserver
        self.statusLoader = statusLoader
        self.writer = writer
        self.resourceProvider = resourceProvider
        self.now = now
    }

    public func run(
        heartbeatInterval: Duration = .seconds(60)
    ) async {
        let updates = await stateObserver.updates()
        await appendBestEffort(reason: .started, state: latestState)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self, updates] in
                for await state in updates {
                    guard let self, Task.isCancelled == false else { return }
                    await self.accept(state)
                }
            }
            group.addTask { [weak self] in
                while Task.isCancelled == false {
                    do {
                        try await Task.sleep(for: heartbeatInterval)
                    } catch {
                        return
                    }
                    guard let self, Task.isCancelled == false else { return }
                    await self.appendHeartbeat()
                }
            }
            await group.next()
            group.cancelAll()
        }
        await appendBestEffort(reason: .stopped, state: latestState)
    }

    private func accept(_ state: StorageHistoryBackgroundState) async {
        latestState = state
        await appendBestEffort(reason: .stateChanged, state: state)
    }

    private func appendHeartbeat() async {
        await appendBestEffort(reason: .heartbeat, state: latestState)
    }

    private func appendBestEffort(
        reason: StorageHistorySoakRecordReason,
        state: StorageHistoryBackgroundState
    ) async {
        do {
            let observedAt = now()
            let status = try? await statusLoader.load(through: observedAt)
            let measurement = try resourceProvider.snapshot()
            let record = StorageHistorySoakDiagnosticRecord(
                sessionID: sessionID,
                recordedAtMilliseconds: dateMilliseconds(observedAt),
                continuousTimeMilliseconds:
                    measurement.continuousTimeMilliseconds,
                reason: reason,
                background: makeBackgroundSnapshot(
                    state,
                    reason: reason,
                    recordedAt: observedAt
                ),
                resource: measurement.resource,
                capacity: StorageHistorySoakCapacitySnapshot(
                    sequence: status?.currentSequence,
                    qualification: status.map {
                        mapQualification($0.qualification)
                    } ?? .queryFailed
                )
            )
            try await writer.append(record)
        } catch {
            // Qualification diagnostics are evidence only. They must never
            // perturb storage monitoring or application shutdown.
        }
    }

    private func makeBackgroundSnapshot(
        _ state: StorageHistoryBackgroundState,
        reason: StorageHistorySoakRecordReason,
        recordedAt: Date
    ) -> StorageHistorySoakBackgroundSnapshot {
        let wakeRecovery: Int64?
        if reason == .stateChanged,
           state.lastSampleTrigger == .wake,
           state.lastSampleAttemptAt == state.lastSuccessfulSampleAt,
           let wakeAt = state.lastSuccessfulSampleAt {
            wakeRecovery = max(
                0,
                dateMilliseconds(recordedAt)
                    - dateMilliseconds(wakeAt)
            )
        } else {
            wakeRecovery = nil
        }
        return StorageHistorySoakBackgroundSnapshot(
            phase: mapPhase(state.phase),
            processedEventCount: state.processedEventCount,
            lastSampleTrigger: state.lastSampleTrigger.map(mapTrigger),
            sampleFailureCount: state.sampleFailureCount,
            consecutiveSampleFailureCount:
                state.consecutiveSampleFailureCount,
            retentionFailureCount: state.retentionFailureCount,
            hasSuccessfulRetention:
                state.lastSuccessfulRetentionAt != nil,
            wakeRecoveryMilliseconds: wakeRecovery
        )
    }

    private func mapPhase(
        _ phase: StorageHistoryBackgroundPhase
    ) -> StorageHistorySoakBackgroundPhase {
        switch phase {
        case .stopped: .stopped
        case .awake: .awake
        case .sleeping: .sleeping
        }
    }

    private func mapTrigger(
        _ trigger: StorageHistorySampleTrigger
    ) -> StorageHistorySoakSampleTrigger {
        switch trigger {
        case .startup: .startup
        case .periodic: .periodic
        case .wake: .wake
        case .significantTimeChange: .significantTimeChange
        }
    }

    private func mapQualification(
        _ qualification: StartupVolume24HourQualification
    ) -> StorageHistorySoakCapacityQualification {
        switch qualification {
        case .qualified: .qualified
        case .collecting: .collecting
        case .stale: .stale
        case .samplingGap: .samplingGap
        case .clockDiscontinuity: .clockDiscontinuity
        case .volumeIdentityChanged: .volumeIdentityChanged
        case .unavailable: .unavailable
        case .historyLimitReached: .historyLimitReached
        }
    }

    private func dateMilliseconds(_ date: Date) -> Int64 {
        let scaled = date.timeIntervalSince1970 * 1_000
        guard scaled.isFinite else { return 0 }
        if scaled >= Double(Int64.max) { return .max }
        if scaled <= Double(Int64.min) { return .min }
        return Int64(scaled.rounded())
    }
}
