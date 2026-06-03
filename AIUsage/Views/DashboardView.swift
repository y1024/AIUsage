import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @EnvironmentObject var proxyVM: ProxyViewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 本地数据（概览/热力图/聚合）始终立即渲染，不再被网络刷新的全局骨架屏遮挡。
                if let error = refreshCoordinator.errorMessage {
                    inlineErrorBanner(error)
                }

                overviewSection

                if !costTrackingProviders.isEmpty {
                    heatmapSection
                        // 让热力图悬浮提示卡片绘制在下方统计卡片之上（同级 VStack 中
                        // 后声明的视图默认覆盖先声明的，故抬高热力图层级）。
                        .zIndex(1)
                } else if isAwaitingLocalStats {
                    skeletonHeatmap
                }

                providersSection
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 首次加载中、本地 Token 统计还没扫到时，仅对热力图区域显示骨架（而非整页）。
    private var isAwaitingLocalStats: Bool {
        !refreshCoordinator.hasCompletedInitialLoad
            && costTrackingProviders.isEmpty
            && appState.selectedProviderIds.contains(where: { $0 == "claude" || $0 == "codex-cost" })
    }

    // MARK: - Overview Section

    private var overviewSection: some View {
        let agg = overviewCostAggregates

        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                overviewTile(
                    icon: "square.stack.3d.up.fill",
                    tint: .blue,
                    value: formatInt(selectedOfficialProviderCount),
                    title: L("Services", "服务"),
                    sub1Label: L("Official", "官方"),
                    sub1Value: formatInt(selectedOfficialProviderCount)
                )
                overviewTile(
                    icon: "person.crop.circle.badge.checkmark",
                    tint: .green,
                    value: formatInt(connectedAccountCount),
                    title: L("Accounts", "账号"),
                    sub1Label: L("Total", "已保存"),
                    sub1Value: formatInt(totalAccountCount)
                )
                overviewTile(
                    icon: "bolt.fill",
                    tint: .purple,
                    value: formatCompactNumber(Double(agg.overallTokens)),
                    title: L("Tokens", "Token"),
                    sub1Label: L("Today", "今日"),
                    sub1Value: formatCompactNumber(Double(agg.todayTokens)),
                    sub2Label: L("Month", "本月"),
                    sub2Value: formatCompactNumber(Double(agg.monthTokens))
                )
                overviewTile(
                    icon: "dollarsign.circle.fill",
                    tint: .orange,
                    value: AIUsage.formatCurrency(agg.overallCost),
                    title: L("Cost", "费用"),
                    sub1Label: L("Today", "今日"),
                    sub1Value: AIUsage.formatCurrency(agg.todayCost),
                    sub2Label: L("Month", "本月"),
                    sub2Value: AIUsage.formatCurrency(agg.monthCost)
                )
            }
        }
    }

    @ViewBuilder
    private func overviewTile(
        icon: String,
        tint: Color,
        value: String,
        title: String,
        sub1Label: String,
        sub1Value: String,
        sub2Label: String? = nil,
        sub2Value: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(sub1Label).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(sub1Value).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
                if let sub2Label, let sub2Value {
                    HStack(spacing: 4) {
                        Text(sub2Label).font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(sub2Value).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private struct OverviewCostAggregates {
        var overallTokens = 0
        var overallCost = 0.0
        var todayTokens = 0
        var todayCost = 0.0
        var monthTokens = 0
        var monthCost = 0.0
    }

    /// 从本地 cost provider (Claude + Codex) 的 costSummary 中汇总全量 Token/费用。
    /// 比代理统计更完整——涵盖直连和代理的全部 JSONL 记录。
    private var overviewCostAggregates: OverviewCostAggregates {
        var agg = OverviewCostAggregates()
        for provider in costTrackingProviders {
            guard let summary = provider.costSummary else { continue }
            agg.overallTokens += summary.overall?.tokens ?? 0
            agg.overallCost += summary.overall?.usd ?? 0
            agg.todayTokens += summary.today?.tokens ?? 0
            agg.todayCost += summary.today?.usd ?? 0
            agg.monthTokens += summary.month?.tokens ?? 0
            agg.monthCost += summary.month?.usd ?? 0
        }
        return agg
    }

    private func overviewMetric(
        icon: String,
        tint: Color,
        value: String,
        title: String,
        note: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    
    // MARK: - Alerts Section
    
    private func alertsSection(_ overview: DashboardOverview) -> some View {
        Group {
            if !overview.alerts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Alerts", "告警", key: "dashboard.alerts"))
                        .font(.title2)
                        .bold()
                    
                    ForEach(overview.alerts) { alert in
                        AlertBanner(alert: alert)
                    }
                }
            }
        }
    }
    
    // MARK: - Providers Grid

    private var costTrackingProviders: [ProviderData] {
        deduplicatedProviders(appState.localCostProviders(from: refreshCoordinator.providers))
    }

    private var claudeLocalProviders: [ProviderData] {
        costTrackingProviders.filter { $0.baseProviderId == "claude" }
    }

    private var codexLocalProviders: [ProviderData] {
        costTrackingProviders.filter { $0.baseProviderId == "codex-cost" }
    }

    /// 顶部活动热力图：按工具拆成 Claude Code 与 Codex 两块（仅展示有数据的一块），
    /// 各自带上自家品牌色——Claude Code 橙、Codex 靛蓝，与卡片/图标/菜单栏口径一致。
    /// 数据源统一为本地 JSONL（已包含真实上游模型名）。
    private var dashboardHeatmapWeeks: Int { 26 }

    private var claudeHeatmap: some View {
        LocalTokenUsageHeatmap(
            providers: claudeLocalProviders,
            brandLabel: "Claude Code",
            brandAsset: "claude",
            accent: Color(red: 0.85, green: 0.47, blue: 0.26),
            weeks: dashboardHeatmapWeeks
        )
    }

    private var codexHeatmap: some View {
        LocalTokenUsageHeatmap(
            providers: codexLocalProviders,
            brandLabel: "Codex",
            brandAsset: "codex",
            accent: .indigo,
            weeks: dashboardHeatmapWeeks
        )
    }

    /// 仪表盘热力图：半年口径，Claude Code 与 Codex 左右两列并排；
    /// 仅一方有数据时占满整行。
    @ViewBuilder
    private var heatmapSection: some View {
        let showClaude = !claudeLocalProviders.isEmpty
        let showCodex = !codexLocalProviders.isEmpty

        if showClaude && showCodex {
            HStack(alignment: .top, spacing: 16) {
                claudeHeatmap.frame(maxWidth: .infinity)
                codexHeatmap.frame(maxWidth: .infinity)
            }
            .zIndex(1)
        } else if showClaude {
            claudeHeatmap.zIndex(1)
        } else if showCodex {
            codexHeatmap.zIndex(1)
        }
    }


    /// 官方服务商的账号条目（来自 Keychain 账号注册表 + live 数据合并），启动即可用。
    /// 用它渲染卡片，能在网络刷新完成前先展示已知账号（占位/加载态），而非空白或假空态。
    private var officialAccountEntries: [ProviderAccountEntry] {
        officialAccountGroups.flatMap(\.accounts)
    }

    private var selectedOfficialProviderCount: Int {
        appState.providerCatalog.filter {
            $0.kind == .official && appState.selectedProviderIds.contains($0.id)
        }.count
    }

    private var officialAccountGroups: [ProviderAccountGroup] {
        appState.providerAccountGroups.filter {
            appState.providerCatalogItem(for: $0.providerId)?.kind == .official
        }
    }

    private var connectedAccountCount: Int {
        officialAccountGroups.reduce(0) { $0 + $1.connectedCount }
    }

    private var totalAccountCount: Int {
        officialAccountGroups.reduce(0) { $0 + $1.accounts.count }
    }

    private var servicesNote: String {
        if selectedOfficialProviderCount > 0 {
            return L(
                "\(selectedOfficialProviderCount) official apps enabled",
                "已启用 \(selectedOfficialProviderCount) 个官方应用"
            )
        }
        return L("Choose apps to start scanning", "选择应用后开始扫描")
    }

    private var accountNote: String {
        if totalAccountCount > 0 {
            return L(
                "\(formatInt(totalAccountCount)) accounts saved securely",
                "已安全保存 \(formatInt(totalAccountCount)) 个账号"
            )
        }
        return L("No account has been saved yet", "还没有保存账号")
    }

    private func formatInt(_ value: Int) -> String {
        formatNumber(value)
    }

    private func deduplicatedProviders(_ providers: [ProviderData]) -> [ProviderData] {
        var seen = Set<String>()
        var unique: [ProviderData] = []

        for provider in providers {
            if seen.insert(provider.id).inserted {
                unique.append(provider)
            }
        }

        return unique
    }

    // MARK: - Providers Section

    @ViewBuilder
    private var providersSection: some View {
        if officialAccountEntries.isEmpty {
            providersCallToAction
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(L("Providers", "服务商", key: "dashboard.providers"))
                        .font(.title2)
                        .bold()
                    if refreshCoordinator.isAnyRefreshInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text(L("Syncing…", "同步中…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(officialAccountEntries) { entry in
                        accountCard(for: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountCard(for entry: ProviderAccountEntry) -> some View {
        if let live = entry.liveProvider {
            if live.needsCredentialConnection {
                // 「未连接」≠「采集失败」：缺 Key / 未登录时给引导态，而非吓人的不可用卡。
                NeedsConnectionCard(
                    providerId: entry.providerId,
                    title: entry.cardTitle,
                    subtitle: entry.cardSubtitle,
                    onConnect: { appState.selectedSection = .providers }
                )
            } else {
                ManagedProviderAccountCard(account: entry, provider: live)
                    .environmentObject(appState)
                    .environmentObject(refreshCoordinator)
            }
        } else if isEntryLoading(entry) {
            LoadingAccountCard(
                providerId: entry.providerId,
                title: entry.cardTitle,
                subtitle: entry.cardSubtitle
            )
        } else {
            SavedAccountCard(account: entry, onReconnect: { appState.selectedSection = .providers })
                .environmentObject(appState)
                .environmentObject(refreshCoordinator)
        }
    }

    /// 首次刷新还没完成，或该应用正在刷新时，未拿到 live 数据的账号显示「加载中」占位，
    /// 而不是 SavedAccountCard 的「凭证可能已过期」误导态。
    private func isEntryLoading(_ entry: ProviderAccountEntry) -> Bool {
        !refreshCoordinator.hasCompletedInitialLoad
            || refreshCoordinator.isProviderRefreshInFlight(entry.providerId)
    }

    private var providersCallToAction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Providers", "服务商", key: "dashboard.providers"))
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 10) {
                Text(appState.selectedProviderIds.isEmpty
                     ? L("No sources selected yet", "尚未选择扫描来源")
                     : L("No accounts connected yet", "还没有连接账号"))
                    .font(.headline)

                Text(L(
                    "Choose the apps you use and connect an account to start monitoring usage here.",
                    "选择你在用的应用并连接账号，就能在这里监控用量。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    appState.providerPickerMode = appState.needsInitialProviderSetup ? .initialSetup : .manage
                } label: {
                    Label(L("Choose Sources", "选择来源"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }

    // MARK: - State Views

    /// 网络刷新失败时的轻量提示条（不再整页报错），有已知账号时仍能看到其它本地内容。
    private func inlineErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L("Retry", "重试")) {
                refreshCoordinator.refreshAllProviders()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(refreshCoordinator.isAnyRefreshInProgress)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private var skeletonHeatmap: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonPill(width: 180, height: 16)
            SkeletonPill(width: 100, height: 10)
            SkeletonBlock(height: 130, cornerRadius: 8)
                .padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

}

#Preview {
    DashboardView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 900, height: 700)
}
