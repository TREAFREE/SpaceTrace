import SwiftUI

enum SpaceTraceSection: String, CaseIterable, Hashable, Identifiable {
    case overview
    case permissions
    case diagnostics

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "概览"
        case .permissions: "目录授权"
        case .diagnostics: "诊断导出"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .permissions: "folder.badge.gearshape"
        case .diagnostics: "doc.badge.arrow.up"
        }
    }

    var accessibilityIdentifier: String {
        "navigation-\(rawValue)"
    }
}

enum OverviewReadiness: Equatable {
    case preparing
    case needsAuthorization
    case ready(authorizedCount: Int)
    case needsAttention(authorizedCount: Int, issueCount: Int)

    init(summary: DirectoryAuthorizationSummary) {
        switch summary {
        case .loading:
            self = .preparing
        case .unconfigured:
            self = .needsAuthorization
        case let .ready(authorizedCount):
            self = .ready(authorizedCount: authorizedCount)
        case let .needsAttention(authorizedCount, issueCount):
            self = .needsAttention(
                authorizedCount: authorizedCount,
                issueCount: issueCount
            )
        case .failed:
            self = .needsAttention(authorizedCount: 0, issueCount: 0)
        }
    }
}
