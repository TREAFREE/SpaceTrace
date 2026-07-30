import SwiftUI
import SpaceTraceApplication
import SpaceTracePersistence

struct ContentView: View {
    @Bindable var authorizationModel: DirectoryAuthorizationViewModel
    @Bindable var baselineScanModel: BaselineScanViewModel
    @Bindable var directoryHistoryModel: DirectoryHistoryViewModel
    @Bindable var databaseRecoveryModel: DatabaseRecoveryViewModel
    @State private var selection: SpaceTraceSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(SpaceTraceSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .font(.body.weight(.medium))
                    .padding(.vertical, 3)
                    .tag(section)
                    .accessibilityIdentifier(section.accessibilityIdentifier)
            }
            .listStyle(.sidebar)
            .navigationTitle("SpaceTrace")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            detail
                .background {
                    SpaceTracePageBackground()
                }
        }
        .navigationSplitViewStyle(.balanced)
        .groupBoxStyle(SpaceTracePanelGroupBoxStyle())
        .frame(minWidth: 820, minHeight: 560)
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
        .task(id: historyContexts) {
            await directoryHistoryModel.load(
                contexts: historyContexts
            )
        }
    }

    private var historyContexts: [AuthorizedBaselineScanContext] {
        baselineScanModel.historyContexts(
            configuredScopeIDs: authorizationModel.configuredScopeIDs
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(
                authorizationSummary: authorizationModel.summary,
                scopeIDs: authorizationModel.authorizedScopeIDs,
                baselineScanModel: baselineScanModel,
                directoryHistoryModel: directoryHistoryModel
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
        directoryHistoryModel: DirectoryHistoryViewModel(),
        databaseRecoveryModel: DatabaseRecoveryViewModel()
    )
}

private struct DatabaseRecoveryBanner: View {
    let overview: SQLiteReadOnlyRecoveryOverview

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("数据库已进入只读恢复模式")
                    .font(.spaceTraceCardTitle)
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
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.orange.opacity(0.35))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("database-recovery-banner")
    }
}
