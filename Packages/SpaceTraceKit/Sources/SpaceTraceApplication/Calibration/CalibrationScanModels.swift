import SpaceTraceDomain

public struct CalibrationScanBudget: Sendable, Equatable, Hashable {
    public static let incremental = CalibrationScanBudget(
        validatedMaximumEntries: 100_000,
        maximumDepth: 128,
        maximumDurationMilliseconds: 30_000,
        stageBatchSize: 128,
        yieldEveryEntries: 2_000
    )

    public let maximumEntries: Int
    public let maximumDepth: Int
    public let maximumDurationMilliseconds: UInt64
    public let stageBatchSize: Int
    public let yieldEveryEntries: Int

    public init(
        maximumEntries: Int,
        maximumDepth: Int,
        maximumDurationMilliseconds: UInt64,
        stageBatchSize: Int,
        yieldEveryEntries: Int
    ) throws(CalibrationScanModelError) {
        guard maximumEntries > 0 else { throw .invalidMaximumEntries }
        guard maximumDepth >= 0 else { throw .invalidMaximumDepth }
        guard maximumDurationMilliseconds > 0 else { throw .invalidMaximumDuration }
        guard stageBatchSize > 0 else { throw .invalidStageBatchSize }
        guard yieldEveryEntries > 0 else { throw .invalidYieldInterval }

        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.stageBatchSize = stageBatchSize
        self.yieldEveryEntries = yieldEveryEntries
    }

    private init(
        validatedMaximumEntries maximumEntries: Int,
        maximumDepth: Int,
        maximumDurationMilliseconds: UInt64,
        stageBatchSize: Int,
        yieldEveryEntries: Int
    ) {
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.stageBatchSize = stageBatchSize
        self.yieldEveryEntries = yieldEveryEntries
    }
}

public enum CalibrationGapReason: String, Sendable, Equatable, Hashable {
    case permissionDenied
    case metadataUnavailable
    case entryDisappeared
    case mountBoundary
    case depthBudgetExceeded
    case entryBudgetExceeded
    case timeBudgetExceeded
    case arithmeticOverflow
}

public struct CalibrationGap: Sendable, Equatable, Hashable {
    public let path: DirtyRegionPath
    public let reason: CalibrationGapReason

    public init(path: DirtyRegionPath, reason: CalibrationGapReason) {
        self.path = path
        self.reason = reason
    }
}

/// A directory-only aggregate. Leaf file names never cross this boundary.
public struct DirectoryMetadataAggregate: Sendable, Equatable, Hashable {
    public let path: DirtyRegionPath
    public let logicalBytes: ByteCount?
    public let allocatedBytes: ByteCount?
    public let descendantCount: Int64
    public let coverage: CalibrationCoverage

    public init(
        path: DirtyRegionPath,
        logicalBytes: ByteCount?,
        allocatedBytes: ByteCount?,
        descendantCount: Int64,
        coverage: CalibrationCoverage
    ) throws(CalibrationScanModelError) {
        guard descendantCount >= 0 else {
            throw .negativeDescendantCount(descendantCount)
        }
        if coverage == .complete,
           logicalBytes == nil || allocatedBytes == nil {
            throw .completeAggregateRequiresBothMetrics
        }

        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.descendantCount = descendantCount
        self.coverage = coverage
    }
}

public struct CalibrationReport: Sendable, Equatable {
    public let coverage: CalibrationCoverage
    public let entriesVisited: Int64
    public let directoriesStaged: Int64
    public let gaps: [CalibrationGap]

    public init(
        coverage: CalibrationCoverage,
        entriesVisited: Int64,
        directoriesStaged: Int64,
        gaps: [CalibrationGap]
    ) throws(CalibrationScanModelError) {
        guard entriesVisited >= 0 else { throw .negativeEntriesVisited }
        guard directoriesStaged >= 0 else { throw .negativeDirectoriesStaged }
        guard coverage != .complete || directoriesStaged > 0 else {
            throw .completeReportRequiresStagedDirectory
        }
        guard coverage != .complete || gaps.isEmpty else {
            throw .completeReportCannotContainGaps
        }

        self.coverage = coverage
        self.entriesVisited = entriesVisited
        self.directoriesStaged = directoriesStaged
        self.gaps = gaps
    }
}

public struct CalibrationRunID: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) throws(CalibrationScanModelError) {
        guard rawValue.isEmpty == false,
              rawValue.utf8.contains(0) == false,
              rawValue.first?.isWhitespace == false,
              rawValue.last?.isWhitespace == false else {
            throw .invalidRunID
        }
        self.rawValue = rawValue
    }
}

public enum CalibrationRunDisposition: String, Sendable, Equatable {
    case partial
    case cancelled
    case failed
}

public enum CalibrationScanModelError: Error, Sendable, Equatable {
    case invalidMaximumEntries
    case invalidMaximumDepth
    case invalidMaximumDuration
    case invalidStageBatchSize
    case invalidYieldInterval
    case negativeDescendantCount(Int64)
    case completeAggregateRequiresBothMetrics
    case negativeEntriesVisited
    case negativeDirectoriesStaged
    case completeReportRequiresStagedDirectory
    case completeReportCannotContainGaps
    case invalidRunID
}
