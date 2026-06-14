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

    /// 计算调用分析快照。`windowDays > 0` 时只解析最近 N 天（按文件修改时间 / 库时间裁剪）；0 为全部历史。
    public func computeSnapshot(windowDays: Int) -> CallAnalyticsSnapshot {
        let cutoff = cutoffDate(windowDays: windowDays)

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

        return CallAnalyticsSnapshot(
            generatedAt: Date(),
            windowDays: windowDays,
            entries: entries,
            installedSkills: installedSkills,
            installedMCPServers: installedMCP,
            sources: [claude.status, codex.status, opencode.status]
        )
    }

    private func cutoffDate(windowDays: Int) -> Date? {
        guard windowDays > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -(windowDays - 1), to: startOfToday)
    }
}
