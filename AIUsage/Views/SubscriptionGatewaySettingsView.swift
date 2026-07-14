import SwiftUI

// MARK: - CPA Settings Categories

private enum GatewaySettingsCategory: String, CaseIterable, Identifiable {
    case runtime
    case updates
    case versions
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtime: return L("Runtime", "运行")
        case .updates: return L("Updates", "更新")
        case .versions: return L("Versions", "版本")
        case .diagnostics: return L("Diagnostics", "诊断")
        }
    }

    var icon: String {
        switch self {
        case .runtime: return "gearshape"
        case .updates: return "arrow.down.circle"
        case .versions: return "shippingbox"
        case .diagnostics: return "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .runtime: return .gray
        case .updates: return .blue
        case .versions: return .orange
        case .diagnostics: return .teal
        }
    }
}

// MARK: - Settings View

struct SubscriptionGatewaySettingsView: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var draftSettings: CLIProxyGatewaySettings
    @Binding var pendingVersionDeletion: CLIProxyInstalledVersion?

    @State private var selectedCategory: GatewaySettingsCategory = .runtime
    @State private var showLANConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsDetail
        }
        .alert(L("Enable Local Network Access?", "开启局域网访问？"), isPresented: $showLANConfirmation) {
            Button(L("Enable and Apply", "开启并应用"), role: .destructive) {
                applySettings()
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                draftSettings.allowLANAccess = runtime.settings.allowLANAccess
            }
        } message: {
            Text(L(
                "CPA will listen on all IPv4 interfaces over HTTP. Keep keys private; use only on trusted networks.",
                "CPA 将通过 HTTP 监听所有 IPv4 接口。请妥善保管密钥，仅在可信网络中开启。"
            ))
        }
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(GatewaySettingsCategory.allCases) { category in
                    categoryRow(category)
                }
            }
            .padding(10)
        }
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    private func categoryRow(_ category: GatewaySettingsCategory) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selectedCategory == category ? .white : category.color)
                    .frame(width: 20)
                Text(category.title)
                    .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                    .foregroundStyle(selectedCategory == category ? .white : .primary)
                Spacer(minLength: 0)
                if category == .runtime, hasUnappliedChanges {
                    Circle()
                        .fill(selectedCategory == category ? Color.white.opacity(0.9) : Color.orange)
                        .frame(width: 6, height: 6)
                } else if category == .updates, manager.hasUpdate {
                    Circle()
                        .fill(selectedCategory == category ? Color.white.opacity(0.9) : Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedCategory == category ? Color.accentColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                errorBanners
                switch selectedCategory {
                case .runtime:
                    runtimeSection
                case .updates:
                    updatesSection
                case .versions:
                    versionsSection
                case .diagnostics:
                    diagnosticsSection
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError { GatewayErrorBanner(message: error) }
        if case .failed(let error) = runtime.state { GatewayErrorBanner(message: error) }
    }

    // MARK: - Runtime

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Runtime", "运行")) {
                if hasUnappliedChanges {
                    GatewayQuietBadge(text: L("Not applied", "未应用"), tint: .orange)
                }
            }

            GatewayCard(padding: 14) {
                VStack(spacing: 0) {
                    settingsRow(
                        title: L("Start with AIUsage", "随 AIUsage 启动"),
                        detail: L("Launch verified CPA after app start.", "应用启动后自动运行已校验的 CPA。")
                    ) {
                        Toggle("", isOn: $draftSettings.autoStart)
                            .labelsHidden()
                            .accessibilityLabel(L("Start with AIUsage", "随 AIUsage 启动"))
                    }

                    Divider().padding(.vertical, 10)

                    settingsRow(
                        title: L("Service port", "服务端口"),
                        detail: L("Default 127.0.0.1; all interfaces when LAN is on.", "默认本机；开启局域网后监听所有接口。")
                    ) {
                        TextField(
                            "14420",
                            value: $draftSettings.port,
                            format: IntegerFormatStyle<Int>.number.grouping(.never)
                        )
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .accessibilityLabel(L("Service port", "服务端口"))
                    }

                    Divider().padding(.vertical, 10)

                    settingsRow(
                        title: L("LAN access", "局域网访问"),
                        detail: L("Expose inference APIs on the local network.", "向同一网络开放推理 API。")
                    ) {
                        Toggle("", isOn: $draftSettings.allowLANAccess)
                            .labelsHidden()
                            .accessibilityLabel(L("LAN access", "局域网访问"))
                    }

                    if draftSettings.allowLANAccess {
                        lanAddressesBlock
                            .padding(.top, 10)
                    }

                    Divider().padding(.vertical, 10)

                    settingsRow(
                        title: L("Account routing", "账号路由"),
                        detail: L("How CPA picks among ready accounts.", "在可用账号间的选择方式。")
                    ) {
                        Picker("", selection: $draftSettings.routingStrategy) {
                            Text(L("Round robin", "轮询")).tag(CLIProxyRoutingStrategy.roundRobin)
                            Text(L("Fill first", "优先用满")).tag(CLIProxyRoutingStrategy.fillFirst)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    Divider().padding(.vertical, 10)

                    settingsRow(
                        title: L("Request retries", "请求重试"),
                        detail: L("Retry on other accounts after failure.", "失败后在其它账号上重试。")
                    ) {
                        Stepper(value: $draftSettings.requestRetry, in: 0...10) {
                            Text("\(draftSettings.requestRetry)")
                                .monospacedDigit()
                                .frame(minWidth: 18, alignment: .trailing)
                        }
                    }

                    Divider().padding(.vertical, 10)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("Network proxy URL", "网络代理 URL"))
                            .font(.subheadline.weight(.semibold))
                        TextField("http://127.0.0.1:7890", text: $draftSettings.proxyURL)
                            .textFieldStyle(.roundedBorder)
                        Text(L(
                            "HTTP/SOCKS for CPA upstream calls. Empty = direct. Not an AIUsage proxy node.",
                            "CPA 访问上游时使用的 HTTP/SOCKS；留空直连。不是 AIUsage 代理节点。"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().padding(.vertical, 10)

                    settingsRow(
                        title: L("Official plugins", "官方插件"),
                        detail: L("Allow installed CPA provider plugins.", "允许已安装的 CPA 提供商插件。")
                    ) {
                        Toggle("", isOn: $draftSettings.enablePlugins)
                            .labelsHidden()
                            .accessibilityLabel(L("Official plugins", "官方插件"))
                    }
                }
            }

            HStack {
                if hasUnappliedChanges {
                    Button(L("Reset", "还原")) { draftSettings = runtime.settings }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button {
                    requestApplySettings()
                } label: {
                    Label(L("Apply", "应用"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnappliedChanges || runtime.state.isTransitioning)
            }
        }
    }

    private var lanAddressesBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Trusted networks only", "仅可信网络"))
                    .font(.caption.weight(.semibold))
                let addresses = runtime.detectedLANBaseURLs(port: draftSettings.normalized.port)
                if addresses.isEmpty {
                    Text(L("No private IPv4 detected.", "未检测到私有 IPv4。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(addresses, id: \.absoluteString) { address in
                        Text(address.absoluteString)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Updates", "更新")) {
                updateStatusPill
            }

            GatewayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        versionChip(
                            title: L("Installed", "已装"),
                            value: manager.currentVersion.map { "v\($0)" } ?? "—"
                        )
                        versionChip(
                            title: L("Latest", "最新"),
                            value: manager.latestRelease.map { "v\($0.version)" } ?? "—"
                        )
                    }

                    if manager.operation.isBusy {
                        ProgressView(operationLabel)
                    }

                    HStack {
                        if let checkedAt = manager.lastCheckedAt {
                            Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Check", "检查")) {
                            Task { await manager.checkForUpdates() }
                        }
                        .disabled(manager.operation.isBusy)
                        Button(primaryUpdateActionTitle) {
                            Task { await manager.installOrUpdateLatest() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            manager.operation.isBusy
                                || (manager.latestRelease != nil && !manager.hasUpdate && manager.isInstalled)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusPill: some View {
        if manager.hasUpdate {
            GatewayQuietBadge(text: L("Update available", "有更新"), tint: .orange)
        } else if manager.isInstalled, manager.latestRelease != nil {
            GatewayQuietBadge(text: L("Up to date", "已最新"), tint: .green)
        } else if manager.isInstalled {
            GatewayQuietBadge(text: L("Not checked", "未检查"), tint: .secondary)
        }
    }

    // MARK: - Versions

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Versions & rollback", "版本与回退"))

            GatewayCard(padding: 4) {
                if manager.installedVersions.isEmpty {
                    Text(L("No CPA versions installed.", "尚未安装 CPA。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    VStack(spacing: 0) {
                        ForEach(manager.installedVersions) { version in
                            HStack(spacing: 10) {
                                Image(systemName: version.isCurrent ? "checkmark.seal.fill" : "shippingbox")
                                    .foregroundStyle(version.isCurrent ? .green : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("v\(version.version)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                    Text(version.installedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if version.isCurrent {
                                    GatewayQuietBadge(text: L("Active", "当前"), tint: .green)
                                }
                                Spacer(minLength: 8)
                                if !version.isCurrent {
                                    Button(L("Activate", "切换")) {
                                        Task { await manager.activate(version) }
                                    }
                                    Button(role: .destructive) {
                                        pendingVersionDeletion = version
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L("Delete", "删除"))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            if version.id != manager.installedVersions.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Diagnostics", "诊断"))

            GatewayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        Text(runtime.recentLogs.isEmpty
                             ? L("No logs yet.", "暂无日志。")
                             : runtime.recentLogs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxHeight: 280)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                    HStack {
                        Button {
                            manager.revealStorage()
                        } label: {
                            Label(L("Managed files", "托管文件"), systemImage: "folder")
                        }
                        Spacer()
                        Link(
                            L("Repository", "仓库"),
                            destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
                        )
                        .font(.caption)
                        Button(L("Notices", "许可")) {
                            manager.openThirdPartyNotices()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Shared chrome

    private func sectionHeader<Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            trailing()
        }
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func versionChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var hasUnappliedChanges: Bool {
        draftSettings.normalized != runtime.settings.normalized
    }

    private func requestApplySettings() {
        if draftSettings.allowLANAccess, !runtime.settings.allowLANAccess {
            showLANConfirmation = true
        } else {
            applySettings()
        }
    }

    private func applySettings() {
        Task {
            await runtime.applySettings(draftSettings)
            draftSettings = runtime.settings
            if runtime.state.isRunning { await manager.refreshAccounts() }
        }
    }

    private var primaryUpdateActionTitle: String {
        if !manager.isInstalled { return L("Install", "安装") }
        if manager.latestRelease == nil { return L("Check & Update", "检查并更新") }
        if manager.hasUpdate { return L("Update", "更新") }
        return L("Up to date", "已最新")
    }

    private var operationLabel: String {
        switch manager.operation {
        case .idle: ""
        case .checking: L("Checking…", "检查中…")
        case .downloading(let version): L("Downloading v\(version)…", "下载 v\(version)…")
        case .verifying(let version): L("Verifying v\(version)…", "校验 v\(version)…")
        case .installing(let version): L("Installing v\(version)…", "安装 v\(version)…")
        case .activating(let version): L("Activating v\(version)…", "切换到 v\(version)…")
        }
    }
}
