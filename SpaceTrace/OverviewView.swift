import SwiftUI

struct OverviewView: View {
    let status: DirectoryAuthorizationStatus
    let showPermissions: () -> Void

    private var readiness: OverviewReadiness {
        OverviewReadiness(status: status)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                readinessCard
                workflow
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("概览")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("空间变化，从这里开始")
                .font(.largeTitle.weight(.semibold))
            Text("SpaceTrace 会在本机记录你授权目录的变化，并用可核验的扫描结果解释空间去了哪里。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readinessCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: readinessSymbol)
                    .font(.title)
                    .foregroundStyle(readinessColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(readinessTitle)
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("overview-readiness-title")
                    Text(readinessDetail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(readinessActionTitle) {
                        showPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("overview-permissions-button")
                }

                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("监控准备状态")
    }

    private var workflow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("工作方式")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                WorkflowStep(
                    number: 1,
                    title: "选择目录",
                    detail: "只读访问由你明确选择的位置。",
                    isReady: isAuthorized
                )
                WorkflowStep(
                    number: 2,
                    title: "建立基线",
                    detail: "用有界扫描记录目录摘要和覆盖范围。",
                    isReady: false
                )
                WorkflowStep(
                    number: 3,
                    title: "解释变化",
                    detail: "把时间窗口、大小口径和证据放在一起。",
                    isReady: false
                )
            }
        }
    }

    private var isAuthorized: Bool {
        if case .ready = readiness { return true }
        return false
    }

    private var readinessTitle: LocalizedStringKey {
        switch readiness {
        case .preparing: "正在准备监控"
        case .needsAuthorization: "先选择一个要观察的目录"
        case .ready: "目录授权已就绪"
        case .needsAttention: "目录授权需要处理"
        }
    }

    private var readinessDetail: String {
        switch readiness {
        case .preparing:
            String(localized: "正在恢复保存在此 Mac 上的只读授权。")
        case .needsAuthorization:
            String(localized: "SpaceTrace 不会自行扩大访问范围，也不会要求先授予 Full Disk Access。")
        case let .ready(path):
            String(localized: "已准备观察：\(path)。基线扫描与变化解释将在后续里程碑接入，本页不会展示虚构数据。")
        case .needsAttention:
            String(localized: "授权位置可能暂时不可用、已经变化或需要重新确认。进入目录授权页查看准确原因。")
        }
    }

    private var readinessActionTitle: LocalizedStringKey {
        switch readiness {
        case .needsAuthorization: "前往目录授权"
        case .preparing, .ready, .needsAttention: "查看目录授权"
        }
    }

    private var readinessSymbol: String {
        switch readiness {
        case .preparing: "hourglass"
        case .needsAuthorization: "folder.badge.plus"
        case .ready: "checkmark.shield"
        case .needsAttention: "exclamationmark.shield"
        }
    }

    private var readinessColor: Color {
        switch readiness {
        case .ready: .green
        case .needsAttention: .orange
        case .preparing, .needsAuthorization: .secondary
        }
    }
}

private struct WorkflowStep: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(isReady ? Color.green.opacity(0.16) : Color.secondary.opacity(0.12))
                    .clipShape(Circle())
                Text(title)
                    .font(.headline)
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(isReady ? "已就绪" : "尚未接入")
                .font(.caption.weight(.medium))
                .foregroundStyle(isReady ? Color.green : Color.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
