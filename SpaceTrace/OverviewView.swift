import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import SwiftUI

struct OverviewView: View {
    let authorizationSummary: DirectoryAuthorizationSummary
    let scopeIDs: [WatchedScopeID]
    @Bindable var baselineScanModel: BaselineScanViewModel
    let showPermissions: () -> Void

    private var readiness: OverviewReadiness {
        OverviewReadiness(summary: authorizationSummary)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                readinessCard
                baselineCard
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
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("overview-permissions-button")
                }

                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("监控准备状态")
    }

    private var baselineCard: some View {
        GroupBox("目录基线") {
            VStack(alignment: .leading, spacing: 16) {
                if scopeIDs.isEmpty == false {
                    baselineContent(scopeIDs: scopeIDs)
                } else {
                    Label("授权目录后才能建立基线", systemImage: "folder.badge.questionmark")
                        .font(.headline)
                    Text("扫描只会读取你明确选择的目录；没有授权时不会启动，也不会展示猜测值。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目录基线扫描")
    }

    @ViewBuilder
    private func baselineContent(scopeIDs: [WatchedScopeID]) -> some View {
        switch currentBaselineState(for: scopeIDs) {
        case .idle:
            baselineIdle(scopeIDs: scopeIDs)
        case let .preparing(request, startedAt):
            baselineActive(
                title: "正在准备扫描",
                detail: "正在确认授权目录与当前 FSEvents 监控代次。",
                startedAt: startedAt,
                progress: nil,
                totalRootCount: request.scopeIDs.count
            )
        case let .scanning(progress):
            baselineActive(
                title: "正在扫描目录",
                detail: "扫描受条目数、深度和时间预算约束；当前不伪造完成百分比。",
                startedAt: progress.startedAt,
                progress: progress
            )
        case let .publishing(progress):
            baselineActive(
                title: "正在原子发布结果",
                detail: "只有完整、且未被新事件取代的结果才会成为当前基线。",
                startedAt: progress.startedAt,
                progress: progress
            )
        case let .completed(result):
            baselineCompleted(result, scopeIDs: scopeIDs)
        case let .incomplete(result):
            baselineIncomplete(result, scopeIDs: scopeIDs)
        case let .cancelled(cancellation):
            baselineCancelled(cancellation, scopeIDs: scopeIDs)
        case let .failed(failure):
            baselineFailed(failure, scopeIDs: scopeIDs)
        }
    }

    private func baselineIdle(scopeIDs: [WatchedScopeID]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "可以为 \(scopeIDs.count) 个已授权目录建立基线",
                systemImage: "externaldrive.badge.checkmark"
            )
                .font(.headline)
            Text("目录会按稳定顺序逐个扫描。结果区分逻辑大小与可观察分配大小，并明确标注完整或部分覆盖。")
                .foregroundStyle(.secondary)
            Button("开始基线扫描") {
                Task { await baselineScanModel.start(scopeIDs: scopeIDs) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("overview-start-baseline")
        }
    }

    private func baselineActive(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        startedAt: Date,
        progress: AuthorizedBaselineScanProgress?,
        totalRootCount: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.headline)
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                LabeledContent("已用时间", value: elapsedText(from: startedAt, to: timeline.date))
            }
            LabeledContent(
                "根目录进度",
                value: "\(progress?.completedRootCount ?? 0) / \(progress?.totalRootCount ?? totalRootCount)"
            )
            LabeledContent("不可完整读取的根目录", value: "\(progress?.unreadableRootCount ?? 0)")
            if let progress, progress.entriesVisited > 0 {
                LabeledContent("已核验条目", value: progress.entriesVisited.formatted())
                LabeledContent("已生成目录摘要", value: progress.directoriesObserved.formatted())
            }
            Button("取消扫描", role: .cancel) {
                Task { await baselineScanModel.cancel() }
            }
            .accessibilityIdentifier("overview-cancel-baseline")
        }
    }

    private func baselineCompleted(
        _ result: AuthorizedBaselineScanResult,
        scopeIDs: [WatchedScopeID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            coverageHeader(
                title: "基线已发布",
                detail: "完整覆盖",
                symbol: "checkmark.seal.fill",
                color: .green
            )
            metricGrid {
                LabeledContent(
                    "完成根目录",
                    value: "\(result.snapshot.roots.count) / \(result.snapshot.roots.count)"
                )
                LabeledContent("不可完整读取的根目录", value: "0")
                LabeledContent(
                    "数据卷总容量",
                    value: formatOptionalBytes(result.snapshot.startupVolume.totalBytes)
                )
                LabeledContent(
                    "数据卷当前可用",
                    value: formatOptionalBytes(result.snapshot.startupVolume.availableBytes)
                )
                LabeledContent(
                    "macOS 重要用途可用估计",
                    value: formatOptionalBytes(
                        result.snapshot.startupVolume.availableForImportantUsageBytes
                    )
                )
            }
            Text("目录结果")
                .font(.headline)
            ForEach(result.snapshot.roots, id: \.context.scopeID) { root in
                VStack(alignment: .leading, spacing: 8) {
                    Text(root.context.root.rawValue)
                        .font(.callout.weight(.medium))
                        .textSelection(.enabled)
                    LabeledContent("逻辑大小", value: formatBytes(root.logicalBytes.value))
                    LabeledContent(
                        "可观察分配大小",
                        value: formatBytes(root.allocatedBytes.value)
                    )
                    LabeledContent("后代条目", value: root.descendantCount.formatted())
                    LabeledContent("扫描条目", value: root.entriesVisited.formatted())
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("大小使用二进制单位。可观察分配大小不等于 APFS 唯一物理占用，也不代表可回收空间。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("“重要用途可用估计”由 macOS 提供，可能包含系统可清理空间，不等于当前空闲块。未知值会明确显示为未知。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("发布于 \(result.completedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                result.origin == .restoredAfterRestart
                    ? "已从本机已提交记录恢复 · App \(result.snapshot.build.appVersion) · Schema \(result.snapshot.build.schemaVersion)"
                    : "App \(result.snapshot.build.appVersion) · Schema \(result.snapshot.build.schemaVersion)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("重新扫描") {
                Task { await baselineScanModel.start(scopeIDs: scopeIDs) }
            }
            .accessibilityIdentifier("overview-rescan-baseline")
        }
    }

    private func baselineIncomplete(
        _ result: AuthorizedBaselineIncompleteResult,
        scopeIDs: [WatchedScopeID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            coverageHeader(
                title: incompleteTitle(result.reason),
                detail: "结果未发布",
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
            Text(incompleteDetail(result.reason))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            metricGrid {
                LabeledContent("覆盖状态", value: coverageLabel(result.report.coverage))
                LabeledContent("扫描条目", value: result.report.entriesVisited.formatted())
                LabeledContent("目录摘要", value: result.report.directoriesStaged.formatted())
                LabeledContent("访问缺口", value: result.report.gaps.count.formatted())
                LabeledContent(
                    "完成根目录",
                    value: "\(result.completedRootCount) / \(result.totalRootCount)"
                )
                LabeledContent(
                    "不可完整读取的根目录",
                    value: result.unreadableRootCount.formatted()
                )
            }
            Text("由于没有完整发布，SpaceTrace 不会把暂存的字节数当作当前基线。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新扫描") {
                Task { await baselineScanModel.start(scopeIDs: scopeIDs) }
            }
            .accessibilityIdentifier("overview-retry-baseline")
        }
    }

    private func baselineCancelled(
        _ cancellation: AuthorizedBaselineScanCancellation,
        scopeIDs: [WatchedScopeID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            coverageHeader(
                title: "扫描已取消",
                detail: "未发布新基线",
                symbol: "stop.circle.fill",
                color: .secondary
            )
            Text("取消会丢弃本次暂存结果并保留待校准标记，不会把部分数据标记为完整。")
                .foregroundStyle(.secondary)
            LabeledContent(
                "已用时间",
                value: elapsedText(from: cancellation.startedAt, to: cancellation.cancelledAt)
            )
            LabeledContent(
                "已完成根目录",
                value: "\(cancellation.completedRootCount) / \(cancellation.requestedScopeIDs.count)"
            )
            Button("重新开始") {
                Task { await baselineScanModel.start(scopeIDs: scopeIDs) }
            }
            .accessibilityIdentifier("overview-restart-baseline")
        }
    }

    private func baselineFailed(
        _ failure: AuthorizedBaselineScanFailure,
        scopeIDs: [WatchedScopeID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            coverageHeader(
                title: "基线扫描未完成",
                detail: "没有发布不可信结果",
                symbol: "xmark.octagon.fill",
                color: .red
            )
            Text(failureDetail(failure.code))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(
                failure.code == .baselinePersistenceFailed
                    ? "恢复上次已提交基线"
                    : "重试"
            ) {
                Task {
                    if failure.code == .baselinePersistenceFailed {
                        await baselineScanModel.restore(scopeID: scopeIDs.first)
                    } else {
                        await baselineScanModel.start(scopeIDs: scopeIDs)
                    }
                }
            }
            .accessibilityIdentifier("overview-retry-failed-baseline")
        }
    }

    private func coverageHeader(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private func metricGrid<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
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
                    state: isAuthorized ? .ready : .waiting
                )
                WorkflowStep(
                    number: 2,
                    title: "建立基线",
                    detail: "用有界扫描记录目录摘要和覆盖范围。",
                    state: baselineWorkflowState
                )
                WorkflowStep(
                    number: 3,
                    title: "解释变化",
                    detail: "把时间窗口、大小口径和证据放在一起。",
                    state: .planned
                )
            }
        }
    }

    private var isAuthorized: Bool {
        scopeIDs.isEmpty == false
    }

    private var baselineWorkflowState: WorkflowStepState {
        guard scopeIDs.isEmpty == false else { return .waiting }
        switch currentBaselineState(for: scopeIDs) {
        case .preparing, .scanning, .publishing:
            return .active
        case .completed:
            return .ready
        case .idle, .incomplete, .cancelled, .failed:
            return .waiting
        }
    }

    private func currentBaselineState(
        for scopeIDs: [WatchedScopeID]
    ) -> AuthorizedBaselineScanState {
        let state = baselineScanModel.state
        switch state {
        case .idle:
            return .idle
        case let .preparing(request, _) where request.scopeIDs == scopeIDs:
            return state
        case let .scanning(progress)
            where progress.totalRootCount == scopeIDs.count
                && scopeIDs.contains(progress.context.scopeID):
            return state
        case let .publishing(progress)
            where progress.totalRootCount == scopeIDs.count
                && scopeIDs.contains(progress.context.scopeID):
            return state
        case let .completed(result)
            where result.snapshot.roots.map(\.context.scopeID) == scopeIDs:
            return state
        case let .incomplete(result)
            where result.totalRootCount == scopeIDs.count
                && scopeIDs.contains(result.context.scopeID):
            return state
        case let .cancelled(result) where result.requestedScopeIDs == scopeIDs:
            return state
        case let .failed(result) where scopeIDs.contains(result.scopeID):
            return state
        default:
            return .idle
        }
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
        case let .ready(authorizedCount):
            String(localized: "已准备观察 \(authorizedCount) 个目录。你现在可以建立可取消、覆盖范围明确的批量基线。")
        case let .needsAttention(authorizedCount, issueCount):
            if authorizedCount > 0 {
                String(localized: "\(authorizedCount) 个目录可用，\(issueCount) 个目录需要处理。可用目录仍可建立批量基线。")
            } else {
                String(localized: "当前没有可安全访问的目录。请处理 \(issueCount) 个授权问题后再建立基线。")
            }
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

    private func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds]))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    private func formatOptionalBytes(_ bytes: ByteCount?) -> String {
        guard let bytes else { return String(localized: "未知") }
        return formatBytes(bytes.value)
    }

    private func coverageLabel(_ coverage: CalibrationCoverage) -> String {
        switch coverage {
        case .complete: String(localized: "完整")
        case .partial: String(localized: "部分")
        }
    }

    private func incompleteTitle(
        _ reason: AuthorizedBaselineIncompleteReason
    ) -> LocalizedStringKey {
        switch reason {
        case .partialCoverage: "扫描仅获得部分覆盖"
        case .changedDuringScan: "扫描期间目录继续变化"
        }
    }

    private func incompleteDetail(_ reason: AuthorizedBaselineIncompleteReason) -> String {
        switch reason {
        case .partialCoverage:
            String(localized: "部分位置无法读取或触及扫描预算；访问缺口保留为未知，而不是零。")
        case .changedDuringScan:
            String(localized: "新文件系统事件使本次扫描的修订令牌失效。待校准工作仍然保留，可以再次扫描。")
        }
    }

    private func failureDetail(_ code: AuthorizedBaselineScanFailureCode) -> String {
        switch code {
        case .scopeNotAuthorized:
            String(localized: "当前目录授权已经变化。请先在目录授权页确认状态。")
        case .monitoringNotReady:
            String(localized: "目录监控代次尚未激活或正在恢复。请稍后重试；SpaceTrace 不会绕过监控连续性直接发布结果。")
        case .publishedRootMissing:
            String(localized: "原子发布完成后没有找到可验证的根目录摘要。旧数据保持不变。")
        case .baselinePersistenceFailed:
            String(localized: "已发布目录聚合，但基线记录未能安全写入或恢复。SpaceTrace 不会把它展示为持久基线，请重试或检查本地数据库状态。")
        case .operationFailed:
            String(localized: "扫描或本地数据库操作失败。没有发布新的基线，请稍后重试。")
        }
    }
}

private enum WorkflowStepState {
    case ready
    case active
    case waiting
    case planned

    var label: LocalizedStringKey {
        switch self {
        case .ready: "已就绪"
        case .active: "进行中"
        case .waiting: "等待操作"
        case .planned: "后续阶段"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .active: .blue
        case .waiting, .planned: .secondary
        }
    }
}

private struct WorkflowStep: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let state: WorkflowStepState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(state.color.opacity(0.16))
                    .clipShape(Circle())
                Text(title)
                    .font(.headline)
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.color)
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
