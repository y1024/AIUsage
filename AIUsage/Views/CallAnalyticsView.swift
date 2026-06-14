import SwiftUI
import QuotaBackend

// MARK: - Call Analytics View
// 「调用分析」主页：解析 Claude Code / Codex / OpenCode 本地会话日志，
// 统计 MCP / Skill / 工具调用频次，提供 Top-N 排行、每日趋势与零调用（僵尸技能/MCP）检测。
// 数据只读、零埋点；规则命中因原理不可得不在此统计。设计见 docs/CALL_ANALYTICS_DESIGN.md。

struct CallAnalyticsView: View {
    @StateObject var store = CallAnalyticsStore.shared

    @AppStorage("callAnalytics.windowDays") private var windowRaw = CallWindow.month.rawValue
    @AppStorage("callAnalytics.scope") private var scopeRaw = CallScope.all.rawValue
    @State var lens: CallLens = .mcp
    /// MCP 排行里已展开（下钻查看 tool 列表）的 server。
    @State var expandedServers: Set<String> = []

    var window: CallWindow { CallWindow(rawValue: windowRaw) ?? .month }
    var scope: CallScope { CallScope(rawValue: scopeRaw) ?? .all }
    var derived: CallAnalyticsDerived { CallAnalyticsDerived(snapshot: store.snapshot, scope: scope) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controlDeck
                if store.snapshot.isEmpty && !store.isRefreshing {
                    emptyState
                } else {
                    kpiStrip
                    trendCard
                    rankingCard
                    if derived.hasSubagentActivity {
                        agentCard
                    }
                    zeroCallCard
                }
                sourceFooter
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: windowRaw) {
            await store.refreshIfNeeded(windowDays: window.rawValue)
        }
    }

    // MARK: - Control deck

    private var controlDeck: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scopeControl; windowControl; Spacer(); refreshControl }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) { scopeControl; windowControl; Spacer() }
                HStack(spacing: 12) { Spacer(); refreshControl }
            }
        }
    }

    private var scopeControl: some View {
        Picker(L("Source", "来源", key: "calls.source"), selection: $scopeRaw) {
            ForEach(CallScope.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var windowControl: some View {
        Picker(L("Range", "时间范围", key: "calls.range"), selection: $windowRaw) {
            ForEach(CallWindow.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var refreshControl: some View {
        HStack(spacing: 8) {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refresh(windowDays: window.rawValue) }
            } label: {
                Label(L("Rescan", "重新扫描", key: "calls.rescan"), systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
    }

    // MARK: - KPI

    private var kpiStrip: some View {
        let d = derived
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            kpiCell(title: L("Total Calls", "总调用", key: "calls.kpi.total"),
                    value: "\(d.totalCalls)", icon: "wrench.and.screwdriver", tint: .secondary)
            kpiCell(title: L("MCP Calls", "MCP 调用", key: "calls.kpi.mcp"),
                    value: "\(d.mcpCalls)", icon: "puzzlepiece.extension", tint: .purple)
            kpiCell(title: L("Skill Calls", "技能调用", key: "calls.kpi.skill"),
                    value: "\(d.skillCalls)", icon: "sparkles", tint: .pink)
            kpiCell(title: L("Active MCP Servers", "活跃 MCP", key: "calls.kpi.servers"),
                    value: "\(d.usedServers.count)", icon: "server.rack", tint: .blue)
            kpiCell(title: L("Zombie Skills", "僵尸技能", key: "calls.kpi.zombie"),
                    value: "\(d.zombieSkillCount)", icon: "moon.zzz", tint: .orange)
        }
    }

    private func kpiCell(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Daily trend

    private var trendCard: some View {
        let points = derived.dailyCounts
        return cardContainer(
            title: L("Daily Calls", "每日调用", key: "calls.trend.title"),
            subtitle: window == .all ? L("All history", "全部历史", key: "calls.trend.all")
                                     : L("Last \(window.rawValue) days", "最近 \(window.rawValue) 天", key: "calls.trend.window")
        ) {
            if points.isEmpty {
                Text(L("No calls in range", "范围内暂无调用", key: "calls.trend.empty"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                CallTrendBars(points: points)
                    .frame(height: 64)
            }
        }
    }

    // MARK: - Agent breakdown (Claude main vs subagent)

    private var agentCard: some View {
        let rows = derived.agentBreakdown()
        let total = max(rows.reduce(0) { $0 + $1.count }, 1)
        return cardContainer(
            title: L("By Agent (Claude)", "按 Agent 分组（Claude）", key: "calls.agent.title"),
            subtitle: L("Main session vs each subagent type — only Claude exposes this", "主会话 vs 各子代理类型 · 仅 Claude 提供该维度", key: "calls.agent.sub")
        ) {
            VStack(spacing: 8) {
                ForEach(rows) { agentRow($0, total: total) }
            }
        }
    }

    private func agentRow(_ row: AgentBreakdownRow, total: Int) -> some View {
        // id: "main" = 主会话；"subagent" = 类型未知的子代理；其余 = 具体子代理类型名（Explore/Plan…）。
        let isMain = row.id == "main"
        let label: String
        if isMain {
            label = L("Main", "主会话", key: "calls.agent.label.main")
        } else if row.id == "subagent" {
            label = L("Subagents", "子代理", key: "calls.agent.label.sub")
        } else {
            label = row.id
        }
        let style = CallAnalyticsView.agentStyle(for: row.id)
        let ratio = CGFloat(row.count) / CGFloat(total)
        // 主会话齐左、加粗、条更高；子代理整体右移并带「↳」层级线索、字号与条高更小，凸显从属关系。
        return HStack(spacing: 8) {
            if !isMain {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            Label {
                Text(label).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: style.icon).foregroundStyle(style.color)
            }
            .font(isMain ? .callout.weight(.semibold) : .caption)
            .labelStyle(.titleAndIcon)
            .frame(width: isMain ? 130 : 110, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(style.color.opacity(isMain ? 0.9 : 0.6))
                        .frame(width: max(4, proxy.size.width * ratio))
                }
            }
            .frame(height: isMain ? 14 : 11)
            if let rate = row.successRate {
                Text(CallAnalyticsView.formatRate(rate))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .help(L("Success rate", "成功率", key: "calls.metric.success.help"))
            }
            Text("\(row.count)")
                .font((isMain ? Font.callout : Font.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.leading, isMain ? 0 : 14)
    }

    /// 按 agent id 给出稳定的图标 + 颜色：主会话/通用子代理固定，具体子代理类型按关键词选图标、按名称哈希取调色板色。
    static func agentStyle(for id: String) -> (icon: String, color: Color) {
        if id == "main" { return ("person.crop.circle.fill", .blue) }
        if id == "subagent" { return ("person.2.fill", .gray) }

        let lower = id.lowercased()
        let icon: String
        if lower.contains("explore") {
            icon = "magnifyingglass"
        } else if lower.contains("plan") {
            icon = "list.bullet.rectangle"
        } else if lower.contains("review") {
            icon = "checkmark.seal"
        } else if lower.contains("bug") || lower.contains("debug") {
            icon = "ladybug"
        } else if lower.contains("test") {
            icon = "checkmark.diamond"
        } else if lower.contains("doc") {
            icon = "doc.text"
        } else if lower.contains("ui") || lower.contains("sketch") || lower.contains("design") {
            icon = "paintbrush.pointed"
        } else if lower.contains("research") || lower.contains("search") {
            icon = "magnifyingglass.circle"
        } else if lower.contains("story") || lower.contains("write") {
            icon = "square.and.pencil"
        } else if lower.contains("shell") || lower.contains("command") || lower.contains("terminal") {
            icon = "terminal"
        } else if lower.contains("general") {
            icon = "sparkles"
        } else {
            icon = "person.2"
        }

        let palette: [Color] = [.orange, .purple, .green, .pink, .teal, .indigo, .mint, .cyan]
        var hash: UInt64 = 1469598103934665603 // FNV-1a 偏移基
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return (icon, palette[Int(hash % UInt64(palette.count))])
    }

    // MARK: - Source footer

    private var sourceFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Data Sources", "数据来源", key: "calls.sources.title"))
                    .font(.subheadline.weight(.semibold))
                Text(L("Local CLI logs scanned for the selected range — what feeds the stats above.",
                       "上面所有统计的来源：按所选时间范围扫描的各 CLI 本地日志。",
                       key: "calls.sources.sub"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(store.snapshot.sources, id: \.source) { status in
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.errorCode != nil ? Color.red : (status.available ? Color.green : Color.secondary.opacity(0.4)))
                        .frame(width: 7, height: 7)
                    Text(status.source.displayName).font(.caption2.weight(.medium))
                    Text(sourceDetail(status)).font(.caption2).foregroundStyle(.secondary)
                }
                .help(sourceHelp(status))
            }

            Text(L("Rules-hit counts are not tracked: rules are injected as context, not discrete calls.",
                   "不统计「规则命中」：规则是上下文注入，并非离散调用。",
                   key: "calls.note.rules"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单行简述：绿点正常时显示「扫 N 个会话 · M 次调用」。
    private func sourceDetail(_ status: CallSourceStatus) -> String {
        if let code = status.errorCode {
            return L("error: \(code)", "采集失败: \(code)", key: "calls.source.error")
        }
        if !status.available {
            return L("not installed / no data", "未安装 / 无数据", key: "calls.source.absent")
        }
        return L("scanned \(status.filesScanned) sessions · \(status.eventCount) calls",
                 "扫 \(status.filesScanned) 个会话 · \(status.eventCount) 次调用",
                 key: "calls.source.ok")
    }

    /// 悬停完整说明：解释「会话文件」与「调用次数」分别是什么。
    private func sourceHelp(_ status: CallSourceStatus) -> String {
        if let code = status.errorCode {
            return L("Collection failed (\(code)).",
                     "采集失败（\(code)）。", key: "calls.source.help.error")
        }
        if !status.available {
            return L("\(status.source.displayName) not installed, or no local session logs found.",
                     "未检测到 \(status.source.displayName)，或本地没有会话日志。",
                     key: "calls.source.help.absent")
        }
        return L("Scanned \(status.filesScanned) \(status.source.displayName) session file(s) and counted \(status.eventCount) tool / MCP / skill calls within the selected range.",
                 "在所选时间范围内，扫描了 \(status.filesScanned) 个 \(status.source.displayName) 会话文件，统计到 \(status.eventCount) 次工具 / MCP / 技能调用。",
                 key: "calls.source.help.ok")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(L("No tool/MCP/Skill calls found locally.",
                   "本地未发现工具 / MCP / 技能调用。",
                   key: "calls.empty.title"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("Use Claude Code, Codex or OpenCode, then rescan.",
                   "使用 Claude Code、Codex 或 OpenCode 后重新扫描。",
                   key: "calls.empty.hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Shared card container

    func cardContainer<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    static func color(for source: CallSourceKind) -> Color {
        switch source {
        case .claude: return .orange
        case .codex: return .green
        case .opencode: return .blue
        }
    }
}

// MARK: - Daily trend bars

private struct CallTrendBars: View {
    let points: [(day: String, count: Int)]

    var body: some View {
        let maxCount = max(points.map(\.count).max() ?? 1, 1)
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let count = points.count
            let barWidth = max(2, (proxy.size.width - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1)))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(points, id: \.day) { point in
                    let ratio = CGFloat(point.count) / CGFloat(maxCount)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.25 + 0.75 * ratio))
                        .frame(width: barWidth, height: max(2, proxy.size.height * ratio))
                        .help("\(point.day): \(point.count)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
