import Charts
import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import SwiftUI

struct DirectoryHistoryOverviewView: View {
    @Bindable var model: DirectoryHistoryViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                controls
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("历史变化", systemImage: "chart.xyaxis.line")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("目录历史变化")
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker(
                "时间范围",
                selection: Binding(
                    get: { model.selectedWindow },
                    set: { window in
                        Task { await model.selectWindow(window) }
                    }
                )
            ) {
                ForEach(DirectoryHistoryWindow.allCases, id: \.self) { window in
                    Text(window.displayName).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("overview-history-window")

            Spacer(minLength: 0)

            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新历史", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(model.state == .loading || model.state == .waitingForBaseline)
            .help("重新读取本机历史")
            .accessibilityLabel("刷新历史")
            .accessibilityIdentifier("overview-refresh-history")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .waitingForBaseline:
            ContentUnavailableView {
                Label("正在等待首次空间观测", systemImage: "clock.badge.questionmark")
            } description: {
                Text("SpaceTrace 启动后会记录数据卷可用空间；目录变化仍只使用原子发布的扫描摘要。")
            }
            .accessibilityIdentifier("overview-history-waiting")
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取本机历史…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .accessibilityIdentifier("overview-history-loading")
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Label("暂时无法读取历史", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("当前基线保持不变。SpaceTrace 不会用零值或旧查询冒充本次结果。")
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("overview-history-retry")
            }
            .accessibilityIdentifier("overview-history-failed")
        case .loaded:
            if let overview = model.overview {
                loadedContent(overview)
            } else {
                ContentUnavailableView(
                    "历史结果不可用",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ overview: StorageHistoryOverview) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            volumeSection(overview)

            Divider()

            reconciliationSection(overview)

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("可见目录逻辑大小")
                    .font(.headline)
                coverageBadge(overview.directories.coverage)
                Spacer(minLength: 0)
                Text(windowInterval(overview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if overview.directories.hasMeasurements {
                DirectoryHistoryChart(overview: overview.directories)
            } else {
                ContentUnavailableView {
                    Label("还没有历史观测", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("完成下一次可比较的校准扫描后，这里才会出现趋势；缺失数据保持为空白。")
                }
                .frame(minHeight: 180)
                .accessibilityIdentifier("overview-history-empty")
            }

            Text("每条曲线对应一个已发布的目录根；多目录不会被合并成可能重复计算的总量。图中的空白表示该时间桶没有可用证据，不会自动连线或补成零。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            growthSection(overview.directories)
        }
        .accessibilityIdentifier("overview-history-loaded")
    }

    @ViewBuilder
    private func volumeSection(_ overview: StorageHistoryOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("启动数据卷可用空间")
                    .font(.headline)
                coverageBadge(overview.volume.coverage)
                Spacer(minLength: 0)
                Text(windowInterval(overview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if overview.volume.hasMeasurements {
                StartupVolumeHistoryChart(
                    series: overview.volume,
                    bucket: overview.bucket
                )
            } else {
                ContentUnavailableView {
                    Label("还没有卷空间历史", systemImage: "internaldrive")
                } description: {
                    Text("应用保持运行后会按小时记录一次；缺失值不会被补成零。")
                }
                .frame(minHeight: 160)
                .accessibilityIdentifier("overview-volume-history-empty")
            }

            if overview.volume.identityDiscontinuity {
                Label(
                    "检测到启动卷身份变化，SpaceTrace 已断开跨卷比较。",
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if overview.volume.clockDiscontinuity {
                Label(
                    "检测到系统时间回拨；提交顺序仍由单调序号保存，但本窗口不进行端点归因。",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Text("这里展示文件系统 API 返回的当前可用空间。它与“重要用途可用空间”、APFS 唯一物理占用和可回收空间不是同一个指标。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("启动数据卷可用空间历史")
        .accessibilityIdentifier("overview-volume-history")
    }

    @ViewBuilder
    private func reconciliationSection(_ overview: StorageHistoryOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("空间变化解释")
                    .font(.headline)
                if let reconciliation = overview.reconciliation {
                    coverageBadge(reconciliation.coverage)
                }
            }

            if let reconciliation = overview.reconciliation {
                HStack(alignment: .center, spacing: 10) {
                    ReconciliationMetric(
                        title: "磁盘少了多少",
                        value: byteText(reconciliation.diskSpaceLoss),
                        detail: "启动卷可用空间减少",
                        symbol: "internaldrive"
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ReconciliationMetric(
                        title: "授权目录能解释",
                        value: optionalByteText(
                            reconciliation.explainedDiskSpaceLoss
                        ),
                        detail: reconciliation.observedDirectoryAllocatedGrowth == nil
                            ? "缺少可比较目录证据"
                            : "\(reconciliation.comparableScopeCount) 个互不重叠目录",
                        symbol: "folder.badge.gearshape"
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ReconciliationMetric(
                        title: "仍无法归因",
                        value: optionalByteText(
                            reconciliation.unattributedDiskSpaceLoss
                        ),
                        detail: reconciliation.unattributedDiskSpaceLoss == nil
                            ? "保持未知，不按零处理"
                            : "卷变化减去可证明部分",
                        symbol: "questionmark.circle"
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("overview-storage-reconciliation")

                if reconciliation.excludedNestedScopeCount > 0
                    || reconciliation.excludedExternalScopeCount > 0
                    || reconciliation.unknownVolumeScopeCount > 0 {
                    Text(exclusionSummary(reconciliation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("至少需要同一启动卷上的两个可用空间观测，才能计算这个时间窗口的变化。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overview-reconciliation-empty")
            }

            Text("“能解释”只使用启动卷上互不重叠授权根的 allocated-size 净增长，并且最多抵扣磁盘减少量。无法归因部分可能来自未授权目录、APFS 快照或克隆、系统与应用缓存、可清理空间，以及扫描缺口；它不是异常文件的直接证据。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func growthSection(_ overview: DirectoryHistoryOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("增长来源")
                    .font(.headline)
                Spacer()
                if overview.growthSources.isEmpty == false {
                    Text("Top \(min(10, overview.growthSources.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if overview.growthSources.isEmpty {
                Text("这个时间窗口内还没有两个可比较观测形成的正增长记录。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overview-growth-empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(overview.growthSources.prefix(10).enumerated()),
                        id: \.element.id
                    ) { index, source in
                        DirectoryGrowthRow(rank: index + 1, source: source)
                        if index + 1 < min(10, overview.growthSources.count) {
                            Divider()
                        }
                    }
                }
                .spaceTraceCompactSurface()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("目录增长来源排名")
            }

            Text("增长值是相同目录、相同口径下的逻辑大小变化，不等于 APFS 唯一物理占用或可回收空间。父子目录可能描述同一变化，因此本列表只排序、不把各行相加。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func coverageBadge(
        _ coverage: DirectoryHistoryEvidenceCoverage
    ) -> some View {
        Label(coverage.displayName, systemImage: coverage.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(coverage.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(coverage.color.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel("时间窗口覆盖：\(coverage.accessibilityName)")
    }

    private func windowInterval(_ overview: StorageHistoryOverview) -> String {
        "\(overview.start.formatted(date: .abbreviated, time: .shortened)) – \(overview.end.formatted(date: .abbreviated, time: .shortened))"
    }

    private func byteText(_ value: ByteCount) -> String {
        ByteCountFormatter.string(fromByteCount: value.value, countStyle: .binary)
    }

    private func optionalByteText(_ value: ByteCount?) -> String {
        value.map(byteText) ?? "证据不足"
    }

    private func exclusionSummary(_ summary: StorageReconciliationSummary) -> String {
        var parts: [String] = []
        if summary.excludedNestedScopeCount > 0 {
            parts.append("排除 \(summary.excludedNestedScopeCount) 个嵌套根，避免重复计算")
        }
        if summary.excludedExternalScopeCount > 0 {
            parts.append("排除 \(summary.excludedExternalScopeCount) 个外置卷目录")
        }
        if summary.unknownVolumeScopeCount > 0 {
            parts.append("\(summary.unknownVolumeScopeCount) 个目录的卷身份未知")
        }
        return parts.joined(separator: "；") + "。"
    }
}

private struct ReconciliationMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.spaceTraceMetric)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .spaceTraceCompactSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
        .accessibilityValue(detail)
    }
}

private struct StartupVolumeHistoryChart: View {
    let series: StartupVolumeHistorySeries
    let bucket: DirectoryHistoryBucket

    private var data: [StartupVolumeChartPoint] {
        StartupVolumeChartProjection.makePoints(from: series)
    }

    var body: some View {
        Chart(data) { point in
            LineMark(
                x: .value("时间", point.observedAt),
                y: .value("可用空间", Double(point.availableBytes)),
                series: .value("连续区间", point.segmentID)
            )
            .foregroundStyle(Color.accentColor)
            .interpolationMethod(.linear)

            PointMark(
                x: .value("时间", point.observedAt),
                y: .value("可用空间", Double(point.availableBytes))
            )
            .foregroundStyle(Color.accentColor)
            .symbolSize(point.coverage == .complete ? 20 : 56)
            .accessibilityLabel("启动数据卷可用空间")
            .accessibilityValue(
                "\(ByteCountFormatter.string(fromByteCount: point.availableBytes, countStyle: .binary))，\(point.observedAt.formatted(date: .abbreviated, time: .shortened))，\(point.coverage.accessibilityName)"
            )
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(max(0, bytes)),
                                countStyle: .binary
                            )
                        )
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: bucket == .hourly ? 6 : 7))
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.accentColor.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(minHeight: 220)
        .accessibilityLabel("启动数据卷可用空间历史图")
        .accessibilityHint("空白或卷身份变化会断开曲线，较大的点表示部分覆盖。")
    }
}

struct StartupVolumeChartPoint: Identifiable, Equatable {
    let segmentID: String
    let observedAt: Date
    let availableBytes: Int64
    let coverage: DirectoryHistoryEvidenceCoverage

    var id: String {
        "\(segmentID)\u{0}\(observedAt.timeIntervalSince1970)"
    }
}

enum StartupVolumeChartProjection {
    static func makePoints(
        from series: StartupVolumeHistorySeries
    ) -> [StartupVolumeChartPoint] {
        var segment = 0
        var previousUUID: UUID?
        var previousWasAvailable = false
        return series.points.compactMap { point in
            guard let bytes = point.availableBytes else {
                previousWasAvailable = false
                previousUUID = nil
                return nil
            }
            if previousWasAvailable == false || previousUUID != point.volumeUUID {
                segment += 1
            }
            previousWasAvailable = true
            previousUUID = point.volumeUUID
            return StartupVolumeChartPoint(
                segmentID: "volume-\(segment)",
                observedAt: point.bucketStart,
                availableBytes: bytes.value,
                coverage: point.coverage
            )
        }
    }
}

private struct DirectoryHistoryChart: View {
    let overview: DirectoryHistoryOverview

    private var data: [DirectoryHistoryChartPoint] {
        DirectoryHistoryChartProjection.makePoints(from: overview)
    }

    var body: some View {
        Chart(data) { point in
            LineMark(
                x: .value("时间", point.observedAt),
                y: .value("逻辑大小", Double(point.logicalBytes)),
                series: .value("连续区间", point.segmentID)
            )
            .foregroundStyle(by: .value("目录", point.seriesName))
            .interpolationMethod(.linear)

            PointMark(
                x: .value("时间", point.observedAt),
                y: .value("逻辑大小", Double(point.logicalBytes))
            )
            .foregroundStyle(by: .value("目录", point.seriesName))
            .symbolSize(point.coverage == .complete ? 20 : 56)
            .accessibilityLabel(point.seriesName)
            .accessibilityValue(
                "\(formatBytes(point.logicalBytes))，\(point.observedAt.formatted(date: .abbreviated, time: .shortened))，\(point.coverage.accessibilityName)"
            )
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(formatBytes(Int64(max(0, bytes))))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: overview.bucket == .hourly ? 6 : 7))
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.accentColor.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .frame(minHeight: 260)
        .accessibilityLabel("目录逻辑大小历史图")
        .accessibilityHint("每条曲线对应一个目录根，较大的点表示部分覆盖；缺失时间桶不会连线。")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

struct DirectoryHistoryChartPoint: Identifiable, Equatable {
    let scopeID: WatchedScopeID
    let seriesName: String
    let segmentID: String
    let observedAt: Date
    let logicalBytes: Int64
    let coverage: DirectoryHistoryEvidenceCoverage

    var id: String {
        "\(scopeID.rawValue)\u{0}\(segmentID)\u{0}\(observedAt.timeIntervalSince1970)"
    }
}

enum DirectoryHistoryChartProjection {
    static func makePoints(
        from overview: DirectoryHistoryOverview
    ) -> [DirectoryHistoryChartPoint] {
        overview.series.flatMap { series in
            var segment = 0
            var previousPointWasAvailable = false
            return series.points.compactMap { point -> DirectoryHistoryChartPoint? in
                guard let bytes = point.logicalBytes else {
                    previousPointWasAvailable = false
                    return nil
                }
                if previousPointWasAvailable == false {
                    segment += 1
                }
                previousPointWasAvailable = true
                return DirectoryHistoryChartPoint(
                    scopeID: series.scopeID,
                    seriesName: series.root.rawValue,
                    segmentID: "\(series.scopeID.rawValue)-\(segment)",
                    observedAt: point.observedAt,
                    logicalBytes: bytes.value,
                    coverage: point.coverage
                )
            }
        }
    }
}

private struct DirectoryGrowthRow: View {
    let rank: Int
    let source: DirectoryGrowthSource

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(rank)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.callout.weight(.semibold))
                Text(source.path.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(interval)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("逻辑大小变化 · \(source.coverage.displayName)覆盖 · 未分类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(delta)
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(.green)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "第 \(rank) 名，\(displayName)，增长 \(delta)，\(source.coverage.accessibilityName)"
        )
        .accessibilityValue(source.path.rawValue)
    }

    private var displayName: String {
        let component = URL(fileURLWithPath: source.path.rawValue).lastPathComponent
        return component.isEmpty ? source.path.rawValue : component
    }

    private var delta: String {
        "+\(ByteCountFormatter.string(fromByteCount: source.logicalByteDelta, countStyle: .binary))"
    }

    private var interval: String {
        if source.firstObservedAt == source.lastObservedAt {
            return String(
                localized: "观测于 \(source.lastObservedAt.formatted(date: .abbreviated, time: .shortened))"
            )
        }
        return "\(source.firstObservedAt.formatted(date: .abbreviated, time: .shortened)) – \(source.lastObservedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private extension DirectoryHistoryWindow {
    var displayName: LocalizedStringKey {
        switch self {
        case .last24Hours:
            "24 小时"
        case .last7Days:
            "7 天"
        case .last30Days:
            "30 天"
        }
    }
}

private extension DirectoryHistoryEvidenceCoverage {
    var displayName: String {
        switch self {
        case .complete:
            String(localized: "完整")
        case .partial:
            String(localized: "部分")
        case .unavailable:
            String(localized: "不可用")
        }
    }

    var accessibilityName: String {
        switch self {
        case .complete:
            String(localized: "完整覆盖")
        case .partial:
            String(localized: "部分覆盖")
        case .unavailable:
            String(localized: "无可用证据")
        }
    }

    var symbolName: String {
        switch self {
        case .complete:
            "checkmark.circle.fill"
        case .partial:
            "exclamationmark.circle.fill"
        case .unavailable:
            "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .complete:
            .green
        case .partial:
            .orange
        case .unavailable:
            .secondary
        }
    }
}
