import SwiftUI
import Charts

private struct OptionalDateChartXScale: ViewModifier {
    let domain: ClosedRange<Date>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let domain {
            content.chartXScale(domain: domain)
        } else {
            content
        }
    }
}

extension CostTrackingView {

    private var maxVisibleChartModels: Int { 8 }

    var chartSection: some View {
        let allSorted = cachedSortedChartSeries
        let displayed = computeDisplayedSeries(from: allSorted, limit: maxVisibleChartModels)
        let colorMap = cachedModelColorMap
        let hiddenCount = max(0, allSorted.count - displayed.count)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Spend Trend", "消费趋势"))
                    .font(.headline.weight(.bold))

                Spacer()

                modelFilterMenuView(selectableModels: allSorted.map(\.model))

                Picker("", selection: $selectedMetric) {
                    Text("USD").tag(CostMetric.usd)
                    Text("Tokens").tag(CostMetric.tokens)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("", selection: Binding(
                    get: { chartTimeRange },
                    set: { selectChartTimeRange($0) }
                )) {
                    Text(L("Today", "今日")).tag(ChartTimeRange.today)
                    Text(L("Week", "本周")).tag(ChartTimeRange.thisWeek)
                    Text(L("Month", "本月")).tag(ChartTimeRange.thisMonth)
                    Text(L("All", "全部")).tag(ChartTimeRange.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            spendChartView(series: displayed, colorMap: colorMap)
                .frame(height: 220)

            chartLegendView(series: displayed, colorMap: colorMap, hiddenCount: hiddenCount)
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

    var modelFilterMenu: some View {
        modelFilterMenuView(selectableModels: chartSelectableModels)
    }

    func modelFilterMenuView(selectableModels: [String]) -> some View {
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

    var modelFilterLabel: String {
        if selectedModels.isEmpty { return L("All Models", "全部模型") }
        if selectedModels.count == 1, let only = selectedModels.first {
            return shortModelName(only)
        }
        return "\(selectedModels.count) " + L("models", "个模型")
    }

    func toggleModelSelection(_ model: String) {
        if selectedModels.contains(model) {
            selectedModels.remove(model)
        } else {
            selectedModels.insert(model)
        }
    }

    @ViewBuilder
    var spendChart: some View {
        spendChartView(series: displayedChartSeries(limit: maxVisibleChartModels), colorMap: modelColorMap)
    }

    @ViewBuilder
    func spendChartView(series: [ChartSeriesDescriptor], colorMap: [String: Color]) -> some View {
        if selectedModels.isEmpty {
            let points = aggregateChartPoints()
            if !points.contains(where: hasUsage) {
                Text(L("No data", "暂无数据"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if series.count > 1 {
                multiModelChartFor(series, colorMap: colorMap)
            } else {
                singleSeriesChart(points: points)
            }
        } else if selectedModels.count == 1, let onlyModel = selectedModels.first {
            let points = chartPointsForModel(onlyModel)
            if !points.contains(where: hasUsage) {
                Text(L("No data", "暂无数据"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                singleSeriesChart(points: points)
            }
        } else {
            multiModelChartFor(series, colorMap: colorMap)
        }
    }

    func multiModelChartFor(_ allSeries: [ChartSeriesDescriptor], colorMap: [String: Color]) -> some View {
        let isUsd = selectedMetric == .usd
        let hoverDate = chartHoverDate
        let xDomain = chartCurrentXDomain()
        let singlePointModels = Set(
            allSeries
                .filter { $0.points.filter(hasUsage).count == 1 }
                .map(\.model)
        )
        return Chart {
            ForEach(allSeries, id: \.model) { series in
                let color = modelColor(for: series.model, from: colorMap)
                ForEach(series.points, id: \.bucket) { point in
                    let yVal: Double = isUsd ? point.usd : Double(point.tokens)
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", yVal),
                        series: .value("Model", series.model)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))

                    if singlePointModels.contains(series.model), hasUsage(point) {
                        PointMark(
                            x: .value("Time", point.date),
                            y: .value("Value", yVal)
                        )
                        .foregroundStyle(color)
                        .symbolSize(44)
                    }
                }
            }

            if let hoverDate {
                RuleMark(x: .value("Hover", hoverDate))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit, y: .disabled)) {
                        multiModelTooltip(date: hoverDate, series: allSeries, colorMap: colorMap)
                    }
            }
        }
        .chartLegend(.hidden)
        .modifier(OptionalDateChartXScale(domain: xDomain))
        .chartXAxis { costChartXAxis }
        .chartYAxis { costChartYAxis }
        .chartOverlay { (proxy: ChartProxy) in
            GeometryReader { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let rawDate: Date = proxy.value(atX: location.x),
                                  !allSeries.isEmpty else {
                                if chartHoverDate != nil { chartHoverDate = nil }
                                return
                            }
                            let snapped = nearestPointDate(to: rawDate, fromSeries: allSeries)
                            if chartHoverDate != snapped { chartHoverDate = snapped }
                        case .ended:
                            if chartHoverDate != nil { chartHoverDate = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    var chartLegendSection: some View {
        chartLegendView(series: displayedChartSeries(limit: maxVisibleChartModels), colorMap: modelColorMap, hiddenCount: hiddenChartSeriesCount)
    }

    @ViewBuilder
    func chartLegendView(series: [ChartSeriesDescriptor], colorMap: [String: Color], hiddenCount: Int) -> some View {
        if series.count > 1 {
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

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(series, id: \.model) { series in
                        StatsLegendChip(
                            color: modelColor(for: series.model, from: colorMap),
                            title: series.model,
                            value: selectedMetric == .usd
                                ? formatCurrency(series.totalUsd)
                                : formatCompactNumber(Double(series.totalTokens))
                        )
                        .help(series.model)
                    }
                }
            }
        }
    }

    func singleSeriesChart(points: [CostTimelinePoint]) -> some View {
        let isUsd = selectedMetric == .usd
        let tint: Color = isUsd ? .orange : .purple
        let gradient = LinearGradient(
            colors: [tint.opacity(0.25), tint.opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
        let hoverDate = chartHoverDate
        let xDomain = chartCurrentXDomain()
        let showSinglePoint = points.filter(hasUsage).count == 1
        return Chart {
            ForEach(points, id: \.bucket) { point in
                let yVal: Double = isUsd ? point.usd : Double(point.tokens)
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Value", yVal)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(gradient)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Value", yVal)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))

                if showSinglePoint, hasUsage(point) {
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Value", yVal)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(48)
                }
            }

            if let hoverDate {
                RuleMark(x: .value("Hover", hoverDate))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit, y: .disabled)) {
                        singleTooltip(date: hoverDate, points: points, tint: tint)
                    }
            }
        }
        .modifier(OptionalDateChartXScale(domain: xDomain))
        .chartXAxis { costChartXAxis }
        .chartYAxis { costChartYAxis }
        .chartOverlay { (proxy: ChartProxy) in
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
                            let snapped = nearestPointDate(to: rawDate, from: points)
                            if chartHoverDate != snapped { chartHoverDate = snapped }
                        case .ended:
                            if chartHoverDate != nil { chartHoverDate = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Shared Axis Builders

    @AxisContentBuilder
    var costChartXAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: selectedGranularity == .hourly ? 6 : 7)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [3, 4]))
                .foregroundStyle(.secondary.opacity(0.15))
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(date, format: selectedGranularity == .hourly
                         ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                         : .dateTime.month(.twoDigits).day(.twoDigits))
                        .font(.caption2)
                }
            }
        }
    }

    @AxisContentBuilder
    var costChartYAxis: some AxisContent {
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

    // MARK: - Chart Hover Helpers

    func nearestPointDate(to target: Date, from points: [CostTimelinePoint]) -> Date? {
        var closest: Date?
        var minDistance: TimeInterval = .infinity
        for point in points {
            let distance = abs(point.date.timeIntervalSince(target))
            if distance < minDistance {
                minDistance = distance
                closest = point.date
            }
        }
        return closest
    }

    func nearestPointDate(to target: Date, fromSeries allSeries: [ChartSeriesDescriptor]) -> Date? {
        var closest: Date?
        var minDistance: TimeInterval = .infinity
        for series in allSeries {
            for point in series.points {
                let distance = abs(point.date.timeIntervalSince(target))
                if distance < minDistance {
                    minDistance = distance
                    closest = point.date
                }
            }
        }
        return closest
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

    private func tooltipDateLabel(_ date: Date) -> String {
        let formatter = selectedGranularity == .hourly
            ? Self.tooltipHourlyFormatter
            : Self.tooltipDailyFormatter
        return formatter.string(from: date)
    }

    func singleTooltip(date: Date, points: [CostTimelinePoint], tint: Color) -> some View {
        let point = points.first(where: { $0.date == date })
        let value = point.map { selectedMetric == .usd ? $0.usd : Double($0.tokens) } ?? 0

        return VStack(alignment: .leading, spacing: 3) {
            Text(tooltipDateLabel(date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(selectedMetric == .usd ? formatCurrency(value) : formatCompactNumber(value))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    func multiModelTooltip(date: Date, series: [ChartSeriesDescriptor], colorMap: [String: Color]) -> some View {
        let entries: [(String, Color, Double)] = series.compactMap { s in
            guard let point = s.points.first(where: { $0.date == date }) else { return nil }
            let value = selectedMetric == .usd ? point.usd : Double(point.tokens)
            if value == 0 && series.count > 1 { return nil }
            return (s.model, modelColor(for: s.model, from: colorMap), value)
        }

        return VStack(alignment: .leading, spacing: 3) {
            Text(tooltipDateLabel(date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(entries, id: \.0) { model, color, value in
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(shortModelName(model))
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(selectedMetric == .usd ? formatCurrency(value) : formatCompactNumber(value))
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
                    Text(selectedMetric == .usd ? formatCurrency(total) : formatCompactNumber(total))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}
