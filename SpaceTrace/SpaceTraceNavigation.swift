import SwiftUI

enum SpaceTraceSection: String, CaseIterable, Hashable, Identifiable {
    case overview
    case permissions

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "概览"
        case .permissions: "目录授权"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .permissions: "folder.badge.gearshape"
        }
    }

    var accessibilityIdentifier: String {
        "navigation-\(rawValue)"
    }
}

enum OverviewReadiness: Equatable {
    case preparing
    case needsAuthorization
    case ready(path: String)
    case needsAttention

    init(status: DirectoryAuthorizationStatus) {
        switch status {
        case .loading:
            self = .preparing
        case .unconfigured:
            self = .needsAuthorization
        case let .authorized(path):
            self = .ready(path: path)
        case .unavailable, .requiresReauthorization, .failed:
            self = .needsAttention
        }
    }
}
