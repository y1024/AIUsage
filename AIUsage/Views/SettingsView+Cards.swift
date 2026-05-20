import SwiftUI

// MARK: - Section Views

extension SettingsView {

    // MARK: - General

    var generalSection: some View {
        settingsCard(
            title: L("General", "通用"),
            subtitle: L("Language, appearance, and basic preferences.", "语言、外观和基本偏好设置。")
        ) {
            settingsBlock(title: L("Language", "语言")) {
                Picker("", selection: $settings.language) {
                    Text("English").tag("en")
                    Text("中文").tag("zh")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: L("Theme", "主题"),
                subtitle: L("Choose app appearance: follow system, light, or dark.", "选择外观模式：跟随系统、浅色或深色。")
            ) {
                Picker("", selection: $settings.themeMode) {
                    Text(L("System", "系统")).tag("system")
                    Text(L("Light", "浅色")).tag("light")
                    Text(L("Dark", "深色")).tag("dark")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: L("Display Currency", "显示货币"),
                subtitle: L("Currency for cost display across the app.", "应用中费用显示的货币单位。")
            ) {
                Picker("", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: DefaultsKey.displayCurrency) ?? "USD" },
                    set: { UserDefaults.standard.set($0, forKey: DefaultsKey.displayCurrency) }
                )) {
                    Text("USD ($)").tag("USD")
                    Text("CNY (¥)").tag("CNY")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200, alignment: .leading)
            }

            Divider()

            settingsToggleRow(
                title: L("Launch at Login", "开机启动"),
                subtitle: L("Open AIUsage automatically after login.", "登录系统后自动打开 AIUsage。"),
                isOn: $launchAtLogin
            )

            Divider()

            settingsToggleRow(
                title: L("Hide Dock Icon", "隐藏 Dock 图标"),
                subtitle: L("Keep AIUsage in the menu bar only.", "让 AIUsage 只出现在菜单栏。"),
                isOn: $hideDockIcon
            )
            .help(L("The app will only appear in the menu bar", "应用将只显示在菜单栏"))
        }
    }

    // MARK: - Data & Refresh

    var dataRefreshSection: some View {
        settingsCard(
            title: L("Data & Refresh", "数据与刷新"),
            subtitle: L("Backend mode and refresh intervals.", "后端模式和数据刷新频率。")
        ) {
            settingsBlock(title: L("Backend Mode", "后端模式")) {
                Picker("", selection: $settings.backendMode) {
                    Text(L("Local", "本地")).tag("local")
                    Text(L("Remote", "远程")).tag("remote")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.backendMode) { _, _ in
                    settings.saveSettings()
                    refreshCoordinator.refreshAllProviders()
                }
            }

            if settings.backendMode == "remote" {
                Divider()

                settingsBlock(title: L("Host", "地址")) {
                    TextField("127.0.0.1", text: $remoteHostInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyRemoteSettings() }
                }

                Divider()

                settingsBlock(title: L("Port", "端口")) {
                    TextField("4318", text: $remotePortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120, alignment: .leading)
                        .onSubmit { applyRemoteSettings() }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button(L("Apply", "应用")) { applyRemoteSettings() }
                            .buttonStyle(.borderedProminent)

                        Button {
                            Task { await testRemoteConnection() }
                        } label: {
                            HStack(spacing: 6) {
                                if isTestingRemoteConnection {
                                    SmallProgressView()
                                        .frame(width: 12, height: 12)
                                } else {
                                    Image(systemName: "bolt.horizontal.circle")
                                }
                                Text(L("Test Connection", "测试连接"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTestingRemoteConnection)
                    }

                    remoteConnectionStatusView

                    Text(
                        L(
                            "Connect to a QuotaServer running on another machine. Start server: swift run QuotaServer --host 0.0.0.0 --port 4318",
                            "连接到其他机器上的 QuotaServer。启动命令：swift run QuotaServer --host 0.0.0.0 --port 4318"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            settingsBlock(
                title: L("Providers auto-refresh", "服务商自动刷新"),
                subtitle: L("Refresh interval for API-based providers (OpenAI, Anthropic, etc.)", "API 服务商的刷新间隔（OpenAI、Anthropic 等）")
            ) {
                Picker("", selection: $settings.autoRefreshInterval) {
                    ForEach(AppSettings.supportedAutoRefreshIntervals, id: \.self) { interval in
                        Text(autoRefreshTitle(for: interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: L("Local token stats auto-refresh", "本地 Token 统计自动刷新"),
                subtitle: L("Refresh interval for local Claude and Codex token stats (faster intervals available)", "本地 Claude 与 Codex Token 统计的刷新间隔（支持更短间隔）")
            ) {
                Picker("", selection: $settings.claudeCodeRefreshInterval) {
                    ForEach(AppSettings.supportedClaudeCodeRefreshIntervals, id: \.self) { interval in
                        Text(claudeCodeRefreshTitle(for: interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }
        }
    }

    // MARK: - Menu Bar

    var menuBarSection: some View {
        settingsCard(
            title: L("Menu Bar", "菜单栏"),
            subtitle: L("Configure what appears next to the menu bar icon.", "配置菜单栏图标旁显示的内容。")
        ) {
            menuBarQuotaAccountsPicker

            Divider()

            menuBarCostSourcesPicker

            if totalPinnedCount > StatusBarItemView.recommendedMaxAccounts {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text(L(
                        "You have \(totalPinnedCount) items pinned. More than \(StatusBarItemView.recommendedMaxAccounts) may cause the menu bar to be too wide.",
                        "已固定 \(totalPinnedCount) 项。超过 \(StatusBarItemView.recommendedMaxAccounts) 个可能导致菜单栏过长。"
                    ))
                    .font(.caption2)
                }
                .foregroundStyle(.orange)
            }
        }
        .onAppear { pruneStaleMenuBarPins() }
    }

    // MARK: - Card Appearance

    var cardAppearanceSection: some View {
        settingsCard(
            title: L("Card Appearance", "卡片外观"),
            subtitle: L("Adjust how quota cards present information.", "调整额度卡片的呈现方式。")
        ) {
            settingsBlock(title: L("Quota card style", "额度卡片样式")) {
                Picker("", selection: $settings.quotaIndicatorStyle) {
                    ForEach(CardQuotaIndicatorStyle.allCases, id: \.self) { style in
                        Text(quotaStyleTitle(style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340, alignment: .leading)
            }

            Divider()

            settingsBlock(title: L("Progress meaning", "进度语义")) {
                Picker("", selection: $settings.quotaIndicatorMetric) {
                    ForEach(CardQuotaIndicatorMetric.allCases, id: \.self) { metric in
                        Text(quotaMetricTitle(metric)).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(L("Preview", "预览"))
                    .font(.subheadline.weight(.semibold))

                quotaIndicatorPreview

                Text(L("Applies instantly to all provider cards.", "会立即应用到所有服务卡片。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Proxy

    var proxySection: some View {
        settingsCard(
            title: L("Proxy", "代理"),
            subtitle: L("Claude Code proxy behavior and logging.", "Claude Code 代理行为和日志管理。")
        ) {
            settingsToggleRow(
                title: L("Auto-restore proxies on launch", "启动时自动恢复代理"),
                subtitle: L(
                    "If enabled, AIUsage restores the last activated node and all proxy-only nodes when the app launches.",
                    "开启后，启动 AIUsage 时会自动恢复上次接入 Claude 的节点以及所有仅代理运行的节点。"
                ),
                isOn: $settings.proxyAutoRestoreOnLaunch
            )

            Divider()

            settingsBlock(
                title: L("Proxy Log Retention", "代理日志保留"),
                subtitle: L("Automatically delete proxy request logs older than the specified number of days.", "自动删除超过指定天数的代理请求日志。")
            ) {
                Picker("", selection: $proxyLogRetentionDays) {
                    Text(L("7 days", "7 天")).tag(7)
                    Text(L("14 days", "14 天")).tag(14)
                    Text(L("30 days", "30 天")).tag(30)
                    Text(L("90 days", "90 天")).tag(90)
                    Text(L("180 days", "180 天")).tag(180)
                    Text(L("365 days", "365 天")).tag(365)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }
        }
    }

    // MARK: - Notifications

    var notificationsSection: some View {
        settingsCard(
            title: L("Notifications", "通知"),
            subtitle: L("Decide when AIUsage should proactively nudge you.", "设置 AIUsage 在什么情况下主动提醒你。")
        ) {
            settingsToggleRow(
                title: L("Enable Notifications", "启用通知"),
                subtitle: L("Show desktop alerts for low quota and other status changes.", "为低额度和状态变化显示桌面提醒。"),
                isOn: $showNotifications
            )

            Divider()

            settingsBlock(
                title: L("Low Quota Alert", "低额度提醒"),
                subtitle: L("Trigger when remaining quota drops below the selected threshold.", "当剩余额度低于阈值时触发提醒。")
            ) {
                HStack(spacing: 14) {
                    Slider(value: $lowQuotaThreshold, in: 5...50, step: 5)
                    Text("\(Int(lowQuotaThreshold))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            }
            .opacity(showNotifications ? 1 : 0.45)
            .disabled(!showNotifications)

            Divider()

            settingsBlock(
                title: L("Claude daily cost alert", "Claude 每日消费提醒"),
                subtitle: L("Get notified when daily spending exceeds threshold (0 = off)", "当每日消费超过阈值时通知（0 = 关闭）")
            ) {
                HStack(spacing: 8) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("0.00", value: $settings.claudeCodeDailyThreshold, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: settings.claudeCodeDailyThreshold) { _, _ in
                            settings.saveSettings()
                        }
                    Text(L("USD", "美元"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .opacity(showNotifications ? 1 : 0.45)
            .disabled(!showNotifications)
        }
    }

    // MARK: - About

    var aboutSection: some View {
        settingsCard(
            title: L("About", "关于"),
            subtitle: L("Version information and update checks.", "版本信息与更新检查。")
        ) {
            settingsValueRow(title: L("Version", "版本"), value: appVersion)

            Divider()

            settingsToggleRow(
                title: L("Automatic Updates", "自动检查更新"),
                subtitle: L("Periodically check for new versions in the background.", "后台定期检查是否有新版本。"),
                isOn: Binding(
                    get: { sparkle.automaticallyChecksForUpdates },
                    set: { sparkle.setAutoCheckEnabled($0) }
                )
            )

            Divider()

            HStack(spacing: 10) {
                if let repositoryURL {
                    Link(destination: repositoryURL) {
                        Label("GitHub", systemImage: "link")
                    }
                }

                Button {
                    sparkle.checkForUpdates()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle")
                        Text(L("Check for Updates", "检查更新"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!sparkle.canCheckForUpdates)
            }
        }
    }

    // MARK: - Menu Bar Helpers

    private func pruneStaleMenuBarPins() {
        let allEntries = appState.providerAccountGroups.flatMap(\.accounts)
        let quotaIds = Set(allEntries.filter { $0.liveProvider?.category != "local-cost" }.map(\.id))
        let costIds = Set(allEntries.filter { $0.liveProvider?.category == "local-cost" }.map(\.id))
        settings.pruneMenuBarPinnedIds(validQuotaIds: quotaIds, validCostIds: costIds)
    }

    private var menuBarQuotaAccountsPicker: some View {
        settingsBlock(
            title: L("Quota accounts", "配额账号"),
            subtitle: L("Select quota-based accounts to show in the menu bar. Empty = icon only. You can also right-click accounts in the popover to pin.", "选择显示在菜单栏的配额账号。不选则仅显示图标。也可在弹窗中右键账号进行固定。")
        ) {
            let groups = appState.providerAccountGroups
            let quotaEntries = groups.flatMap { group in
                group.accounts
                    .filter { $0.liveProvider?.category != "local-cost" }
                    .map { (group: group, entry: $0) }
            }

            if quotaEntries.isEmpty {
                Text(L("No quota accounts available", "暂无配额账号"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                pinnedAccountList(
                    entries: quotaEntries,
                    selectedIds: $settings.menuBarPinnedQuotaAccountIds
                )
            }
        }
    }

    private var menuBarCostSourcesPicker: some View {
        settingsBlock(
            title: L("Cost sources", "费用来源"),
            subtitle: L("Select cost sources to show in the menu bar.", "选择显示在菜单栏的费用来源。")
        ) {
            let groups = appState.providerAccountGroups
            let costEntries = groups.flatMap { group in
                group.accounts
                    .filter { $0.liveProvider?.category == "local-cost" }
                    .map { (group: group, entry: $0) }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(costEntries, id: \.entry.id) { pair in
                    let isSelected = settings.menuBarPinnedCostSourceIds.contains(pair.entry.id)
                    HStack(spacing: 8) {
                        Button {
                            var ids = settings.menuBarPinnedCostSourceIds
                            if isSelected { ids.remove(pair.entry.id) } else { ids.insert(pair.entry.id) }
                            settings.menuBarPinnedCostSourceIds = ids
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.orange : Color.secondary)
                                    .font(.system(size: 14))
                                ProviderIconView(pair.group.providerId, size: 14)
                                Text(pair.entry.accountEmail ?? pair.entry.accountDisplayName ?? pair.entry.providerTitle)
                                    .font(.caption).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isSelected {
                            costSourceConfigMenu(for: pair.entry.id)
                        }
                    }
                }

                let proxySelected = settings.menuBarPinnedCostSourceIds.contains("proxy-stats")
                HStack(spacing: 8) {
                    Button {
                        var ids = settings.menuBarPinnedCostSourceIds
                        if proxySelected { ids.remove("proxy-stats") } else { ids.insert("proxy-stats") }
                        settings.menuBarPinnedCostSourceIds = ids
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: proxySelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(proxySelected ? Color.blue : Color.secondary)
                                .font(.system(size: 14))
                            Image(systemName: "network")
                                .font(.system(size: 12))
                                .frame(width: 14, height: 14)
                            Text(L("Proxy Stats", "代理统计"))
                                .font(.caption).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if proxySelected {
                        costSourceConfigMenu(for: "proxy-stats")
                    }
                }

                if costEntries.isEmpty && !proxySelected {
                    Text(L("No cost sources available", "暂无费用来源"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func costSourceConfigMenu(for sourceId: String) -> some View {
        let config = settings.costSourceConfig(for: sourceId)
        HStack(spacing: 6) {
            Menu {
                ForEach(MenuBarCostPeriod.allCases, id: \.self) { period in
                    Button {
                        var next = config
                        next.period = period
                        settings.setCostSourceConfig(next, for: sourceId)
                    } label: {
                        Label {
                            Text(periodDisplayLabel(period))
                        } icon: {
                            Image(systemName: period == config.period ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Text(periodDisplayLabel(config.period))
                    .font(.caption)
                    .frame(minWidth: 44)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(MenuBarCostMetric.allCases, id: \.self) { metric in
                    Button {
                        var next = config
                        next.metric = metric
                        settings.setCostSourceConfig(next, for: sourceId)
                    } label: {
                        Label {
                            Text(metricDisplayLabel(metric))
                        } icon: {
                            Image(systemName: metric == config.metric ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                Text(metricDisplayLabel(config.metric))
                    .font(.caption)
                    .frame(minWidth: 44)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func periodDisplayLabel(_ period: MenuBarCostPeriod) -> String {
        switch period {
        case .today:   return L("Today", "今日")
        case .week:    return L("Week", "本周")
        case .month:   return L("Month", "本月")
        case .overall: return L("All", "全部")
        }
    }

    private func metricDisplayLabel(_ metric: MenuBarCostMetric) -> String {
        switch metric {
        case .cost:   return L("Cost", "费用")
        case .tokens: return L("Tokens", "Tokens")
        }
    }

    private var totalPinnedCount: Int {
        validPinnedQuotaIds.count + validPinnedCostIds.count
    }

    private var validPinnedQuotaIds: Set<String> {
        let allEntryIds = Set(
            appState.providerAccountGroups.flatMap { $0.accounts }
                .filter { $0.liveProvider?.category != "local-cost" }
                .map(\.id)
        )
        return settings.menuBarPinnedQuotaAccountIds.intersection(allEntryIds)
    }

    private var validPinnedCostIds: Set<String> {
        let allEntryIds = Set(
            appState.providerAccountGroups.flatMap { $0.accounts }
                .filter { $0.liveProvider?.category == "local-cost" }
                .map(\.id)
        )
        return settings.menuBarPinnedCostSourceIds.intersection(allEntryIds)
    }

    private func pinnedAccountList(
        entries: [(group: ProviderAccountGroup, entry: ProviderAccountEntry)],
        selectedIds: Binding<Set<String>>
    ) -> some View {
        let grouped = Dictionary(grouping: entries, by: { $0.group.providerId })
        let orderedProviderIds: [String] = {
            var seen = Set<String>()
            return entries.compactMap { pair in
                seen.insert(pair.group.providerId).inserted ? pair.group.providerId : nil
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(orderedProviderIds, id: \.self) { providerId in
                let items = grouped[providerId] ?? []
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        ProviderIconView(providerId, size: 12)
                        Text(items.first?.group.title ?? providerId)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 1)

                    let columns = [GridItem(.adaptive(minimum: 180), spacing: 6)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                        ForEach(items, id: \.entry.id) { pair in
                            let isSelected = selectedIds.wrappedValue.contains(pair.entry.id)
                            Button {
                                var ids = selectedIds.wrappedValue
                                if isSelected { ids.remove(pair.entry.id) } else { ids.insert(pair.entry.id) }
                                selectedIds.wrappedValue = ids
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                                        .font(.system(size: 13))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(pair.entry.accountEmail ?? pair.entry.accountDisplayName ?? pair.entry.providerTitle)
                                            .font(.caption).lineLimit(1)
                                        if let ws = pair.entry.workspaceLabel, ws != "Personal" {
                                            Text(ws)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
