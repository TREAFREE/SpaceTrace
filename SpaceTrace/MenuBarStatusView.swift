import AppKit
import SwiftUI

struct MenuBarStatusView: View {
    @Bindable var model: DirectoryAuthorizationViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.summary.symbolName)
                    .font(.title2)
                    .foregroundStyle(model.summary.symbolColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.summary.title)
                        .font(.headline)
                    Text(model.summary.detail)
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

            if model.hasUnavailableScope {
                Button("重新检查目录状态") {
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
