import Foundation

public enum StartupVolumeCapacitySampleSource: String, Sendable, Equatable, Codable {
    case lifecycle
    case baseline
}

/// One durable capacity observation. `sequence` is the database commit order;
/// wall-clock time is descriptive and is not used as an ordering guarantee.
public struct StartupVolumeCapacityHistorySample: Sendable, Equatable {
    public let sequence: Int64
    public let snapshot: StartupVolumeCapacitySnapshot
    public let source: StartupVolumeCapacitySampleSource

    public init(
        sequence: Int64,
        snapshot: StartupVolumeCapacitySnapshot,
        source: StartupVolumeCapacitySampleSource
    ) {
        self.sequence = sequence
        self.snapshot = snapshot
        self.source = source
    }
}

public protocol StartupVolumeCapacityHistoryRepository: Sendable {
    func recordStartupVolumeCapacity(
        _ snapshot: StartupVolumeCapacitySnapshot,
        source: StartupVolumeCapacitySampleSource
    ) async throws

    func startupVolumeCapacityHistory(
        from start: Date,
        through end: Date
    ) async throws -> [StartupVolumeCapacityHistorySample]

    /// Returns the newest committed samples in ascending commit-sequence
    /// order. This bounded sequence view is deliberately independent of wall
    /// time so a clock rollback cannot hide the evidence that it occurred.
    func recentStartupVolumeCapacityHistory(
        limit: Int
    ) async throws -> [StartupVolumeCapacityHistorySample]
}

public enum StorageHistorySampleTrigger: Sendable, Equatable {
    case startup
    case periodic
    case wake
    case significantTimeChange
}

public protocol StartupVolumeCapacityRecording: Sendable {
    func record(trigger: StorageHistorySampleTrigger) async throws
}

/// Application use case for one capacity observation. Scheduling is owned by
/// the app lifecycle; the provider and persistence adapter stay replaceable.
public struct StartupVolumeCapacityRecorder:
    StartupVolumeCapacityRecording,
    Sendable
{
    private let provider: any StartupVolumeCapacitySnapshotProviding
    private let repository: any StartupVolumeCapacityHistoryRepository

    public init(
        provider: any StartupVolumeCapacitySnapshotProviding,
        repository: any StartupVolumeCapacityHistoryRepository
    ) {
        self.provider = provider
        self.repository = repository
    }

    public func record() async throws {
        try await record(trigger: .periodic)
    }

    public func record(trigger: StorageHistorySampleTrigger) async throws {
        _ = trigger
        try Task.checkCancellation()
        let snapshot = await provider.snapshot()
        try Task.checkCancellation()
        try await repository.recordStartupVolumeCapacity(
            snapshot,
            source: .lifecycle
        )
    }
}
