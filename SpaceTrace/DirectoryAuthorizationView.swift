import SwiftUI

struct DirectoryAuthorizationView: View {
    @Bindable var model: DirectoryAuthorizationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                authorizationCard
                privacyNote
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("目录授权")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("目录授权")
                .font(.largeTitle.weight(.semibold))
            Text("SpaceTrace 只读取你主动选择目录中的文件系统元数据，用于解释磁盘空间变化。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var authorizationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: model.status.symbolName)
                        .font(.title2)
                        .foregroundStyle(model.status.symbolColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.status.title)
                            .font(.headline)
                            .accessibilityIdentifier("authorization-status-title")
                        Text(model.status.detail)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("authorization-status-detail")
                    }
                    Spacer(minLength: 0)
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在更新目录授权")
                    }
                }

                Divider()
                actions
            }
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目录授权状态")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            switch model.status {
            case .loading:
                EmptyView()
            case .unconfigured:
                Button("选择目录…") {
                    Task { await model.chooseDirectory() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("choose-directory-button")
            case .authorized:
                Button("更换目录…") {
                    Task { await model.chooseDirectory() }
                }
                .accessibilityIdentifier("replace-directory-button")
                Button("移除授权", role: .destructive) {
                    Task { await model.revoke() }
                }
                .accessibilityIdentifier("revoke-directory-button")
            case .unavailable:
                Button("重新检查") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("refresh-directory-button")
                Button("重新授权…") {
                    Task { await model.chooseDirectory() }
                }
                .accessibilityIdentifier("reauthorize-directory-button")
                Button("移除授权", role: .destructive) {
                    Task { await model.revoke() }
                }
                .accessibilityIdentifier("revoke-directory-button")
            case .requiresReauthorization:
                Button("重新授权…") {
                    Task { await model.chooseDirectory() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("reauthorize-directory-button")
                Button("移除授权", role: .destructive) {
                    Task { await model.revoke() }
                }
                .accessibilityIdentifier("revoke-directory-button")
            case .failed:
                Button("重试") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("retry-authorization-button")
                Button(model.hasConfiguredScope ? "重新授权…" : "选择目录…") {
                    Task { await model.chooseDirectory() }
                }
                .accessibilityIdentifier(
                    model.hasConfiguredScope
                        ? "reauthorize-directory-button"
                        : "choose-directory-button"
                )
                if model.hasConfiguredScope {
                    Button("移除授权", role: .destructive) {
                        Task { await model.revoke() }
                    }
                    .accessibilityIdentifier("revoke-directory-button")
                }
            }
        }
        .disabled(model.isBusy)
    }

    private var privacyNote: some View {
        Label(
            "授权为只读，并保存在此 Mac 的 SpaceTrace 沙盒中。移除授权不会删除被监控目录中的任何文件。",
            systemImage: "lock.shield"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
