import Foundation
import SpaceTraceDomain

public enum DirectoryHistoryBucket: String, Sendable, Equatable, Codable {
    case hourly
    case daily

    public var durationMilliseconds: Int64 {
        switch self {
        case .hourly: 3_600_000
        case .daily: 86_400_000
        }
    }
}

public enum DirectoryHistoryWindow: String, CaseIterable, Sendable, Equatable, Codable {
    case last24Hours
    case last7Days
    case last30Days

    public var bucket: DirectoryHistoryBucket {
        switch self {
        case .last24Hours:
            .hourly
        case .last7Days, .last30Days:
            .daily
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .last24Hours:
            24 * 3_600
        case .last7Days:
            7 * 86_400
        case .last30Days:
            30 * 86_400
        }
    }
}

public struct DirectoryHistorySample: Sendable, Equatable {
    public let streamID: EventStreamID
    public let path: DirtyRegionPath
    public let bucket: DirectoryHistoryBucket
    public let bucketStart: Date
    public let logicalBytes: ByteCount?
    public let allocatedBytes: ByteCount?
    public let descendantCount: Int64
    public let coverage: CalibrationCoverage

    public init(
        streamID: EventStreamID,
        path: DirtyRegionPath,
        bucket: DirectoryHistoryBucket,
        bucketStart: Date,
        logicalBytes: ByteCount?,
        allocatedBytes: ByteCount?,
        descendantCount: Int64,
        coverage: CalibrationCoverage
    ) {
        self.streamID = streamID
        self.path = path
        self.bucket = bucket
        self.bucketStart = bucketStart
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.descendantCount = descendantCount
        self.coverage = coverage
    }
}

public struct DirectoryGrowthSample: Sendable, Equatable {
    public let streamID: EventStreamID
    public let path: DirtyRegionPath
    public let logicalByteDelta: Int64
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let coverage: CalibrationCoverage

    public init(
        streamID: EventStreamID,
        path: DirtyRegionPath,
        logicalByteDelta: Int64,
        firstObservedAt: Date,
        lastObservedAt: Date,
        coverage: CalibrationCoverage
    ) {
        self.streamID = streamID
        self.path = path
        self.logicalByteDelta = logicalByteDelta
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.coverage = coverage
    }
}

public protocol DirectoryHistoryRepository: Sendable {
    func directoryHistory(
        for streamID: EventStreamID,
        path: DirtyRegionPath,
        bucket: DirectoryHistoryBucket,
        from start: Date,
        through end: Date
    ) async throws -> [DirectoryHistorySample]

    func topDirectoryGrowth(
        for streamID: EventStreamID,
        under root: DirtyRegionPath,
        bucket: DirectoryHistoryBucket,
        from start: Date,
        through end: Date,
        limit: Int
    ) async throws -> [DirectoryGrowthSample]
}

public enum DirectoryHistoryEvidenceCoverage: Sendable, Equatable {
    case complete
    case partial
    case unavailable
}

public struct DirectoryHistoryPoint: Sendable, Equatable, Identifiable {
    public let observedAt: Date
    public let logicalBytes: ByteCount?
    public let allocatedBytes: ByteCount?
    public let coverage: DirectoryHistoryEvidenceCoverage

    public var id: Date { observedAt }

    public init(
        observedAt: Date,
        logicalBytes: ByteCount?,
        allocatedBytes: ByteCount?,
        coverage: DirectoryHistoryEvidenceCoverage
    ) {
        self.observedAt = observedAt
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.coverage = coverage
    }
}

public struct DirectoryHistorySeries: Sendable, Equatable, Identifiable {
    public let scopeID: WatchedScopeID
    public let root: DirtyRegionPath
    public let points: [DirectoryHistoryPoint]
    public let coverage: DirectoryHistoryEvidenceCoverage

    public var id: WatchedScopeID { scopeID }

    public init(
        scopeID: WatchedScopeID,
        root: DirtyRegionPath,
        points: [DirectoryHistoryPoint],
        coverage: DirectoryHistoryEvidenceCoverage
    ) {
        self.scopeID = scopeID
        self.root = root
        self.points = points
        self.coverage = coverage
    }
}

public struct DirectoryGrowthSource: Sendable, Equatable, Identifiable {
    public let scopeID: WatchedScopeID
    public let path: DirtyRegionPath
    public let logicalByteDelta: Int64
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let coverage: DirectoryHistoryEvidenceCoverage

    public var id: String { "\(scopeID.rawValue)\u{0}\(path.rawValue)" }

    public init(
        scopeID: WatchedScopeID,
        path: DirtyRegionPath,
        logicalByteDelta: Int64,
        firstObservedAt: Date,
        lastObservedAt: Date,
        coverage: DirectoryHistoryEvidenceCoverage
    ) {
        self.scopeID = scopeID
        self.path = path
        self.logicalByteDelta = logicalByteDelta
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.coverage = coverage
    }
}

public struct DirectoryHistoryOverview: Sendable, Equatable {
    public let window: DirectoryHistoryWindow
    public let start: Date
    public let end: Date
    public let bucket: DirectoryHistoryBucket
    public let series: [DirectoryHistorySeries]
    public let growthSources: [DirectoryGrowthSource]
    public let coverage: DirectoryHistoryEvidenceCoverage

    public var hasMeasurements: Bool {
        series.contains { item in
            item.points.contains { $0.logicalBytes != nil }
        }
    }

    public init(
        window: DirectoryHistoryWindow,
        start: Date,
        end: Date,
        bucket: DirectoryHistoryBucket,
        series: [DirectoryHistorySeries],
        growthSources: [DirectoryGrowthSource],
        coverage: DirectoryHistoryEvidenceCoverage
    ) {
        self.window = window
        self.start = start
        self.end = end
        self.bucket = bucket
        self.series = series
        self.growthSources = growthSources
        self.coverage = coverage
    }
}

public enum DirectoryHistoryQueryError: Error, Sendable, Equatable {
    case emptyContexts
    case tooManyContexts(maximum: Int)
    case duplicateScope
    case invalidGrowthLimit
    case inconsistentRepositoryResult
}

public protocol DirectoryHistoryOverviewLoading: Sendable {
    func loadOverview(
        contexts: [AuthorizedBaselineScanContext],
        window: DirectoryHistoryWindow,
        through end: Date,
        growthLimit: Int
    ) async throws -> DirectoryHistoryOverview
}

public struct DirectoryHistoryOverviewQuery: DirectoryHistoryOverviewLoading, Sendable {
    public static let maximumContextCount = AuthorizedBaselineScanRequest.maximumScopeCount

    private let repository: any DirectoryHistoryRepository

    public init(repository: any DirectoryHistoryRepository) {
        self.repository = repository
    }

    public func loadOverview(
        contexts: [AuthorizedBaselineScanContext],
        window: DirectoryHistoryWindow,
        through end: Date,
        growthLimit: Int = 100
    ) async throws -> DirectoryHistoryOverview {
        guard contexts.isEmpty == false else {
            throw DirectoryHistoryQueryError.emptyContexts
        }
        guard contexts.count <= Self.maximumContextCount else {
            throw DirectoryHistoryQueryError.tooManyContexts(
                maximum: Self.maximumContextCount
            )
        }
        guard Set(contexts.map(\.scopeID)).count == contexts.count else {
            throw DirectoryHistoryQueryError.duplicateScope
        }
        guard growthLimit > 0 else {
            throw DirectoryHistoryQueryError.invalidGrowthLimit
        }

        let start = end.addingTimeInterval(-window.duration)
        let orderedContexts = contexts.sorted { $0.scopeID.rawValue < $1.scopeID.rawValue }
        var series: [DirectoryHistorySeries] = []
        var growthSources: [DirectoryGrowthSource] = []
        series.reserveCapacity(orderedContexts.count)

        for context in orderedContexts {
            try Task.checkCancellation()
            let samples = try await repository.directoryHistory(
                for: context.streamID,
                path: context.root,
                bucket: window.bucket,
                from: start,
                through: end
            )
            let historySeries = try makeSeries(
                context: context,
                samples: samples,
                bucket: window.bucket,
                start: start,
                end: end
            )
            series.append(historySeries)

            try Task.checkCancellation()
            let growth = try await repository.topDirectoryGrowth(
                for: context.streamID,
                under: context.root,
                bucket: window.bucket,
                from: start,
                through: end,
                limit: growthLimit
            )
            growthSources.append(contentsOf: try growth.map { sample in
                guard sample.streamID == context.streamID,
                      contains(sample.path, in: context.root),
                      sample.firstObservedAt <= sample.lastObservedAt,
                      sample.firstObservedAt > start,
                      sample.lastObservedAt <= end else {
                    throw DirectoryHistoryQueryError.inconsistentRepositoryResult
                }
                return DirectoryGrowthSource(
                    scopeID: context.scopeID,
                    path: sample.path,
                    logicalByteDelta: sample.logicalByteDelta,
                    firstObservedAt: sample.firstObservedAt,
                    lastObservedAt: sample.lastObservedAt,
                    coverage: combine(
                        stored: sample.coverage,
                        window: historySeries.coverage
                    )
                )
            })
        }

        growthSources = growthSources
            .filter { $0.logicalByteDelta > 0 }
            .sorted {
                if $0.logicalByteDelta != $1.logicalByteDelta {
                    return $0.logicalByteDelta > $1.logicalByteDelta
                }
                if $0.path.rawValue != $1.path.rawValue {
                    return $0.path.rawValue < $1.path.rawValue
                }
                return $0.scopeID.rawValue < $1.scopeID.rawValue
            }
        if growthSources.count > growthLimit {
            growthSources.removeSubrange(growthLimit...)
        }

        return DirectoryHistoryOverview(
            window: window,
            start: start,
            end: end,
            bucket: window.bucket,
            series: series,
            growthSources: growthSources,
            coverage: aggregateCoverage(series.map(\.coverage))
        )
    }

    private func makeSeries(
        context: AuthorizedBaselineScanContext,
        samples: [DirectoryHistorySample],
        bucket: DirectoryHistoryBucket,
        start: Date,
        end: Date
    ) throws -> DirectoryHistorySeries {
        let startMilliseconds = Self.milliseconds(start)
        let flooredStartBucket = bucketStart(
            milliseconds: startMilliseconds,
            duration: bucket.durationMilliseconds
        )
        let firstBucket = flooredStartBucket < startMilliseconds
            ? flooredStartBucket + bucket.durationMilliseconds
            : flooredStartBucket
        let lastBucket = bucketStart(
            milliseconds: Self.milliseconds(end),
            duration: bucket.durationMilliseconds
        )
        var samplesByBucket: [Int64: DirectoryHistorySample] = [:]
        for sample in samples {
            let sampleMilliseconds = Self.milliseconds(sample.bucketStart)
            guard sample.streamID == context.streamID,
                  sample.path == context.root,
                  sample.bucket == bucket,
                  sampleMilliseconds == bucketStart(
                    milliseconds: sampleMilliseconds,
                    duration: bucket.durationMilliseconds
                  ),
                  sampleMilliseconds >= firstBucket,
                  sampleMilliseconds <= lastBucket,
                  samplesByBucket[sampleMilliseconds] == nil,
                  sample.descendantCount >= 0,
                  sample.coverage != .complete || (
                    sample.logicalBytes != nil && sample.allocatedBytes != nil
                  ) else {
                throw DirectoryHistoryQueryError.inconsistentRepositoryResult
            }
            samplesByBucket[sampleMilliseconds] = sample
        }

        var points: [DirectoryHistoryPoint] = []
        var timestamp = firstBucket
        while timestamp <= lastBucket {
            if let sample = samplesByBucket[timestamp] {
                points.append(
                    DirectoryHistoryPoint(
                        observedAt: Self.date(milliseconds: timestamp),
                        logicalBytes: sample.logicalBytes,
                        allocatedBytes: sample.allocatedBytes,
                        coverage: sample.coverage == .complete ? .complete : .partial
                    )
                )
            } else {
                points.append(
                    DirectoryHistoryPoint(
                        observedAt: Self.date(milliseconds: timestamp),
                        logicalBytes: nil,
                        allocatedBytes: nil,
                        coverage: .unavailable
                    )
                )
            }
            guard timestamp <= Int64.max - bucket.durationMilliseconds else { break }
            timestamp += bucket.durationMilliseconds
        }

        return DirectoryHistorySeries(
            scopeID: context.scopeID,
            root: context.root,
            points: points,
            coverage: aggregateCoverage(points.map(\.coverage))
        )
    }

    private func aggregateCoverage(
        _ coverages: [DirectoryHistoryEvidenceCoverage]
    ) -> DirectoryHistoryEvidenceCoverage {
        guard coverages.contains(where: { $0 != .unavailable }) else {
            return .unavailable
        }
        return coverages.allSatisfy { $0 == .complete } ? .complete : .partial
    }

    private func combine(
        stored: CalibrationCoverage,
        window: DirectoryHistoryEvidenceCoverage
    ) -> DirectoryHistoryEvidenceCoverage {
        guard window != .unavailable else { return .unavailable }
        return stored == .complete && window == .complete ? .complete : .partial
    }

    private func contains(_ path: DirtyRegionPath, in root: DirtyRegionPath) -> Bool {
        root.rawValue == "/"
            || path == root
            || path.rawValue.hasPrefix(root.rawValue + "/")
    }

    private func bucketStart(milliseconds: Int64, duration: Int64) -> Int64 {
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
