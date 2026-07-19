import AppKit
import SwiftUI

struct MenuBarStatusView: View {
    @Bindable var model: DirectoryAuthorizationViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.status.symbolName)
                    .font(.title2)
                    .foregroundStyle(model.status.symbolColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status.title)
                        .font(.headline)
                    Text(model.status.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)

            Divider()

            Button("打开 SpaceTrace") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityIdentifier("menu-bar-open-main-window")

            if case .unavailable = model.status {
                Button("重新检查目录") {
                    Task { await model.refresh() }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("menu-bar-refresh-directory")
            }

            Divider()

            Button("退出 SpaceTrace") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(16)
        .frame(width: 320)
    }
}
