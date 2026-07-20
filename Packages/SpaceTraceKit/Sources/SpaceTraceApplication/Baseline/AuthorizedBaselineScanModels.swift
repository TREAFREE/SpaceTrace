import Foundation
import SpaceTraceDomain

public struct AuthorizedBaselineScanContext: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let root: DirtyRegionPath
    public let streamID: EventStreamID

    public init(
        scopeID: WatchedScopeID,
        root: DirtyRegionPath,
        streamID: EventStreamID
    ) {
        self.scopeID = scopeID
        self.root = root
        self.streamID = streamID
    }
}

public protocol AuthorizedBaselineScanContextProviding: Sendable {
    func context(for scopeID: WatchedScopeID) async throws -> AuthorizedBaselineScanContext
}

public enum AuthorizedBaselineScanContextError: Error, Sendable, Equatable {
    case scopeNotAuthorized
    case monitoringNotReady
}

public struct AuthorizedBaselineScanProgress: Sendable, Equatable {
    public let context: AuthorizedBaselineScanContext
    public let startedAt: Date
    public let completedRootCount: Int
    public let totalRootCount: Int
    public let unreadableRootCount: Int
    public let entriesVisited: Int64
    public let directoriesObserved: Int64

    public init(
        context: AuthorizedBaselineScanContext,
        startedAt: Date,
        completedRootCount: Int = 0,
        totalRootCount: Int = 1,
        unreadableRootCount: Int = 0,
        entriesVisited: Int64 = 0,
        directoriesObserved: Int64 = 0
    ) {
        self.context = context
        self.startedAt = startedAt
        self.completedRootCount = completedRootCount
        self.totalRootCount = totalRootCount
        self.unreadableRootCount = unreadableRootCount
        self.entriesVisited = entriesVisited
        self.directoriesObserved = directoriesObserved
    }
}

public struct AuthorizedBaselineScanResult: Sendable, Equatable {
    public let context: AuthorizedBaselineScanContext
    public let logicalBytes: ByteCount
    public let allocatedBytes: ByteCount
    public let descendantCount: Int64
    public let report: CalibrationReport
    public let startedAt: Date
    public let completedAt: Date

    public init(
        context: AuthorizedBaselineScanContext,
        logicalBytes: ByteCount,
        allocatedBytes: ByteCount,
        descendantCount: Int64,
        report: CalibrationReport,
        startedAt: Date,
        completedAt: Date
    ) {
        self.context = context
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.descendantCount = descendantCount
        self.report = report
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum AuthorizedBaselineIncompleteReason: Sendable, Equatable {
    case partialCoverage
    case changedDuringScan
}

public struct AuthorizedBaselineIncompleteResult: Sendable, Equatable {
    public let context: AuthorizedBaselineScanContext
    public let reason: AuthorizedBaselineIncompleteReason
    public let report: CalibrationReport
    public let startedAt: Date
    public let completedAt: Date

    public init(
        context: AuthorizedBaselineScanContext,
        reason: AuthorizedBaselineIncompleteReason,
        report: CalibrationReport,
        startedAt: Date,
        completedAt: Date
    ) {
        self.context = context
        self.reason = reason
        self.report = report
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct AuthorizedBaselineScanCancellation: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let context: AuthorizedBaselineScanContext?
    public let startedAt: Date
    public let cancelledAt: Date

    public init(
        scopeID: WatchedScopeID,
        context: AuthorizedBaselineScanContext?,
        startedAt: Date,
        cancelledAt: Date
    ) {
        self.scopeID = scopeID
        self.context = context
        self.startedAt = startedAt
        self.cancelledAt = cancelledAt
    }
}

public enum AuthorizedBaselineScanFailureCode: Sendable, Equatable {
    case scopeNotAuthorized
    case monitoringNotReady
    case publishedRootMissing
    case operationFailed
}

public struct AuthorizedBaselineScanFailure: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let code: AuthorizedBaselineScanFailureCode
    public let failedAt: Date

    public init(
        scopeID: WatchedScopeID,
        code: AuthorizedBaselineScanFailureCode,
        failedAt: Date
    ) {
        self.scopeID = scopeID
        self.code = code
        self.failedAt = failedAt
    }
}

public enum AuthorizedBaselineScanState: Sendable, Equatable {
    case idle
    case preparing(scopeID: WatchedScopeID, startedAt: Date)
    case scanning(AuthorizedBaselineScanProgress)
    case publishing(AuthorizedBaselineScanProgress)
    case completed(AuthorizedBaselineScanResult)
    case incomplete(AuthorizedBaselineIncompleteResult)
    case cancelled(AuthorizedBaselineScanCancellation)
    case failed(AuthorizedBaselineScanFailure)
}

public enum AuthorizedBaselineCalibrationProgress: Sendable, Equatable {
    case scanning(AuthorizedBaselineScanContext)
    case publishing(AuthorizedBaselineScanContext, CalibrationReport)
}

public enum AuthorizedBaselineCalibrationOutcome: Sendable, Equatable {
    case published(DirectoryMetadataAggregate, CalibrationReport)
    case incomplete(CalibrationReport, AuthorizedBaselineIncompleteReason)
}

public protocol AuthorizedBaselineCalibrationRunning: Sendable {
    func run(
        context: AuthorizedBaselineScanContext,
        onProgress: @escaping @Sendable (AuthorizedBaselineCalibrationProgress) async -> Void
    ) async throws -> AuthorizedBaselineCalibrationOutcome
}
