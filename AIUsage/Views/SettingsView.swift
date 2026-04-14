import SwiftUI
import Sparkle
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sparkle: SparkleController
    @State private var hideDockIcon = UserDefaults.standard.bool(forKey: "hideDockIcon")
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    @State private var showNotifications = UserDefaults.standard.bool(forKey: "showNotifications")
    @State private var lowQuotaThreshold: Double = UserDefaults.standard.double(forKey: "lowQuotaThreshold")
    @State private var remoteHostInput: String = ""
    @State private var remotePortInput: String = ""
    @State private var isTestingRemoteConnection = false
    @State private var remoteConnectionState: RemoteConnectionState = .idle
    @State private var remoteConnectionMessage: String?
    @AppStorage("proxyLogRetentionDays") private var proxyLogRetentionDays: Int = 30

    init() {
        if _lowQuotaThreshold.wrappedValue == 0 {
            _lowQuotaThreshold = State(initialValue: 20.0)
        }
    }
    
    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var repositoryURL: URL? {
        if let raw = Bundle.main.infoDictionary?["ProjectRepositoryURL"] as? String,
           let url = URL(string: raw) {
            return url
        }

        guard let owner = gitHubOwner, let repository = gitHubRepository else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repository)")
    }

    private var gitHubOwner: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubOwner"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private var gitHubRepository: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubRepository"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private enum RemoteConnectionState {
        case idle
        case success
        case failure
    }

    
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsHero
                    settingsSections(for: proxy.size.width)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(settingsBackground.ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            remoteHostInput = settings.remoteHost
            remotePortInput = "\(settings.remotePort)"
        }
        .onChange(of: hideDockIcon) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "hideDockIcon")
            updateDockIconVisibility(hidden: newValue)
        }
        .onChange(of: launchAtLogin) { _, newValue in
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        }
        .onChange(of: showNotifications) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "showNotifications")
        }
        .onChange(of: lowQuotaThreshold) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "lowQuotaThreshold")
        }
        .onChange(of: settings.autoRefreshInterval) { _, _ in
            settings.saveSettings()
            appState.setupAutoRefresh()
        }
        .onChange(of: settings.claudeCodeRefreshInterval) { _, _ in
            settings.saveSettings()
            appState.setupClaudeCodeAutoRefresh()
        }
        .onChange(of: settings.isDarkMode) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.themeMode) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.quotaIndicatorStyle) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.quotaIndicatorMetric) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.language) { _, _ in
            settings.saveSettings()
            appState.refreshAllProviders()
        }
    }

    @ViewBuilder
    private func settingsSections(for availableWidth: CGFloat) -> some View {
        if availableWidth >= 1100 {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    backendCard
                    appearanceCard
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 20) {
                    generalCard
                    notificationsCard
                    aboutCard
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 20) {
                backendCard
                generalCard
                appearanceCard
                notificationsCard
                aboutCard
            }
        }
    }

    private var settingsBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.accentColor.opacity(0.06),
                Color(nsColor: .windowBackgroundColor)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var settingsHero: some View {
        VStack(spacing: 16) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 6)
            } else {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 88, height: 88)
            }

            Text("AIUsage")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text(t("Your AI Quota Command Center", "您的 AI 额度指挥中心"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Label(t("Version", "版本") + " " + appVersion, systemImage: "tag")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            HStack(spacing: 10) {
                heroPill(
                    title: t("Backend", "后端"),
                    value: settings.backendMode == "remote" ? t("Remote", "远程") : t("Local", "本地"),
                    tint: .blue
                )
                heroPill(
                    title: t("Auto Refresh", "自动刷新"),
                    value: autoRefreshTitle(for: settings.autoRefreshInterval),
                    tint: .teal
                )
                heroPill(
                    title: t("Theme", "主题"),
                    value: {
                        switch settings.themeMode {
                        case "light": return t("Light", "浅色")
                        case "dark": return t("Dark", "深色")
                        default: return t("System", "系统")
                        }
                    }(),
                    tint: .orange
                )
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var backendCard: some View {
        settingsCard(
            title: t("Backend", "后端"),
            subtitle: t("Choose whether AIUsage reads data locally or from a remote QuotaServer.", "选择 AIUsage 从本地还是远程 QuotaServer 读取数据。")
        ) {
            settingsBlock(title: t("Mode", "模式")) {
                Picker("", selection: $settings.backendMode) {
                    Text(t("Local", "本地")).tag("local")
                    Text(t("Remote", "远程")).tag("remote")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.backendMode) { _, _ in
                    settings.saveSettings()
                    appState.refreshAllProviders()
                }
            }

            if settings.backendMode == "remote" {
                Divider()

                settingsBlock(title: t("Host", "地址")) {
                    TextField("127.0.0.1", text: $remoteHostInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyRemoteSettings() }
                }

                Divider()

                settingsBlock(title: t("Port", "端口")) {
                    TextField("4318", text: $remotePortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120, alignment: .leading)
                        .onSubmit { applyRemoteSettings() }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button(t("Apply", "应用")) { applyRemoteSettings() }
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
                                Text(t("Test Connection", "测试连接"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTestingRemoteConnection)
                    }

                    remoteConnectionStatusView

                    Text(
                        t(
                            "Connect to a QuotaServer running on another machine. Start server: swift run QuotaServer --host 0.0.0.0 --port 4318",
                            "连接到其他机器上的 QuotaServer。启动命令：swift run QuotaServer --host 0.0.0.0 --port 4318"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var generalCard: some View {
        settingsCard(
            title: t("General", "通用"),
            subtitle: t("Control refresh cadence and language.", "控制刷新频率和界面语言。")
        ) {
            settingsBlock(
                title: t("Providers auto-refresh", "服务商自动刷新"),
                subtitle: t("Refresh interval for API-based providers (OpenAI, Anthropic, etc.)", "API 服务商的刷新间隔（OpenAI、Anthropic 等）")
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
                title: t("Claude Code auto-refresh", "Claude Code 自动刷新"),
                subtitle: t("Refresh interval for local Claude Code stats (faster intervals available)", "本地 Claude Code 统计的刷新间隔（支持更短间隔）")
            ) {
                Picker("", selection: $settings.claudeCodeRefreshInterval) {
                    ForEach(AppSettings.supportedClaudeCodeRefreshIntervals, id: \.self) { interval in
                        Text(claudeCodeRefreshTitle(for: interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: t("Claude Code daily cost alert", "Claude Code 每日消费提醒"),
                subtitle: t("Get notified when daily spending exceeds threshold (0 = off)", "当每日消费超过阈值时通知（0 = 关闭）")
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
                    Text(t("USD", "美元"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Divider()

            settingsBlock(
                title: t("Display Currency", "显示货币"),
                subtitle: t("Currency for cost display across the app.", "应用中费用显示的货币单位。")
            ) {
                Picker("", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "displayCurrency") ?? "USD" },
                    set: { UserDefaults.standard.set($0, forKey: "displayCurrency") }
                )) {
                    Text("USD ($)").tag("USD")
                    Text("CNY (¥)").tag("CNY")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: t("Proxy Log Retention", "代理日志保留"),
                subtitle: t("Automatically delete proxy request logs older than the specified number of days.", "自动删除超过指定天数的代理请求日志。")
            ) {
                Picker("", selection: $proxyLogRetentionDays) {
                    Text(t("7 days", "7 天")).tag(7)
                    Text(t("14 days", "14 天")).tag(14)
                    Text(t("30 days", "30 天")).tag(30)
                    Text(t("90 days", "90 天")).tag(90)
                    Text(t("180 days", "180 天")).tag(180)
                    Text(t("365 days", "365 天")).tag(365)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }

            Divider()

            settingsBlock(
                title: t("Theme", "主题"),
                subtitle: t("Choose app appearance: follow system, light, or dark.", "选择外观模式：跟随系统、浅色或深色。")
            ) {
                Picker("", selection: $settings.themeMode) {
                    Text(t("System", "系统")).tag("system")
                    Text(t("Light", "浅色")).tag("light")
                    Text(t("Dark", "深色")).tag("dark")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280, alignment: .leading)
            }

            Divider()

            settingsBlock(title: t("Language", "语言")) {
                Picker("", selection: $settings.language) {
                    Text("English").tag("en")
                    Text("中文").tag("zh")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    private var appearanceCard: some View {
        settingsCard(
            title: t("Appearance", "外观"),
            subtitle: t("Adjust how quota cards present information.", "调整额度卡片的呈现方式。")
        ) {
            settingsToggleRow(
                title: t("Hide Dock Icon", "隐藏 Dock 图标"),
                subtitle: t("Keep AIUsage in the menu bar only.", "让 AIUsage 只出现在菜单栏。"),
                isOn: $hideDockIcon
            )
            .help(t("The app will only appear in the menu bar", "应用将只显示在菜单栏"))

            Divider()

            settingsToggleRow(
                title: t("Launch at Login", "开机启动"),
                subtitle: t("Open AIUsage automatically after login.", "登录系统后自动打开 AIUsage。"),
                isOn: $launchAtLogin
            )

            Divider()

            settingsBlock(title: t("Quota card style", "额度卡片样式")) {
                Picker("", selection: $settings.quotaIndicatorStyle) {
                    ForEach(CardQuotaIndicatorStyle.allCases, id: \.self) { style in
                        Text(quotaStyleTitle(style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340, alignment: .leading)
            }

            Divider()

            settingsBlock(title: t("Progress meaning", "进度语义")) {
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
                Text(t("Preview", "预览"))
                    .font(.subheadline.weight(.semibold))

                quotaIndicatorPreview

                Text(t("Applies instantly to all provider cards.", "会立即应用到所有服务卡片。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsCard: some View {
        settingsCard(
            title: t("Notifications", "通知"),
            subtitle: t("Decide when AIUsage should proactively nudge you.", "设置 AIUsage 在什么情况下主动提醒你。")
        ) {
            settingsToggleRow(
                title: t("Enable Notifications", "启用通知"),
                subtitle: t("Show desktop alerts for low quota and other status changes.", "为低额度和状态变化显示桌面提醒。"),
                isOn: $showNotifications
            )

            Divider()

            settingsBlock(
                title: t("Low Quota Alert", "低额度提醒"),
                subtitle: t("Trigger when remaining quota drops below the selected threshold.", "当剩余额度低于阈值时触发提醒。")
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
        }
    }

    private var aboutCard: some View {
        settingsCard(
            title: t("About", "关于"),
            subtitle: t("Version information and update checks.", "版本信息与更新检查。")
        ) {
            settingsValueRow(title: t("Version", "版本"), value: appVersion)

            Divider()

            settingsToggleRow(
                title: t("Automatic Updates", "自动检查更新"),
                subtitle: t("Periodically check for new versions in the background.", "后台定期检查是否有新版本。"),
                isOn: Binding(
                    get: { sparkle.updaterController.updater.automaticallyChecksForUpdates },
                    set: { sparkle.updaterController.updater.automaticallyChecksForUpdates = $0 }
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
                        Text(t("Check for Updates", "检查更新"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!sparkle.canCheckForUpdates)
            }
        }
    }

    private func heroPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func settingsBlock<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private func quotaStyleTitle(_ style: CardQuotaIndicatorStyle) -> String {
        switch style {
        case .bar:
            return t("Bar", "条形")
        case .ring:
            return t("Ring", "圆环")
        case .segments:
            return t("Segments", "分段")
        }
    }

    private func autoRefreshTitle(for interval: Int) -> String {
        switch interval {
        case 0:
            return t("Off", "关闭")
        case 30:
            return t("30 seconds", "30 秒")
        case 60:
            return t("1 minute", "1 分钟")
        case 180:
            return t("3 minutes", "3 分钟")
        case 300:
            return t("5 minutes", "5 分钟")
        case 600:
            return t("10 minutes", "10 分钟")
        case 900:
            return t("15 minutes", "15 分钟")
        case 1800:
            return t("30 minutes", "30 分钟")
        case 3600:
            return t("1 hour", "1 小时")
        default:
            return interval >= 60
                ? t("\(interval / 60) minutes", "\(interval / 60) 分钟")
                : t("\(interval) seconds", "\(interval) 秒")
        }
    }

    private func claudeCodeRefreshTitle(for interval: Int) -> String {
        switch interval {
        case 0:
            return t("Off", "关闭")
        case 10:
            return t("10 seconds", "10 秒")
        case 30:
            return t("30 seconds", "30 秒")
        case 60:
            return t("1 minute", "1 分钟")
        case 180:
            return t("3 minutes", "3 分钟")
        case 300:
            return t("5 minutes", "5 分钟")
        case 600:
            return t("10 minutes", "10 分钟")
        default:
            return interval >= 60
                ? t("\(interval / 60) minutes", "\(interval / 60) 分钟")
                : t("\(interval) seconds", "\(interval) 秒")
        }
    }

    private func quotaMetricTitle(_ metric: CardQuotaIndicatorMetric) -> String {
        switch metric {
        case .remaining:
            return t("Remaining", "剩余")
        case .used:
            return t("Used", "已用")
        }
    }

    private var previewRemainingPercent: Double {
        68
    }

    private var previewDisplayPercent: Double {
        settings.quotaIndicatorMetric == .remaining ? previewRemainingPercent : 100 - previewRemainingPercent
    }

    private var previewValueText: String {
        let rounded = (previewDisplayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var quotaIndicatorPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Cursor")
                            .font(.headline)
                            .bold()

                        Text("Pro")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(t("Sample Card", "示例卡片"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(previewValueText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text(
                        settings.quotaIndicatorMetric == .remaining
                        ? t("Healthy reserve for the current cycle", "当前周期余量依然充足")
                        : t("Usage is visible without feeling alarming", "使用趋势清晰，但还不紧张")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                QuotaIndicatorView(remainingPercent: previewRemainingPercent, accentColor: .blue)
                    .frame(width: settings.quotaIndicatorStyle == .ring ? 120 : 220)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
    
    private var remoteConnectionStatusView: some View {
        let icon: String
        let tint: Color
        let title: String
        switch remoteConnectionState {
        case .idle:
            icon = "network"; tint = .secondary; title = t("Connection not tested", "\u{5C1A}\u{672A}\u{6D4B}\u{8BD5}\u{8FDE}\u{63A5}")
        case .success:
            icon = "checkmark.circle.fill"; tint = .green; title = t("Remote server reachable", "\u{8FDC}\u{7A0B}\u{670D}\u{52A1}\u{53EF}\u{8FDE}\u{63A5}")
        case .failure:
            icon = "xmark.octagon.fill"; tint = .red; title = t("Connection failed", "\u{8FDE}\u{63A5}\u{5931}\u{8D25}")
        }

        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(remoteConnectionMessage?.nilIfBlank ?? title)
                .font(.caption)
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func applyRemoteSettings(refreshDashboard: Bool = true) {
        let host = remoteHostInput.trimmingCharacters(in: .whitespaces)
        let port = Int(remotePortInput.trimmingCharacters(in: .whitespaces)) ?? 4318
        settings.remoteHost = host.isEmpty ? "127.0.0.1" : host
        settings.remotePort = port
        settings.saveSettings()
        remoteConnectionState = .idle
        remoteConnectionMessage = nil
        if refreshDashboard {
            appState.refreshAllProviders()
        }
    }

    @MainActor
    private func testRemoteConnection() async {
        applyRemoteSettings(refreshDashboard: false)
        isTestingRemoteConnection = true
        defer { isTestingRemoteConnection = false }

        APIService.shared.updateBaseURL("http://\(settings.remoteHost):\(settings.remotePort)")
        let startedAt = Date()

        do {
            let response = try await APIService.shared.checkHealth()
            let latencyMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
            remoteConnectionState = response.ok ? .success : .failure
            remoteConnectionMessage = t(
                "Responded in \(latencyMs) ms · \(response.generatedAt)",
                "响应耗时 \(latencyMs) ms · \(response.generatedAt)"
            )
        } catch {
            remoteConnectionState = .failure
            remoteConnectionMessage = error.localizedDescription
        }
    }

    private func updateDockIconVisibility(hidden: Bool) {
        if hidden {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
        .environmentObject(AppSettings.shared)
}
