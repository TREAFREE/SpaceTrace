import Foundation
import SpaceTraceDomain

public struct StartupVolumeHistoryPoint: Sendable, Equatable, Identifiable {
    public let bucketStart: Date
    public let sampledAt: Date?
    public let sequence: Int64?
    public let volumeUUID: UUID?
    public let totalBytes: ByteCount?
    public let availableBytes: ByteCount?
    public let availableForImportantUsageBytes: ByteCount?
    public let coverage: DirectoryHistoryEvidenceCoverage

    public var id: Date { bucketStart }

    public init(
        bucketStart: Date,
        sampledAt: Date?,
        sequence: Int64?,
        volumeUUID: UUID?,
        totalBytes: ByteCount?,
        availableBytes: ByteCount?,
        availableForImportantUsageBytes: ByteCount?,
        coverage: DirectoryHistoryEvidenceCoverage
    ) {
        self.bucketStart = bucketStart
        self.sampledAt = sampledAt
        self.sequence = sequence
        self.volumeUUID = volumeUUID
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.coverage = coverage
    }
}

public struct StartupVolumeHistorySeries: Sendable, Equatable {
    public let points: [StartupVolumeHistoryPoint]
    public let coverage: DirectoryHistoryEvidenceCoverage
    public let identityDiscontinuity: Bool
    public let clockDiscontinuity: Bool

    public var hasMeasurements: Bool {
        points.contains { $0.availableBytes != nil }
    }

    public init(
        points: [StartupVolumeHistoryPoint],
        coverage: DirectoryHistoryEvidenceCoverage,
        identityDiscontinuity: Bool,
        clockDiscontinuity: Bool = false
    ) {
        self.points = points
        self.coverage = coverage
        self.identityDiscontinuity = identityDiscontinuity
        self.clockDiscontinuity = clockDiscontinuity
    }
}

public struct StorageReconciliationSummary: Sendable, Equatable {
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let startingAvailableBytes: ByteCount
    public let endingAvailableBytes: ByteCount
    public let diskSpaceLoss: ByteCount
    public let observedDirectoryAllocatedGrowth: ByteCount?
    public let explainedDiskSpaceLoss: ByteCount?
    public let unattributedDiskSpaceLoss: ByteCount?
    public let comparableScopeCount: Int
    public let excludedNestedScopeCount: Int
    public let excludedExternalScopeCount: Int
    public let unknownVolumeScopeCount: Int
    public let coverage: DirectoryHistoryEvidenceCoverage

    public init(
        firstObservedAt: Date,
        lastObservedAt: Date,
        startingAvailableBytes: ByteCount,
        endingAvailableBytes: ByteCount,
        diskSpaceLoss: ByteCount,
        observedDirectoryAllocatedGrowth: ByteCount?,
        explainedDiskSpaceLoss: ByteCount?,
        unattributedDiskSpaceLoss: ByteCount?,
        comparableScopeCount: Int,
        excludedNestedScopeCount: Int,
        excludedExternalScopeCount: Int,
        unknownVolumeScopeCount: Int,
        coverage: DirectoryHistoryEvidenceCoverage
    ) {
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.startingAvailableBytes = startingAvailableBytes
        self.endingAvailableBytes = endingAvailableBytes
        self.diskSpaceLoss = diskSpaceLoss
        self.observedDirectoryAllocatedGrowth = observedDirectoryAllocatedGrowth
        self.explainedDiskSpaceLoss = explainedDiskSpaceLoss
        self.unattributedDiskSpaceLoss = unattributedDiskSpaceLoss
        self.comparableScopeCount = comparableScopeCount
        self.excludedNestedScopeCount = excludedNestedScopeCount
        self.excludedExternalScopeCount = excludedExternalScopeCount
        self.unknownVolumeScopeCount = unknownVolumeScopeCount
        self.coverage = coverage
    }
}

public struct StorageHistoryOverview: Sendable, Equatable {
    public let window: DirectoryHistoryWindow
    public let start: Date
    public let end: Date
    public let bucket: DirectoryHistoryBucket
    public let volume: StartupVolumeHistorySeries
    public let directories: DirectoryHistoryOverview
    public let reconciliation: StorageReconciliationSummary?

    public init(
        window: DirectoryHistoryWindow,
        start: Date,
        end: Date,
        bucket: DirectoryHistoryBucket,
        volume: StartupVolumeHistorySeries,
        directories: DirectoryHistoryOverview,
        reconciliation: StorageReconciliationSummary?
    ) {
        self.window = window
        self.start = start
        self.end = end
        self.bucket = bucket
        self.volume = volume
        self.directories = directories
        self.reconciliation = reconciliation
    }
}

public protocol StorageHistoryOverviewLoading: Sendable {
    func loadOverview(
        contexts: [AuthorizedBaselineScanContext],
        window: DirectoryHistoryWindow,
        through end: Date,
        growthLimit: Int
    ) async throws -> StorageHistoryOverview
}

public struct StorageHistoryOverviewQuery: StorageHistoryOverviewLoading, Sendable {
    private let directoryQuery: DirectoryHistoryOverviewQuery
    private let volumeRepository: any StartupVolumeCapacityHistoryRepository

    public init(
        directoryRepository: any DirectoryHistoryRepository,
        volumeRepository: any StartupVolumeCapacityHistoryRepository
    ) {
        directoryQuery = DirectoryHistoryOverviewQuery(repository: directoryRepository)
        self.volumeRepository = volumeRepository
    }

    public func loadOverview(
        contexts: [AuthorizedBaselineScanContext],
        window: DirectoryHistoryWindow,
        through end: Date,
        growthLimit: Int = 100
    ) async throws -> StorageHistoryOverview {
        guard contexts.count <= DirectoryHistoryOverviewQuery.maximumContextCount else {
            throw DirectoryHistoryQueryError.tooManyContexts(
                maximum: DirectoryHistoryOverviewQuery.maximumContextCount
            )
        }
        guard Set(contexts.map(\.scopeID)).count == contexts.count else {
            throw DirectoryHistoryQueryError.duplicateScope
        }
        guard growthLimit > 0 else {
            throw DirectoryHistoryQueryError.invalidGrowthLimit
        }

        let start = end.addingTimeInterval(-window.duration)
        async let storedVolumeSamples = volumeRepository.startupVolumeCapacityHistory(
            from: start,
            through: end
        )
        let directories: DirectoryHistoryOverview
        if contexts.isEmpty {
            directories = Self.emptyDirectoryOverview(
                window: window,
                start: start,
                end: end
            )
        } else {
            directories = try await directoryQuery.loadOverview(
                contexts: contexts,
                window: window,
                through: end,
                growthLimit: growthLimit
            )
        }
        let volume = try makeVolumeSeries(
            samples: await storedVolumeSamples,
            bucket: window.bucket,
            start: start,
            end: end
        )
        let reconciliation = try makeReconciliation(
            contexts: contexts,
            directories: directories,
            volume: volume
        )
        return StorageHistoryOverview(
            window: window,
            start: start,
            end: end,
            bucket: window.bucket,
            volume: volume,
            directories: directories,
            reconciliation: reconciliation
        )
    }

    private func makeVolumeSeries(
        samples: [StartupVolumeCapacityHistorySample],
        bucket: DirectoryHistoryBucket,
        start: Date,
        end: Date
    ) throws -> StartupVolumeHistorySeries {
        var previousSequence: Int64?
        var previousObservedAt: Date?
        var clockDiscontinuity = false
        var byBucket: [Int64: StartupVolumeCapacityHistorySample] = [:]
        let startMilliseconds = Self.milliseconds(start)
        let firstBucket = Self.firstBucket(
            startMilliseconds: startMilliseconds,
            duration: bucket.durationMilliseconds
        )
        let lastBucket = Self.bucketStart(
            milliseconds: Self.milliseconds(end),
            duration: bucket.durationMilliseconds
        )

        for sample in samples {
            guard sample.sequence > 0,
                  previousSequence.map({ sample.sequence > $0 }) ?? true,
                  sample.snapshot.observedAt >= start,
                  sample.snapshot.observedAt <= end else {
                throw DirectoryHistoryQueryError.inconsistentRepositoryResult
            }
            previousSequence = sample.sequence
            if let previousObservedAt,
               sample.snapshot.observedAt < previousObservedAt {
                clockDiscontinuity = true
            }
            previousObservedAt = sample.snapshot.observedAt
            let key = Self.bucketStart(
                milliseconds: Self.milliseconds(sample.snapshot.observedAt),
                duration: bucket.durationMilliseconds
            )
            guard key >= firstBucket, key <= lastBucket else { continue }
            if let existing = byBucket[key], existing.sequence >= sample.sequence {
                throw DirectoryHistoryQueryError.inconsistentRepositoryResult
            }
            byBucket[key] = sample
        }

        var points: [StartupVolumeHistoryPoint] = []
        var timestamp = firstBucket
        while timestamp <= lastBucket {
            if let sample = byBucket[timestamp] {
                let snapshot = sample.snapshot
                let coverage: DirectoryHistoryEvidenceCoverage =
                    snapshot.availableBytes == nil
                    ? .unavailable
                    : (snapshot.volumeUUID == nil ? .partial : .complete)
                points.append(
                    StartupVolumeHistoryPoint(
                        bucketStart: Self.date(milliseconds: timestamp),
                        sampledAt: snapshot.observedAt,
                        sequence: sample.sequence,
                        volumeUUID: snapshot.volumeUUID,
                        totalBytes: snapshot.totalBytes,
                        availableBytes: snapshot.availableBytes,
                        availableForImportantUsageBytes:
                            snapshot.availableForImportantUsageBytes,
                        coverage: coverage
                    )
                )
            } else {
                points.append(
                    StartupVolumeHistoryPoint(
                        bucketStart: Self.date(milliseconds: timestamp),
                        sampledAt: nil,
                        sequence: nil,
                        volumeUUID: nil,
                        totalBytes: nil,
                        availableBytes: nil,
                        availableForImportantUsageBytes: nil,
                        coverage: .unavailable
                    )
                )
            }
            guard timestamp <= Int64.max - bucket.durationMilliseconds else { break }
            timestamp += bucket.durationMilliseconds
        }

        let knownIdentities = points.compactMap(\.volumeUUID)
        let identityDiscontinuity = zip(
            knownIdentities,
            knownIdentities.dropFirst()
        ).contains { $0 != $1 }
        return StartupVolumeHistorySeries(
            points: points,
            coverage: clockDiscontinuity
                ? .partial
                : Self.aggregateCoverage(points.map(\.coverage)),
            identityDiscontinuity: identityDiscontinuity,
            clockDiscontinuity: clockDiscontinuity
        )
    }

    private func makeReconciliation(
        contexts: [AuthorizedBaselineScanContext],
        directories: DirectoryHistoryOverview,
        volume: StartupVolumeHistorySeries
    ) throws -> StorageReconciliationSummary? {
        guard volume.clockDiscontinuity == false,
              volume.identityDiscontinuity == false else {
            return nil
        }
        let availablePoints = volume.points.filter { $0.availableBytes != nil }
        guard let last = availablePoints.last,
              let latestVolumeUUID = last.volumeUUID,
              let first = availablePoints.first(where: {
                  $0.volumeUUID == latestVolumeUUID
              }),
              first.id < last.id,
              let startingAvailable = first.availableBytes,
              let endingAvailable = last.availableBytes else {
            return nil
        }

        let diskLossValue = max(0, startingAvailable.value - endingAvailable.value)
        let diskLoss = try ByteCount(diskLossValue)
        let externalCount = contexts.count { context in
            context.volumeUUID.map { $0 != latestVolumeUUID } ?? false
        }
        let unknownCount = contexts.count { $0.volumeUUID == nil }
        let startupContexts = contexts.filter { $0.volumeUUID == latestVolumeUUID }
        let (nonOverlapping, nestedCount) = Self.topmostContexts(startupContexts)

        var allocatedNetGrowth: Int64 = 0
        var comparableCount = 0
        var directoryEvidenceComplete = true
        for context in nonOverlapping {
            guard let series = directories.series.first(where: {
                $0.scopeID == context.scopeID
            }) else {
                directoryEvidenceComplete = false
                continue
            }
            let observed = series.points.filter { $0.allocatedBytes != nil }
            guard let firstDirectory = observed.first,
                  let lastDirectory = observed.last,
                  firstDirectory.id < lastDirectory.id,
                  let firstBytes = firstDirectory.allocatedBytes,
                  let lastBytes = lastDirectory.allocatedBytes else {
                directoryEvidenceComplete = false
                continue
            }
            comparableCount += 1
            let delta = lastBytes.value - firstBytes.value
            let (sum, overflow) = allocatedNetGrowth.addingReportingOverflow(delta)
            guard overflow == false else {
                throw DirectoryHistoryQueryError.inconsistentRepositoryResult
            }
            allocatedNetGrowth = sum
            if series.coverage != .complete {
                directoryEvidenceComplete = false
            }
        }

        let observedGrowth: ByteCount?
        let explained: ByteCount?
        let unattributed: ByteCount?
        if comparableCount > 0 {
            let positiveGrowth = max(0, allocatedNetGrowth)
            let credited = min(diskLossValue, positiveGrowth)
            observedGrowth = try ByteCount(positiveGrowth)
            explained = try ByteCount(credited)
            unattributed = try ByteCount(diskLossValue - credited)
        } else {
            observedGrowth = nil
            explained = nil
            unattributed = nil
        }

        let isComplete = volume.coverage == .complete
            && volume.identityDiscontinuity == false
            && directoryEvidenceComplete
            && unknownCount == 0
            && comparableCount > 0
        return StorageReconciliationSummary(
            firstObservedAt: first.sampledAt ?? first.bucketStart,
            lastObservedAt: last.sampledAt ?? last.bucketStart,
            startingAvailableBytes: startingAvailable,
            endingAvailableBytes: endingAvailable,
            diskSpaceLoss: diskLoss,
            observedDirectoryAllocatedGrowth: observedGrowth,
            explainedDiskSpaceLoss: explained,
            unattributedDiskSpaceLoss: unattributed,
            comparableScopeCount: comparableCount,
            excludedNestedScopeCount: nestedCount,
            excludedExternalScopeCount: externalCount,
            unknownVolumeScopeCount: unknownCount,
            coverage: isComplete ? .complete : .partial
        )
    }

    private static func emptyDirectoryOverview(
        window: DirectoryHistoryWindow,
        start: Date,
        end: Date
    ) -> DirectoryHistoryOverview {
        DirectoryHistoryOverview(
            window: window,
            start: start,
            end: end,
            bucket: window.bucket,
            series: [],
            growthSources: [],
            coverage: .unavailable
        )
    }

    private static func topmostContexts(
        _ contexts: [AuthorizedBaselineScanContext]
    ) -> ([AuthorizedBaselineScanContext], Int) {
        let ordered = contexts.sorted {
            if $0.root.rawValue.count != $1.root.rawValue.count {
                return $0.root.rawValue.count < $1.root.rawValue.count
            }
            return $0.root.rawValue < $1.root.rawValue
        }
        var retained: [AuthorizedBaselineScanContext] = []
        var nestedCount = 0
        for context in ordered {
            if retained.contains(where: { Self.contains(context.root, in: $0.root) }) {
                nestedCount += 1
            } else {
                retained.append(context)
            }
        }
        return (retained, nestedCount)
    }

    private static func contains(_ path: DirtyRegionPath, in root: DirtyRegionPath) -> Bool {
        root.rawValue == "/"
            || path == root
            || path.rawValue.hasPrefix(root.rawValue + "/")
    }

    private static func aggregateCoverage(
        _ coverages: [DirectoryHistoryEvidenceCoverage]
    ) -> DirectoryHistoryEvidenceCoverage {
        guard coverages.contains(where: { $0 != .unavailable }) else {
            return .unavailable
        }
        return coverages.allSatisfy { $0 == .complete } ? .complete : .partial
    }

    private static func firstBucket(
        startMilliseconds: Int64,
        duration: Int64
    ) -> Int64 {
        let floored = bucketStart(
            milliseconds: startMilliseconds,
            duration: duration
        )
        return floored < startMilliseconds ? floored + duration : floored
    }

    private static func bucketStart(milliseconds: Int64, duration: Int64) -> Int64 {
        let quotient = milliseconds / duration
        let remainder = milliseconds % duration
        return (remainder < 0 ? quotient - 1 : quotient) * duration
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}
