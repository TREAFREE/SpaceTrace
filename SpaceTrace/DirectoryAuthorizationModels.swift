import SpaceTraceApplication
import SwiftUI

enum DirectoryAuthorizationStatus: Equatable {
    case authorized(path: String)
    case unavailable
    case requiresReauthorization(reason: WatchedScopeRestorationFailureCode)

    var title: LocalizedStringKey {
        switch self {
        case .authorized:
            "目录已授权"
        case .unavailable:
            "目录当前不可用"
        case .requiresReauthorization:
            "需要重新授权"
        }
    }

    var detail: String {
        switch self {
        case let .authorized(path):
            path
        case .unavailable:
            String(localized: "目录所在的卷可能尚未连接。卷返回后将自动重试，也可以立即重新检查。")
        case let .requiresReauthorization(reason):
            reason.userFacingExplanation
        }
    }

    var symbolName: String {
        switch self {
        case .authorized: "checkmark.shield"
        case .unavailable: "externaldrive.badge.questionmark"
        case .requiresReauthorization: "exclamationmark.shield"
        }
    }

    var symbolColor: Color {
        switch self {
        case .authorized: .green
        case .unavailable, .requiresReauthorization: .orange
        }
    }
}

struct DirectoryAuthorizationItem: Identifiable, Equatable {
    let id: WatchedScopeID
    let status: DirectoryAuthorizationStatus

    var isAuthorized: Bool {
        if case .authorized = status { return true }
        return false
    }
}

enum DirectoryAuthorizationSummary: Equatable {
    case loading
    case unconfigured
    case ready(authorizedCount: Int)
    case needsAttention(authorizedCount: Int, issueCount: Int)
    case failed

    var title: LocalizedStringKey {
        switch self {
        case .loading: "正在检查授权"
        case .unconfigured: "尚未选择目录"
        case .ready: "目录授权已就绪"
        case .needsAttention: "部分目录需要处理"
        case .failed: "无法读取授权状态"
        }
    }

    var detail: String {
        switch self {
        case .loading:
            String(localized: "正在恢复保存在此 Mac 上的只读目录授权。")
        case .unconfigured:
            String(localized: "请选择一个或多个目录。系统目录选择器只会授权你明确确认的位置。")
        case let .ready(authorizedCount):
            String(localized: "已恢复 \(authorizedCount) 个只读目录授权，可以建立覆盖范围明确的批量基线。")
        case let .needsAttention(authorizedCount, issueCount):
            String(localized: "\(authorizedCount) 个目录可用，\(issueCount) 个目录暂不可用或需要重新授权。健康目录仍保持独立授权。")
        case .failed:
            String(localized: "SpaceTrace 不会依据不完整状态启动新扫描。请重试；如果问题持续，请重新启动应用。")
        }
    }

    var symbolName: String {
        switch self {
        case .loading: "hourglass"
        case .unconfigured: "folder.badge.questionmark"
        case .ready: "checkmark.shield"
        case .needsAttention: "exclamationmark.shield"
        case .failed: "xmark.octagon"
        }
    }

    var symbolColor: Color {
        switch self {
        case .ready: .green
        case .needsAttention: .orange
        case .failed: .red
        case .loading, .unconfigured: .secondary
        }
    }
}

enum DirectoryAuthorizationOperationError: Equatable {
    case scopeLimitReached
    case scopeIdentityUnavailable
    case authorizationFailed
    case revocationFailed
    case refreshFailed

    var detail: String {
        switch self {
        case .scopeLimitReached:
            String(localized: "第一阶段最多同时配置 64 个目录。请先移除不再需要的授权。")
        case .scopeIdentityUnavailable:
            String(localized: "无法为新目录生成安全的本机标识。现有授权没有改变，请重试。")
        case .authorizationFailed:
            String(localized: "目录授权未能安全保存。现有授权和监控状态已经保留或恢复。")
        case .revocationFailed:
            String(localized: "未能安全移除该授权。目录条目仍然保留，可以稍后重试。")
        case .refreshFailed:
            String(localized: "未能重新检查目录状态。现有授权没有被删除。")
        }
    }
}

extension WatchedScopeRestorationFailureCode {
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
