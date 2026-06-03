import Foundation

// MARK: - Claude Provider
// Claude Code 用量统计的唯一数据源 = 代理日志的永久日归档（成本逐条冻结、不可篡改、
// 支持同模型不同节点不同价）。本类只读 App 侧 ProxyUsageArchiveStore 写出的 JSON，
// 复用既有聚合 / 时间线辅助构建 ProviderUsage。
// 数据来源: ~/.config/aiusage/usage-archive/proxy-usage-claude-v1.json（见 ClaudeProvider+ProxyArchive）
// 注: 旧的本地 JSONL 扫描管线（+Scanning/+Discovery/+FileParsing/+ArchiveStore/定价表）已停用，待清理。

public struct ClaudeProvider: ProviderFetcher {
    public let id = "claude"
    public let displayName = "Claude Code"
    public let description = "Usage-derived Claude token and cost ledger from proxy logs"

    /// 归档为空时的回退天数（用于 trailing 时间线长度）。
    static let defaultScanDays = 30

    let homeDirectory: String
    let timeZone: TimeZone

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeZone: TimeZone = .current) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()

        // 唯一数据源：代理日志的永久日归档（成本逐条冻结、不可篡改、支持同模型不同节点不同价）。
        let archivedDays = loadProxyUsageDays()
        guard !archivedDays.isEmpty else {
            throw ProviderError("no_usage_data", "No proxy usage recorded for Claude Code yet")
        }

        let todayKey = dayKey(now)
        let weekRange = currentWeekRange(now)
        let monthKey = monthKeyStr(now)

        let today = archivedDays[todayKey] ?? .empty
        let currentWeek = aggregateDays(archivedDays) { weekRange.dayKeys.contains($0) }
        let currentMonth = aggregateDays(archivedDays) { $0.hasPrefix(monthKey) }
        let overall = aggregateDays(archivedDays) { _ in true }
        let archiveDayCount = archivedDayCount(archivedDays, now: now, fallback: max(archivedDays.count, Self.defaultScanDays))
        let overallRangeLabel = archivedRangeLabel(archivedDays, fallback: "All proxy history")

        var extra: [String: AnyCodable] = [:]
        extra["today.estimatedCostUsd"] = AnyCodable(roundUsd(today.estimatedCostUsd))
        extra["today.totalTokens"] = AnyCodable(today.totalTokens)
        extra["today.key"] = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(roundUsd(currentWeek.estimatedCostUsd))
        extra["currentWeek.totalTokens"] = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"] = AnyCodable("\(weekRange.start)..\(weekRange.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(roundUsd(currentMonth.estimatedCostUsd))
        extra["currentMonth.totalTokens"] = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"] = AnyCodable(monthKey)

        // 代理日归档无小时粒度，hourly 留空；热力图与统计页按日呈现。
        extra["timeline.hourly"] = AnyCodable([AnyCodable]())
        extra["timeline.daily"] = AnyCodable(encodeTimeline(trailingDailyTimeline(bucketsByDay: archivedDays, now: now, dayCount: archiveDayCount)))

        // 仅看「今天」：历史日的 0 成本（旧模型名/当时未配价）不应永久纠缠——成本历史不可篡改，
        // 只提示当前仍在产生「有 token 但 cost==0」流量的模型，引导用户给当前节点配价。
        let unpricedModels = today.unpricedModels
        extra["overall.estimatedCostUsd"] = AnyCodable(roundUsd(overall.estimatedCostUsd))
        extra["overall.totalTokens"] = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"] = AnyCodable(overall.usageRows)
        extra["overall.duplicateRowsRemoved"] = AnyCodable(0)
        extra["overall.rangeLabel"] = AnyCodable(overallRangeLabel)
        extra["overall.unpricedModels"] = AnyCodable(unpricedModels.sorted().map { AnyCodable($0) })

        extra["currentMonth.models"] = AnyCodable(encodeModelBreakdown(currentMonth))
        extra["today.models"] = AnyCodable(encodeModelBreakdown(today))
        extra["currentWeek.models"] = AnyCodable(encodeModelBreakdown(currentWeek))
        extra["overall.models"] = AnyCodable(encodeModelBreakdown(overall))

        var modelTimelines: [AnyCodable] = []
        let archivedModelNames = Set(archivedDays.values.flatMap { $0.models.keys })
        for modelName in archivedModelNames.sorted() {
            let daily = trailingDailyTimeline(bucketsByDay: archivedDays, now: now, dayCount: archiveDayCount, model: modelName)
            guard !daily.isEmpty else { continue }
            modelTimelines.append(AnyCodable([
                "model": AnyCodable(modelName),
                "hourly": AnyCodable([AnyCodable]()),
                "daily": AnyCodable(encodeTimeline(daily, includeDetail: true))
            ] as [String: AnyCodable]))
        }
        extra["timeline.byModel"] = AnyCodable(modelTimelines)

        var usage = ProviderUsage(provider: id, label: displayName, extra: extra)
        usage.source = SourceInfo(mode: "auto", type: "claude-proxy-usage")
        return usage
    }

}
