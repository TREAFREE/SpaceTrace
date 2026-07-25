import Foundation
import Observation
import SpaceTraceApplication
import struct SpaceTraceDomain.ByteCount
import enum SpaceTraceDomain.StorageDelta

enum MenuBarStorageState: Equatable {
    case loading
    case loaded(StartupVolume24HourStatus)
    case failed
}

enum MenuBarOperationalState: Equatable {
    case healthy
    case scanning
    case paused
    case limitedEvidence
    case attentionRequired
    case unavailable

    static func resolve(
        storage: MenuBarStorageState,
        authorization: DirectoryAuthorizationSummary,
        baseline: AuthorizedBaselineScanState,
        recoveryIsActive: Bool
    ) -> Self {
        if recoveryIsActive {
            return .unavailable
        }
        switch authorization {
        case .failed:
            return .unavailable
        case .unconfigured, .needsAttention:
            return .attentionRequired
        case .loading:
            return .limitedEvidence
        case .ready:
            break
        }
        switch baseline {
        case .preparing, .resuming, .scanning, .publishing:
            return .scanning
        case .deferred:
            return .paused
        case .failed, .incomplete:
            return .attentionRequired
        case .idle, .completed, .cancelled:
            break
        }
        switch storage {
        case .loading:
            return .limitedEvidence
        case .failed:
            return .unavailable
        case let .loaded(status):
            return status.qualification == .qualified
                ? .healthy
                : status.qualification == .unavailable
                    ? .unavailable
                    : .limitedEvidence
        }
    }

    var title: String {
        switch self {
        case .healthy: "24 小时证据完整"
        case .scanning: "正在校准目录"
        case .paused: "扫描已安全暂停"
        case .limitedEvidence: "正在积累可靠证据"
        case .attentionRequired: "需要你的处理"
        case .unavailable: "当前结果不可用"
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .scanning: "arrow.trianglehead.2.clockwise.rotate.90"
        case .paused: "pause.circle.fill"
        case .limitedEvidence: "clock.badge.questionmark"
        case .attentionRequired: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.octagon.fill"
        }
    }
}

@MainActor
@Observable
final class MenuBarStatusViewModel {
    private var loader: (any StartupVolume24HourStatusLoading)?
    private let now: () -> Date
    private var isRefreshing = false

    private(set) var storageState: MenuBarStorageState = .loading
    private(set) var backgroundState: StorageHistoryBackgroundState = .stopped

    init(
        loader: (any StartupVolume24HourStatusLoading)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.loader = loader
        self.now = now
    }

    func connect(_ loader: any StartupVolume24HourStatusLoading) {
        self.loader = loader
    }

    func refresh() async {
        guard let loader, isRefreshing == false else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            storageState = .loaded(try await loader.load(through: now()))
        } catch is CancellationError {
            return
        } catch {
            storageState = .failed
        }
    }

    func monitor(
        background: any StorageHistoryBackgroundStateObserving
    ) async {
        let updates = await background.updates()
        var previous = backgroundState
        for await update in updates {
            guard Task.isCancelled == false else { return }
            backgroundState = update
            let shouldRefresh =
                update.lastSuccessfulSampleAt
                    != previous.lastSuccessfulSampleAt
                || update.consecutiveSampleFailureCount
                    != previous.consecutiveSampleFailureCount
                || update.phase != previous.phase
            previous = update
            if shouldRefresh {
                await refresh()
            }
        }
    }

    func handleCompositionFailure() {
        storageState = .failed
        backgroundState = .stopped
    }

#if DEBUG
    func loadUITestFixture() {
        let now = Date()
        storageState = .loaded(
            StartupVolume24HourStatus(
                qualification: .qualified,
                currentAvailableBytes: try? ByteCount(
                    98 * 1_073_741_824
                ),
                currentObservedAt: now,
                baselineObservedAt: now.addingTimeInterval(-86_400),
                change: .volumeAvailable(bytes: -2 * 1_073_741_824)
            )
        )
        backgroundState = StorageHistoryBackgroundState(
            phase: .awake,
            processedEventCount: 25,
            lastSampleTrigger: .periodic,
            lastSampleAttemptAt: now,
            lastSuccessfulSampleAt: now,
            sampleFailureCount: 0,
            consecutiveSampleFailureCount: 0,
            lastRetentionAttemptAt: now,
            lastSuccessfulRetentionAt: now,
            retentionFailureCount: 0
        )
    }
#endif
}
