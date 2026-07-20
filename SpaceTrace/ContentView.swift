import SwiftUI

struct ContentView: View {
    @Bindable var authorizationModel: DirectoryAuthorizationViewModel
    @Bindable var baselineScanModel: BaselineScanViewModel
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
        baselineScanModel: BaselineScanViewModel()
    )
}
