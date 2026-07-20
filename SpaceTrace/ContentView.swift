import SwiftUI
import SpaceTracePersistence

struct ContentView: View {
    @Bindable var authorizationModel: DirectoryAuthorizationViewModel
    @Bindable var baselineScanModel: BaselineScanViewModel
    @Bindable var databaseRecoveryModel: DatabaseRecoveryViewModel
    @State private var selection: SpaceTraceSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(SpaceTraceSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
                    .accessibilityIdentifier(section.accessibilityIdentifier)
            }
            .navigationTitle("SpaceTrace")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .safeAreaInset(edge: .top) {
            if let overview = databaseRecoveryModel.overview {
                DatabaseRecoveryBanner(overview: overview)
            }
        }
        .task {
            await authorizationModel.monitorUnavailableScopes()
        }
        .task {
            await baselineScanModel.monitor()
        }
        .task(id: authorizationModel.authorizedScopeIDs) {
            await baselineScanModel.restore(
                scopeID: authorizationModel.authorizedScopeIDs.first
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(
                authorizationSummary: authorizationModel.summary,
                scopeIDs: authorizationModel.authorizedScopeIDs,
                baselineScanModel: baselineScanModel
            ) {
                selection = .permissions
            }
        case .permissions:
            DirectoryAuthorizationView(model: authorizationModel)
        }
    }
}

#Preview {
    ContentView(
        authorizationModel: DirectoryAuthorizationViewModel(
            initialSummary: .unconfigured
        ),
        baselineScanModel: BaselineScanViewModel(),
        databaseRecoveryModel: DatabaseRecoveryViewModel()
    )
}

private struct DatabaseRecoveryBanner: View {
    let overview: SQLiteReadOnlyRecoveryOverview

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("数据库已进入只读恢复模式")
                    .font(.headline)
                Text("为避免覆盖原始数据，SpaceTrace 已停止扫描和写入。请保留恢复资料并重新打开应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .accessibilityIdentifier("database-recovery-banner")
    }
}
