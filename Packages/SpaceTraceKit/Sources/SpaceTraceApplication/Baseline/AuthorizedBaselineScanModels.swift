import Foundation
import SpaceTraceDomain

public struct AuthorizedBaselineScanContext: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let root: DirtyRegionPath
    public let streamID: EventStreamID
    /// The persistent identity of the volume containing `root`.
    ///
    /// `nil` means the monitoring runtime could not establish the identity.
    /// Callers must keep that state unknown rather than inferring a volume
    /// from the path text.
    public let volumeUUID: UUID?

    public init(
        scopeID: WatchedScopeID,
        root: DirtyRegionPath,
        streamID: EventStreamID,
        volumeUUID: UUID? = nil
    ) {
        self.scopeID = scopeID
        self.root = root
        self.streamID = streamID
        self.volumeUUID = volumeUUID
    }
}

public protocol AuthorizedBaselineScanContextProviding: Sendable {
    func context(for scopeID: WatchedScopeID) async throws -> AuthorizedBaselineScanContext
}

public enum AuthorizedBaselineScanContextError: Error, Sendable, Equatable {
    case scopeNotAuthorized
    case monitoringNotReady
}

public struct AuthorizedBaselineScanRequest: Sendable, Equatable {
    public static let maximumScopeCount = 64
    public let scopeIDs: [WatchedScopeID]

    public init(
        scopeIDs: [WatchedScopeID]
    ) throws(AuthorizedBaselineScanRequestError) {
        guard scopeIDs.isEmpty == false else { throw .emptyScopes }
        guard scopeIDs.count <= Self.maximumScopeCount else {
            throw .tooManyScopes(maximum: Self.maximumScopeCount)
        }
        guard Set(scopeIDs).count == scopeIDs.count else { throw .duplicateScope }
        self.scopeIDs = scopeIDs.sorted { $0.rawValue < $1.rawValue }
    }

    init(singleScopeID: WatchedScopeID) {
        scopeIDs = [singleScopeID]
    }
}

public enum AuthorizedBaselineScanRequestError: Error, Sendable, Equatable {
    case emptyScopes
    case tooManyScopes(maximum: Int)
    case duplicateScope
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
    public enum Origin: Sendable, Equatable {
        case completedScan
        case restoredAfterRestart
    }

    public let snapshot: AuthorizedBaselineSnapshot
    public let root: AuthorizedBaselineRootSnapshot
    public let origin: Origin

    public var context: AuthorizedBaselineScanContext { root.context }
    public var logicalBytes: ByteCount { root.logicalBytes }
    public var allocatedBytes: ByteCount { root.allocatedBytes }
    public var descendantCount: Int64 { root.descendantCount }
    public var startedAt: Date { snapshot.startedAt }
    public var completedAt: Date { snapshot.committedAt }

    public init(
        snapshot: AuthorizedBaselineSnapshot,
        scopeID: WatchedScopeID,
        origin: Origin
    ) throws(AuthorizedBaselineSnapshotError) {
        guard let root = snapshot.root(for: scopeID) else {
            throw .requestedScopeMissing
        }
        self.snapshot = snapshot
        self.root = root
        self.origin = origin
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
    public let completedRootCount: Int
    public let totalRootCount: Int
    public let unreadableRootCount: Int

    public init(
        context: AuthorizedBaselineScanContext,
        reason: AuthorizedBaselineIncompleteReason,
        report: CalibrationReport,
        startedAt: Date,
        completedAt: Date,
        completedRootCount: Int = 0,
        totalRootCount: Int = 1,
        unreadableRootCount: Int = 1
    ) {
        self.context = context
        self.reason = reason
        self.report = report
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.completedRootCount = completedRootCount
        self.totalRootCount = totalRootCount
        self.unreadableRootCount = unreadableRootCount
    }
}

public struct AuthorizedBaselineScanCancellation: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let requestedScopeIDs: [WatchedScopeID]
    public let context: AuthorizedBaselineScanContext?
    public let startedAt: Date
    public let cancelledAt: Date
    public let completedRootCount: Int

    public init(
        scopeID: WatchedScopeID,
        requestedScopeIDs: [WatchedScopeID]? = nil,
        context: AuthorizedBaselineScanContext?,
        startedAt: Date,
        cancelledAt: Date,
        completedRootCount: Int = 0
    ) {
        self.scopeID = scopeID
        self.requestedScopeIDs = requestedScopeIDs ?? [scopeID]
        self.context = context
        self.startedAt = startedAt
        self.cancelledAt = cancelledAt
        self.completedRootCount = completedRootCount
    }
}

public struct AuthorizedBaselineScanDeferral: Sendable, Equatable {
    public let request: AuthorizedBaselineScanRequest
    public let context: AuthorizedBaselineScanContext?
    public let reason: AuthorizedBaselineScanDeferralReason
    public let snapshot: ScanSchedulingSnapshot
    public let startedAt: Date
    public let deferredAt: Date
    public let completedRootCount: Int

    public init(
        request: AuthorizedBaselineScanRequest,
        context: AuthorizedBaselineScanContext?,
        reason: AuthorizedBaselineScanDeferralReason,
        snapshot: ScanSchedulingSnapshot,
        startedAt: Date,
        deferredAt: Date,
        completedRootCount: Int
    ) {
        self.request = request
        self.context = context
        self.reason = reason
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.deferredAt = deferredAt
        self.completedRootCount = completedRootCount
    }
}

public struct AuthorizedBaselineScanResume: Sendable, Equatable {
    public let request: AuthorizedBaselineScanRequest
    public let context: AuthorizedBaselineScanContext?
    public let clearedReason: AuthorizedBaselineScanDeferralReason
    public let snapshot: ScanSchedulingSnapshot
    public let startedAt: Date
    public let resumedAt: Date
    public let completedRootCount: Int

    public init(
        request: AuthorizedBaselineScanRequest,
        context: AuthorizedBaselineScanContext?,
        clearedReason: AuthorizedBaselineScanDeferralReason,
        snapshot: ScanSchedulingSnapshot,
        startedAt: Date,
        resumedAt: Date,
        completedRootCount: Int
    ) {
        self.request = request
        self.context = context
        self.clearedReason = clearedReason
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.resumedAt = resumedAt
        self.completedRootCount = completedRootCount
    }
}

public enum AuthorizedBaselineScanFailureCode: Sendable, Equatable {
    case scopeNotAuthorized
    case monitoringNotReady
    case publishedRootMissing
    case baselinePersistenceFailed
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
    case preparing(request: AuthorizedBaselineScanRequest, startedAt: Date)
    case deferred(AuthorizedBaselineScanDeferral)
    case resuming(AuthorizedBaselineScanResume)
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
