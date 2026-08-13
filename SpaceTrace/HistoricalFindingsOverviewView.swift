import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import SwiftUI

enum ReconciliationStatusTone: Sendable, Equatable {
    case success
    case attention
    case failure
    case neutral
}

struct ReconciliationStatusPresentation: Sendable, Equatable {
    let detail: String
    let symbolName: String
    let tone: ReconciliationStatusTone

    init(state: ReconciliationStatusState) {
        switch state {
        case .current(let success):
            detail = "已校准至修订 \(success.sequence.rawValue) · \(Self.formatted(success.completedAt))"
            symbolName = "checkmark.circle.fill"
            tone = .success
        case .pending(_, let revision, _):
            if let revision {
                detail = "有待处理变化 · dirty revision \(revision.rawValue)"
            } else {
                detail = "有待处理变化；路径已按隐私保留策略移除，仍需重新扫描"
            }
            symbolName = "clock.arrow.circlepath"
            tone = .attention
        case .partial(_, let revision, let attemptedAt):
            detail = "修订 \(revision.rawValue) 的扫描覆盖不完整 · \(Self.formatted(attemptedAt))"
            symbolName = "circle.lefthalf.filled"
            tone = .attention
        case .failed(_, let revision, let attemptedAt):
            detail = "修订 \(revision.rawValue) 的扫描失败 · \(Self.formatted(attemptedAt))"
            symbolName = "exclamationmark.triangle.fill"
            tone = .failure
        case .permissionRequired:
            detail = "目录授权已过期或被撤回，需要重新授权后才能校准"
            symbolName = "exclamationmark.shield.fill"
            tone = .attention
        case .volumeUnavailable:
            detail = "目录所在卷当前不可用，卷返回后才能继续校准"
            symbolName = "externaldrive.badge.questionmark"
            tone = .attention
        case .historyDisabled:
            detail = "路径历史已关闭"
            symbolName = "clock.badge.xmark"
            tone = .neutral
        case .baselineUnavailable:
            detail = "尚无可用于比较的完整历史基线"
            symbolName = "clock.badge.questionmark"
            tone = .neutral
        }
    }

    private static func formatted(_ instant: ObservationInstant) -> String {
        Date(
            timeIntervalSince1970:
                Double(instant.millisecondsSince1970) / 1_000
        ).formatted(date: .abbreviated, time: .shortened)
    }
}

struct HistoricalFindingsOverviewView: View {
    @Bindable var model: HistoricalFindingsViewModel
    @State private var confirmsHistoryOff = false
    @State private var showsInvalidated = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                statusBar
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("可核验的空间变化", systemImage: "list.bullet.rectangle.portrait")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("可核验的空间变化")
        .alert("关闭路径历史？", isPresented: $confirmsHistoryOff) {
            Button("取消", role: .cancel) {}
            Button("关闭并清除历史", role: .destructive) {
                Task { await model.setHistoryEnabled(false) }
            }
            .accessibilityIdentifier("confirm-history-off")
        } message: {
            Text("这会删除路径历史、历史基线、变化记录和证据已失效的审计记录，且无法撤销。目录授权、当前监控状态和不含路径的卷空间记录会保留。")
        }
        .alert(
            "历史设置未更改",
            isPresented: Binding(
                get: { model.operationError != nil },
                set: { presented in
                    if presented == false { model.dismissOperationError() }
                }
            )
        ) {
            Button("好", role: .cancel) { model.dismissOperationError() }
        } message: {
            Text("SpaceTrace 没有把失败的设置写成成功。原有历史状态保持不变，请稍后重试。")
        }
    }

    private var statusBar: some View {
        HStack(alignment: .center, spacing: 12) {
            if let overview = model.overview {
                Label(
                    overview.retentionDays == 0
                        ? "路径历史已关闭"
                        : "路径历史最多保留 \(overview.retentionDays) 天",
                    systemImage: overview.retentionDays == 0
                        ? "clock.badge.xmark"
                        : "clock.arrow.circlepath"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(overview.retentionDays == 0 ? .orange : .secondary)
                .accessibilityIdentifier("finding-history-policy-status")
            } else {
                Text("当前有效记录与审计状态")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if model.state == .loaded, let overview = model.overview {
                if overview.retentionDays == 0 {
                    Button("开启 30 天路径历史") {
                        Task { await model.setHistoryEnabled(true) }
                    }
                    .disabled(model.isChangingPolicy)
                    .accessibilityIdentifier("enable-path-history")
                } else {
                    Button("关闭路径历史…", role: .destructive) {
                        confirmsHistoryOff = true
                    }
                    .disabled(model.isChangingPolicy)
                    .accessibilityIdentifier("disable-path-history")
                }
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新变化记录", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(
                model.state == .loading
                    || model.state == .waitingForAuthorization
                    || model.isChangingPolicy
            )
            .help("重新读取本机变化记录")
            .accessibilityLabel("刷新变化记录")
            .accessibilityIdentifier("refresh-historical-findings")

            if model.isChangingPolicy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在更新路径历史设置")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .waitingForAuthorization:
            ContentUnavailableView {
                Label("先授权一个目录", systemImage: "folder.badge.questionmark")
            } description: {
                Text("变化记录只会来自你明确授权并完成基线扫描的目录。")
            }
            .accessibilityIdentifier("historical-findings-waiting")
        case .loading:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在读取当前有效变化…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            .accessibilityIdentifier("historical-findings-loading")
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Label("暂时无法读取变化记录", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("SpaceTrace 不会用旧列表或空数组冒充本次结果。")
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await model.refresh() } }
                    .accessibilityIdentifier("historical-findings-retry")
            }
            .accessibilityIdentifier("historical-findings-failed")
        case .loaded:
            if let overview = model.overview {
                loadedContent(overview)
            } else {
                Text("变化结果不可用")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ overview: HistoricalFindingOverview) -> some View {
        if overview.retentionDays == 0 {
            ContentUnavailableView {
                Label("路径历史已关闭", systemImage: "eye.slash")
            } description: {
                Text("SpaceTrace 继续监控已授权目录，但不会保存新的路径历史。重新开启后，需要完成一份新基线才能再次比较。")
            }
            .accessibilityIdentifier("historical-findings-history-disabled")
        } else if overview.scopes.allSatisfy({ $0.availability == .baselineUnavailable }) {
            VStack(alignment: .leading, spacing: 18) {
                if model.reconciliationStatuses.isEmpty == false {
                    reconciliationSection(overview)
                    Divider()
                }

                ContentUnavailableView {
                    Label("正在等待新的历史基线", systemImage: "clock.badge.questionmark")
                } description: {
                    Text("路径历史已经开启，但还没有可比较的完整基线。请在上方开始或重新执行基线扫描。")
                }
                .accessibilityIdentifier("historical-findings-baseline-unavailable")
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if model.reconciliationStatuses.isEmpty == false {
                    reconciliationSection(overview)
                    Divider()
                }

                currentSection(overview)

                if overview.scopes.contains(where: {
                    $0.availability == .baselineUnavailable
                }) {
                    baselineUnavailableScopes(overview)
                }

                Divider()

                invalidatedSection(overview)

                Text("这里显示不可变扫描证据生成的本机记录。逻辑大小与可观察分配大小都不等于 APFS 唯一物理占用或可回收空间；变化记录也不是清理建议。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reconciliationSection(
        _ overview: HistoricalFindingOverview
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("校准状态")
                .font(.headline)
                .accessibilityIdentifier("reconciliation-status-heading")

            ForEach(overview.scopes) { scope in
                if let status = model.reconciliationStatuses[scope.scopeID] {
                    let presentation = ReconciliationStatusPresentation(
                        state: status.state
                    )
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: presentation.symbolName)
                            .foregroundStyle(reconciliationColor(presentation.tone))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.displayPath(for: scope.scopeID) ?? "已配置目录")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(presentation.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "reconciliation-status-\(scope.scopeID.rawValue)"
                    )
                }
            }
        }
    }

    private func reconciliationColor(
        _ tone: ReconciliationStatusTone
    ) -> Color {
        switch tone {
        case .success: .green
        case .attention: .orange
        case .failure: .red
        case .neutral: .secondary
        }
    }

    private func baselineUnavailableScopes(
        _ overview: HistoricalFindingOverview
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("仍在等待基线的目录", systemImage: "clock.badge.questionmark")
                .font(.callout.weight(.semibold))
            ForEach(
                overview.scopes.filter {
                    $0.availability == .baselineUnavailable
                }
            ) { scope in
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayPath(for: scope.scopeID) ?? "已授权目录")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("尚无可比较的完整历史基线；这不是零变化或空目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "historical-findings-baseline-unavailable-\(scope.scopeID.rawValue)"
                )
            }
        }
    }

    private func currentSection(_ overview: HistoricalFindingOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("当前有效变化")
                    .font(.headline)
                    .accessibilityIdentifier("historical-findings-loaded")
                Spacer(minLength: 0)
                Text("\(overview.currentFindings.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if overview.currentFindings.isEmpty {
                Text("还没有达到证据门槛的增长、移动或消失记录。未知、部分覆盖和未经证明的缺失会继续保持为空白。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("historical-findings-empty")
            } else {
                ForEach(overview.scopes) { scope in
                    if scope.currentFindings.isEmpty == false {
                        findingScope(
                            scope,
                            findings: scope.currentFindings,
                            invalidated: false
                        )
                    }
                }
            }
        }
    }

    private func invalidatedSection(_ overview: HistoricalFindingOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsInvalidated.toggle()
            } label: {
                HStack {
                    Image(
                        systemName: showsInvalidated
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
                    .accessibilityHidden(true)
                    Label("证据已失效的审计记录", systemImage: "exclamationmark.shield")
                    Spacer(minLength: 0)
                    Text("\(overview.invalidatedFindings.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsInvalidated ? "已展开" : "已折叠")
            .accessibilityIdentifier("historical-findings-invalidated-disclosure")

            if showsInvalidated {
                VStack(alignment: .leading, spacing: 12) {
                    Text("这些不可变原记录只用于本机审计。它们的证据已失效，因此不会出现在“当前有效变化”中；这不表示文件已修复、替换、删除或清理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if overview.invalidatedFindings.isEmpty {
                        Text("没有证据已失效的记录。")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("historical-findings-invalidated-empty")
                    } else {
                        ForEach(overview.scopes) { scope in
                            if scope.invalidatedFindings.isEmpty == false {
                                findingScope(
                                    scope,
                                    findings: scope.invalidatedFindings,
                                    invalidated: true
                                )
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func findingScope(
        _ scope: HistoricalFindingScopeOverview,
        findings: [HistoricalFindingOverviewItem],
        invalidated: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.displayPath(for: scope.scopeID) ?? "已授权目录")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.displayPath(for: scope.scopeID) ?? "已授权目录")
            VStack(spacing: 0) {
                ForEach(Array(findings.enumerated()), id: \.element.id) { index, item in
                    HistoricalFindingRow(item: item, invalidated: invalidated)
                    if index < findings.count - 1 { Divider() }
                }
            }
            .spaceTraceCompactSurface()
        }
    }
}

private struct HistoricalFindingRow: View {
    let item: HistoricalFindingOverviewItem
    let invalidated: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(invalidated ? .orange : symbolColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(metricName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let rank = item.positiveRank, invalidated == false {
                        Text("Top \(rank)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }

                Text(pathDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(classificationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(classificationEvidenceDescription)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text(timeDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Text(deltaDescription)
                .font(.spaceTraceMetric)
                .foregroundStyle(invalidated ? .secondary : symbolColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(
            invalidated
                ? "historical-finding-invalidated-\(findingIdentifier)"
                : "historical-finding-current-\(findingIdentifier)"
        )
    }

    private var findingIdentifier: String {
        switch item.id {
        case .original(let id):
            "original-\(id.rawValue)"
        case .corrected(let id):
            "corrected-\(id.rawValue)"
        }
    }

    private var title: String {
        let name: String
        switch item.kind {
        case .disappearance:
            name = item.baselineDisplayName
        default:
            name = item.comparisonDisplayName
        }
        let event: String
        switch item.kind {
        case .growth: event = "增长"
        case .decrease: event = "减少"
        case .appearance: event = "新出现"
        case .disappearance: event = "已观测到消失"
        case .move: event = "位置变化"
        }
        return "\(name) · \(event)"
    }

    private var metricName: String {
        switch item.metric {
        case .logical: "逻辑大小"
        case .allocated: "可观察分配"
        case .volumeAvailable: "不支持的口径"
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .growth: "arrow.up.right"
        case .decrease: "arrow.down.right"
        case .appearance: "plus.circle"
        case .disappearance: "minus.circle"
        case .move: "arrow.triangle.swap"
        }
    }

    private var symbolColor: Color {
        switch item.kind {
        case .growth, .appearance: .blue
        case .decrease, .disappearance: .secondary
        case .move: .purple
        }
    }

    private var pathDescription: String {
        if item.kind == .move {
            return "\(item.baselinePath) → \(item.comparisonPath)"
        }
        return item.kind == .disappearance
            ? item.baselinePath
            : item.comparisonPath
    }

    private var deltaDescription: String {
        if item.kind == .move, item.inclusiveDeltaBytes == 0 { return "—" }
        let value = ByteCountFormatter.string(
            fromByteCount: item.inclusiveDeltaBytes,
            countStyle: .binary
        )
        return item.inclusiveDeltaBytes > 0 ? "+\(value)" : value
    }

    private var timeDescription: String {
        let baselineDate = Date(
            timeIntervalSince1970:
                Double(item.baselineTime.millisecondsSince1970) / 1_000
        )
        let comparisonDate = Date(
            timeIntervalSince1970:
                Double(item.comparisonTime.millisecondsSince1970) / 1_000
        )
        let prefix: String
        switch item.validity {
        case .currentEffective:
            prefix = "观测于"
        case .evidenceInvalidated(let invalidatedAt):
            let invalidatedDate = Date(
                timeIntervalSince1970:
                    Double(invalidatedAt.millisecondsSince1970) / 1_000
            )
            return "完整证据 · \(baselineDate.formatted(date: .abbreviated, time: .shortened)) – \(comparisonDate.formatted(date: .abbreviated, time: .shortened)) · 证据已失效于 \(invalidatedDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return "完整证据 · \(prefix) \(baselineDate.formatted(date: .abbreviated, time: .shortened)) – \(comparisonDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private var classificationDescription: String {
        switch item.classification {
        case .classified(let category, let confidence, _, _, _, _):
            return "分类：\(categoryDescription(category)) · \(confidenceDescription(confidence))置信度"
        case .unknownNoMatchingRule:
            return "分类：未知 · 没有匹配到足够精确的规则"
        case .unknownAmbiguous(_, let ruleIDs):
            return "分类：未知 · \(ruleIDs.count) 条同优先级规则存在冲突"
        }
    }

    private var classificationEvidenceDescription: String {
        switch item.classification {
        case .classified(_, _, let ruleID, let ruleVersion, let catalogVersion, let evidenceCode):
            return "规则 \(ruleID.rawValue) v\(ruleVersion.rawValue) · 目录 v\(catalogVersion.rawValue) · 证据 \(evidenceCode.rawValue)"
        case .unknownNoMatchingRule(let catalogVersion):
            return "规则目录 v\(catalogVersion.rawValue) · no_matching_rule"
        case .unknownAmbiguous(let catalogVersion, let ruleIDs):
            return "规则目录 v\(catalogVersion.rawValue) · \(ruleIDs.map(\.rawValue).joined(separator: ", "))"
        }
    }

    private func categoryDescription(_ category: StorageAttributionCategory) -> String {
        switch category {
        case .developerTools: "开发工具"
        case .virtualization: "虚拟机与容器"
        case .aiModelsAndCaches: "AI 模型与缓存"
        case .creativeCachesAndRenderData: "创作缓存与渲染数据"
        case .games: "游戏"
        case .logsAndCaches: "日志与缓存"
        case .cloudLocalData: "云端本地数据"
        case .snapshotFactors: "快照相关因素"
        }
    }

    private func confidenceDescription(_ confidence: AttributionConfidence) -> String {
        switch confidence {
        case .high: "高"
        case .medium: "中"
        case .low: "低"
        case .unknown: "未知"
        }
    }

    private var accessibilityDescription: String {
        let validity = invalidated ? "证据已失效的审计记录" : "当前有效变化"
        return "\(validity)，\(title)，\(metricName)，\(deltaDescription)，\(pathDescription)，\(classificationDescription)，\(classificationEvidenceDescription)，\(timeDescription)"
    }
}
