import Foundation

extension UsageNormalizer {

    // MARK: - OpenCode
    // 本地会话账本（单轨）：token 与成本同源（opencode.db，cost 为 models.dev 定价冻结值）。
    // 订阅渠道 cost 恒 0 属正常语义，不产生未定价告警（unpricedModels 恒 nil）。

    static func normalizeOpenCode(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let monthUsd = extraDouble(usage, "currentMonth.estimatedCostUsd") ?? 0
        let weekUsd = extraDouble(usage, "currentWeek.estimatedCostUsd") ?? 0
        let todayUsd = extraDouble(usage, "today.estimatedCostUsd") ?? 0
        let overallUsd = extraDouble(usage, "overall.estimatedCostUsd") ?? 0
        let monthTokens = extraInt(usage, "currentMonth.totalTokens") ?? 0
        let weekTokens = extraInt(usage, "currentWeek.totalTokens") ?? 0
        let todayTokens = extraInt(usage, "today.totalTokens") ?? 0
        let overallTokens = extraInt(usage, "overall.totalTokens") ?? 0
        let usageRows = extraInt(usage, "overall.usageRows") ?? 0
        let sessionCount = extraInt(usage, "overall.sessionCount") ?? 0

        let rawModelItems = (usage.extra["currentMonth.models"]?.value as? [AnyCodable]) ?? []
        let topModels: [ModelInfo] = rawModelItems
            .prefix(5)
            .compactMap { item in
                guard let model = (item.value as? [String: AnyCodable])?["model"]?.value as? String else {
                    return nil
                }
                let itemDict = item.value as? [String: AnyCodable]
                let tokens: Int
                switch itemDict?["totalTokens"]?.value {
                case let value as Int:
                    tokens = value
                case let value as Double:
                    tokens = Int(value)
                default:
                    tokens = 0
                }
                let cost = itemDict?["estimatedCostDisplay"]?.value as? String
                return ModelInfo(label: model, value: formatInt(tokens), note: cost)
            }

        let modelBreakdown = extractModelBreakdown(usage, "currentMonth.models")
        let modelBreakdownToday = extractModelBreakdown(usage, "today.models")
        let modelBreakdownWeek = extractModelBreakdown(usage, "currentWeek.models")
        let modelBreakdownOverall = extractModelBreakdown(usage, "overall.models")
        let modelTimelines = extraModelTimelines(usage, "timeline.byModel")

        base.category = ProviderCategory.localCost
        base.status = "healthy"
        base.statusLabel = "Healthy"
        base.headline = HeadlineInfo(
            eyebrow: "Local session ledger",
            primary: "\(formatInt(monthTokens)) tokens",
            secondary: "OpenCode session usage this month",
            supporting: "Week \(formatInt(weekTokens)) tokens / Today \(formatInt(todayTokens))"
        )
        base.metrics = [
            MetricInfo(label: "Today", value: formatInt(todayTokens), note: formatCurrency(todayUsd)),
            MetricInfo(label: "This Week", value: formatInt(weekTokens), note: formatCurrency(weekUsd)),
            MetricInfo(label: "This Month", value: formatInt(monthTokens), note: formatCurrency(monthUsd)),
            MetricInfo(label: "Messages", value: formatInt(usageRows), note: "\(formatInt(sessionCount)) sessions")
        ]
        base.windows = []
        base.costSummary = CostSummaryInfo(
            today: CostPeriod(usd: todayUsd, tokens: todayTokens, rangeLabel: extraString(usage, "today.key") ?? "Today"),
            week: CostPeriod(usd: weekUsd, tokens: weekTokens, rangeLabel: extraString(usage, "currentWeek.key") ?? "This week"),
            month: CostPeriod(usd: monthUsd, tokens: monthTokens, rangeLabel: extraString(usage, "currentMonth.key") ?? "This month"),
            overall: CostPeriod(usd: overallUsd, tokens: overallTokens, rangeLabel: extraString(usage, "overall.rangeLabel") ?? "Overall"),
            timeline: CostTimelineInfo(
                hourly: extraCostTimeline(usage, "timeline.hourly"),
                daily: extraCostTimeline(usage, "timeline.daily")
            ),
            modelBreakdown: modelBreakdown.isEmpty ? nil : modelBreakdown,
            modelBreakdownToday: modelBreakdownToday.isEmpty ? nil : modelBreakdownToday,
            modelBreakdownWeek: modelBreakdownWeek.isEmpty ? nil : modelBreakdownWeek,
            modelBreakdownOverall: modelBreakdownOverall.isEmpty ? nil : modelBreakdownOverall,
            modelTimelines: modelTimelines.isEmpty ? nil : modelTimelines
        )
        base.models = topModels.isEmpty ? nil : topModels
        base.nextResetAt = nil
        base.spotlight = "This tracker reads the local OpenCode session database. Costs are frozen at request time using models.dev pricing; OAuth subscription usage is recorded at $0."
        base.unpricedModels = nil
        return base
    }
}
