import SwiftUI

// MARK: - Bucket → Date Parsing

private enum BucketDateParser {
    /// Wrapper class so the cache can store either a parsed `Date` or an
    /// explicit "unresolvable" marker without using a magic sentinel value.
    /// Replaces the prior `Date(timeIntervalSince1970: -1)` sentinel.
    private final class CachedDate {
        let date: Date?
        init(_ date: Date?) { self.date = date }
    }

    private static let lock = NSLock()
    private static let cache: NSCache<NSString, CachedDate> = {
        let cache = NSCache<NSString, CachedDate>()
        cache.countLimit = 2_048
        return cache
    }()

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

    /// Returns the parsed date for a bucket label, or `nil` when the input matches neither
    /// the hourly nor daily format. Cached and thread-safe.
    static func parseOptional(_ bucket: String) -> Date? {
        let cacheKey = bucket as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.date
        }

        lock.lock()
        defer { lock.unlock() }

        if let cached = cache.object(forKey: cacheKey) {
            return cached.date
        }

        let parsed = hourly.date(from: bucket) ?? daily.date(from: bucket)
        cache.setObject(CachedDate(parsed), forKey: cacheKey)
        return parsed
    }

    /// Convenience for callers that need a non-optional `Date`. Falls back to
    /// `.distantPast` so chart rendering does not crash, but callers that surface points
    /// to time-domain charts should prefer `parseOptional` and filter unparseable points
    /// upstream — otherwise `.all` views will be pinned to year 1 by garbage buckets.
    static func parse(_ bucket: String) -> Date {
        parseOptional(bucket) ?? .distantPast
    }
}

extension CostTimelinePoint {
    var date: Date { BucketDateParser.parse(bucket) }

    /// Nil when the bucket label cannot be parsed by either the hourly or daily formatter.
    /// Used by upstream filters to drop garbage points before they reach the chart domain.
    var resolvedDate: Date? { BucketDateParser.parseOptional(bucket) }
}

private extension Array where Element == CostTimelinePoint {
    /// Drop points whose `bucket` cannot be parsed. Without this filter a single bad
    /// bucket would surface as `.distantPast` and stretch the chart X-axis to year 1
    /// in the `.all` time range (which intentionally does not apply a domain clamp).
    func droppingUnresolvedDates() -> [CostTimelinePoint] {
        filter { $0.resolvedDate != nil }
    }
}

extension CostTrackingView {

    func aggregateChartPoints() -> [CostTimelinePoint] {
        cachedAggregateChartPoints
    }

    func makeAggregateChartPoints(from summary: CostSummary) -> [CostTimelinePoint] {
        guard let timeline = summary.timeline else { return [] }
        let raw = selectedGranularity == .hourly
            ? (!timeline.hourly.isEmpty ? timeline.hourly : timeline.daily)
            : (!timeline.daily.isEmpty ? timeline.daily : timeline.hourly)
        return filterByTimeRange(raw.droppingUnresolvedDates())
    }

    func hasUsage(_ point: CostTimelinePoint) -> Bool {
        point.tokens > 0 || point.usd > 0
    }

    func hasUsage(_ model: ModelCostBreakdown) -> Bool {
        model.totalTokens > 0 || model.estimatedCostUsd > 0
    }

    func filterByTimeRange(_ points: [CostTimelinePoint]) -> [CostTimelinePoint] {
        guard let start = chartTimeRange.startDate() else { return points }
        let now = Date()
        return points.filter {
            let date = $0.date
            return date >= start && date <= now
        }
    }

    func chartCurrentXDomain() -> ClosedRange<Date>? {
        guard let start = chartTimeRange.startDate() else { return nil }
        let now = Date()
        guard now > start else {
            let fallbackEnd = start.addingTimeInterval(selectedGranularity == .hourly ? 3_600 : 86_400)
            return start...fallbackEnd
        }
        return start...now
    }

    func chartPointsForModel(_ model: String) -> [CostTimelinePoint] {
        cachedSortedChartSeries.first { $0.model == model }?.points ?? []
    }

    func makeChartModelSeries(from summary: CostSummary) -> [ChartSeriesDescriptor] {
        guard let modelTimelines = summary.modelTimelines else { return [] }
        return modelTimelines.compactMap { series in
            let points = timelineFromSeries(series)
            guard points.contains(where: hasUsage) else { return nil }
            return ChartSeriesDescriptor(
                model: series.model,
                points: points,
                totalUsd: points.reduce(0) { $0 + $1.usd },
                totalTokens: points.reduce(0) { $0 + $1.tokens }
            )
        }
    }

    func makeSortedChartSeries(from summary: CostSummary) -> [ChartSeriesDescriptor] {
        makeChartModelSeries(from: summary).sorted { lhs, rhs in
            let lhsValue = selectedMetric == .usd ? lhs.totalUsd : Double(lhs.totalTokens)
            let rhsValue = selectedMetric == .usd ? rhs.totalUsd : Double(rhs.totalTokens)
            if lhsValue == rhsValue {
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
    }

    func displayedChartSeries(limit: Int = 8) -> [ChartSeriesDescriptor] {
        computeDisplayedSeries(from: cachedSortedChartSeries, limit: limit)
    }

    func computeDisplayedSeries(from sorted: [ChartSeriesDescriptor], limit: Int = 8) -> [ChartSeriesDescriptor] {
        guard !selectedModels.isEmpty else { return Array(sorted.prefix(limit)) }
        let selected = sorted.filter { selectedModels.contains($0.model) }
        return selected.isEmpty ? Array(sorted.prefix(limit)) : selected
    }

    var hiddenChartSeriesCount: Int {
        let allCount = cachedSortedChartSeries.count
        let visibleCount = displayedChartSeries().count
        return max(0, allCount - visibleCount)
    }

    var chartSelectableModels: [String] {
        cachedSortedChartSeries.map(\.model)
    }

    func timelineFromSeries(_ series: ModelTimelineSeries?) -> [CostTimelinePoint] {
        guard let series else { return [] }
        let raw = selectedGranularity == .hourly
            ? (!series.hourly.isEmpty ? series.hourly : series.daily)
            : (!series.daily.isEmpty ? series.daily : series.hourly)
        return filterByTimeRange(raw.droppingUnresolvedDates())
    }

    func modelSparklineValues(_ model: String) -> [Double] {
        cachedSparklineValuesByModel[model] ?? []
    }

    private static let modelPalette: [Color] = [.orange, .blue, .purple, .green, .pink, .cyan, .mint, .indigo, .teal, .red]

    var modelColorMap: [String: Color] {
        cachedModelColorMap
    }

    func makeModelColorMap(from series: [ChartSeriesDescriptor]) -> [String: Color] {
        let palette = Self.modelPalette
        var map: [String: Color] = [:]
        for (idx, descriptor) in series.enumerated() {
            map[descriptor.model] = palette[idx % palette.count]
        }
        return map
    }

    func makeSparklineValuesByModel(from series: [ChartSeriesDescriptor]) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: series.map { descriptor in
            (
                descriptor.model,
                descriptor.points.map { selectedMetric == .usd ? $0.usd : Double($0.tokens) }
            )
        })
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

// MARK: - Aggregate Source

extension CostTrackingView {

    func aggregateCostSummaries(_ providers: [ProviderData]) -> CostSummary? {
        let items = providers.compactMap { provider -> (provider: ProviderData, summary: CostSummary)? in
            guard let summary = provider.costSummary else { return nil }
            return (provider, summary)
        }
        guard !items.isEmpty else { return nil }

        let summaries = items.map(\.summary)

        let timeline = aggregateTimeline(summaries.compactMap(\.timeline))
        let monthBreakdown = aggregateModelBreakdowns(items.flatMap { qualifiedBreakdowns($0.summary.modelBreakdown, provider: $0.provider) })
        let todayBreakdown = aggregateModelBreakdowns(items.flatMap { qualifiedBreakdowns($0.summary.modelBreakdownToday, provider: $0.provider) })
        let weekBreakdown = aggregateModelBreakdowns(items.flatMap { qualifiedBreakdowns($0.summary.modelBreakdownWeek, provider: $0.provider) })
        let overallBreakdown = aggregateModelBreakdowns(items.flatMap { qualifiedBreakdowns($0.summary.modelBreakdownOverall, provider: $0.provider) })
        let modelTimelines = aggregateModelTimelines(items.flatMap { qualifiedTimelines($0.summary.modelTimelines, provider: $0.provider) })

        return CostSummary(
            today: aggregatePeriod(summaries.map(\.today), label: L("Today", "今天")),
            week: aggregatePeriod(summaries.map(\.week), label: L("This Week", "本周")),
            month: aggregatePeriod(summaries.map(\.month), label: L("This Month", "本月")),
            overall: aggregatePeriod(summaries.map(\.overall), label: L("All Sources", "综合")),
            timeline: timeline,
            modelBreakdown: monthBreakdown.isEmpty ? nil : monthBreakdown,
            modelBreakdownToday: todayBreakdown.isEmpty ? nil : todayBreakdown,
            modelBreakdownWeek: weekBreakdown.isEmpty ? nil : weekBreakdown,
            modelBreakdownOverall: overallBreakdown.isEmpty ? nil : overallBreakdown,
            modelTimelines: modelTimelines.isEmpty ? nil : modelTimelines
        )
    }

    private func qualifiedBreakdowns(_ breakdowns: [ModelCostBreakdown]?, provider: ProviderData) -> [ModelCostBreakdown] {
        (breakdowns ?? []).map { item in
            ModelCostBreakdown(
                model: sourceQualifiedModel(item.model, provider: provider),
                totalTokens: item.totalTokens,
                inputTokens: item.inputTokens,
                outputTokens: item.outputTokens,
                cacheReadTokens: item.cacheReadTokens,
                cacheCreateTokens: item.cacheCreateTokens,
                estimatedCostUsd: item.estimatedCostUsd,
                percentage: item.percentage
            )
        }
    }

    private func qualifiedTimelines(_ series: [ModelTimelineSeries]?, provider: ProviderData) -> [ModelTimelineSeries] {
        (series ?? []).map { item in
            ModelTimelineSeries(
                model: sourceQualifiedModel(item.model, provider: provider),
                hourly: item.hourly,
                daily: item.daily
            )
        }
    }

    /// Separator chosen for visual clarity in chart legends and breakdown
    /// rows. Centralized here so future formatting changes (icon prefix, em
    /// dash, etc.) only need to touch one site and don't get duplicated into
    /// breakdown / timeline aggregation paths.
    static let sourceQualifierSeparator: String = " / "

    private func sourceQualifiedModel(_ model: String, provider: ProviderData) -> String {
        "\(provider.label)\(Self.sourceQualifierSeparator)\(model)"
    }

    private func aggregatePeriod(_ periods: [CostPeriod?], label: String) -> CostPeriod? {
        let resolved = periods.compactMap { $0 }
        guard !resolved.isEmpty else { return nil }
        let hasTokens = resolved.contains { $0.tokens != nil }
        return CostPeriod(
            usd: resolved.reduce(0) { $0 + $1.usd },
            tokens: hasTokens ? resolved.reduce(0) { $0 + ($1.tokens ?? 0) } : nil,
            rangeLabel: label
        )
    }

    private func aggregateTimeline(_ timelines: [CostTimeline]) -> CostTimeline? {
        guard !timelines.isEmpty else { return nil }
        return CostTimeline(
            hourly: aggregateTimelinePoints(timelines.map(\.hourly)),
            daily: aggregateTimelinePoints(timelines.map(\.daily))
        )
    }

    private func aggregateTimelinePoints(_ pointGroups: [[CostTimelinePoint]]) -> [CostTimelinePoint] {
        var buckets: [String: (label: String, usd: Double, tokens: Int)] = [:]
        for point in pointGroups.flatMap({ $0 }) {
            // Drop unparseable buckets at the aggregation boundary so they never reach
            // the chart timeline. Without this, garbage buckets would survive aggregation
            // and pin the chart X-axis to year 1 in `.all` view.
            guard point.resolvedDate != nil else { continue }
            var current = buckets[point.bucket] ?? (point.label, 0, 0)
            current.usd += point.usd
            current.tokens += point.tokens
            buckets[point.bucket] = current
        }

        return buckets
            .map { bucket, value in
                CostTimelinePoint(
                    bucket: bucket,
                    label: value.label,
                    usd: value.usd,
                    tokens: value.tokens
                )
            }
            .sorted { $0.date < $1.date }
    }

    private struct MutableModelBreakdown {
        var totalTokens = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreateTokens = 0
        var estimatedCostUsd = 0.0
    }

    private func aggregateModelBreakdowns(_ breakdowns: [ModelCostBreakdown]) -> [ModelCostBreakdown] {
        guard !breakdowns.isEmpty else { return [] }

        var byModel: [String: MutableModelBreakdown] = [:]
        for item in breakdowns {
            var current = byModel[item.model] ?? MutableModelBreakdown()
            current.totalTokens += item.totalTokens
            current.inputTokens += item.inputTokens
            current.outputTokens += item.outputTokens
            current.cacheReadTokens += item.cacheReadTokens
            current.cacheCreateTokens += item.cacheCreateTokens
            current.estimatedCostUsd += item.estimatedCostUsd
            byModel[item.model] = current
        }

        let totalUsd = byModel.values.reduce(0) { $0 + $1.estimatedCostUsd }
        let totalTokens = byModel.values.reduce(0) { $0 + $1.totalTokens }

        return byModel.map { model, totals in
            let percentage: Double
            if totalUsd > 0 {
                percentage = totals.estimatedCostUsd / totalUsd * 100
            } else if totalTokens > 0 {
                percentage = Double(totals.totalTokens) / Double(totalTokens) * 100
            } else {
                percentage = 0
            }

            return ModelCostBreakdown(
                model: model,
                totalTokens: totals.totalTokens,
                inputTokens: totals.inputTokens,
                outputTokens: totals.outputTokens,
                cacheReadTokens: totals.cacheReadTokens,
                cacheCreateTokens: totals.cacheCreateTokens,
                estimatedCostUsd: totals.estimatedCostUsd,
                percentage: percentage
            )
        }
        .sorted {
            if $0.estimatedCostUsd != $1.estimatedCostUsd {
                return $0.estimatedCostUsd > $1.estimatedCostUsd
            }
            if $0.totalTokens != $1.totalTokens {
                return $0.totalTokens > $1.totalTokens
            }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
    }

    private func aggregateModelTimelines(_ series: [ModelTimelineSeries]) -> [ModelTimelineSeries] {
        guard !series.isEmpty else { return [] }
        let grouped = Dictionary(grouping: series, by: \.model)
        return grouped.map { model, items in
            ModelTimelineSeries(
                model: model,
                hourly: aggregateTimelinePoints(items.map(\.hourly)),
                daily: aggregateTimelinePoints(items.map(\.daily))
            )
        }
        .sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
    }
}
