import Foundation
import SpaceTraceApplication
import SpaceTraceDomain

public enum DirectoryHistoryBucket: String, Sendable, Equatable, Codable {
    case hourly
    case daily

    var durationMilliseconds: Int64 {
        switch self {
        case .hourly: 3_600_000
        case .daily: 86_400_000
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
}

public struct DirectoryGrowth: Sendable, Equatable {
    public let path: DirtyRegionPath
    public let logicalByteDelta: Int64
}

public struct PathFreeCalibrationRequirement: Sendable, Equatable {
    public let streamID: EventStreamID
    public let scopeID: WatchedScopeID?
    public let reasons: DirtyRegionReason
    public let createdAt: Date
}
