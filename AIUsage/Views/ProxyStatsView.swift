import SwiftUI
import Charts
import QuotaBackend

struct ProxyStatsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: ProxyViewModel

    @AppStorage("proxyStatsNodeId") private var selectedNodeIdRaw: String = ""
    @AppStorage("proxyStatsModel") private var selectedModelRaw: String = ""
    @AppStorage("proxyStatsGranularity") private var granularity: StatGranularity = .daily
    @AppStorage("proxyStatsMetric") private var metric: StatMetric = .cost

    private var nodeBinding: Binding<String> {
        Binding(get: { selectedNodeIdRaw }, set: { selectedNodeIdRaw = $0 })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { selectedModelRaw }, set: { selectedModelRaw = $0 })
    }
    private var selectedNodeId: String? { selectedNodeIdRaw.isEmpty ? nil : selectedNodeIdRaw }
    private var selectedModel: String? { selectedModelRaw.isEmpty ? nil : selectedModelRaw }

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private func validateSelections() {
        if !selectedNodeIdRaw.isEmpty,
           !viewModel.configurations.contains(where: { $0.id == selectedNodeIdRaw }) {
            selectedNodeIdRaw = ""
        }
        if !selectedModelRaw.isEmpty,
           !viewModel.allUpstreamModels(nodeFilter: selectedNodeId).contains(selectedModelRaw) {
            selectedModelRaw = ""
        }
    }

    enum StatGranularity: String, CaseIterable { case hourly, daily }
    enum StatMetric: String, CaseIterable { case cost, tokens }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.configurations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        filterBar
                        summaryStrip
                        trendChart
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
        .onAppear { validateSelections() }
        .onChange(of: selectedNodeIdRaw) { _ in validateSelections() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(t("No proxy nodes configured", "尚未配置代理节点"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(t("Add a proxy node in Claude Code Proxy to start tracking usage.",
                   "在 Claude Code 代理中添加节点后即可开始统计用量。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Text(t("Proxy Stats", "代理统计"))
                .font(.title2.weight(.bold))

            Spacer()

            Picker(t("Node", "节点"), selection: nodeBinding) {
                Text(t("All Nodes", "全部节点")).tag("")
                ForEach(viewModel.configurations, id: \.id) { config in
                    Text(config.name).tag(config.id)
                }
            }
            .frame(width: 160)

            Picker(t("Model", "模型"), selection: modelBinding) {
                Text(t("All Models", "全部模型")).tag("")
                ForEach(viewModel.allUpstreamModels(nodeFilter: selectedNodeId), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .frame(width: 160)
        }
    }

    // MARK: - Summary

    private var stats: (cost: Double, tokens: Int, requests: Int, successRate: Double) {
        viewModel.overallStats(nodeFilter: selectedNodeId, modelFilter: selectedModel)
    }

    private var dateRange: (earliest: Date?, latest: Date?, days: Int) {
        viewModel.dataDateRange(nodeFilter: selectedNodeId, modelFilter: selectedModel)
    }

    private static let bannerDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        return df
    }()

    private var dataRangeBanner: some View {
        let range = dateRange
        let retentionDays = UserDefaults.standard.integer(forKey: "proxyLogRetentionDays")
        let effectiveDays = retentionDays > 0 ? retentionDays : 30
        let df = Self.bannerDateFormatter

        return Group {
            if let earliest = range.earliest {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(t("Data covers \(range.days) day(s) (\(df.string(from: earliest)) – \(df.string(from: range.latest ?? Date()))). Logs auto-clean after \(effectiveDays) days.",
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
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                summaryCell(icon: "dollarsign.circle.fill",
                            title: t("Cost (\(dateRange.days)d)", "费用（\(dateRange.days)天）"),
                            value: formatCurrency(s.cost), tint: .orange)
                summaryCell(icon: "bolt.fill",
                            title: t("Tokens (\(dateRange.days)d)", "Tokens（\(dateRange.days)天）"),
                            value: formatCompactNumber(Double(s.tokens)), tint: .purple)
                summaryCell(icon: "arrow.up.arrow.down", title: t("Requests", "请求数"),
                            value: "\(s.requests)", tint: .blue)
                summaryCell(icon: "checkmark.seal.fill", title: t("Success Rate", "成功率"),
                            value: String(format: "%.1f%%", s.successRate), tint: .green)
                summaryCell(icon: "cpu", title: t("Models", "模型数"),
                            value: "\(viewModel.modelAggregates(nodeFilter: selectedNodeId, modelFilter: selectedModel).count)",
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
        viewModel.modelTimeSeries(nodeFilter: selectedNodeId, granularity: granularity == .hourly ? "hourly" : "daily")
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("Spend Trend", "消费趋势"))
                    .font(.headline.weight(.bold))
                Spacer()
                Picker("", selection: $metric) {
                    Text(t("Cost", "费用")).tag(StatMetric.cost)
                    Text("Tokens").tag(StatMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("", selection: $granularity) {
                    Text(t("Hourly", "小时")).tag(StatGranularity.hourly)
                    Text(t("Daily", "每日")).tag(StatGranularity.daily)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            let data = modelTimeSeries
            let models = Array(Set(data.map(\.model))).sorted()
            if data.isEmpty {
                Text(t("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else {
                let yLabel = metric == .cost ? "Cost" : "Tokens"

                Chart(data) { item in
                    let yVal = metric == .cost ? item.cost : Double(item.tokens)

                    AreaMark(
                        x: .value("Time", item.date),
                        y: .value(yLabel, yVal)
                    )
                    .foregroundStyle(by: .value("Model", item.model))
                    .opacity(0.2)
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", item.date),
                        y: .value(yLabel, yVal)
                    )
                    .foregroundStyle(by: .value("Model", item.model))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    if data.count <= 30 {
                        PointMark(
                            x: .value("Time", item.date),
                            y: .value(yLabel, yVal)
                        )
                        .foregroundStyle(by: .value("Model", item.model))
                        .symbolSize(16)
                    }
                }
                .chartForegroundStyleScale(domain: models, range: chartColors)
                .chartLegend(position: .top, alignment: .trailing)
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
                .frame(height: 260)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Model Distribution

    private var modelData: [ProxyViewModel.ModelAggregate] {
        viewModel.modelAggregates(nodeFilter: selectedNodeId, modelFilter: selectedModel)
    }

    private let chartColors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .red, .yellow]

    private var modelDistribution: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Model Distribution", "模型分布"))
                .font(.headline.weight(.bold))

            let data = modelData
            if data.isEmpty {
                Text(t("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                Chart(Array(data.enumerated()), id: \.element.id) { idx, item in
                    SectorMark(
                        angle: .value("Cost", item.cost),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(chartColors[idx % chartColors.count])
                    .cornerRadius(4)
                }
                .frame(height: 180)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(data.prefix(6).enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(chartColors[idx % chartColors.count])
                                .frame(width: 8, height: 8)
                            Text(item.model)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(formatCurrency(item.cost))
                                .font(.caption.weight(.medium).monospacedDigit())
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

    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Model Details", "模型明细"))
                .font(.headline.weight(.bold))

            let data = modelData
            if data.isEmpty {
                Text(t("No data yet", "暂无数据"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        Text(t("Model", "模型")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(t("Requests", "请求")).frame(width: 60, alignment: .trailing)
                        Text(t("Input", "输入")).frame(width: 70, alignment: .trailing)
                        Text(t("Output", "输出")).frame(width: 70, alignment: .trailing)
                        Text(t("Cache", "缓存")).frame(width: 70, alignment: .trailing)
                        Text(t("Cost", "费用")).frame(width: 80, alignment: .trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    Divider()

                    ForEach(data) { item in
                        HStack(spacing: 0) {
                            Text(item.model)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(item.requests)")
                                .frame(width: 60, alignment: .trailing)
                            Text(formatCompactNumber(Double(item.inputTokens)))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatCompactNumber(Double(item.outputTokens)))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatCompactNumber(Double(item.cacheTokens)))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatCurrency(item.cost))
                                .font(.caption.weight(.semibold))
                                .frame(width: 80, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)

                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Formatting

    private func formatAxisDate(_ date: Date) -> String {
        DateFormat.string(from: date, format: granularity == .hourly ? "HH:mm" : "MM/dd")
    }
}

#Preview {
    ProxyStatsView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 900, height: 700)
}
