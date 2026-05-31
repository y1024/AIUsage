import SwiftUI
import Charts
import QuotaBackend

struct ProxyStatsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: ProxyViewModel

    @AppStorage(DefaultsKey.proxyStatsNodeId) private var selectedNodeIdRaw: String = ""
    @AppStorage(DefaultsKey.proxyStatsMetric) private var metric: StatMetric = .cost
    @AppStorage(DefaultsKey.proxyStatsChartRange) private var chartTimeRange: ChartTimeRange = .today
    @AppStorage(DefaultsKey.proxyStatsDistributionMetric) private var distributionMetric: StatMetric = .cost
    @AppStorage(DefaultsKey.proxyStatsFamily) private var familyRaw: String = FamilyFilter.all.rawValue
    @State private var contentWidth: CGFloat = 0
    @State private var expandedModels: Set<String> = []
    @State private var distributionPeriod: DistributionPeriod = .all
    @State private var selectedModels: Set<String> = []
    @State private var chartHoverDate: Date?

    enum DistributionPeriod: String, CaseIterable { case today, week, month, all }

    /// 代理实测的家族过滤：全部 / Claude 代理 / CodeX 代理。
    enum FamilyFilter: String, CaseIterable {
        case all, claude, codex

        var scope: ProxyNodeFamily? {
            switch self {
            case .all: return nil
            case .claude: return .claude
            case .codex: return .codex
            }
        }
    }

    private var familyFilter: FamilyFilter { FamilyFilter(rawValue: familyRaw) ?? .all }
    private var familyBinding: Binding<FamilyFilter> {
        Binding(get: { familyFilter }, set: { familyRaw = $0.rawValue })
    }
    private var selectedFamily: ProxyNodeFamily? { familyFilter.scope }

    /// 当前家族下可见的节点（家族=全部时为所有节点）。
    private var familyNodes: [ProxyConfiguration] {
        guard let scope = selectedFamily else { return viewModel.configurations }
        return viewModel.configurations.filter { scope.contains($0.nodeType) }
    }

    /// 是否同时存在 Claude 与 CodeX 两类节点；只有混合时才展示家族切换控件。
    private var hasMixedFamilies: Bool {
        let hasCodex = viewModel.configurations.contains { $0.nodeType.isCodex }
        let hasClaude = viewModel.configurations.contains { !$0.nodeType.isCodex }
        return hasCodex && hasClaude
    }

    private var nodeBinding: Binding<String> {
        Binding(get: { selectedNodeIdRaw }, set: { selectedNodeIdRaw = $0 })
    }
    private var selectedNodeId: String? { selectedNodeIdRaw.isEmpty ? nil : selectedNodeIdRaw }
    private func validateSelections() {
        // 节点选择必须落在当前家族内；否则回退到「家族内全部」。
        if !selectedNodeIdRaw.isEmpty,
           !familyNodes.contains(where: { $0.id == selectedNodeIdRaw }) {
            selectedNodeIdRaw = ""
        }
        selectedModels = selectedModels.filter {
            viewModel.allUpstreamModels(nodeFilter: selectedNodeId, family: selectedFamily).contains($0)
        }
    }

    enum StatGranularity: String, CaseIterable { case hourly, daily }
    enum StatMetric: String, CaseIterable { case cost, tokens }
    private var granularity: StatGranularity { chartTimeRange.isHourly ? .hourly : .daily }
    private enum InsightsLayout {
        case split
        case stacked
    }

    private struct TrendSeriesDescriptor: Identifiable {
        let model: String
        let points: [ProxyViewModel.ModelTimePoint]
        let totalCost: Double
        let totalTokens: Int

        var id: String { model }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.configurations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    let ranked = rankedTrendSeries
                    let colorMap = buildModelColorMap(from: ranked)
                    LazyVStack(spacing: 16) {
                        filterBar
                        summaryStrip
                        trendChartSection(ranked: ranked, colorMap: colorMap)
                        insightPanelsSection(colorMap: colorMap, sparklineMap: buildSparklineMap(from: ranked))
                    }
                    .padding(20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: ProxyStatsContentWidthPreferenceKey.self, value: proxy.size.width)
                        }
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { validateSelections() }
        .onChange(of: selectedNodeIdRaw) { _, _ in validateSelections() }
        .onChange(of: familyRaw) { _, _ in
            chartHoverDate = nil
            validateSelections()
        }
        .onPreferenceChange(ProxyStatsContentWidthPreferenceKey.self) { newWidth in
            // Threshold avoids rebuilding the whole body on sub-pixel width jitter during scroll
            // or expand/collapse. 8pt is well below the 1080pt breakpoint used by usesStackedInsightsLayout.
            if abs(newWidth - contentWidth) > 8 {
                contentWidth = newWidth
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(L("No proxy nodes configured", "尚未配置代理节点"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L("Add a node in Claude Code Proxy or CodeX Proxy to start tracking usage.",
                   "在 Claude Code 代理或 CodeX 代理中添加节点后即可开始统计用量。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Text(L("Proxy Stats", "代理统计"))
                .font(.title2.weight(.bold))
            Spacer()
            if hasMixedFamilies {
                Picker("", selection: familyBinding) {
                    Text(L("All", "全部")).tag(FamilyFilter.all)
                    Text(L("Claude Proxy", "Claude 代理")).tag(FamilyFilter.claude)
                    Text(L("CodeX Proxy", "CodeX 代理")).tag(FamilyFilter.codex)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    // MARK: - Summary

    private var stats: ProxyViewModel.OverallStats {
        viewModel.overallStats(nodeFilter: selectedNodeId, modelFilter: nil, family: selectedFamily)
    }

    private var dateRange: (earliest: Date?, latest: Date?, days: Int) {
        viewModel.dataDateRange(nodeFilter: selectedNodeId, modelFilter: nil, family: selectedFamily)
    }

    private static let bannerDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        return df
    }()

    private var dataRangeBanner: some View {
        let range = dateRange
        let retentionDays = UserDefaults.standard.integer(forKey: DefaultsKey.proxyLogRetentionDays)
        let effectiveDays = retentionDays > 0 ? retentionDays : 30
        let df = Self.bannerDateFormatter

        return Group {
            if let earliest = range.earliest {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(L("Data covers \(range.days) day(s) (\(df.string(from: earliest)) – \(df.string(from: range.latest ?? Date()))). Logs auto-clean after \(effectiveDays) days.",
                           "数据覆盖 \(range.days) 天（\(df.string(from: earliest)) – \(df.string(from: range.latest ?? Date()))）。日志 \(effectiveDays) 天后自动清理。"))
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

    private var summaryStrip: some View {
        let s = stats
        let range = dateRange
        return VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                summaryCell(icon: "dollarsign.circle.fill",
                            title: L("Cost (\(range.days)d)", "费用（\(range.days)天）"),
                            value: formatCurrency(s.cost), tint: .orange)
                summaryCell(icon: "bolt.fill",
                            title: L("Tokens (\(range.days)d)", "Tokens（\(range.days)天）"),
                            value: formatCompactNumber(Double(s.tokens)), tint: .purple)
                summaryCell(
                    icon: "scope",
                    title: L("Cache Hit Rate", "缓存命中率"),
                    value: s.cacheTokens + s.inputTokens > 0
                        ? String(format: "%.1f%%", s.cacheHitRate)
                        : "—",
                    tint: .teal
                )
                summaryCell(icon: "arrow.up.arrow.down", title: L("Request Count", "请求数"),
                            value: "\(s.requests)", tint: .blue)
                summaryCell(icon: "checkmark.seal.fill", title: L("Success Rate", "成功率"),
                            value: String(format: "%.1f%%", s.successRate), tint: .green)
                summaryCell(icon: "cpu", title: L("Models", "模型数"),
                            value: "\(viewModel.modelAggregates(nodeFilter: selectedNodeId, modelFilter: nil, family: selectedFamily).count)",
                            tint: .pink)
            }
            dataRangeBanner
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Trend Chart

    private var modelTimeSeries: [ProxyViewModel.ModelTimePoint] {
        let all = viewModel.modelTimeSeries(nodeFilter: selectedNodeId, granularity: granularity == .hourly ? "hourly" : "daily", family: selectedFamily)
        guard let start = chartTimeRange.startDate() else { return all }
        return all.filter { $0.date >= start }
    }

    private var maxVisibleTrendModels: Int { 8 }

    private var rankedTrendSeries: [TrendSeriesDescriptor] {
        Dictionary(grouping: modelTimeSeries, by: \.model)
            .map { model, points in
                let sortedPoints = points.sorted { $0.date < $1.date }
                return TrendSeriesDescriptor(
                    model: model,
                    points: sortedPoints,
                    totalCost: sortedPoints.reduce(0) { $0 + $1.cost },
                    totalTokens: sortedPoints.reduce(0) { $0 + $1.tokens }
                )
            }
            .sorted { lhs, rhs in
                let lhsValue = metric == .cost ? lhs.totalCost : Double(lhs.totalTokens)
                let rhsValue = metric == .cost ? rhs.totalCost : Double(rhs.totalTokens)
                if lhsValue == rhsValue {
                    return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
                }
                return lhsValue > rhsValue
            }
    }

    private var modelFilterLabel: String {
        if selectedModels.isEmpty { return L("All Models", "全部模型") }
        if selectedModels.count == 1, let only = selectedModels.first { return only }
        return "\(selectedModels.count) " + L("models", "个模型")
    }

    private func toggleModelSelection(_ model: String) {
        if selectedModels.contains(model) {
            selectedModels.remove(model)
        } else {
            selectedModels.insert(model)
        }
    }

    private func proxyModelFilterMenu(selectableModels: [String]) -> some View {
        Menu {
            Button(action: { selectedModels = [] }) {
                HStack {
                    Text(L("All Models (Combined)", "全部模型（合计）"))
                    if selectedModels.isEmpty {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(selectableModels, id: \.self) { model in
                Button(action: { toggleModelSelection(model) }) {
                    HStack {
                        Text(model)
                        if selectedModels.contains(model) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !selectedModels.isEmpty {
                Divider()
                Button(action: { selectedModels = [] }) {
                    Text(L("Clear Selection", "清除选择"))
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

    private func trendChartSection(ranked: [TrendSeriesDescriptor], colorMap: [String: Color]) -> some View {
        let series: [TrendSeriesDescriptor] = selectedModels.isEmpty
            ? Array(ranked.prefix(maxVisibleTrendModels))
            : ranked.filter { selectedModels.contains($0.model) }
        let hiddenCount = max(0, ranked.count - series.count)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Spend Trend", "消费趋势"))
                    .font(.headline.weight(.bold))

                Spacer()

                if familyNodes.count > 1 {
                    Picker(L("Node", "节点"), selection: nodeBinding) {
                        Text(L("All Nodes", "全部节点")).tag("")
                        ForEach(familyNodes, id: \.id) { config in
                            Text(config.name).tag(config.id)
                        }
                    }
                    .frame(width: 140)
                }

                proxyModelFilterMenu(selectableModels: ranked.map(\.model))

                Picker("", selection: $metric) {
                    Text(L("Cost", "费用")).tag(StatMetric.cost)
                    Text("Tokens").tag(StatMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("", selection: $chartTimeRange) {
                    Text(L("Today", "今日")).tag(ChartTimeRange.today)
                    Text(L("Week", "本周")).tag(ChartTimeRange.thisWeek)
                    Text(L("Month", "本月")).tag(ChartTimeRange.thisMonth)
                    Text(L("All", "全部")).tag(ChartTimeRange.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if series.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else {
                proxyTrendChart(for: series, colorMap: colorMap)
                    .frame(height: 260)

                VStack(alignment: .leading, spacing: 8) {
                    if hiddenCount > 0 && selectedModels.isEmpty {
                        Text(
                            L(
                                "Showing Top \(series.count) models by current metric",
                                "按当前指标仅显示前 \(series.count) 个模型"
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    if series.count > 1 {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(series) { descriptor in
                                StatsLegendChip(
                                    color: colorForProxyModel(descriptor.model, from: colorMap),
                                    title: descriptor.model,
                                    value: metric == .cost
                                        ? formatCurrency(descriptor.totalCost)
                                        : formatCompactNumber(Double(descriptor.totalTokens))
                                )
                                .help(descriptor.model)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Model Distribution

    private var distributionSinceDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch distributionPeriod {
        case .today: return cal.startOfDay(for: now)
        case .week: return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now))
        case .month: return cal.date(byAdding: .month, value: -1, to: cal.startOfDay(for: now))
        case .all: return nil
        }
    }

    private var filteredModelData: [ProxyViewModel.ModelAggregate] {
        viewModel.modelAggregates(nodeFilter: selectedNodeId, modelFilter: nil, since: distributionSinceDate, family: selectedFamily)
    }

    private var modelData: [ProxyViewModel.ModelAggregate] {
        filteredModelData.sorted { lhs, rhs in
            let lhsValue = distributionMetric == .cost ? lhs.cost : Double(lhs.tokens)
            let rhsValue = distributionMetric == .cost ? rhs.cost : Double(rhs.tokens)
            if lhsValue == rhsValue {
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
    }

    private let chartColors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .red, .yellow, .mint, .indigo]

    private var usesStackedInsightsLayout: Bool {
        contentWidth > 0 && contentWidth < 1080
    }

    private var splitDistributionWidth: CGFloat {
        let availableWidth = max(contentWidth, 980)
        return min(max(availableWidth * 0.34, 320), 380)
    }

    private func insightPanelsSection(colorMap: [String: Color], sparklineMap: [String: [Double]]) -> some View {
        let data = modelData
        let distTotal = data.reduce(0.0) { $0 + distributionValue($1) }
        return Group {
            if usesStackedInsightsLayout {
                VStack(alignment: .leading, spacing: 16) {
                    modelDistribution(layout: .stacked, data: data, colorMap: colorMap, distTotal: distTotal)
                    modelTable(layout: .stacked, data: data, colorMap: colorMap, distTotal: distTotal, sparklineMap: sparklineMap)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    modelDistribution(layout: .split, data: data, colorMap: colorMap, distTotal: distTotal)
                        .frame(width: splitDistributionWidth, alignment: .topLeading)
                    modelTable(layout: .split, data: data, colorMap: colorMap, distTotal: distTotal, sparklineMap: sparklineMap)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
            }
        }
    }

    private func distributionChartHeight(for layout: InsightsLayout) -> CGFloat {
        layout == .split ? 210 : 225
    }

    private func tableColumnWidth(_ column: ProxyStatsTableColumn, layout: InsightsLayout) -> CGFloat {
        switch (layout, column) {
        case (.split, .cost): return 88
        case (.split, .tokens): return 86
        case (.split, .share): return 62
        case (.split, .trend): return 70
        case (.stacked, .cost): return 94
        case (.stacked, .tokens): return 92
        case (.stacked, .share): return 68
        case (.stacked, .trend): return 76
        }
    }

    private func buildModelColorMap(from ranked: [TrendSeriesDescriptor]) -> [String: Color] {
        var map: [String: Color] = [:]
        for (idx, descriptor) in ranked.enumerated() {
            map[descriptor.model] = chartColors[idx % chartColors.count]
        }
        return map
    }

    private func colorForProxyModel(_ model: String, from colorMap: [String: Color]) -> Color {
        colorMap[model] ?? chartColors[stablePaletteIndex(for: model, paletteCount: chartColors.count)]
    }

    private func distributionValue(_ item: ProxyViewModel.ModelAggregate) -> Double {
        distributionMetric == .cost ? item.cost : Double(item.tokens)
    }

    private func distributionShare(_ item: ProxyViewModel.ModelAggregate, total: Double) -> Double {
        guard total > 0 else { return 0 }
        return distributionValue(item) / total * 100
    }

    private func distributionValueText(_ item: ProxyViewModel.ModelAggregate) -> String {
        distributionMetric == .cost
            ? formatCurrency(item.cost)
            : formatCompactNumber(Double(item.tokens))
    }

    private func buildSparklineMap(from ranked: [TrendSeriesDescriptor]) -> [String: [Double]] {
        var map: [String: [Double]] = [:]
        for descriptor in ranked {
            map[descriptor.model] = descriptor.points.map {
                metric == .cost ? $0.cost : Double($0.tokens)
            }
        }
        return map
    }

    private func proxyTrendChart(for series: [TrendSeriesDescriptor], colorMap: [String: Color]) -> some View {
        let isSingle = series.count == 1
        return Chart {
            ForEach(series) { descriptor in
                let color = colorForProxyModel(descriptor.model, from: colorMap)

                ForEach(descriptor.points, id: \.id) { point in
                    let value = metric == .cost ? point.cost : Double(point.tokens)

                    if isSingle {
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value(metric == .cost ? "Cost" : "Tokens", value),
                            series: .value("Model", descriptor.model)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.25), color.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(metric == .cost ? "Cost" : "Tokens", value),
                        series: .value("Model", descriptor.model)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: isSingle ? 2.4 : 2.0, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
            }

            if let hoverDate = chartHoverDate {
                RuleMark(x: .value("Hover", hoverDate))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(
                        position: .top, spacing: 4,
                        overflowResolution: .init(x: .fit, y: .disabled)
                    ) {
                        proxyChartTooltip(date: hoverDate, series: series, colorMap: colorMap)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(Color.primary.opacity(0.1))
                AxisValueLabel {
                    if metric == .cost {
                        Text(formatCurrency(value.as(Double.self) ?? 0))
                            .font(.system(size: 9, design: .monospaced))
                    } else {
                        Text(formatCompactNumber(value.as(Double.self) ?? 0))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                    .foregroundStyle(Color.primary.opacity(0.1))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatAxisDate(date))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let rawDate: Date = proxy.value(atX: location.x) else {
                                if chartHoverDate != nil { chartHoverDate = nil }
                                return
                            }
                            let snapped = nearestBucketDate(to: rawDate, from: series)
                            if chartHoverDate != snapped { chartHoverDate = snapped }
                        case .ended:
                            if chartHoverDate != nil { chartHoverDate = nil }
                        }
                    }
            }
        }
    }

    private func nearestBucketDate(to target: Date, from series: [TrendSeriesDescriptor]) -> Date? {
        var closest: Date?
        var minDistance: TimeInterval = .infinity
        for s in series {
            for point in s.points {
                let distance = abs(point.date.timeIntervalSince(target))
                if distance < minDistance {
                    minDistance = distance
                    closest = point.date
                }
            }
        }
        return closest
    }

    private func proxyChartTooltip(date: Date, series: [TrendSeriesDescriptor], colorMap: [String: Color]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(formatTooltipDate(date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            let entries = series.compactMap { descriptor -> (String, Color, Double)? in
                guard let point = descriptor.points.first(where: { $0.date == date }) else { return nil }
                let value = metric == .cost ? point.cost : Double(point.tokens)
                if value == 0 && series.count > 1 { return nil }
                return (descriptor.model, colorForProxyModel(descriptor.model, from: colorMap), value)
            }

            ForEach(entries, id: \.0) { model, color, value in
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(model)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(metric == .cost ? formatCurrency(value) : formatCompactNumber(value))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
            }

            if entries.count > 1 {
                Divider()
                let total = entries.reduce(0.0) { $0 + $1.2 }
                HStack(spacing: 4) {
                    Text(L("Total", "合计"))
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(metric == .cost ? formatCurrency(total) : formatCompactNumber(total))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private static let tooltipHourlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:00"
        return f
    }()
    private static let tooltipDailyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func formatTooltipDate(_ date: Date) -> String {
        let formatter = granularity == .hourly
            ? Self.tooltipHourlyFormatter
            : Self.tooltipDailyFormatter
        return formatter.string(from: date)
    }

    private func modelDistribution(layout: InsightsLayout, data: [ProxyViewModel.ModelAggregate], colorMap: [String: Color], distTotal: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Model Distribution", "模型分布"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Picker("", selection: $distributionPeriod) {
                        Text(L("Today", "今日")).tag(DistributionPeriod.today)
                        Text(L("Week", "本周")).tag(DistributionPeriod.week)
                        Text(L("Month", "本月")).tag(DistributionPeriod.month)
                        Text(L("All", "全部")).tag(DistributionPeriod.all)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    Spacer(minLength: 8)

                    Picker("", selection: $distributionMetric) {
                        Text(L("Cost", "费用")).tag(StatMetric.cost)
                        Text("Tokens").tag(StatMetric.tokens)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $distributionPeriod) {
                        Text(L("Today", "今日")).tag(DistributionPeriod.today)
                        Text(L("Week", "本周")).tag(DistributionPeriod.week)
                        Text(L("Month", "本月")).tag(DistributionPeriod.month)
                        Text(L("All", "全部")).tag(DistributionPeriod.all)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Spacer()
                        Picker("", selection: $distributionMetric) {
                            Text(L("Cost", "费用")).tag(StatMetric.cost)
                            Text("Tokens").tag(StatMetric.tokens)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                }
            }

            if data.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Chart(Array(data.prefix(6)), id: \.id) { item in
                    SectorMark(
                        angle: .value(distributionMetric == .cost ? "Cost" : "Tokens", max(distributionValue(item), 0.001)),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(colorForProxyModel(item.model, from: colorMap))
                    .cornerRadius(4)
                    .annotation(position: .overlay) {
                        let share = distributionShare(item, total: distTotal)
                        if share >= 10 {
                            Text(String(format: "%.0f%%", share))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(height: distributionChartHeight(for: layout))

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(data.prefix(6)), id: \.id) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorForProxyModel(item.model, from: colorMap))
                                .frame(width: 8, height: 8)
                            Text(item.model)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.model)
                            Spacer()
                            Text(distributionValueText(item))
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(colorForProxyModel(item.model, from: colorMap))
                            Text(String(format: "%.1f%%", distributionShare(item, total: distTotal)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Model Table

    private func modelTable(layout: InsightsLayout, data: [ProxyViewModel.ModelAggregate], colorMap: [String: Color], distTotal: Double, sparklineMap: [String: [Double]]) -> some View {
        let costWidth = tableColumnWidth(.cost, layout: layout)
        let tokensWidth = tableColumnWidth(.tokens, layout: layout)
        let shareWidth = tableColumnWidth(.share, layout: layout)
        let trendWidth = tableColumnWidth(.trend, layout: layout)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Model Details", "模型详情"))
                .font(.headline.weight(.bold))

            if data.isEmpty {
                Text(L("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                LazyVStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(L("Model", "模型")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("Cost", "费用")).frame(width: costWidth, alignment: .trailing)
                        Text("Tokens").frame(width: tokensWidth, alignment: .trailing)
                        Text(L("Share", "占比")).frame(width: shareWidth, alignment: .trailing)
                        Text(L("Trend", "趋势")).frame(width: trendWidth, alignment: .center)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    Divider()

                    ForEach(Array(data.enumerated()), id: \.element.id) { index, item in
                        let itemColor = colorForProxyModel(item.model, from: colorMap)
                        proxyModelRow(
                            item,
                            color: itemColor,
                            costWidth: costWidth,
                            tokensWidth: tokensWidth,
                            shareWidth: shareWidth,
                            trendWidth: trendWidth,
                            distTotal: distTotal,
                            sparkValues: sparklineMap[item.model] ?? []
                        )

                        if expandedModels.contains(item.model) {
                            proxyModelDetailRow(item, color: itemColor)
                        }

                        if index < data.count - 1 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func proxyModelRow(
        _ item: ProxyViewModel.ModelAggregate,
        color: Color,
        costWidth: CGFloat,
        tokensWidth: CGFloat,
        shareWidth: CGFloat,
        trendWidth: CGFloat,
        distTotal: Double,
        sparkValues: [Double]
    ) -> some View {
        let isExpanded = expandedModels.contains(item.model)

        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(item.model)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatCurrency(item.cost))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: costWidth, alignment: .trailing)

            Text(formatCompactNumber(Double(item.tokens)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: tokensWidth, alignment: .trailing)

            Text(String(format: "%.1f%%", distributionShare(item, total: distTotal)))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .frame(width: shareWidth, alignment: .trailing)

            MiniSparkline(values: sparkValues, color: color)
                .frame(width: max(52, trendWidth - 8), height: 20)
                .padding(.leading, 8)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expandedModels.remove(item.model)
                } else {
                    expandedModels.insert(item.model)
                }
            }
        }
        .background(
            (isExpanded || selectedModels.contains(item.model))
                ? RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08))
                : nil
        )
    }

    private func proxyModelDetailRow(_ item: ProxyViewModel.ModelAggregate, color: Color) -> some View {
        let cacheEligible = item.inputTokens + item.cacheReadTokens + item.cacheCreationTokens
        let hitRateValue = cacheEligible > 0 ? String(format: "%.1f%%", item.cacheHitRate) : "—"
        let detailItems: [(String, String, Color)] = [
            (L("Requests", "请求"), "\(item.requests)", .secondary),
            (L("Input", "输入"), formatCompactNumber(Double(item.inputTokens)), .blue),
            (L("Output", "输出"), formatCompactNumber(Double(item.outputTokens)), .green),
            (L("Cache Read", "缓存读取"), formatCompactNumber(Double(item.cacheReadTokens)), .orange),
            (L("Cache Write", "缓存写入"), formatCompactNumber(Double(item.cacheCreationTokens)), .purple),
            (L("Hit Rate", "命中率"), hitRateValue, .teal)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(detailItems, id: \.0) { detail in
                    proxyMetricPill(label: detail.0, value: detail.1, color: detail.2)
                }
            }

            HStack {
                Spacer()
                Button {
                    toggleCompareModel(item.model)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedModels.contains(item.model) ? "checkmark.circle.fill" : "circle")
                        Text(L("Compare", "对比"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selectedModels.contains(item.model) ? color : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(color.opacity(0.04))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func toggleCompareModel(_ model: String) {
        toggleModelSelection(model)
    }

    private func proxyMetricPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }

    // MARK: - Formatting

    private func formatAxisDate(_ date: Date) -> String {
        DateFormat.string(from: date, format: granularity == .hourly ? "HH:mm" : "MM/dd")
    }
}

private enum ProxyStatsTableColumn {
    case cost
    case tokens
    case share
    case trend
}

private struct ProxyStatsContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    ProxyStatsView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 900, height: 700)
}
