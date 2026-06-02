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
                    LocalTokenUsageHeatmap(providers: costTrackingProviders)
                        // 让热力图悬浮提示卡片绘制在下方统计卡片之上（同级 VStack 中
                        // 后声明的视图默认覆盖先声明的，故抬高热力图层级）。
                        .zIndex(1)
                } else if isAwaitingLocalStats {
                    skeletonHeatmap
                }

                unifiedStatsSection

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
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Overview", "概览", key: "dashboard.overview"))
                .font(.title2)
                .bold()
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                ForEach(overviewCards()) { stat in
                    StatCard(stat: stat)
                }
            }
        }
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

    /// 官方服务商的账号条目（来自 Keychain 账号注册表 + live 数据合并），启动即可用。
    /// 用它渲染卡片，能在网络刷新完成前先展示已知账号（占位/加载态），而非空白或假空态。
    private var officialAccountEntries: [ProviderAccountEntry] {
        officialAccountGroups.flatMap(\.accounts)
    }

    private var localCostMonthUsd: Double {
        costTrackingProviders.reduce(0) { $0 + ($1.costSummary?.month?.usd ?? 0) }
    }

    private var localWeekTokens: Int {
        costTrackingProviders.reduce(0) { $0 + ($1.costSummary?.week?.tokens ?? 0) }
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

    private func overviewCards() -> [DashboardSummaryCard] {
        let servicesNote: String
        if selectedOfficialProviderCount > 0 {
            servicesNote = L(
                "\(selectedOfficialProviderCount) official apps enabled",
                "已启用 \(selectedOfficialProviderCount) 个官方应用"
            )
        } else {
            servicesNote = L("Choose apps to start scanning", "选择应用后开始扫描")
        }

        let accountNote: String
        if totalAccountCount > 0 {
            accountNote = L(
                "\(formatInt(totalAccountCount)) accounts saved securely",
                "已安全保存 \(formatInt(totalAccountCount)) 个账号"
            )
        } else {
            accountNote = L("No account has been saved yet", "还没有保存账号")
        }

        let costNote: String
        if costTrackingProviders.isEmpty {
            costNote = L("No local token stats source yet", "还没有本地 Token 统计来源")
        } else {
            costNote = L(
                "\(costTrackingProviders.count) source tracked this week",
                "当前跟踪 \(costTrackingProviders.count) 个费用来源"
            ) + " · " + L(
                "\(formatInt(localWeekTokens)) tokens logged",
                "本周记录 \(formatInt(localWeekTokens)) 个 tokens"
            )
        }

        return [
            DashboardSummaryCard(
                title: L("Tracked Services", "监控服务", key: "dashboard.summary.tracked_services"),
                value: formatInt(selectedOfficialProviderCount),
                note: servicesNote,
                icon: "square.stack.3d.up.fill",
                color: .blue
            ),
            DashboardSummaryCard(
                title: L("Live Accounts", "在线账号", key: "dashboard.summary.live_accounts"),
                value: formatInt(connectedAccountCount),
                note: accountNote,
                icon: "person.crop.circle.badge.checkmark",
                color: .green
            ),
            DashboardSummaryCard(
                title: L("Token Stats", "Token 统计", key: "dashboard.summary.cost_tracking"),
                value: formatCurrency(localCostMonthUsd),
                note: costNote,
                icon: "chart.line.uptrend.xyaxis.circle.fill",
                color: .purple
            ),
            {
                let proxyStats = proxyVM.overallStats(nodeFilter: nil, modelFilter: nil)
                let proxyRange = proxyVM.dataDateRange(nodeFilter: nil, modelFilter: nil)
                let proxyNote: String
                if proxyStats.requests == 0 {
                    proxyNote = L("No proxy requests recorded yet", "暂无代理请求记录")
                } else {
                    proxyNote = L(
                        "\(proxyStats.requests) requests over \(proxyRange.days) days · \(proxyVM.modelAggregates(nodeFilter: nil, modelFilter: nil).count) models",
                        "\(proxyRange.days) 天内 \(proxyStats.requests) 次请求 · \(proxyVM.modelAggregates(nodeFilter: nil, modelFilter: nil).count) 个模型"
                    )
                }
                return DashboardSummaryCard(
                    title: L("Proxy Stats", "代理统计", key: "dashboard.summary.proxy_stats"),
                    value: formatCurrency(proxyStats.cost),
                    note: proxyNote,
                    icon: "server.rack",
                    color: .teal
                )
            }()
        ]
    }

    private func formatInt(_ value: Int) -> String {
        formatNumber(value)
    }

    private func formatCurrency(_ value: Double) -> String {
        AIUsage.formatCurrency(value)
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

    @ViewBuilder
    private var unifiedStatsSection: some View {
        let showCC = !costTrackingProviders.isEmpty
        let showProxy = !proxyVM.configurations.isEmpty
        if showCC || showProxy {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                spacing: 16
            ) {
                if showCC {
                    LocalTokenAggregateCard(providers: costTrackingProviders) {
                        UserDefaults.standard.set(StatsDomain.local.rawValue, forKey: DefaultsKey.statsDomain)
                        appState.selectedSection = .costTracking
                    }
                }
                if showProxy {
                    ProxyStatsAggregateCard(proxyVM: proxyVM) {
                        UserDefaults.standard.set(StatsDomain.proxy.rawValue, forKey: DefaultsKey.statsDomain)
                        appState.selectedSection = .costTracking
                    }
                }
            }
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
        .frame(width: 900, height: 700)
}
