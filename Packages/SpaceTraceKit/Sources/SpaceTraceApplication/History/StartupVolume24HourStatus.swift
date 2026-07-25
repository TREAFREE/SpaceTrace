import Foundation
import SpaceTraceDomain

public enum StartupVolume24HourQualification: Sendable, Equatable {
    case qualified
    case collecting
    case stale
    case samplingGap
    case clockDiscontinuity
    case volumeIdentityChanged
    case unavailable
    case historyLimitReached
}

public struct StartupVolume24HourStatus: Sendable, Equatable {
    public let qualification: StartupVolume24HourQualification
    public let currentAvailableBytes: ByteCount?
    public let currentObservedAt: Date?
    public let baselineObservedAt: Date?
    public let change: StorageDelta?

    public init(
        qualification: StartupVolume24HourQualification,
        currentAvailableBytes: ByteCount?,
        currentObservedAt: Date?,
        baselineObservedAt: Date?,
        change: StorageDelta?
    ) {
        self.qualification = qualification
        self.currentAvailableBytes = currentAvailableBytes
        self.currentObservedAt = currentObservedAt
        self.baselineObservedAt = baselineObservedAt
        self.change = change
    }

    public static let unavailable = StartupVolume24HourStatus(
        qualification: .unavailable,
        currentAvailableBytes: nil,
        currentObservedAt: nil,
        baselineObservedAt: nil,
        change: nil
    )
}

public protocol StartupVolume24HourStatusLoading: Sendable {
    func load(through end: Date) async throws -> StartupVolume24HourStatus
}

public struct StartupVolume24HourQualificationPolicy: Sendable, Equatable {
    public let comparisonDuration: TimeInterval
    public let endpointTolerance: TimeInterval
    public let maximumSampleGap: TimeInterval
    public let maximumCurrentAge: TimeInterval
    public let maximumFutureSkew: TimeInterval
    public let recentSampleLimit: Int

    public init(
        comparisonDuration: TimeInterval = 24 * 3_600,
        endpointTolerance: TimeInterval = 90 * 60,
        maximumSampleGap: TimeInterval = 90 * 60,
        maximumCurrentAge: TimeInterval = 90 * 60,
        maximumFutureSkew: TimeInterval = 5 * 60,
        recentSampleLimit: Int = 2_048
    ) {
        self.comparisonDuration = comparisonDuration
        self.endpointTolerance = endpointTolerance
        self.maximumSampleGap = maximumSampleGap
        self.maximumCurrentAge = maximumCurrentAge
        self.maximumFutureSkew = maximumFutureSkew
        self.recentSampleLimit = recentSampleLimit
    }
}

public struct StartupVolume24HourStatusQuery:
    StartupVolume24HourStatusLoading,
    Sendable
{
    private let repository: any StartupVolumeCapacityHistoryRepository
    private let policy: StartupVolume24HourQualificationPolicy

    public init(
        repository: any StartupVolumeCapacityHistoryRepository,
        policy: StartupVolume24HourQualificationPolicy = .init()
    ) {
        self.repository = repository
        self.policy = policy
    }

    public func load(
        through end: Date
    ) async throws -> StartupVolume24HourStatus {
        try validatePolicy()
        let samples = try await repository.recentStartupVolumeCapacityHistory(
            limit: policy.recentSampleLimit
        )
        try validateSamples(samples)
        guard let current = samples.last else { return .unavailable }
        let currentSnapshot = current.snapshot
        guard let currentBytes = currentSnapshot.availableBytes,
              let currentVolumeUUID = currentSnapshot.volumeUUID else {
            return StartupVolume24HourStatus(
                qualification: .unavailable,
                currentAvailableBytes: nil,
                currentObservedAt: currentSnapshot.observedAt,
                baselineObservedAt: nil,
                change: nil
            )
        }

        let currentAge = end.timeIntervalSince(currentSnapshot.observedAt)
        if currentAge < -policy.maximumFutureSkew {
            return incomplete(
                .clockDiscontinuity,
                current: currentSnapshot
            )
        }
        if currentAge > policy.maximumCurrentAge {
            return incomplete(.stale, current: currentSnapshot)
        }

        let target = end.addingTimeInterval(-policy.comparisonDuration)
        let lowerBound = target.addingTimeInterval(-policy.endpointTolerance)
        var usable: [StartupVolumeCapacityHistorySample] = [current]
        var boundary: StartupVolume24HourQualification?

        if samples.count > 1 {
            for index in stride(
                from: samples.count - 2,
                through: 0,
                by: -1
            ) {
                let previous = samples[index]
                let next = samples[index + 1]
                if previous.snapshot.observedAt < lowerBound {
                    break
                }
                if previous.snapshot.observedAt > next.snapshot.observedAt {
                    boundary = .clockDiscontinuity
                    break
                }
                if let previousUUID = previous.snapshot.volumeUUID,
                   previousUUID != currentVolumeUUID {
                    boundary = .volumeIdentityChanged
                    break
                }
                if previous.snapshot.volumeUUID == currentVolumeUUID,
                   previous.snapshot.availableBytes != nil {
                    usable.append(previous)
                }
            }
        }
        usable.reverse()

        let baseline = usable.min { lhs, rhs in
            abs(lhs.snapshot.observedAt.timeIntervalSince(target))
                < abs(rhs.snapshot.observedAt.timeIntervalSince(target))
        }
        guard let baseline,
              abs(baseline.snapshot.observedAt.timeIntervalSince(target))
                <= policy.endpointTolerance,
              let baselineBytes = baseline.snapshot.availableBytes else {
            let oldest = usable.first?.snapshot.observedAt
            let limitReached = samples.count == policy.recentSampleLimit
                && oldest.map { $0 > lowerBound } == true
            return incomplete(
                boundary
                    ?? (limitReached ? .historyLimitReached : .collecting),
                current: currentSnapshot
            )
        }

        let windowSamples = usable.filter {
            $0.sequence >= baseline.sequence
        }
        guard hasAcceptableGaps(windowSamples) else {
            return incomplete(.samplingGap, current: currentSnapshot)
        }
        if let boundary {
            return incomplete(boundary, current: currentSnapshot)
        }

        let (delta, overflow) = currentBytes.value.subtractingReportingOverflow(
            baselineBytes.value
        )
        guard overflow == false else {
            throw DirectoryHistoryQueryError.inconsistentRepositoryResult
        }
        return StartupVolume24HourStatus(
            qualification: .qualified,
            currentAvailableBytes: currentBytes,
            currentObservedAt: currentSnapshot.observedAt,
            baselineObservedAt: baseline.snapshot.observedAt,
            change: .volumeAvailable(bytes: delta)
        )
    }

    private func validatePolicy() throws {
        guard policy.recentSampleLimit > 1,
              policy.comparisonDuration > 0,
              policy.endpointTolerance >= 0,
              policy.maximumSampleGap > 0,
              policy.maximumCurrentAge >= 0,
              policy.maximumFutureSkew >= 0 else {
            throw DirectoryHistoryQueryError.inconsistentRepositoryResult
        }
    }

    private func validateSamples(
        _ samples: [StartupVolumeCapacityHistorySample]
    ) throws {
        guard samples.count <= policy.recentSampleLimit else {
            throw DirectoryHistoryQueryError.inconsistentRepositoryResult
        }
        var previousSequence: Int64?
        for sample in samples {
            guard sample.sequence > 0,
                  previousSequence.map({ sample.sequence > $0 }) ?? true else {
                throw DirectoryHistoryQueryError.inconsistentRepositoryResult
            }
            previousSequence = sample.sequence
        }
    }

    private func hasAcceptableGaps(
        _ samples: [StartupVolumeCapacityHistorySample]
    ) -> Bool {
        guard samples.count >= 2 else { return false }
        return zip(samples, samples.dropFirst()).allSatisfy { first, second in
            let gap = second.snapshot.observedAt.timeIntervalSince(
                first.snapshot.observedAt
            )
            return gap >= 0 && gap <= policy.maximumSampleGap
        }
    }

    private func incomplete(
        _ qualification: StartupVolume24HourQualification,
        current: StartupVolumeCapacitySnapshot
    ) -> StartupVolume24HourStatus {
        StartupVolume24HourStatus(
            qualification: qualification,
            currentAvailableBytes: current.availableBytes,
            currentObservedAt: current.observedAt,
            baselineObservedAt: nil,
            change: nil
        )
    }
}
