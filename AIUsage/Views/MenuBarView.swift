import SwiftUI

// MARK: - Menu Bar View (Main Container)
// Redesigned popover inspired by Quotio: status header, summary stats, multi-window quota bars, cost card, action footer.

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject var proxyVM = ProxyViewModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var activationMessage: String?
    @State private var activationSuccess = true

    var body: some View {
        VStack(spacing: 0) {
            menuBarHeader
            Divider()
            summaryStatsRow
            Divider()
            menuBarContent
            costTrackingSection
            Divider()
            menuBarFooter
        }
        .frame(width: 420)
        .background(VisualEffectBlur())
    }

    // MARK: - Header

    private var overallStatus: OverallHealthStatus {
        let groups = appState.providerAccountGroups
        let providers = refreshCoordinator.providers
        let hasCritical = providers.contains { $0.status == .error }
        let hasWarning = providers.contains { ($0.remainingPercent ?? 100) < 35 }
        if hasCritical { return .critical }
        if hasWarning { return .warning }
        if groups.isEmpty && !refreshCoordinator.isLoading { return .idle }
        return .healthy
    }

    private var menuBarHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("AIUsage")
                            .font(.system(size: 14, weight: .bold, design: .rounded))

                        Circle()
                            .fill(overallStatus.color)
                            .frame(width: 7, height: 7)
                    }

                    if let lastRefresh = refreshCoordinator.lastRefreshTime {
                        RefreshableTimeView(
                            date: lastRefresh,
                            language: appState.language,
                            font: .system(size: 10),
                            foregroundStyle: .secondary
                        )
                    } else {
                        Text(L("Not refreshed yet", "尚未刷新"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                refreshCoordinator.refreshAllProviders()
            } label: {
                Group {
                    if refreshCoordinator.isAnyRefreshInProgress {
                        SmallProgressView().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(refreshCoordinator.isAnyRefreshInProgress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Summary Stats Row

    private var summaryStatsRow: some View {
        let groups = appState.providerAccountGroups
        let totalAccounts = groups.reduce(0) { $0 + $1.accounts.count }
        let connectedAccounts = groups.reduce(0) { $0 + $1.connectedCount }

        let activeNode = proxyVM.configurations.first { $0.id == proxyVM.activatedConfigId }

        let accountIconColor: Color = connectedAccounts == totalAccounts && totalAccounts > 0
            ? Color(red: 0.15, green: 0.78, blue: 0.40)
            : connectedAccounts > 0 ? .orange : .secondary
        let accountValueColor: Color = connectedAccounts > 0 ? .cyan : .secondary

        return HStack(spacing: 0) {
            summaryStatCell(
                value: "\(connectedAccounts)/\(totalAccounts)",
                label: L("Accounts", "账号"),
                icon: "person.2.fill",
                iconColor: accountIconColor,
                valueColor: accountValueColor
            )
            .frame(maxWidth: .infinity)

            summaryStatDivider

            proxyNodeSwitcher(activeNode: activeNode)
                .frame(maxWidth: .infinity)

            summaryStatDivider

            statsSummaryCell()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func proxyNodeSwitcher(activeNode: ProxyConfiguration?) -> some View {
        Menu {
            if proxyVM.configurations.isEmpty {
                Text(L("No proxy nodes", "暂无代理节点"))
            } else {
                let anthropicNodes = proxyVM.configurations.filter { $0.nodeType == .anthropicDirect }
                let openaiNodes = proxyVM.configurations.filter { $0.nodeType == .openaiProxy }

                if !anthropicNodes.isEmpty {
                    Section("Anthropic") {
                        ForEach(anthropicNodes) { config in
                            proxyNodeMenuItem(config)
                        }
                    }
                }

                if !openaiNodes.isEmpty {
                    Section("OpenAI") {
                        ForEach(openaiNodes) { config in
                            proxyNodeMenuItem(config)
                        }
                    }
                }

                Divider()

                Button {
                    if let activeId = proxyVM.activatedConfigId {
                        Task { await proxyVM.deactivateConfiguration(activeId) }
                    }
                } label: {
                    Label(L("Stop Proxy", "停止代理"), systemImage: "stop.circle")
                }
                .disabled(proxyVM.activatedConfigId == nil)
            }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: activeNode != nil ? "bolt.circle.fill" : "bolt.slash.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(activeNode != nil ? Color(red: 0.20, green: 0.84, blue: 0.42) : .gray)
                        .shadow(color: activeNode != nil ? Color.green.opacity(0.4) : .clear, radius: 3)
                    Text(activeNode?.name ?? L("Off", "未启用"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(activeNode != nil ? Color(red: 0.20, green: 0.84, blue: 0.42) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.7)
                }
                if let node = activeNode {
                    Text(proxyNodeTypeLabel(node))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(proxyNodeTypeColor(node))
                } else {
                    Text(L("Proxy", "代理"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func proxyNodeMenuItem(_ config: ProxyConfiguration) -> some View {
        let isActive = config.id == proxyVM.activatedConfigId
        Button {
            Task { await proxyVM.toggleActivation(config.id) }
        } label: {
            Label {
                Text(config.name)
            } icon: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
            }
        }
    }

    private func proxyNodeTypeLabel(_ config: ProxyConfiguration) -> String {
        switch config.nodeType {
        case .anthropicDirect:
            return config.usePassthroughProxy ? "Anthropic Proxy" : "Anthropic Direct"
        case .openaiProxy:
            return "OpenAI Proxy"
        }
    }

    private func proxyNodeIcon(_ config: ProxyConfiguration) -> String {
        switch config.nodeType {
        case .anthropicDirect:
            return config.usePassthroughProxy ? "bolt.shield.fill" : "bolt.horizontal.fill"
        case .openaiProxy:
            return "arrow.triangle.swap"
        }
    }

    private func proxyNodeTypeColor(_ config: ProxyConfiguration) -> Color {
        switch config.nodeType {
        case .anthropicDirect: return Color(red: 0.85, green: 0.45, blue: 0.25)
        case .openaiProxy: return Color(red: 0.40, green: 0.78, blue: 0.55)
        }
    }

    // MARK: - Stats Summary Cell (Proxy / local token stats switchable)

    private var statsConfigKey: String {
        settings.menuBarSummaryStatsSource == .proxy ? "proxy-stats" : "claude-code-stats"
    }

    private var localTokenCostSummary: CostSummary? {
        let summaries = appState.localCostProviders(from: refreshCoordinator.providers)
            .compactMap(\.costSummary)
        guard !summaries.isEmpty else { return nil }

        func period(_ keyPath: KeyPath<CostSummary, CostPeriod?>, label: String) -> CostPeriod {
            let periods = summaries.compactMap { $0[keyPath: keyPath] }
            return CostPeriod(
                usd: periods.reduce(0) { $0 + $1.usd },
                tokens: periods.reduce(0) { $0 + ($1.tokens ?? 0) },
                rangeLabel: label
            )
        }

        return CostSummary(
            today: period(\.today, label: "Today"),
            week: period(\.week, label: "This week"),
            month: period(\.month, label: "This month"),
            overall: period(\.overall, label: "Overall"),
            timeline: nil,
            modelBreakdown: nil,
            modelBreakdownToday: nil,
            modelBreakdownWeek: nil,
            modelBreakdownOverall: nil,
            modelTimelines: nil
        )
    }

    private func statsSummaryCell() -> some View {
        let source = settings.menuBarSummaryStatsSource
        let config = settings.costSourceConfig(for: statsConfigKey)
        let (valueText, tintColor, requestCount) = statsValues(source: source, config: config)
        let primaryLabel = statsCostLabel(source: source, period: config.period, metric: config.metric)

        return Menu {
            Section(L("Source", "数据源")) {
                ForEach(MenuBarStatsSource.allCases, id: \.self) { src in
                    Button {
                        settings.menuBarSummaryStatsSource = src
                    } label: {
                        Label {
                            Text(sourceLabel(src))
                        } icon: {
                            Image(systemName: src == source ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            Section(L("Period", "周期")) {
                ForEach(MenuBarCostPeriod.allCases, id: \.self) { period in
                    Button {
                        var next = config
                        next.period = period
                        settings.setCostSourceConfig(next, for: statsConfigKey)
                    } label: {
                        Label {
                            Text(periodLabel(period))
                        } icon: {
                            Image(systemName: period == config.period ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            Section(L("Metric", "指标")) {
                ForEach(MenuBarCostMetric.allCases, id: \.self) { metric in
                    Button {
                        var next = config
                        next.metric = metric
                        settings.setCostSourceConfig(next, for: statsConfigKey)
                    } label: {
                        Label {
                            Text(metricLabel(metric))
                        } icon: {
                            Image(systemName: metric == config.metric ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: statsIcon(source: source, metric: config.metric))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tintColor.opacity(0.7))
                    Text(valueText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(tintColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if requestCount > 0 {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("\(requestCount)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(primaryLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Stats Helpers

    private func statsValues(source: MenuBarStatsSource, config: MenuBarCostSourceConfig) -> (String, Color, Int) {
        switch source {
        case .proxy:
            let stats = proxyVM.overallStats(nodeFilter: nil, modelFilter: nil, since: config.period.sinceDate())
            let value: String
            let tint: Color
            switch config.metric {
            case .cost:
                value = formatCostCompact(stats.cost)
                tint = stats.cost > 0 ? .orange : .primary
            case .tokens:
                value = formatCompactNumber(Double(stats.tokens))
                tint = stats.tokens > 0 ? .purple : .primary
            }
            return (value, tint, stats.requests)

        case .claudeCode:
            guard let period = localTokenPeriod(config.period) else {
                return ("--", .secondary, 0)
            }
            let value: String
            let tint: Color
            switch config.metric {
            case .cost:
                value = formatCostCompact(period.usd)
                tint = period.usd > 0 ? .orange : .primary
            case .tokens:
                value = formatCompactNumber(Double(period.tokens ?? 0))
                tint = (period.tokens ?? 0) > 0 ? .purple : .primary
            }
            return (value, tint, 0)
        }
    }

    private func localTokenPeriod(_ period: MenuBarCostPeriod) -> CostPeriod? {
        guard let summary = localTokenCostSummary else { return nil }
        switch period {
        case .today:   return summary.today
        case .week:    return summary.week
        case .month:   return summary.month
        case .overall: return summary.overall
        }
    }

    private func statsIcon(source: MenuBarStatsSource, metric: MenuBarCostMetric) -> String {
        if metric == .cost { return "dollarsign.circle.fill" }
        return source == .claudeCode ? "chart.bar.xaxis" : "bolt.fill"
    }

    private func sourceLabel(_ source: MenuBarStatsSource) -> String {
        switch source {
        case .proxy:     return L("Proxy Stats", "代理统计")
        case .claudeCode: return L("Token Stats", "Token 统计")
        }
    }

    private func periodLabel(_ period: MenuBarCostPeriod) -> String {
        switch period {
        case .today:   return L("Today", "今日")
        case .week:    return L("This Week", "本周")
        case .month:   return L("This Month", "本月")
        case .overall: return L("All Time", "全部")
        }
    }

    private func metricLabel(_ metric: MenuBarCostMetric) -> String {
        switch metric {
        case .cost:   return L("Cost", "费用")
        case .tokens: return L("Tokens", "Tokens")
        }
    }

    private func statsCostLabel(source: MenuBarStatsSource, period: MenuBarCostPeriod, metric: MenuBarCostMetric) -> String {
        let sourcePrefix: String
        switch source {
        case .proxy:
            sourcePrefix = metric == .cost ? L("Proxy Cost", "代理费用") : L("Proxy Tokens", "代理 Tokens")
        case .claudeCode:
            sourcePrefix = metric == .cost ? L("Token Cost", "Token 费用") : L("Local Tokens", "本地 Tokens")
        }
        if period == .overall { return sourcePrefix }
        return "\(periodLabel(period)) · \(sourcePrefix)"
    }

    private func summaryStatCell(value: String, label: String, icon: String, iconColor: Color = .secondary, valueColor: Color? = nil) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var summaryStatDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 28)
    }

    private var quotaProviderGroups: [ProviderAccountGroup] {
        appState.providerAccountGroups.filter { group in
            group.accounts.contains { $0.liveProvider?.category != "local-cost" }
        }
    }

    // MARK: - Content

    private var menuBarContent: some View {
        Group {
            if refreshCoordinator.isLoading && refreshCoordinator.providers.isEmpty {
                VStack(spacing: 12) {
                    SmallProgressView().frame(width: 20, height: 20)
                    Text(L("Loading...", "加载中..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if quotaProviderGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(L("No providers", "暂无服务"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(quotaProviderGroups) { group in
                            MenuBarProviderSection(
                                group: group,
                                activationMessage: $activationMessage,
                                activationSuccess: $activationSuccess
                            )
                            .environmentObject(appState)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 600)
                .overlay(alignment: .bottom) {
                    if let message = activationMessage {
                        activationToast(message: message, success: activationSuccess)
                    }
                }
            }
        }
    }

    private func activationToast(message: String, success: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeOut(duration: 0.3)) {
                    activationMessage = nil
                }
            }
        }
    }

    // MARK: - Cost Tracking Section

    @ViewBuilder
    private var costTrackingSection: some View {
        let costProviders = appState.localCostProviders(from: refreshCoordinator.providers)
        let proxyStats = proxyVM.overallStats(nodeFilter: nil, modelFilter: nil)
        let hasProxyData = proxyStats.requests > 0
        let hasCostData = !costProviders.isEmpty || hasProxyData

        if hasCostData {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(L("Cost Tracking", "费用追踪"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                ForEach(costProviders, id: \.id) { provider in
                    costProviderRow(provider)
                }

                if hasProxyData {
                    proxyStatsRow(cost: proxyStats.cost, requests: proxyStats.requests, successRate: proxyStats.successRate)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func proxyStatsRow(cost: Double, requests: Int, successRate: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
                .frame(width: 16, height: 16)

            Text(L("Proxy Stats", "代理统计"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                costPill(formatCostCompact(cost), label: L("Cost", "费用"))
                costPill("\(requests)", label: L("Reqs", "请求"))
                costPill(String(format: "%.0f%%", successRate), label: L("Success", "成功"))
            }
        }
    }

    private func costPill(_ valueText: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(valueText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private func costProviderRow(_ provider: ProviderData) -> some View {
        HStack(spacing: 8) {
            ProviderIconView(provider.baseProviderId, size: 16)

            Text(provider.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let cs = provider.costSummary {
                HStack(spacing: 10) {
                    if let today = cs.today?.usd {
                        costPill(L("Today", "今日"), value: today)
                    }
                    if let week = cs.week?.usd {
                        costPill(L("Week", "本周"), value: week)
                    }
                    if let month = cs.month?.usd {
                        costPill(L("Month", "本月"), value: month)
                    }
                }
            }
        }
    }

    private func costPill(_ label: String, value: Double) -> some View {
        VStack(spacing: 1) {
            Text(formatCostCompact(value))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer

    private var menuBarFooter: some View {
        HStack(spacing: 6) {
            footerButton(L("Open AIUsage", "打开 AIUsage"), shortcut: "⌘O") {
                openMainWindow(section: .dashboard)
            }

            Spacer()

            footerButton(L("Refresh", "刷新"), shortcut: "⌘R") {
                refreshCoordinator.refreshAllProviders()
            }

            footerButton(L("Quit", "退出"), shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(shortcut)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func openMainWindow(section: AppSection) {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.revealMainWindow(section: section)
        } else {
            appState.presentMainWindow(section: section)
        }
    }

    private func quotaColor(_ percent: Double) -> Color { MenuBarHelpers.quotaColor(percent) }
    private func formatCostCompact(_ usd: Double) -> String { MenuBarHelpers.formatCostCompact(usd) }
}

// MARK: - Overall Health Status

private enum OverallHealthStatus {
    case healthy, warning, critical, idle

    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .idle: return .gray
        }
    }
}

// MARK: - Provider Section

struct MenuBarProviderSection: View {
    let group: ProviderAccountGroup
    @Binding var activationMessage: String?
    @Binding var activationSuccess: Bool
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        MenuBarColors.accent(for: group.providerId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(group.accounts) { entry in
                MenuBarAccountRow(
                    entry: entry,
                    providerId: group.providerId,
                    accentColor: accentColor,
                    activationMessage: $activationMessage,
                    activationSuccess: $activationSuccess
                )
                .environmentObject(appState)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
        )
        .padding(.vertical, 2)
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            ProviderIconView(group.providerId, size: 16)

            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            if group.accounts.count > 1 {
                Text("\(group.accounts.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            if let channel = group.channel {
                Text(channel.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Account Row (with multi-window quota bars)

struct MenuBarAccountRow: View {
    let entry: ProviderAccountEntry
    let providerId: String
    let accentColor: Color
    @Binding var activationMessage: String?
    @Binding var activationSuccess: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var activationManager: ProviderActivationManager
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var isActive: Bool { activationManager.isActiveAccount(entry) }
    private var canActivate: Bool { activationManager.canActivateProvider(providerId) && !isActive }
    private var remainingPercent: Double? { entry.liveProvider?.remainingPercent }
    private var isCostProvider: Bool { entry.liveProvider?.category == "local-cost" }
    private var costMonthUsd: Double? { entry.liveProvider?.costSummary?.month?.usd }
    private var windows: [QuotaWindow] { entry.liveProvider?.windows ?? [] }
    @State private var isWindowsExpanded = false

    private var isPinnedToStatusBar: Bool {
        if isCostProvider {
            return settings.menuBarPinnedCostSourceIds.contains(entry.id)
        }
        return settings.menuBarPinnedQuotaAccountIds.contains(entry.id)
    }

    private var primaryLabel: String {
        if let email = entry.accountEmail, !email.isEmpty { return email }
        if let name = entry.accountDisplayName, !name.isEmpty { return name }
        return entry.providerTitle
    }

    private var secondaryLabel: String? {
        if let note = entry.accountNote?.nilIfBlank {
            return note
        }
        return nil
    }

    private var membershipBadge: String? {
        entry.liveProvider?.membershipLabel?.nilIfBlank
    }

    private var membershipColor: Color {
        membershipBadgeTint(for: membershipBadge)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            accountHeader

            if !isCostProvider && !windows.isEmpty {
                quotaWindowBars
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isPinnedToStatusBar ? accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .onTapGesture { if canActivate { performActivation() } }
        .contextMenu { pinContextMenu }
    }

    private var rowBackground: Color {
        if isPinnedToStatusBar {
            return isHovered
                ? accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10)
                : accentColor.opacity(colorScheme == .dark ? 0.08 : 0.05)
        }
        return isHovered ? Color.primary.opacity(0.06) : Color.clear
    }

    @ViewBuilder
    private var pinContextMenu: some View {
        Button {
            togglePin()
        } label: {
            if isPinnedToStatusBar {
                Label(L("Unpin from Menu Bar", "从菜单栏取消固定"), systemImage: "pin.slash")
            } else {
                Label(L("Pin to Menu Bar", "固定到菜单栏"), systemImage: "pin")
            }
        }
    }

    private func togglePin() {
        if isCostProvider {
            var ids = settings.menuBarPinnedCostSourceIds
            if ids.contains(entry.id) { ids.remove(entry.id) } else { ids.insert(entry.id) }
            settings.menuBarPinnedCostSourceIds = ids
        } else {
            var ids = settings.menuBarPinnedQuotaAccountIds
            if ids.contains(entry.id) { ids.remove(entry.id) } else { ids.insert(entry.id) }
            settings.menuBarPinnedQuotaAccountIds = ids
        }
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        HStack(spacing: 8) {
            if isCostProvider {
                statusDot(color: entry.isConnected ? .orange : .gray)
            } else if remainingPercent == nil {
                if entry.isConnected {
                    statusDot(color: entry.liveProvider?.status == .error ? .orange : .green)
                } else {
                    statusDot(color: .gray)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(primaryLabel)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if let badge = membershipBadge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(membershipColor.opacity(0.85))
                            .clipShape(Capsule())
                    }

                    if isPinnedToStatusBar {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(accentColor.opacity(0.5))
                            .rotationEffect(.degrees(45))
                    }
                }

                if let secondary = secondaryLabel {
                    Text(secondary)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isCostProvider, let usd = costMonthUsd {
                Text(MenuBarHelpers.formatCostCompact(usd))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
            } else if let percent = remainingPercent {
                Text("\(Int(percent))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(MenuBarHelpers.quotaColor(percent))
            }

            if isActive && activationManager.canActivateProvider(providerId) {
                activeBadge
            } else if canActivate {
                switchButton
            }
        }
    }

    // MARK: - Multi-Window Quota Bars

    private static let maxVisibleWindows = 3

    @ViewBuilder
    private var quotaWindowBars: some View {
        let hasOverflow = windows.count > Self.maxVisibleWindows
        let displayWindows = isWindowsExpanded ? windows : Array(windows.prefix(Self.maxVisibleWindows))

        VStack(alignment: .leading, spacing: 3) {
            if isWindowsExpanded {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(Array(displayWindows.enumerated()), id: \.offset) { _, window in
                        MenuBarQuotaBar(window: window)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(displayWindows.enumerated()), id: \.offset) { _, window in
                        MenuBarQuotaBar(window: window)
                    }
                }
            }

            if hasOverflow {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isWindowsExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isWindowsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                        Text(isWindowsExpanded
                             ? L("Collapse", "收起")
                             : "+\(windows.count - Self.maxVisibleWindows) " + L("more", "更多"))
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Subviews

    private func statusDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .frame(width: 28, height: 28)
    }

    private var activeBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text(L("Active", "活跃"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.12))
        .clipShape(Capsule())
    }

    private var switchButton: some View {
        Button {
            performActivation()
        } label: {
            Text(L("Switch", "切换"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func performActivation() {
        do {
            try activationManager.activateAccount(entry: entry)
            withAnimation(.easeInOut(duration: 0.3)) {
                activationSuccess = true
                activationMessage = L("Switched to ", "已切换至 ") + primaryLabel
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.3)) {
                activationSuccess = false
                activationMessage = L("Switch failed", "切换失败")
            }
        }
    }
}

// MARK: - Multi-Window Quota Bar

struct MenuBarQuotaBar: View {
    let window: QuotaWindow
    @Environment(\.colorScheme) private var colorScheme

    private var isUnlimited: Bool {
        window.remainingPercent == nil
    }

    private var percent: Double {
        min(max(window.displayRemainingPercent, 0), 100)
    }

    private var barColor: Color {
        isUnlimited ? Color.secondary.opacity(0.55) : MenuBarHelpers.quotaColor(percent)
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if isUnlimited {
                    Image(systemName: "infinity")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(barColor)
                } else {
                    Text("\(Int(percent))%")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(barColor)
                }
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(trackColor)
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .scaleEffect(x: isUnlimited ? 1 : max(percent / 100, 0.001), y: 1, anchor: .leading)
            }
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

// MARK: - Shared Helpers

enum MenuBarHelpers {
    static func quotaColor(_ percent: Double) -> Color {
        if percent >= 70 { return Color(red: 0.15, green: 0.78, blue: 0.40) }
        if percent >= 35 { return Color(red: 0.96, green: 0.64, blue: 0.18) }
        return Color(red: 0.92, green: 0.25, blue: 0.28)
    }

    static func formatCostCompact(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 1 { return String(format: "$%.2f", usd) }
        if usd < 100 { return String(format: "$%.1f", usd) }
        return String(format: "$%.0f", usd)
    }
}

enum MenuBarColors {
    static func accent(for providerId: String) -> Color {
        switch providerId {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude": return .purple
        case "cursor": return .green
        case "gemini": return .orange
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "warp": return .pink
        case "amp": return .teal
        default: return .gray
        }
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .environmentObject(ProviderActivationManager.shared)
}
