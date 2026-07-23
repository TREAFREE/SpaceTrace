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
            .padding(8)
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
                Label("完成基线后查看历史", systemImage: "clock.badge.questionmark")
            } description: {
                Text("历史只使用已经原子发布的目录摘要；没有可比较基线时不会生成变化值。")
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
    private func loadedContent(_ overview: DirectoryHistoryOverview) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("可见目录逻辑大小")
                    .font(.headline)
                coverageBadge(overview.coverage)
                Spacer(minLength: 0)
                Text(windowInterval(overview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if overview.hasMeasurements {
                DirectoryHistoryChart(overview: overview)
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

            growthSection(overview)
        }
        .accessibilityIdentifier("overview-history-loaded")
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
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }
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

    private func windowInterval(_ overview: DirectoryHistoryOverview) -> String {
        "\(overview.start.formatted(date: .abbreviated, time: .shortened)) – \(overview.end.formatted(date: .abbreviated, time: .shortened))"
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
                .font(.callout.monospacedDigit().weight(.semibold))
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
