import SwiftUI

struct ContentView: View {
    @Bindable var model: DirectoryAuthorizationViewModel
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
            await model.monitorUnavailableScope()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(status: model.status) {
                selection = .permissions
            }
        case .permissions:
            DirectoryAuthorizationView(model: model)
        }
    }
}

#Preview {
    ContentView(
        model: DirectoryAuthorizationViewModel(
            initialStatus: .unconfigured
        )
    )
}
