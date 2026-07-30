import SpaceTraceApplication
import SwiftUI

struct DirectoryAuthorizationView: View {
    @Bindable var model: DirectoryAuthorizationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpaceTraceDesign.sectionSpacing) {
                header
                summaryCard
                directoryList
                privacyNote
            }
            .spaceTracePageLayout()
        }
        .navigationTitle("目录授权")
        .alert(
            "操作未完成",
            isPresented: Binding(
                get: { model.operationError != nil },
                set: { presented in
                    if presented == false { model.dismissOperationError() }
                }
            ),
            presenting: model.operationError
        ) { _ in
            Button("好", role: .cancel) {
                model.dismissOperationError()
            }
        } message: { error in
            Text(error.detail)
        }
    }

    private var header: some View {
        SpaceTracePageHeader(
            eyebrow: "隐私边界",
            title: "目录授权",
            detail: "SpaceTrace 只读取你主动选择目录中的文件系统元数据。每个目录拥有独立授权，可以单独重新确认或移除。",
            symbol: "lock.shield"
        )
    }

    private var summaryCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: model.summary.symbolName)
                        .font(.title2)
                        .foregroundStyle(model.summary.symbolColor)
                        .frame(width: 44, height: 44)
                        .background(
                            model.summary.symbolColor.opacity(0.12),
                            in: Circle()
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.summary.title)
                            .font(.spaceTraceCardTitle)
                            .accessibilityIdentifier("authorization-status-title")
                        Text(model.summary.detail)
                            .foregroundStyle(.secondary)
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
                summaryActions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目录授权概况")
    }

    @ViewBuilder
    private var summaryActions: some View {
        HStack(spacing: 12) {
            if model.summary != .loading, model.summary != .failed {
                Button(model.items.isEmpty ? "选择目录…" : "添加目录…") {
                    Task { await model.addDirectory() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(model.items.isEmpty ? .defaultAction : nil)
                .accessibilityIdentifier(
                    model.items.isEmpty
                        ? "choose-directory-button"
                        : "add-directory-button"
                )
                .disabled(model.canAddDirectory == false)
            }
            if model.hasUnavailableScope || model.summary == .failed {
                Button("重新检查") {
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier("refresh-directories-button")
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private var directoryList: some View {
        if model.items.isEmpty == false {
            GroupBox("已配置目录（\(model.items.count)）") {
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        directoryRow(item)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("已配置目录列表")
        }
    }

    private func directoryRow(_ item: DirectoryAuthorizationItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.status.symbolName)
                .font(.title3)
                .foregroundStyle(item.status.symbolColor)
                .frame(width: 32, height: 32)
                .background(
                    item.status.symbolColor.opacity(0.12),
                    in: Circle()
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.status.title)
                    .font(.spaceTraceCardTitle)
                    .accessibilityIdentifier("authorization-scope-status-\(item.id.rawValue)")
                Text(item.status.detail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            scopeActions(item)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func scopeActions(_ item: DirectoryAuthorizationItem) -> some View {
        HStack(spacing: 10) {
            if case .unavailable = item.status {
                Button("重新检查") {
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier("refresh-directory-button-\(item.id.rawValue)")
            }

            Button(scopeAuthorizationActionTitle(item.status)) {
                Task { await model.reauthorize(scopeID: item.id) }
            }
            .accessibilityIdentifier("reauthorize-directory-button-\(item.id.rawValue)")

            Button("移除授权", role: .destructive) {
                Task { await model.revoke(scopeID: item.id) }
            }
            .accessibilityIdentifier("revoke-directory-button-\(item.id.rawValue)")
        }
        .disabled(model.isBusy)
    }

    private func scopeAuthorizationActionTitle(
        _ status: DirectoryAuthorizationStatus
    ) -> LocalizedStringKey {
        switch status {
        case .authorized: "更换目录…"
        case .unavailable, .requiresReauthorization: "重新授权…"
        }
    }

    private var privacyNote: some View {
        Label(
            "授权为只读，并保存在此 Mac 的 SpaceTrace 沙盒中。移除授权不会删除被监控目录中的任何文件；添加或移除目录时，正在运行的基线会先安全取消。",
            systemImage: "lock.shield"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
        .spaceTraceCompactSurface()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("隐私说明：授权为只读，移除授权不会删除目录中的文件。")
    }
}
