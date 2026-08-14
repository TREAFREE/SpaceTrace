import Foundation
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

/// Filesystem family observed for a directory-object identity. Only APFS is a
/// candidate for the current stable-object qualification policy; every other
/// value remains deliberately unsupported rather than inferred from a path.
public enum HistoricalDirectoryFileSystem: Sendable, Equatable, Hashable {
    case apfs
    case unsupported
}

/// Transient filesystem evidence captured by the source adapter. This value is
/// not durable by itself: the Application builder decides whether it is strong
/// enough to become stable identity evidence in an immutable frame.
public struct HistoricalDirectoryObjectIdentityObservation: Sendable, Equatable, Hashable {
    public let fileSystem: HistoricalDirectoryFileSystem
    public let volumeLocalObjectID: UInt64
    public let birthTime: HistoricalFindingBirthTime?
    public let linkStatus: HistoricalFindingLinkStatus

    public init(
        fileSystem: HistoricalDirectoryFileSystem,
        volumeLocalObjectID: UInt64,
        birthTime: HistoricalFindingBirthTime?,
        linkStatus: HistoricalFindingLinkStatus
    ) {
        self.fileSystem = fileSystem
        self.volumeLocalObjectID = volumeLocalObjectID
        self.birthTime = birthTime
        self.linkStatus = linkStatus
    }
}

/// One fully measured directory from a complete calibration scan. Leaf paths
/// never cross this boundary. Direct-child coverage is kept separate from the
/// recursive aggregate measurement because absence proof needs both facts.
public struct HistoricalDirectoryScanObservation: Sendable, Equatable, Hashable {
    public let path: DirtyRegionPath
    public let parentPath: DirtyRegionPath?
    public let logicalBytes: ByteCount
    public let allocatedBytes: ByteCount
    public let directChildrenCoverage: ObservationCoverage
    public let observedAt: ObservationInstant
    public let objectIdentity: HistoricalDirectoryObjectIdentityObservation?

    public init(
        path: DirtyRegionPath,
        parentPath: DirtyRegionPath?,
        logicalBytes: ByteCount,
        allocatedBytes: ByteCount,
        directChildrenCoverage: ObservationCoverage,
        observedAt: ObservationInstant,
        objectIdentity: HistoricalDirectoryObjectIdentityObservation?
    ) throws(HistoricalCalibrationScanEvidenceError) {
        guard directChildrenCoverage == .complete else {
            throw .incompleteDirectChildren(path)
        }
        self.path = path
        self.parentPath = parentPath
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.directChildrenCoverage = directChildrenCoverage
        self.observedAt = observedAt
        self.objectIdentity = objectIdentity
    }
}

/// Canonical directory-only evidence emitted only when the complete scan
/// report can support an immutable historical frame.
public struct HistoricalCalibrationScanEvidence: Sendable, Equatable {
    public let rootPath: DirtyRegionPath
    public let directories: [HistoricalDirectoryScanObservation]

    public init(
        rootPath: DirtyRegionPath,
        directories: [HistoricalDirectoryScanObservation]
    ) throws(HistoricalCalibrationScanEvidenceError) {
        guard directories.isEmpty == false else { throw .emptyDirectories }
        let canonical = directories.sorted {
            $0.path.rawValue.utf8.lexicographicallyPrecedes($1.path.rawValue.utf8)
        }
        let pathBytes = canonical.map { Data($0.path.rawValue.utf8) }
        guard Set(pathBytes).count == canonical.count else { throw .duplicatePath }
        let rootBytes = Data(rootPath.rawValue.utf8)
        guard let root = canonical.first(where: {
            Data($0.path.rawValue.utf8) == rootBytes
        }),
              root.parentPath == nil else {
            throw .invalidRoot
        }
        let paths = Set(pathBytes)
        for directory in canonical
        where Data(directory.path.rawValue.utf8) != rootBytes {
            guard let parent = directory.parentPath,
                  paths.contains(Data(parent.rawValue.utf8)) else {
                throw .missingParent(directory.path)
            }
        }
        self.rootPath = rootPath
        self.directories = canonical
    }
}

public struct HistoricalCalibrationScanResult: Sendable, Equatable {
    public let report: CalibrationReport
    public let evidence: HistoricalCalibrationScanEvidence?

    public init(
        report: CalibrationReport,
        evidence: HistoricalCalibrationScanEvidence?
    ) throws(HistoricalCalibrationScanEvidenceError) {
        guard (report.coverage == .complete) == (evidence != nil) else {
            throw .reportEvidenceMismatch
        }
        self.report = report
        self.evidence = evidence
    }
}

public enum HistoricalCalibrationScanEvidenceError: Error, Sendable, Equatable {
    case incompleteDirectChildren(DirtyRegionPath)
    case emptyDirectories
    case duplicatePath
    case invalidRoot
    case missingParent(DirtyRegionPath)
    case reportEvidenceMismatch
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
