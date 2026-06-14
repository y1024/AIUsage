import Foundation

// MARK: - Call Analytics Engine
// 调用分析的后台编排：运行三家来源 + 已装清单探测，合并为一份快照。
// 在 actor 内串行执行（重活在后台线程，不阻塞主线程）；无成本冻结，整份可重建。
// 设计见 docs/CALL_ANALYTICS_DESIGN.md。

public actor CallAnalyticsEngine {
    public static let shared = CallAnalyticsEngine()

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeZone: TimeZone = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
    }

    /// 计算调用分析快照。
    /// - Parameters:
    ///   - rangeKey: 时间范围标识（`today`/`week`/`month`/`all` 或自定义键），仅作快照/缓存身份用。
    ///   - cutoff: 起始日界（含）。`nil` = 不设下限（全部历史）。文件预筛 + 按事件日期精确过滤都用它。
    ///   - end: 结束日界（含）。`nil` = 不设上限（到现在）。日历口径恒为 `nil`，仅自定义区间用到。
    ///
    /// 注：`cutoff` 既用于「按文件 mtime / 库时间」预筛跳过窗外文件（省 IO），也用于对**每条事件**按
    /// `dayKey` 精确过滤——后者保证「今日」只含今天的调用，不被跨天会话的旧调用串味。
    public func computeSnapshot(rangeKey: String, cutoff: Date?, end: Date? = nil) -> CallAnalyticsSnapshot {
        // 先建清单：OpenCode 已装 MCP server 名要回灌给其事件源做精确前缀匹配。
        let inventory = CallAnalyticsInventory(homeDirectory: homeDirectory)
        let installedSkills = inventory.installedSkills()
        let installedMCP = inventory.installedMCPServers()
        let openCodeServers = Set(installedMCP.filter { $0.source == .opencode }.map(\.name))

        let claude = ClaudeCallEventSource(homeDirectory: homeDirectory, timeZone: timeZone, environment: environment)
            .collect(cutoff: cutoff)
        let codex = CodexCallEventSource(homeDirectory: homeDirectory, timeZone: timeZone, environment: environment)
            .collect(cutoff: cutoff)
        let opencode = OpenCodeCallEventSource(
            homeDirectory: homeDirectory, timeZone: timeZone, environment: environment,
            knownMCPServers: openCodeServers
        ).collect(cutoff: cutoff)

        var entries: [CallAnalyticsEntry] = []
        entries.reserveCapacity(claude.entries.count + codex.entries.count + opencode.entries.count)
        entries.append(contentsOf: claude.entries)
        entries.append(contentsOf: codex.entries)
        entries.append(contentsOf: opencode.entries)
        entries = filterByDay(entries, cutoff: cutoff, end: end)

        // 各源对外展示的「调用次数」以过滤后的实际条目为准，避免页脚 M 次调用与上方 KPI 对不上。
        let rawStatuses = [claude.status, codex.status, opencode.status]
        let statuses = rawStatuses.map { status -> CallSourceStatus in
            let count = entries.filter { $0.source == status.source }.reduce(0) { $0 + $1.count }
            return CallSourceStatus(
                source: status.source,
                available: status.available,
                eventCount: count,
                filesScanned: status.filesScanned,
                errorCode: status.errorCode
            )
        }

        return CallAnalyticsSnapshot(
            generatedAt: Date(),
            rangeKey: rangeKey,
            entries: entries,
            installedSkills: installedSkills,
            installedMCPServers: installedMCP,
            agentInvocations: claude.agentInvocations,
            sources: statuses
        )
    }

    /// 按事件 `dayKey`（yyyy-MM-dd，可字典序比较）做闭区间过滤。两端任意为 nil 即该侧不设限。
    private func filterByDay(_ entries: [CallAnalyticsEntry], cutoff: Date?, end: Date?) -> [CallAnalyticsEntry] {
        guard cutoff != nil || end != nil else { return entries }
        let clock = CallAnalyticsClock(timeZone: timeZone)
        let lowerKey = cutoff.map { clock.dayKey($0) }
        let upperKey = end.map { clock.dayKey($0) }
        return entries.filter { entry in
            if let lowerKey, entry.dayKey < lowerKey { return false }
            if let upperKey, entry.dayKey > upperKey { return false }
            return true
        }
    }
}
