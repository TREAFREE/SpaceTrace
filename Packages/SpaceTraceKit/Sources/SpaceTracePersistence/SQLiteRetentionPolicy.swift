import Foundation

/// The bounded path-bearing history window selected by ADR-004.
public struct SQLiteRetentionPolicy: Sendable, Equatable {
    public static let maximumPathHistoryDays = 30
    public static let `default` = SQLiteRetentionPolicy(knownValidDays: maximumPathHistoryDays)

    public let pathHistoryDays: Int

    public init(pathHistoryDays: Int) throws {
        guard (1...Self.maximumPathHistoryDays).contains(pathHistoryDays) else {
            throw SQLiteRetentionPolicyError.invalidPathHistoryDays(pathHistoryDays)
        }
        self.pathHistoryDays = pathHistoryDays
    }

    private init(knownValidDays: Int) {
        pathHistoryDays = knownValidDays
    }

    func cutoff(referenceDate: Date) -> Date {
        referenceDate.addingTimeInterval(-TimeInterval(pathHistoryDays) * 86_400)
    }
}

public enum SQLiteRetentionPolicyError: Error, Sendable, Equatable {
    case invalidPathHistoryDays(Int)
}

/// Counts rows removed by one atomic retention transaction.
public struct SQLiteRetentionReport: Sendable, Equatable {
    public let deletedNodeCount: Int
    public let baselineCount: Int
    public let scanRunCount: Int
    public let hourlyHistoryCount: Int
    public let pathHistoryCount: Int
    public let agedDirtyPathCount: Int
    public let volumeHistoryCount: Int

    public init(
        deletedNodeCount: Int,
        baselineCount: Int,
        scanRunCount: Int,
        hourlyHistoryCount: Int = 0,
        pathHistoryCount: Int = 0,
        agedDirtyPathCount: Int = 0,
        volumeHistoryCount: Int = 0
    ) {
        self.deletedNodeCount = deletedNodeCount
        self.baselineCount = baselineCount
        self.scanRunCount = scanRunCount
        self.hourlyHistoryCount = hourlyHistoryCount
        self.pathHistoryCount = pathHistoryCount
        self.agedDirtyPathCount = agedDirtyPathCount
        self.volumeHistoryCount = volumeHistoryCount
    }
}
