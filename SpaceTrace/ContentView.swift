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
            await authorizationModel.monitorUnavailableScope()
        }
        .task {
            await baselineScanModel.monitor()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(
                authorizationStatus: authorizationModel.status,
                scopeID: authorizationModel.authorizedScopeID,
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
            initialStatus: .unconfigured
        ),
        baselineScanModel: BaselineScanViewModel()
    )
}
