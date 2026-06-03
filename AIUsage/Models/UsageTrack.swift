import Foundation

// MARK: - Usage Track (用量轨道)
// Codex 用量分两轨：API（代理日志，模型名带 " (API)" 后缀）与 订阅（本地 JSONL，带 " (Sub)" 后缀），
// 合并轨同时含两者。统计页用本类型在「合计 / API / 订阅」间切换，靠模型名后缀过滤、显示时剥后缀。
// Claude 单轨（仅代理），模型名无后缀，故只有 codex 家族需要轨道切换器。

enum UsageTrack: String, CaseIterable, Identifiable {
    case combined
    case api
    case subscription

    var id: String { rawValue }

    var label: String {
        switch self {
        case .combined:     return L("Combined", "合计")
        case .api:          return L("API", "API")
        case .subscription: return L("Subscription", "订阅")
        }
    }

    static let apiSuffix = " (API)"
    static let subSuffix = " (Sub)"

    static func isAPI(_ model: String) -> Bool { model.hasSuffix(apiSuffix) }
    static func isSubscription(_ model: String) -> Bool { model.hasSuffix(subSuffix) }

    /// 该模型是否属于当前轨（合计恒真）。
    func matches(_ model: String) -> Bool {
        switch self {
        case .combined:     return true
        case .api:          return UsageTrack.isAPI(model)
        case .subscription: return UsageTrack.isSubscription(model)
        }
    }

    /// 去掉轨道后缀，用于在单轨视图里更干净地展示模型名（合计视图保留后缀以区分来源）。
    static func stripSuffix(_ model: String) -> String {
        if isAPI(model) { return String(model.dropLast(apiSuffix.count)) }
        if isSubscription(model) { return String(model.dropLast(subSuffix.count)) }
        return model
    }
}

// MARK: - CostSummary track filtering

extension CostSummary {
    /// 按轨道过滤：合计原样返回；API/订阅仅保留对应后缀的模型行，剥掉后缀，
    /// 并据过滤后的模型明细重算各周期总额与时间线（与后端 overall.api/sub 一致）。
    func filtered(by track: UsageTrack) -> CostSummary {
        guard track != .combined else { return self }

        let today = Self.filterBreakdown(modelBreakdownToday, track: track)
        let week = Self.filterBreakdown(modelBreakdownWeek, track: track)
        let month = Self.filterBreakdown(modelBreakdown, track: track)
        let overallModels = Self.filterBreakdown(modelBreakdownOverall, track: track)
        let timelines = Self.filterTimelines(modelTimelines, track: track)

        return CostSummary(
            today: Self.period(today, like: self.today),
            week: Self.period(week, like: self.week),
            month: Self.period(month, like: self.month),
            overall: Self.period(overallModels, like: self.overall),
            timeline: Self.timeline(from: timelines),
            modelBreakdown: month.isEmpty ? nil : month,
            modelBreakdownToday: today.isEmpty ? nil : today,
            modelBreakdownWeek: week.isEmpty ? nil : week,
            modelBreakdownOverall: overallModels.isEmpty ? nil : overallModels,
            modelTimelines: timelines.isEmpty ? nil : timelines
        )
    }

    private static func filterBreakdown(
        _ breakdown: [ModelCostBreakdown]?,
        track: UsageTrack
    ) -> [ModelCostBreakdown] {
        let kept = (breakdown ?? []).filter { track.matches($0.model) }
        let totalUsd = kept.reduce(0) { $0 + $1.estimatedCostUsd }
        let totalTokens = kept.reduce(0) { $0 + $1.totalTokens }
        return kept.map { item in
            let pct: Double
            if totalUsd > 0 {
                pct = item.estimatedCostUsd / totalUsd * 100
            } else if totalTokens > 0 {
                pct = Double(item.totalTokens) / Double(totalTokens) * 100
            } else {
                pct = 0
            }
            return ModelCostBreakdown(
                model: UsageTrack.stripSuffix(item.model),
                totalTokens: item.totalTokens,
                inputTokens: item.inputTokens,
                outputTokens: item.outputTokens,
                cacheReadTokens: item.cacheReadTokens,
                cacheCreateTokens: item.cacheCreateTokens,
                estimatedCostUsd: item.estimatedCostUsd,
                percentage: pct
            )
        }
    }

    private static func filterTimelines(
        _ series: [ModelTimelineSeries]?,
        track: UsageTrack
    ) -> [ModelTimelineSeries] {
        (series ?? [])
            .filter { track.matches($0.model) }
            .map { ModelTimelineSeries(model: UsageTrack.stripSuffix($0.model), hourly: $0.hourly, daily: $0.daily) }
    }

    /// 据过滤后的模型明细重算周期总额，保留原周期的标签（rangeLabel）。
    private static func period(_ models: [ModelCostBreakdown], like original: CostPeriod?) -> CostPeriod? {
        guard !models.isEmpty else { return original.map { CostPeriod(usd: 0, tokens: 0, rangeLabel: $0.rangeLabel) } }
        return CostPeriod(
            usd: models.reduce(0) { $0 + $1.estimatedCostUsd },
            tokens: models.reduce(0) { $0 + $1.totalTokens },
            rangeLabel: original?.rangeLabel
        )
    }

    /// 据过滤后的模型时间线重建合并时间线（统计页天数横幅 / 顶部口径用）。
    private static func timeline(from series: [ModelTimelineSeries]) -> CostTimeline? {
        guard !series.isEmpty else { return nil }
        func merge(_ keyPath: KeyPath<ModelTimelineSeries, [CostTimelinePoint]>) -> [CostTimelinePoint] {
            var buckets: [String: (label: String, usd: Double, tokens: Int)] = [:]
            for s in series {
                for p in s[keyPath: keyPath] {
                    var c = buckets[p.bucket] ?? (p.label, 0, 0)
                    c.usd += p.usd
                    c.tokens += p.tokens
                    buckets[p.bucket] = c
                }
            }
            return buckets
                .map { CostTimelinePoint(bucket: $0.key, label: $0.value.label, usd: $0.value.usd, tokens: $0.value.tokens) }
                .sorted { $0.bucket < $1.bucket }
        }
        return CostTimeline(hourly: merge(\.hourly), daily: merge(\.daily))
    }
}
