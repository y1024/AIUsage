import SwiftUI

struct SubscriptionGatewayView: View {
    @StateObject private var manager = CLIProxyGatewayManager.shared
    @StateObject private var runtime = CLIProxyRuntimeController.shared
    @State private var pendingVersionDeletion: CLIProxyInstalledVersion?
    @State private var pendingAuthDeletion: CLIProxyAuthFile?
    @State private var draftSettings = CLIProxyGatewaySettings.default
    @State private var distributionTargets: Set<ProxyTarget> = [.codex, .claude, .openCode]

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView {
                runtimeTab.tabItem { Label(L("Runtime", "运行"), systemImage: "power") }
                accountsTab.tabItem { Label(L("Accounts", "账号池"), systemImage: "person.2") }
                distributionTab.tabItem { Label(L("Distribution", "代理分发"), systemImage: "point.3.connected.trianglepath.dotted") }
                updatesTab.tabItem { Label(L("Updates", "更新"), systemImage: "shippingbox.and.arrow.backward") }
                diagnosticsTab.tabItem { Label(L("Diagnostics", "诊断"), systemImage: "stethoscope") }
            }
            .padding(.horizontal, 18)
        }
        .task {
            draftSettings = runtime.settings
            await manager.refresh()
        }
        .alert(
            L("Delete Installed CPA Version?", "删除已安装的 CPA 版本？"),
            isPresented: Binding(
                get: { pendingVersionDeletion != nil },
                set: { if !$0 { pendingVersionDeletion = nil } }
            ),
            presenting: pendingVersionDeletion
        ) { version in
            Button(L("Delete v\(version.version)", "删除 v\(version.version)"), role: .destructive) {
                Task { await manager.delete(version) }
                pendingVersionDeletion = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingVersionDeletion = nil }
        } message: { _ in
            Text(L("Only this rollback copy is removed.", "只会删除这个回退副本。"))
        }
        .alert(
            L("Remove Account from CPA?", "从 CPA 删除账号？"),
            isPresented: Binding(
                get: { pendingAuthDeletion != nil },
                set: { if !$0 { pendingAuthDeletion = nil } }
            ),
            presenting: pendingAuthDeletion
        ) { file in
            Button(L("Remove", "删除"), role: .destructive) {
                Task { await manager.deleteAuthFile(file) }
                pendingAuthDeletion = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingAuthDeletion = nil }
        } message: { _ in
            Text(L(
                "This removes only CPA's copy. The original AIUsage subscription account remains unchanged.",
                "只删除 CPA 中的副本，AIUsage 原订阅账号不会被修改。"
            ))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("CLIProxyAPI Subscription Gateway", "CLIProxyAPI 订阅网关"))
                    .font(.title2.bold())
                Text(L(
                    "Pool subscription accounts once, then distribute one local gateway to every proxy.",
                    "统一汇聚订阅账号，再将本地网关一键分发到各个代理。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            runtimeBadge
        }
        .padding(24)
        .background(.bar)
    }

    private var runtimeBadge: some View {
        Label(runtimeLabel, systemImage: runtime.state.isRunning ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(runtime.state.isRunning ? .green : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }

    private var runtimeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                errorBanner
                GroupBox(L("Service", "服务")) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(runtimeLabel).font(.headline)
                                Text("http://127.0.0.1:\(draftSettings.port)")
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                Task {
                                    if runtime.state.isRunning { await runtime.stop() }
                                    else { await runtime.start() }
                                    if runtime.state.isRunning { await manager.refreshAccounts() }
                                }
                            } label: {
                                Label(
                                    runtime.state.isRunning ? L("Stop CPA", "停止 CPA") : L("Start CPA", "启动 CPA"),
                                    systemImage: runtime.state.isRunning ? "stop.fill" : "play.fill"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(runtime.state.isTransitioning || !manager.isInstalled)
                        }
                        Divider()
                        Toggle(L("Start CPA with AIUsage", "随 AIUsage 自动启动 CPA"), isOn: $draftSettings.autoStart)
                        HStack {
                            Text(L("Loopback port", "本地端口"))
                            Spacer()
                            TextField("14420", value: $draftSettings.port, format: .number)
                                .frame(width: 100)
                                .textFieldStyle(.roundedBorder)
                        }
                        Picker(L("Account routing", "账号路由"), selection: $draftSettings.routingStrategy) {
                            Text(L("Round robin", "轮询")).tag(CLIProxyRoutingStrategy.roundRobin)
                            Text(L("Fill first", "优先用满")).tag(CLIProxyRoutingStrategy.fillFirst)
                        }
                        HStack {
                            Text(L("Request retries", "请求重试"))
                            Spacer()
                            Stepper(value: $draftSettings.requestRetry, in: 0...10) {
                                Text("\(draftSettings.requestRetry)").monospacedDigit()
                            }
                        }
                        TextField(L("Optional upstream proxy URL", "可选的上游代理 URL"), text: $draftSettings.proxyURL)
                            .textFieldStyle(.roundedBorder)
                        Toggle(L("Enable official CPA plugins", "启用 CPA 官方插件"), isOn: $draftSettings.enablePlugins)
                        HStack {
                            Spacer()
                            Button(L("Apply Settings", "应用设置")) {
                                Task { await runtime.applySettings(draftSettings) }
                            }
                            .disabled(runtime.state.isTransitioning)
                        }
                    }
                    .padding(8)
                }
                if !manager.isInstalled {
                    ContentUnavailableView(
                        L("CPA Is Not Installed", "尚未安装 CPA"),
                        systemImage: "square.and.arrow.down",
                        description: Text(L("Install it from the Updates tab first.", "请先到“更新”页安装。"))
                    )
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(20)
        }
    }

    private var accountsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                errorBanner
                GroupBox(L("Add with CPA OAuth", "通过 CPA OAuth 添加")) {
                    HStack {
                        ForEach(CLIProxyOAuthProvider.allCases) { provider in
                            Button(providerTitle(provider)) {
                                Task { await manager.beginOAuth(provider) }
                            }
                            .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                        }
                        Spacer()
                        if manager.isManagingAccounts { ProgressView().controlSize(.small) }
                        Button { Task { await manager.refreshAccounts() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                    }
                    .padding(8)
                }

                GroupBox(L("Sync Existing AIUsage Accounts", "同步现有 AIUsage 账号")) {
                    VStack(spacing: 0) {
                        if manager.syncCandidates.isEmpty {
                            Text(L("No credential-backed subscription accounts were found.", "没有找到带托管凭据的订阅账号。"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 70)
                        }
                        ForEach(manager.syncCandidates) { candidate in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.label)
                                    Text(candidate.providerId).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                switch candidate.compatibility {
                                case .compatible:
                                    Button(L("Sync Copy to CPA", "同步副本到 CPA")) {
                                        Task { await manager.syncAccount(candidate) }
                                    }
                                    .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                                case .unsupported(let reason):
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 9)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 8)
                }

                GroupBox(L("CPA Account Pool", "CPA 账号池")) {
                    VStack(spacing: 0) {
                        if manager.authFiles.isEmpty {
                            Text(runtime.state.isRunning
                                 ? L("No CPA accounts yet.", "CPA 中还没有账号。")
                                 : L("Start CPA to load its account pool.", "启动 CPA 后即可载入账号池。"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(manager.authFiles) { file in
                            HStack(spacing: 12) {
                                Image(systemName: file.disabled ? "pause.circle" : "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(file.disabled ? Color.secondary : Color.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.displayLabel).font(.headline)
                                    Text("\(file.displayProvider) · \(file.name)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { !file.disabled },
                                    set: { enabled in Task { await manager.setAuthFile(file, disabled: !enabled) } }
                                ))
                                .labelsHidden()
                                Button(role: .destructive) { pendingAuthDeletion = file } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 9)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(20)
        }
    }

    private var distributionTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                errorBanner
                GroupBox(L("One Gateway, Multiple Proxies", "一个网关，分发到多个代理")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L(
                            "AIUsage creates or updates one managed API Provider pointing to CPA, then reuses the existing provider distributor. Linked nodes stay synchronized while each proxy keeps its own local overrides.",
                            "AIUsage 会创建或更新一个指向 CPA 的托管 API 提供商，再复用现有分发器；链接节点持续同步，同时保留各代理自己的本地覆盖。"
                        ))
                        .foregroundStyle(.secondary)
                        ForEach(ProxyTarget.allCases) { target in
                            Toggle(target.displayName, isOn: Binding(
                                get: { distributionTargets.contains(target) },
                                set: { enabled in
                                    if enabled { distributionTargets.insert(target) }
                                    else { distributionTargets.remove(target) }
                                }
                            ))
                        }
                        HStack {
                            Text(L("Models reported by CPA: \(manager.availableModels.count)", "CPA 当前模型数：\(manager.availableModels.count)"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Create / Sync and Distribute", "创建/同步并分发")) {
                                Task { await manager.upsertManagedProvider(targets: distributionTargets) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!runtime.state.isRunning || distributionTargets.isEmpty)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(20)
        }
    }

    private var updatesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                errorBanner
                versionCard
                installedVersionsCard
                securityNotice
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(20)
        }
    }

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Recent redacted runtime logs", "最近的脱敏运行日志")).font(.headline)
                Spacer()
                Button { manager.revealStorage() } label: {
                    Label(L("Show Files", "显示文件"), systemImage: "folder")
                }
            }
            ScrollView {
                Text(runtime.recentLogs.isEmpty ? L("No runtime logs.", "暂无运行日志。") : runtime.recentLogs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Text(L(
                "The generated config is permission 0600. Management is loopback-only, the control panel is disabled, and secret values are redacted from this view.",
                "生成的配置权限为 0600；管理接口仅绑定本机、控制面板关闭，密钥也不会显示在这里。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = manager.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if case .failed(let error) = runtime.state {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var versionCard: some View {
        GroupBox(L("Independent CPA Updates", "CPA 独立更新")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(L("Installed", "当前版本")).font(.caption).foregroundStyle(.secondary)
                        Text(manager.currentVersion.map { "v\($0)" } ?? L("Not installed", "尚未安装"))
                            .font(.title3.monospacedDigit().bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(L("Latest official", "最新官方版本")).font(.caption).foregroundStyle(.secondary)
                        Text(manager.latestRelease.map { "v\($0.version)" } ?? "—").font(.headline.monospacedDigit())
                    }
                }
                if manager.operation.isBusy { ProgressView(operationLabel) }
                HStack {
                    Button(L("Check for Updates", "检查更新")) { Task { await manager.checkForUpdates() } }
                    Button(primaryActionTitle) { Task { await manager.installOrUpdateLatest() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.operation.isBusy || (!manager.hasUpdate && manager.isInstalled))
                }
            }
            .padding(8)
        }
    }

    private var installedVersionsCard: some View {
        GroupBox(L("Installed Versions and Rollback", "已安装版本与回退")) {
            VStack(spacing: 0) {
                ForEach(manager.installedVersions) { version in
                    HStack {
                        Image(systemName: version.isCurrent ? "checkmark.seal.fill" : "shippingbox")
                            .foregroundStyle(version.isCurrent ? .green : .secondary)
                        Text("v\(version.version)").font(.headline.monospacedDigit())
                        if version.isCurrent { Text(L("ACTIVE", "当前")).font(.caption2.bold()).foregroundStyle(.green) }
                        Spacer()
                        if !version.isCurrent {
                            Button(L("Activate", "切换")) { Task { await manager.activate(version) } }
                            Button(role: .destructive) { pendingVersionDeletion = version } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var securityNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L(
                "Only the official full macOS asset is accepted. SHA-256, archive paths, code signature, Mach-O architecture and /healthz are verified before activation; the previous version remains available for rollback.",
                "只接受官方完整 macOS 资产；启用前校验 SHA-256、压缩包路径、代码签名、Mach-O 架构和 /healthz，并保留上一版本用于回退。"
            ), systemImage: "checkmark.shield.fill")
            .foregroundStyle(.secondary)
            Link(L("Open Official CLIProxyAPI Repository", "打开 CLIProxyAPI 官方仓库"), destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!)
            Button(L("Open Third-Party Notices", "打开第三方许可声明")) {
                manager.openThirdPartyNotices()
            }
            .buttonStyle(.link)
        }
        .font(.callout)
    }

    private var runtimeLabel: String {
        switch runtime.state {
        case .stopped: L("CPA stopped", "CPA 已停止")
        case .starting: L("CPA starting…", "CPA 启动中…")
        case .running(let pid): L("CPA running · PID \(pid)", "CPA 运行中 · PID \(pid)")
        case .stopping: L("CPA stopping…", "CPA 停止中…")
        case .failed: L("CPA failed", "CPA 运行失败")
        }
    }

    private func providerTitle(_ provider: CLIProxyOAuthProvider) -> String {
        switch provider {
        case .codex: "Codex"
        case .anthropic: "Claude"
        case .antigravity: "Antigravity"
        case .kimi: "Kimi"
        case .xai: "xAI"
        }
    }

    private var primaryActionTitle: String {
        if !manager.isInstalled { return L("Install Latest CPA", "安装最新 CPA") }
        if manager.hasUpdate { return L("Update CPA", "更新 CPA") }
        return L("CPA Is Up to Date", "CPA 已是最新")
    }

    private var operationLabel: String {
        switch manager.operation {
        case .idle: ""
        case .checking: L("Checking official release…", "正在检查官方版本…")
        case .downloading(let version): L("Downloading v\(version)…", "正在下载 v\(version)…")
        case .verifying(let version): L("Verifying v\(version)…", "正在校验 v\(version)…")
        case .installing(let version): L("Installing v\(version)…", "正在安装 v\(version)…")
        case .activating(let version): L("Activating v\(version)…", "正在切换到 v\(version)…")
        }
    }
}
