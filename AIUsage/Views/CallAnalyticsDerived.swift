import SwiftUI
import QuotaBackend

// MARK: - Call Analytics Derived
// 把快照按当前筛选（来源 scope）派生为 UI 直接消费的结构：KPI、Top-N 排行、每日趋势、零调用。
// 纯计算、无副作用，保持视图层简洁。

/// 来源筛选。
enum CallScope: String, CaseIterable, Identifiable {
    case all, claude, codex, opencode
    var id: String { rawValue }

    var sourceKind: CallSourceKind? {
        switch self {
        case .all: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        }
    }

    var title: String {
        switch self {
        case .all: return L("All", "全部", key: "calls.scope.all")
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

/// 排行维度。
enum CallLens: String, CaseIterable, Identifiable {
    case mcp, skill, tools
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mcp: return L("MCP", "MCP", key: "calls.lens.mcp")
        case .skill: return L("Skills", "技能", key: "calls.lens.skill")
        case .tools: return L("Tools", "工具", key: "calls.lens.tools")
        }
    }
}

/// 解析窗口。
enum CallWindow: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case all = 0
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return L("7d", "7天", key: "calls.window.7d")
        case .month: return L("30d", "30天", key: "calls.window.30d")
        case .quarter: return L("90d", "90天", key: "calls.window.90d")
        case .all: return L("All", "全部", key: "calls.window.all")
        }
    }
}

struct RankedRow: Identifiable {
    let id: String
    let name: String
    let count: Int
    let sources: Set<CallSourceKind>
    /// 成功率（0...1）。无结果信号时为 nil（UI 留白，不显示 0%）。
    var successRate: Double? = nil
    /// 平均耗时（毫秒）。无计时数据时为 nil。
    var avgDurationMs: Double? = nil
    /// 该行是否为可下钻的 MCP server（其下还有具体 tool）。
    var isDrillable: Bool = false
}

struct InventoryStatusRow: Identifiable {
    let id: String
    let name: String
    let count: Int
    var used: Bool { count > 0 }
}

/// Claude 按 agent（main/subagent）分组的一行。
struct AgentBreakdownRow: Identifiable {
    let id: String          // "main" / "subagent"
    let count: Int
    let successRate: Double?
}

struct CallAnalyticsDerived {
    let snapshot: CallAnalyticsSnapshot
    let scope: CallScope

    /// 按来源 scope 过滤后的条目。
    var entries: [CallAnalyticsEntry] {
        guard let kind = scope.sourceKind else { return snapshot.entries }
        return snapshot.entries.filter { $0.source == kind }
    }

    // MARK: - KPI

    var totalCalls: Int { entries.reduce(0) { $0 + $1.count } }
    var mcpCalls: Int { entries.filter { $0.kind == .mcp }.reduce(0) { $0 + $1.count } }
    var skillCalls: Int { entries.filter { $0.kind == .skill }.reduce(0) { $0 + $1.count } }

    var usedServers: Set<String> {
        Set(entries.compactMap { $0.kind == .mcp ? $0.server : nil })
    }

    var usedSkills: Set<String> {
        Set(entries.filter { $0.kind == .skill }.map { $0.name })
    }

    /// 当前 scope 下「已安装」的技能名。指定来源时只取该来源装的；scope=全部 取并集。
    var installedSkillNames: Set<String> {
        if let kind = scope.sourceKind {
            return Set(snapshot.installedSkills.filter { $0.source == kind }.map(\.name))
        }
        return Set(snapshot.installedSkills.map(\.name))
    }

    /// 当前 scope 下「已配置」的 MCP server 名。
    var installedServerNames: Set<String> {
        if let kind = scope.sourceKind {
            return Set(snapshot.installedMCPServers.filter { $0.source == kind }.map(\.name))
        }
        return Set(snapshot.installedMCPServers.map(\.name))
    }

    var zombieSkillCount: Int {
        installedSkillNames.subtracting(usedSkills).count
    }

    // MARK: - Rankings

    func ranking(for lens: CallLens) -> [RankedRow] {
        switch lens {
        case .mcp:
            return rankedByServer()
        case .skill:
            return ranked(entries.filter { $0.kind == .skill })
        case .tools:
            return ranked(entries.filter { $0.kind == .builtin || $0.kind == .webSearch || $0.kind == .other })
        }
    }

    /// 一组条目按指定键聚合的累加器（计数 + 成功率/耗时分量 + 来源集合）。
    private struct RankAgg {
        var count = 0
        var outcomeKnown = 0
        var success = 0
        var durationSamples = 0
        var durationMsTotal = 0.0
        var sources: Set<CallSourceKind> = []

        mutating func add(_ entry: CallAnalyticsEntry) {
            count += entry.count
            outcomeKnown += entry.outcomeKnownCount
            success += entry.successCount
            durationSamples += entry.durationSampleCount
            durationMsTotal += entry.durationMsTotal
            sources.insert(entry.source)
        }

        var successRate: Double? { outcomeKnown > 0 ? Double(success) / Double(outcomeKnown) : nil }
        var avgDurationMs: Double? { durationSamples > 0 ? durationMsTotal / Double(durationSamples) : nil }
    }

    /// MCP 维度按 server 折叠（一个 server 的所有 tool 合并计数 + 指标），并标记可下钻。
    func rankedByServer() -> [RankedRow] {
        let mcp = entries.filter { $0.kind == .mcp }
        var aggs: [String: RankAgg] = [:]
        for entry in mcp {
            aggs[entry.server ?? entry.name, default: RankAgg()].add(entry)
        }
        return aggs.map { key, agg in
            RankedRow(id: key, name: key, count: agg.count, sources: agg.sources,
                      successRate: agg.successRate, avgDurationMs: agg.avgDurationMs, isDrillable: true)
        }
        .sorted(by: Self.rankOrder)
    }

    /// 单个 MCP server 下的具体 tool 列表（下钻用），name 仅取 tool 段。
    func mcpTools(forServer server: String) -> [RankedRow] {
        let subset = entries.filter { $0.kind == .mcp && ($0.server ?? $0.name) == server }
        var aggs: [String: RankAgg] = [:]
        for entry in subset { aggs[entry.name, default: RankAgg()].add(entry) }
        let prefix = server + "/"
        return aggs.map { fullName, agg in
            let tool = fullName.hasPrefix(prefix) ? String(fullName.dropFirst(prefix.count)) : fullName
            return RankedRow(id: fullName, name: tool, count: agg.count, sources: agg.sources,
                             successRate: agg.successRate, avgDurationMs: agg.avgDurationMs)
        }
        .sorted(by: Self.rankOrder)
    }

    /// MCP 维度展开到具体 tool（server/tool）。
    func rankedMCPTools() -> [RankedRow] {
        ranked(entries.filter { $0.kind == .mcp })
    }

    private func ranked(_ subset: [CallAnalyticsEntry]) -> [RankedRow] {
        var aggs: [String: RankAgg] = [:]
        for entry in subset { aggs[entry.name, default: RankAgg()].add(entry) }
        return aggs.map { key, agg in
            RankedRow(id: key, name: key, count: agg.count, sources: agg.sources,
                      successRate: agg.successRate, avgDurationMs: agg.avgDurationMs)
        }
        .sorted(by: Self.rankOrder)
    }

    /// 排行排序：次数降序 → 名称升序。
    /// 同次数时用名称定序，避免字典枚举顺序导致同分项每次刷新位次抖动。
    private static func rankOrder(_ a: RankedRow, _ b: RankedRow) -> Bool {
        if a.count != b.count { return a.count > b.count }
        return a.name < b.name
    }

    // MARK: - Agent breakdown (Claude only)

    /// 当前 scope 下是否有 Claude subagent 活动（决定是否显示 agent 分组卡）。
    /// agent 取值：`"main"` = 主会话；其余（具体类型 Explore/Plan… 或兜底 "subagent"）= 子代理。
    var hasSubagentActivity: Bool {
        entries.contains { $0.source == .claude && $0.agent != nil && $0.agent != "main" && $0.count > 0 }
    }

    /// Claude 按 agent 分组：主会话 + 每个具体子代理类型（Explore/Plan/…）各一行。其它来源无 agent，返回空。
    func agentBreakdown() -> [AgentBreakdownRow] {
        let claude = entries.filter { $0.source == .claude && $0.agent != nil }
        guard !claude.isEmpty else { return [] }
        var aggs: [String: RankAgg] = [:]
        for entry in claude { aggs[entry.agent ?? "main", default: RankAgg()].add(entry) }
        return aggs.map { key, agg in
            AgentBreakdownRow(id: key, count: agg.count, successRate: agg.successRate)
        }
        .sorted(by: Self.agentOrder)
    }

    /// 排序：主会话永远第一；其余子代理类型按次数降序 → 名称升序。
    private static func agentOrder(_ a: AgentBreakdownRow, _ b: AgentBreakdownRow) -> Bool {
        if a.id == "main" || b.id == "main" { return a.id == "main" && b.id != "main" }
        if a.count != b.count { return a.count > b.count }
        return a.id < b.id
    }

    // MARK: - Daily trend

    /// 每日总调用计数，按日期升序。
    var dailyCounts: [(day: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.dayKey, default: 0] += entry.count
        }
        return counts.sorted { $0.key < $1.key }.map { (day: $0.key, count: $0.value) }
    }

    // MARK: - Zero-call inventory

    func skillStatuses() -> [InventoryStatusRow] {
        var used: [String: Int] = [:]
        for entry in entries where entry.kind == .skill {
            used[entry.name, default: 0] += entry.count
        }
        let names = installedSkillNames.union(used.keys)
        return names.map { InventoryStatusRow(id: $0, name: $0, count: used[$0] ?? 0) }
            .sorted(by: Self.inventoryOrder)
    }

    func serverStatuses() -> [InventoryStatusRow] {
        var used: [String: Int] = [:]
        for entry in entries where entry.kind == .mcp {
            let key = entry.server ?? entry.name
            used[key, default: 0] += entry.count
        }
        let names = installedServerNames.union(used.keys)
        return names.map { InventoryStatusRow(id: $0, name: $0, count: used[$0] ?? 0) }
            .sorted(by: Self.inventoryOrder)
    }

    /// 排序：已调用在前 → 次数降序 → 名称升序。
    private static func inventoryOrder(_ a: InventoryStatusRow, _ b: InventoryStatusRow) -> Bool {
        if a.used != b.used { return a.used && !b.used }
        if a.count != b.count { return a.count > b.count }
        return a.name < b.name
    }
}
