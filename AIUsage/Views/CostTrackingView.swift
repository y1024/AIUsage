import SwiftUI
import Charts

// MARK: - Main View

struct CostTrackingView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("ccStatsGranularity") private var selectedGranularity: CostGranularity = .hourly
    @AppStorage("ccStatsMetric") private var selectedMetric: CostMetric = .usd
    @State private var selectedModels: Set<String> = []
    @AppStorage("ccStatsDistMetric") private var distributionMetric: CostMetric = .usd
    @AppStorage("ccStatsDistPeriod") private var distributionPeriod: DistributionPeriod = .today
    @State private var detailProvider: ProviderData?

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var costProviders: [ProviderData] {
        appState.providers.filter { $0.category == "local-cost" }
    }

    private var primaryProvider: ProviderData? {
        costProviders.first
    }

    private var costSummary: CostSummary? {
        primaryProvider?.costSummary
    }

    private var models: [ModelCostBreakdown] {
        distributionModels
    }

    var body: some View {
        VStack(spacing: 0) {
            if costProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        summaryStrip
                        chartSection
                        HStack(alignment: .top, spacing: 16) {
                            modelDistribution
                            modelTable
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $detailProvider) { provider in
            ProviderDetailView(provider: provider)
        }
    }

    // MARK: - Summary Strip

    private var logDateRange: String? {
        guard let timeline = costSummary?.timeline else { return nil }
        let points = !timeline.daily.isEmpty ? timeline.daily : timeline.hourly
        guard let first = points.first?.bucket, let last = points.last?.bucket else { return nil }
        return "\(first) – \(last)"
    }

    private var logDayCount: Int {
        guard let timeline = costSummary?.timeline else { return 0 }
        let points = !timeline.daily.isEmpty ? timeline.daily : timeline.hourly
        return max(1, points.count)
    }

    private var summaryStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                summaryCell(
                    icon: "chart.bar.fill",
                    title: t("Overall", "总计"),
                    value: formatCurrency(costSummary?.overall?.usd ?? 0),
                    tint: .red
                )
                summaryCell(
                    icon: "dollarsign.circle.fill",
                    title: t("This Month", "本月"),
                    value: formatCurrency(costSummary?.month?.usd ?? 0),
                    tint: .orange
                )
                summaryCell(
                    icon: "calendar",
                    title: t("This Week", "本周"),
                    value: formatCurrency(costSummary?.week?.usd ?? 0),
                    tint: .blue
                )
                summaryCell(
                    icon: "sun.max.fill",
                    title: t("Today", "今天"),
                    value: formatCurrency(costSummary?.today?.usd ?? 0),
                    tint: .green
                )
                summaryCell(
                    icon: "bolt.fill",
                    title: t("Total Tokens", "总 Tokens"),
                    value: formatCompactNumber(Double(costSummary?.overall?.tokens ?? 0)),
                    tint: .purple
                )
                summaryCell(
                    icon: "cpu",
                    title: t("Models", "模型数"),
                    value: "\(models.count)",
                    tint: .pink
                )
            }

            if let range = logDateRange {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(t("Based on local JSONL logs (\(range)). Claude Code retains ~7 days of logs; \"Overall\" reflects available data only.",
                           "基于本地 JSONL 日志（\(range)）。Claude Code 仅保留约 7 天日志，「总计」仅反映现有数据。"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            }
        }
    }

    private func summaryCell(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Chart Section

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("Spend Trend", "消费趋势"))
                    .font(.headline.weight(.bold))

                Spacer()

                modelFilterMenu

                Picker("", selection: $selectedMetric) {
                    Text("USD").tag(CostMetric.usd)
                    Text("Tokens").tag(CostMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("", selection: $selectedGranularity) {
                    Text(t("Hourly", "小时")).tag(CostGranularity.hourly)
                    Text(t("Daily", "每日")).tag(CostGranularity.daily)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            spendChart
                .frame(height: 220)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var modelFilterMenu: some View {
        Menu {
            Button(action: { selectedModels = [] }) {
                HStack {
                    Text(t("All Models (Combined)", "全部模型（合计）"))
                    if selectedModels.isEmpty {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(models) { model in
                Button(action: { toggleModelSelection(model.model) }) {
                    HStack {
                        Text(shortModelName(model.model))
                        if selectedModels.contains(model.model) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !selectedModels.isEmpty {
                Divider()
                Button(action: { selectedModels = [] }) {
                    Text(t("Clear Selection", "清除选择"))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(modelFilterLabel)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selectedModels.isEmpty ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private var modelFilterLabel: String {
        if selectedModels.isEmpty { return t("All Models", "全部模型") }
        if selectedModels.count == 1, let only = selectedModels.first {
            return shortModelName(only)
        }
        return "\(selectedModels.count) " + t("models", "个模型")
    }

    private func toggleModelSelection(_ model: String) {
        if selectedModels.contains(model) {
            selectedModels.remove(model)
        } else {
            selectedModels.insert(model)
        }
    }

    @ViewBuilder
    private var spendChart: some View {
        let series = chartModelSeries()
        if selectedModels.isEmpty {
            let points = aggregateChartPoints()
            if points.isEmpty {
                Text(t("No data", "暂无数据"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if series.count > 1 {
                multiModelChart
            } else {
                singleSeriesChart(points: points)
            }
        } else if selectedModels.count == 1, let onlyModel = selectedModels.first {
            let points = chartPointsForModel(onlyModel)
            if points.isEmpty {
                Text(t("No data", "暂无数据"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                singleSeriesChart(points: points)
            }
        } else {
            multiModelChartFiltered
        }
    }

    private var multiModelChart: some View {
        multiModelChartFor(chartModelSeries())
    }

    private var multiModelChartFiltered: some View {
        multiModelChartFor(chartModelSeries().filter { selectedModels.contains($0.model) })
    }

    private func multiModelChartFor(_ allSeries: [(model: String, points: [CostTimelinePoint])]) -> some View {
        Chart {
            ForEach(allSeries, id: \.model) { series in
                ForEach(series.points, id: \.bucket) { point in
                    LineMark(
                        x: .value("Time", point.label),
                        y: .value("Value", selectedMetric == .usd ? point.usd : Double(point.tokens))
                    )
                    .foregroundStyle(by: .value("Model", shortModelName(series.model)))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: selectedGranularity == .hourly ? 6 : 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                    .foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                    .foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(selectedMetric == .usd ? chartCurrencyLabel(v) : formatCompactNumber(v))
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private func singleSeriesChart(points: [CostTimelinePoint]) -> some View {
        let tint: Color = selectedMetric == .usd ? .orange : .purple
        return Chart {
            ForEach(points, id: \.bucket) { point in
                let val = selectedMetric == .usd ? point.usd : Double(point.tokens)
                AreaMark(
                    x: .value("Time", point.label),
                    y: .value("Value", val)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.25), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.label),
                    y: .value("Value", val)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: selectedGranularity == .hourly ? 6 : 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                    .foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                    .foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(selectedMetric == .usd ? chartCurrencyLabel(v) : formatCompactNumber(v))
                            .font(.caption2)
                    }
                }
            }
        }
    }

    // MARK: - Model Distribution

    private var distributionModels: [ModelCostBreakdown] {
        switch distributionPeriod {
        case .today: return costSummary?.modelBreakdownToday ?? []
        case .week: return costSummary?.modelBreakdownWeek ?? []
        case .month: return costSummary?.modelBreakdown ?? []
        case .overall: return costSummary?.modelBreakdownOverall ?? []
        }
    }

    private var modelDistribution: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("Model Distribution", "模型分布"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            HStack(spacing: 8) {
                Picker("", selection: $distributionPeriod) {
                    Text(t("Today", "今日")).tag(DistributionPeriod.today)
                    Text(t("Week", "本周")).tag(DistributionPeriod.week)
                    Text(t("Month", "本月")).tag(DistributionPeriod.month)
                    Text(t("All", "全部")).tag(DistributionPeriod.overall)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()

                Picker("", selection: $distributionMetric) {
                    Text("USD").tag(CostMetric.usd)
                    Text("Tokens").tag(CostMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            let distModels = distributionModels
            if distModels.isEmpty {
                Text(t("No data for this period", "该时段暂无数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                donutChart
                    .frame(height: 200)

                VStack(spacing: 6) {
                    ForEach(Array(distModels.prefix(6).enumerated()), id: \.element.id) { index, model in
                        let color = modelColor(index)
                        HStack(spacing: 8) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(shortModelName(model.model))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            if distributionMetric == .usd {
                                Text(formatCurrency(model.estimatedCostUsd))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(color)
                                Text(String(format: "%.1f%%", model.percentage))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(formatCompactNumber(Double(model.totalTokens)))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(color)
                                let totalTokens = distModels.reduce(0) { $0 + $1.totalTokens }
                                let pct = totalTokens > 0 ? Double(model.totalTokens) / Double(totalTokens) * 100 : 0
                                Text(String(format: "%.1f%%", pct))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var donutChart: some View {
        let items = Array(distributionModels.prefix(6))
        let totalTokens = distributionModels.reduce(0) { $0 + $1.totalTokens }
        return Chart(Array(items.enumerated()), id: \.element.id) { index, model in
            SectorMark(
                angle: .value("Value", max(donutValue(model), 0.001)),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .foregroundStyle(modelColor(index))
            .cornerRadius(4)
            .annotation(position: .overlay) {
                let pct = distributionMetric == .usd ? model.percentage :
                    (totalTokens > 0 ? Double(model.totalTokens) / Double(totalTokens) * 100 : 0)
                if pct >= 10 {
                    Text(String(format: "%.0f%%", pct))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func donutValue(_ model: ModelCostBreakdown) -> Double {
        distributionMetric == .usd ? model.estimatedCostUsd : Double(model.totalTokens)
    }

    // MARK: - Model Table

    @State private var expandedModel: String?

    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Model Details", "模型详情"))
                .font(.headline.weight(.bold))

            if models.isEmpty {
                Text(t("No model data", "暂无模型数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(t("Model", "模型")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(t("Cost", "费用")).frame(width: 80, alignment: .trailing)
                        Text("Tokens").frame(width: 80, alignment: .trailing)
                        Text(t("Share", "占比")).frame(width: 60, alignment: .trailing)
                        Text(t("Trend", "趋势")).frame(width: 70, alignment: .center)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        modelRow(model, index: index)
                        if expandedModel == model.model {
                            modelDetailRow(model, index: index)
                        }
                        if index < models.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func modelRow(_ model: ModelCostBreakdown, index: Int) -> some View {
        let color = modelColor(index)
        let sparkValues = modelSparklineValues(model.model)
        let isExpanded = expandedModel == model.model
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle().fill(color).frame(width: 8, height: 8)
                Text(shortModelName(model.model))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatCurrency(model.estimatedCostUsd))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 80, alignment: .trailing)

            Text(formatCompactNumber(Double(model.totalTokens)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(String(format: "%.1f%%", model.percentage))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 60, alignment: .trailing)

            MiniSparkline(values: sparkValues, color: color)
                .frame(width: 56, height: 20)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedModel = expandedModel == model.model ? nil : model.model
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            toggleModelSelection(model.model)
        })
        .background(
            selectedModels.contains(model.model)
                ? RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08))
                : nil
        )
    }

    private func modelDetailRow(_ model: ModelCostBreakdown, index: Int) -> some View {
        let color = modelColor(index)
        return HStack(spacing: 16) {
            Spacer().frame(width: 28)
            tokenBreakdownPill(label: t("Input", "输入"), tokens: model.inputTokens, color: .blue)
            tokenBreakdownPill(label: t("Output", "输出"), tokens: model.outputTokens, color: .green)
            tokenBreakdownPill(label: t("Cache Read", "缓存读取"), tokens: model.cacheReadTokens, color: .orange)
            tokenBreakdownPill(label: t("Cache Write", "缓存写入"), tokens: model.cacheCreateTokens, color: .purple)
            Spacer()
            Button {
                toggleModelSelection(model.model)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: selectedModels.contains(model.model) ? "checkmark.circle.fill" : "circle")
                    Text(t("Compare", "对比"))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(selectedModels.contains(model.model) ? color : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.04))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func tokenBreakdownPill(label: String, tokens: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(formatCompactNumber(Double(tokens)))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.08)))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(t("No cost data found", "未发现费用数据"))
                .font(.title3.weight(.bold))
            Text(t("Claude Code usage logs will appear here.", "Claude Code 使用日志将在这里显示。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Helpers

    private func aggregateChartPoints() -> [CostTimelinePoint] {
        guard let timeline = costSummary?.timeline else { return [] }
        return selectedGranularity == .hourly
            ? (!timeline.hourly.isEmpty ? timeline.hourly : timeline.daily)
            : (!timeline.daily.isEmpty ? timeline.daily : timeline.hourly)
    }

    private func chartPointsForModel(_ model: String) -> [CostTimelinePoint] {
        let modelSeries = costSummary?.modelTimelines?.first { $0.model == model }
        return timelineFromSeries(modelSeries)
    }

    private func chartModelSeries() -> [(model: String, points: [CostTimelinePoint])] {
        guard let modelTimelines = costSummary?.modelTimelines else { return [] }
        return modelTimelines.compactMap { series in
            let points = timelineFromSeries(series)
            guard !points.isEmpty else { return nil }
            return (model: series.model, points: points)
        }
    }

    private func timelineFromSeries(_ series: ModelTimelineSeries?) -> [CostTimelinePoint] {
        guard let series else { return [] }
        return selectedGranularity == .hourly
            ? (!series.hourly.isEmpty ? series.hourly : series.daily)
            : (!series.daily.isEmpty ? series.daily : series.hourly)
    }

    private func modelSparklineValues(_ model: String) -> [Double] {
        guard let series = costSummary?.modelTimelines?.first(where: { $0.model == model }) else { return [] }
        let points = selectedGranularity == .hourly
            ? (!series.hourly.isEmpty ? series.hourly : series.daily)
            : (!series.daily.isEmpty ? series.daily : series.hourly)
        return points.map { selectedMetric == .usd ? $0.usd : Double($0.tokens) }
    }

    private func modelColor(_ index: Int) -> Color {
        let palette: [Color] = [.orange, .blue, .purple, .green, .pink, .cyan, .mint, .indigo, .teal, .red]
        return palette[index % palette.count]
    }

    private func shortModelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20250514", with: "")
    }

    private func chartCurrencyLabel(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 1 { return String(format: "$%.2f", value) }
        if value < 100 { return String(format: "$%.1f", value) }
        return String(format: "$%.0f", value)
    }
}

// MARK: - Mini Sparkline

private struct MiniSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let pts = sparkPoints(in: geometry.size)
            if pts.count > 1 {
                Path { path in
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func sparkPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let range = max(maxV - minV, 0.0001)
        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = size.height * CGFloat(1 - (v - minV) / range)
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Enums

private enum CostGranularity: String, CaseIterable, Identifiable {
    case hourly, daily
    var id: String { rawValue }
}

private enum CostMetric: String, CaseIterable, Identifiable {
    case usd, tokens
    var id: String { rawValue }
}

private enum DistributionPeriod: String, CaseIterable, Identifiable {
    case today, week, month, overall
    var id: String { rawValue }
}

// MARK: - Dashboard Card (used by DashboardView)

struct CostTrackingCard: View {
    let provider: ProviderData

    @EnvironmentObject var appState: AppState
    @State private var showingDetail = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        switch provider.providerId {
        case "claude": return .orange
        default: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.10))
                        .frame(width: 50, height: 50)
                    ProviderIconView(provider.providerId, size: 26)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.label)
                        .font(.headline.weight(.bold))
                    Text(provider.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
            }

            Text(provider.costSummary?.month.map { formatCurrency($0.usd) } ?? "—")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            HStack(spacing: 10) {
                dashboardMetric(title: "Today", value: provider.costSummary?.today.map { formatCurrency($0.usd) } ?? "—")
                dashboardMetric(title: "Week", value: provider.costSummary?.week.map { formatCurrency($0.usd) } ?? "—")
                dashboardMetric(title: "Tokens", value: provider.costSummary?.month?.tokens.map { formatCompactNumber(Double($0)) } ?? "—")
            }

            if let refreshTimestamp = appState.accountRefreshDate(for: provider) {
                RefreshableTimeView(
                    date: refreshTimestamp,
                    language: appState.language,
                    font: .caption2,
                    foregroundStyle: .secondary
                )
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(color.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { showingDetail = true }
        .sheet(isPresented: $showingDetail) {
            ProviderDetailView(provider: provider)
        }
    }

    private func dashboardMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
    }
}

// formatCompactNumber is defined in Utilities.swift
