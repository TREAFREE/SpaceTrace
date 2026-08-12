import SpaceTraceApplication
import SwiftUI

struct DiagnosticExportView: View {
    @Bindable var model: DiagnosticExportViewModel
    @Bindable var historicalFindingsModel: HistoricalFindingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpaceTraceDesign.sectionSpacing) {
                SpaceTracePageHeader(
                    eyebrow: "隐私可核验",
                    title: "导出诊断信息",
                    detail: "先检查导出范围，再由你选择保存位置。默认路径会使用本次导出独立的不可逆标记；SpaceTrace 不读取文件内容，也不会自动上传。",
                    symbol: "doc.badge.arrow.up"
                )

                if let preview = model.preview {
                    privacyPanel(preview)
                    previewPanel(preview)
                    findingPanel
                    actionPanel
                } else {
                    unavailablePanel
                }
            }
            .frame(maxWidth: SpaceTraceDesign.contentMaxWidth, alignment: .leading)
            .padding(SpaceTraceDesign.pagePadding)
        }
        .accessibilityIdentifier("diagnostic-export-page")
        .alert(
            "导出完整路径？",
            isPresented: Binding(
                get: { model.requiresRawPathConfirmation },
                set: { if $0 == false { model.dismissRawPathConfirmation() } }
            )
        ) {
            Button("保持默认脱敏", role: .cancel) {
                model.useRedactedPaths()
            }
            Button("仅本次导出完整路径", role: .destructive) {
                model.confirmFullPaths()
            }
        } message: {
            Text("完整路径可能包含用户名、项目名和私人目录名。授权只绑定当前这一次导出，下一次必须重新确认。")
        }
        .onAppear(perform: refreshSource)
        .onChange(of: historicalFindingsModel.overview) {
            refreshSource()
        }
    }

    private func privacyPanel(
        _ preview: DiagnosticExportPreview
    ) -> some View {
        GroupBox("路径隐私") {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preview.pathMode == .redacted ? "默认脱敏" : "包含完整路径")
                            .font(.spaceTraceCardTitle)
                        Text(preview.pathMode == .redacted
                             ? "用户名、授权根目录和下级路径组件会替换为仅本次有效的标记。"
                             : "当前导出将包含原始路径；保存或取消后，此授权立即失效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: preview.pathMode == .redacted
                          ? "eye.slash.fill"
                          : "exclamationmark.shield.fill")
                        .foregroundStyle(preview.pathMode == .redacted ? .green : .orange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("diagnostic-export-path-mode")

                HStack {
                    Button("使用默认脱敏") {
                        model.useRedactedPaths()
                    }
                    .disabled(preview.pathMode == .redacted || model.state == .saving)
                    .accessibilityIdentifier("diagnostic-export-redacted-button")

                    Button("包含完整路径…") {
                        model.requestFullPaths()
                    }
                    .disabled(preview.pathMode == .fullPaths || model.state == .saving)
                    .accessibilityIdentifier("diagnostic-export-full-paths-button")
                }
            }
        }
    }

    private func previewPanel(
        _ preview: DiagnosticExportPreview
    ) -> some View {
        GroupBox("写入前预览") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(preview.sections, id: \.kind) { section in
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: section.kind))
                            .foregroundStyle(.tint)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(title(for: section.kind))
                        Spacer()
                        Text("\(section.itemCount)")
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "diagnostic-export-section-\(section.kind.rawValue)"
                    )
                }
                Divider()
                Label("不包含文件内容；不会自动上传", systemImage: "checkmark.shield")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagnostic-export-no-upload")
            }
        }
    }

    private var findingPanel: some View {
        GroupBox("选择发现") {
            if model.findingSelections.isEmpty {
                Text("当前没有可导出的历史发现。系统、覆盖范围和健康事件仍可导出。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("已选择 \(model.selectedFindingCount) / \(DiagnosticExportBuilder.maximumSelectedFindingCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.findingSelections) { finding in
                        Button {
                            model.toggleFinding(finding.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: finding.isSelected
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundStyle(
                                        finding.isSelected
                                            ? Color.accentColor
                                            : Color(nsColor: .secondaryLabelColor)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.title)
                                        .lineLimit(1)
                                    Text(finding.kind.rawValue)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.state == .saving)
                        .accessibilityLabel(finding.title)
                        .accessibilityValue(finding.isSelected ? "已选择" : "未选择")
                        .accessibilityIdentifier(
                            "diagnostic-export-finding-\(finding.id.rawValue)"
                        )
                    }
                }
            }
        }
    }

    private var actionPanel: some View {
        GroupBox("保存到此 Mac") {
            VStack(alignment: .leading, spacing: 14) {
                statusMessage
                HStack {
                    if model.state == .saving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在准备诊断导出")
                        Button("取消") {
                            model.cancelExport()
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("diagnostic-export-cancel-button")
                    } else {
                        Button("选择保存位置…") {
                            model.beginExport()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("diagnostic-export-save-button")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch model.state {
        case .unavailable:
            Text("历史概览尚未就绪，暂时无法生成准确的导出预览。")
                .foregroundStyle(.secondary)
        case .ready:
            Text("准备就绪。保存面板打开后，只有你选择的那个文件获得写入权限。")
                .foregroundStyle(.secondary)
        case .saving:
            Text("正在生成并原子写入；取消不会留下半成品。")
                .foregroundStyle(.secondary)
        case let .saved(fileName):
            Label("已保存 \(fileName)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("diagnostic-export-saved")
        case .failed:
            Label("导出失败，现有文件未被部分内容替换。请重试。", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .accessibilityIdentifier("diagnostic-export-failed")
        }
    }

    private var unavailablePanel: some View {
        GroupBox("暂时无法导出") {
            Label {
                Text("请先授权目录并等待历史概览加载完成。SpaceTrace 不会用不完整数据伪造诊断包。")
            } icon: {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("diagnostic-export-unavailable")
    }

    private func refreshSource() {
        do {
            model.configure(
                source: try DiagnosticExportSourceFactory.make(
                    from: historicalFindingsModel
                )
            )
        } catch {
            model.configure(source: nil)
        }
    }

    private func title(for kind: DiagnosticExportPreviewSectionKind) -> LocalizedStringKey {
        switch kind {
        case .system: "应用与系统信息"
        case .coverage: "授权范围与覆盖状态"
        case .healthEvents: "类型化健康事件"
        case .selectedFindings: "已选择的历史发现"
        }
    }

    private func symbol(for kind: DiagnosticExportPreviewSectionKind) -> String {
        switch kind {
        case .system: "desktopcomputer"
        case .coverage: "scope"
        case .healthEvents: "waveform.path.ecg"
        case .selectedFindings: "list.bullet.rectangle"
        }
    }
}
