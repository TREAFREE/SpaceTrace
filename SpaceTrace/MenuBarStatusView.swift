import AppKit
import SpaceTraceApplication
import SpaceTraceDomain
import SwiftUI

struct MenuBarStatusView: View {
    @Bindable var authorizationModel: DirectoryAuthorizationViewModel
    @Bindable var baselineModel: BaselineScanViewModel
    @Bindable var statusModel: MenuBarStatusViewModel
    @Bindable var recoveryModel: DatabaseRecoveryViewModel
    @Environment(\.openWindow) private var openWindow

    private var operationalState: MenuBarOperationalState {
        .resolve(
            storage: statusModel.storageState,
            authorization: authorizationModel.summary,
            baseline: baselineModel.state,
            recoveryIsActive: recoveryModel.overview != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            evidencePanel
            qualificationDiagnosticsIndicator
            backgroundWarning
            Divider()
            actions
        }
        .padding(18)
        .frame(width: 360)
        .background {
            SpaceTracePageBackground()
        }
        .accessibilityIdentifier("menu-bar-status")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: operationalState.symbolName)
                .font(.title2)
                .foregroundStyle(operationalState.color)
                .frame(width: 44, height: 44)
                .background(
                    operationalState.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("SpaceTrace")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(operationalState.title)
                    .font(.spaceTraceSectionTitle)
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(operationalState.title)。\(statusDetail)"
        )
    }

    private var evidencePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            storageEvidence
            Divider()
            reconciliationEvidence
        }
        .font(.callout)
        .padding(14)
        .spaceTraceCompactSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("空间证据摘要")
    }

    @ViewBuilder
    private var storageEvidence: some View {
        switch statusModel.storageState {
        case .loading:
            LabeledContent("启动卷当前可用") {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在读取")
            }
        case .failed:
            LabeledContent("启动卷当前可用", value: "读取失败")
        case let .loaded(status):
            LabeledContent(
                "启动卷当前可用",
                value: status.currentAvailableBytes.map(formatBytes) ?? "未知"
            )
            LabeledContent(
                "24 小时可用空间变化",
                value: qualifiedDeltaText(status)
            )
            if let observedAt = status.currentObservedAt {
                LabeledContent(
                    "最近空间采样",
                    value: observedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            }
        }
    }

    private var reconciliationEvidence: some View {
        LabeledContent(
            "最近目录校准",
            value: baselineModel.lastReconciliationAt.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "尚未完成"
        )
    }

    @ViewBuilder
    private var qualificationDiagnosticsIndicator: some View {
        if statusModel.qualificationDiagnosticsActive {
            Label(
                "资格诊断正在本机记录；内容不含路径，最长保留 7 天。",
                systemImage: "waveform.path.ecg"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(
                "menu-bar-qualification-diagnostics"
            )
        }
    }

    @ViewBuilder
    private var backgroundWarning: some View {
        if statusModel.backgroundState.consecutiveSampleFailureCount > 0 {
            Label(
                "最近一次后台采样失败；旧结果不会冒充当前结果。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("menu-bar-sampling-warning")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("打开 SpaceTrace") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .keyboardShortcut("o", modifiers: .command)
            .help("打开 SpaceTrace 主窗口（⌘O）")
            .accessibilityIdentifier("menu-bar-open-main-window")

            Button("立即刷新状态") {
                Task {
                    await statusModel.refresh()
                    if authorizationModel.hasUnavailableScope {
                        await authorizationModel.refresh()
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(authorizationModel.isBusy)
            .help("重新读取启动卷与目录授权状态")
            .accessibilityIdentifier("menu-bar-refresh-status")

            Divider()

            Button("退出 SpaceTrace") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var statusDetail: String {
        switch statusModel.storageState {
        case .loading:
            String(localized: "正在读取启动卷空间证据。")
        case .failed:
            String(localized: "本次读取失败，请刷新；旧值不会被当成当前结果。")
        case let .loaded(status):
            switch status.qualification {
            case .qualified:
                String(localized: "采样连续、时间顺序有效，且启动卷身份未变化。")
            case .collecting:
                String(localized: "尚未积累满 24 小时连续采样。")
            case .stale:
                String(localized: "最近采样已过期，等待下一次可靠采样。")
            case .samplingGap:
                String(localized: "24 小时窗口内存在采样缺口，暂不计算变化。")
            case .clockDiscontinuity:
                String(localized: "检测到系统时间变化，已断开跨时间异常比较。")
            case .volumeIdentityChanged:
                String(localized: "启动卷身份发生变化，已断开跨卷比较。")
            case .historyLimitReached:
                String(localized: "最近历史不足以形成可靠的 24 小时端点。")
            case .unavailable:
                String(localized: "启动卷容量指标当前不可用。")
            }
        }
    }

    private func qualifiedDeltaText(
        _ status: StartupVolume24HourStatus
    ) -> String {
        guard status.qualification == .qualified,
              case let .volumeAvailable(bytes)? = status.change else {
            return "证据不足"
        }
        let magnitude: Int64
        if bytes == .min {
            return "数值超出范围"
        } else {
            magnitude = abs(bytes)
        }
        let prefix = bytes > 0 ? "+" : bytes < 0 ? "−" : ""
        return prefix + ByteCountFormatter.string(
            fromByteCount: magnitude,
            countStyle: .binary
        )
    }

    private func formatBytes(_ bytes: ByteCount) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes.value,
            countStyle: .binary
        )
    }
}

private extension MenuBarOperationalState {
    var color: Color {
        switch self {
        case .healthy: .green
        case .scanning: .blue
        case .paused, .limitedEvidence, .attentionRequired: .orange
        case .unavailable: .red
        }
    }
}
