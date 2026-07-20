import Foundation
import Observation
import SpaceTraceApplication
import SpaceTraceMonitoring
import SwiftUI

protocol WatchedScopeAuthorizationCoordinating: Sendable {
    func start() async throws -> WatchedScopeRestorationReport
    func refresh() async throws -> WatchedScopeRestorationReport
    func authorize(
        selectedURL: URL,
        scopeID: WatchedScopeID
    ) async throws -> WatchedScopeRestorationReport
    func revoke(scopeID: WatchedScopeID) async throws -> WatchedScopeRestorationReport
}

extension WatchedScopeAuthorizationCoordinator: WatchedScopeAuthorizationCoordinating {}

enum DirectoryAuthorizationStatus: Equatable {
    case loading
    case unconfigured
    case authorized(path: String)
    case unavailable
    case requiresReauthorization(reason: WatchedScopeRestorationFailureCode)
    case failed

    var title: LocalizedStringKey {
        switch self {
        case .loading:
            "正在检查授权"
        case .unconfigured:
            "尚未选择目录"
        case .authorized:
            "目录已授权"
        case .unavailable:
            "目录当前不可用"
        case .requiresReauthorization:
            "需要重新授权"
        case .failed:
            "无法读取授权状态"
        }
    }

    var detail: String {
        switch self {
        case .loading:
            String(localized: "正在恢复保存在此 Mac 上的只读目录授权。")
        case .unconfigured:
            String(localized: "请选择一个目录。系统目录选择器只会授权你明确确认的位置。")
        case let .authorized(path):
            path
        case .unavailable:
            String(localized: "目录所在的卷可能尚未连接。卷返回后将自动重试，也可以立即重新检查。")
        case let .requiresReauthorization(reason):
            reason.userFacingExplanation
        case .failed:
            String(localized: "SpaceTrace 保持停止访问。请重试；如果问题持续，请重新启动应用。")
        }
    }

    var symbolName: String {
        switch self {
        case .loading: "hourglass"
        case .unconfigured: "folder.badge.questionmark"
        case .authorized: "checkmark.shield"
        case .unavailable: "externaldrive.badge.questionmark"
        case .requiresReauthorization: "exclamationmark.shield"
        case .failed: "xmark.octagon"
        }
    }

    var symbolColor: Color {
        switch self {
        case .authorized: .green
        case .unavailable, .requiresReauthorization: .orange
        case .failed: .red
        case .loading, .unconfigured: .secondary
        }
    }
}

@MainActor
@Observable
final class DirectoryAuthorizationViewModel {
    private static let defaultScopeIDValue = "primary-user-selected"

    private let picker: any DirectorySelecting
    private var coordinator: (any WatchedScopeAuthorizationCoordinating)?
    private var currentScopeID: WatchedScopeID?
    private(set) var status: DirectoryAuthorizationStatus
    private(set) var isBusy = false

    var hasConfiguredScope: Bool {
        currentScopeID != nil
    }

    var authorizedScopeID: WatchedScopeID? {
        guard case .authorized = status else { return nil }
        return currentScopeID
    }

    init(
        picker: (any DirectorySelecting)? = nil,
        coordinator: (any WatchedScopeAuthorizationCoordinating)? = nil,
        initialStatus: DirectoryAuthorizationStatus = .loading
    ) {
        self.picker = picker ?? SystemDirectoryPicker()
        self.coordinator = coordinator
        status = initialStatus
    }

    func connect(_ coordinator: any WatchedScopeAuthorizationCoordinating) {
        self.coordinator = coordinator
    }

    func start() async {
        guard let coordinator else {
            status = .failed
            return
        }
        await perform {
            try await coordinator.start()
        }
    }

    func chooseDirectory() async {
        guard isBusy == false, let coordinator else { return }
        guard let selectedURL = await picker.selectDirectory() else { return }
        defer { selectedURL.stopAccessingSecurityScopedResource() }

        let scopeID: WatchedScopeID
        do {
            scopeID = try currentScopeID ?? WatchedScopeID(Self.defaultScopeIDValue)
        } catch {
            status = .failed
            return
        }
        await perform {
            try await coordinator.authorize(
                selectedURL: selectedURL,
                scopeID: scopeID
            )
        }
    }

    func revoke() async {
        guard let coordinator, let currentScopeID else { return }
        await perform {
            try await coordinator.revoke(scopeID: currentScopeID)
        }
    }

    func refresh() async {
        guard let coordinator else { return }
        await perform {
            try await coordinator.refresh()
        }
    }

    func refreshIfNeeded() async {
        guard isBusy == false else { return }
        switch status {
        case .unavailable, .failed:
            await refresh()
        case .loading, .unconfigured, .authorized, .requiresReauthorization:
            break
        }
    }

    func monitorUnavailableScope() async {
        while Task.isCancelled == false {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard case .unavailable = status else { continue }
            await refresh()
        }
    }

    func handleCompositionFailure() {
        status = .failed
    }

#if DEBUG
    @discardableResult
    func loadUITestScenarioIfConfigured() -> Bool {
        guard let scenario = ProcessInfo.processInfo.environment["SPACETRACE_UI_TEST_SCENARIO"] else {
            return false
        }
        switch scenario {
        case "unconfigured":
            status = .unconfigured
        case "authorized":
            status = .authorized(path: "/Volumes/SpaceTraceFixture/Selected")
        case "unavailable":
            status = .unavailable
        case "stale":
            status = .requiresReauthorization(reason: .staleBookmark)
        default:
            status = .failed
        }
        return true
    }
#endif

    private func perform(
        _ operation: () async throws -> WatchedScopeRestorationReport
    ) async {
        guard isBusy == false else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await operation())
        } catch is CancellationError {
            return
        } catch {
            status = .failed
        }
    }

    private func apply(_ report: WatchedScopeRestorationReport) {
        if let scope = report.scopes.first {
            currentScopeID = scope.id
            status = .authorized(path: scope.root.rawValue)
            return
        }
        if let failure = report.failures.first {
            currentScopeID = failure.scopeID
            status = failure.code == .resourceUnavailable
                ? .unavailable
                : .requiresReauthorization(reason: failure.code)
            return
        }
        currentScopeID = nil
        status = report.configuredScopeCount == 0 ? .unconfigured : .failed
    }
}

private extension WatchedScopeRestorationFailureCode {
    var userFacingExplanation: String {
        switch self {
        case .staleBookmark:
            String(localized: "之前保存的目录授权已过期。请再次选择该目录以确认访问。")
        case .accessDenied:
            String(localized: "macOS 不再允许访问此目录。请重新选择目录；SpaceTrace 不会反复弹出系统提示。")
        case .rootIdentityChanged:
            String(localized: "目录身份已变化。为避免访问错误位置，请重新选择要监控的目录。")
        case .volumeIdentityChanged:
            String(localized: "同一挂载位置出现了不同的卷。SpaceTrace 已停止访问，请明确重新授权。")
        case .invalidResource:
            String(localized: "保存的位置不再是可安全监控的目录。请选择一个真实目录，不要选择符号链接。")
        case .resourceUnavailable:
            String(localized: "目录当前不可用。")
        }
    }
}
