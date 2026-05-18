import SwiftUI

// MARK: - Bucket → Date Parsing

private enum BucketDateParser {
    private static let hourly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let daily: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parse(_ bucket: String) -> Date {
        hourly.date(from: bucket) ?? daily.date(from: bucket) ?? .distantPast
    }
}

extension CostTimelinePoint {
    var date: Date { BucketDateParser.parse(bucket) }
}

extension CostTrackingView {

    typealias ChartSeriesDescriptor = (model: String, points: [CostTimelinePoint], totalUsd: Double, totalTokens: Int)

    func aggregateChartPoints() -> [CostTimelinePoint] {
        guard let timeline = costSummary?.timeline else { return [] }
        let raw = selectedGranularity == .hourly
            ? (!timeline.hourly.isEmpty ? timeline.hourly : timeline.daily)
            : (!timeline.daily.isEmpty ? timeline.daily : timeline.hourly)
        return filterByTimeRange(raw)
    }

    func filterByTimeRange(_ points: [CostTimelinePoint]) -> [CostTimelinePoint] {
        guard let start = chartTimeRange.startDate() else { return points }
        return points.filter { $0.date >= start }
    }

    func chartPointsForModel(_ model: String) -> [CostTimelinePoint] {
        let modelSeries = costSummary?.modelTimelines?.first { $0.model == model }
        return timelineFromSeries(modelSeries)
    }

    func chartModelSeries() -> [ChartSeriesDescriptor] {
        guard let modelTimelines = costSummary?.modelTimelines else { return [] }
        return modelTimelines.compactMap { series in
            let points = timelineFromSeries(series)
            guard !points.isEmpty else { return nil }
            return (
                model: series.model,
                points: points,
                totalUsd: points.reduce(0) { $0 + $1.usd },
                totalTokens: points.reduce(0) { $0 + $1.tokens }
            )
        }
    }

    func sortedChartSeries() -> [ChartSeriesDescriptor] {
        chartModelSeries().sorted { lhs, rhs in
            let lhsValue = selectedMetric == .usd ? lhs.totalUsd : Double(lhs.totalTokens)
            let rhsValue = selectedMetric == .usd ? rhs.totalUsd : Double(rhs.totalTokens)
            if lhsValue == rhsValue {
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
    }

    func displayedChartSeries(limit: Int = 8) -> [ChartSeriesDescriptor] {
        computeDisplayedSeries(from: sortedChartSeries(), limit: limit)
    }

    func computeDisplayedSeries(from sorted: [ChartSeriesDescriptor], limit: Int = 8) -> [ChartSeriesDescriptor] {
        guard !selectedModels.isEmpty else { return Array(sorted.prefix(limit)) }
        let selected = sorted.filter { selectedModels.contains($0.model) }
        return selected.isEmpty ? Array(sorted.prefix(limit)) : selected
    }

    var hiddenChartSeriesCount: Int {
        let allCount = sortedChartSeries().count
        let visibleCount = displayedChartSeries().count
        return max(0, allCount - visibleCount)
    }

    var chartSelectableModels: [String] {
        sortedChartSeries().map(\.model)
    }

    func buildColorMap(from sorted: [ChartSeriesDescriptor]) -> [String: Color] {
        let palette = Self.modelPalette
        var map: [String: Color] = [:]
        for (idx, series) in sorted.enumerated() {
            map[series.model] = palette[idx % palette.count]
        }
        return map
    }

    func timelineFromSeries(_ series: ModelTimelineSeries?) -> [CostTimelinePoint] {
        guard let series else { return [] }
        let raw = selectedGranularity == .hourly
            ? (!series.hourly.isEmpty ? series.hourly : series.daily)
            : (!series.daily.isEmpty ? series.daily : series.hourly)
        return filterByTimeRange(raw)
    }

    func modelSparklineValues(_ model: String) -> [Double] {
        guard let series = costSummary?.modelTimelines?.first(where: { $0.model == model }) else { return [] }
        let raw = selectedGranularity == .hourly
            ? (!series.hourly.isEmpty ? series.hourly : series.daily)
            : (!series.daily.isEmpty ? series.daily : series.hourly)
        return filterByTimeRange(raw).map { selectedMetric == .usd ? $0.usd : Double($0.tokens) }
    }

    private static let modelPalette: [Color] = [.orange, .blue, .purple, .green, .pink, .cyan, .mint, .indigo, .teal, .red]

    var modelColorMap: [String: Color] {
        let palette = Self.modelPalette
        var map: [String: Color] = [:]
        for (idx, series) in sortedChartSeries().enumerated() {
            map[series.model] = palette[idx % palette.count]
        }
        return map
    }

    func modelColor(for model: String, from colorMap: [String: Color]) -> Color {
        colorMap[model] ?? Self.modelPalette[stablePaletteIndex(for: model, paletteCount: Self.modelPalette.count)]
    }

    func distributionShare(for model: ModelCostBreakdown, totalTokens: Int) -> Double {
        guard distributionMetric == .tokens else { return model.percentage }
        guard totalTokens > 0 else { return 0 }
        return Double(model.totalTokens) / Double(totalTokens) * 100
    }

    func shortModelName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20250514", with: "")
    }

    func chartCurrencyLabel(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 1 { return String(format: "$%.2f", value) }
        if value < 100 { return String(format: "$%.1f", value) }
        return String(format: "$%.0f", value)
    }

}
