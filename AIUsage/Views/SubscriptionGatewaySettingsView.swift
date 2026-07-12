import SwiftUI

struct SubscriptionGatewaySettingsView: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var draftSettings: CLIProxyGatewaySettings
    @Binding var pendingVersionDeletion: CLIProxyInstalledVersion?

    @State private var showAdvanced = false
    @State private var showLogs = false
    @State private var showLANConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                errorBanners
                GatewaySectionTitle(
                    title: L("Settings & maintenance", "设置与维护"),
                    subtitle: L(
                        "Runtime, updates, rollback, and diagnostics.",
                        "运行、更新、回退与诊断。"
                    )
                )
                runtimeSettingsCard
                updateCard
                if manager.installedVersions.contains(where: { !$0.isCurrent }) {
                    installedVersionsCard
                }
                diagnosticsCard
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 24)
                .padding(.vertical, 22)
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
                "CPA will listen on every IPv4 interface over unencrypted HTTP. Inference APIs still require the client key; management keeps a separate high-entropy key and the remote-access policy remains off. Only enable this on a trusted network; macOS may ask for firewall permission.",
                "CPA 将通过未加密 HTTP 监听所有 IPv4 接口。推理 API 仍必须使用客户端密钥；管理接口继续使用独立高强度密钥，并保持关闭远程访问策略。请只在可信网络中开启；macOS 可能会请求防火墙权限。"
            ))
        }
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError { GatewayErrorBanner(message: error) }
        if case .failed(let error) = runtime.state { GatewayErrorBanner(message: error) }
    }

    private var runtimeSettingsCard: some View {
        GatewayCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Runtime", "运行设置")).font(.headline)
                        Text(L(
                            "Basic settings are visible by default. Changes restart CPA only when it is already running.",
                            "默认只显示常用设置；CPA 正在运行时，应用修改会自动重启服务。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasUnappliedChanges {
                        GatewayStatusPill(
                            text: L("Not applied", "尚未应用"),
                            color: .orange,
                            systemImage: "circle.fill"
                        )
                    }
                }

                settingToggle(
                    title: L("Start CPA with AIUsage", "随 AIUsage 自动启动 CPA"),
                    detail: L("Starts the verified managed runtime after AIUsage launches.", "AIUsage 启动后自动运行已校验的托管版本。"),
                    isOn: $draftSettings.autoStart
                )

                Divider()

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Service port", "服务端口")).font(.subheadline.weight(.semibold))
                        Text(L("Uses 127.0.0.1 unless LAN access is enabled.", "默认绑定 127.0.0.1；开启局域网访问后监听所有接口。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField(
                        "14420",
                        value: $draftSettings.port,
                        format: IntegerFormatStyle<Int>.number.grouping(.never)
                    )
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .accessibilityLabel(L("Service port", "服务端口"))
                }

                Divider()

                settingToggle(
                    title: L("Allow local network clients", "允许局域网客户端访问"),
                    detail: L(
                        "Expose inference APIs over HTTP. Client and management keys stay separate; the remote-management policy remains off.",
                        "通过 HTTP 向同一网络开放推理 API；客户端与管理密钥保持分离，远程管理策略仍关闭。"
                    ),
                    isOn: $draftSettings.allowLANAccess
                )

                if draftSettings.allowLANAccess {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Trusted networks only", "仅在可信网络中使用"))
                                .font(.caption.weight(.semibold))
                            let addresses = runtime.detectedLANBaseURLs(port: draftSettings.normalized.port)
                            if !addresses.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(addresses, id: \.absoluteString) { address in
                                        Text(address.absoluteString)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                            } else {
                                Text(L("No active private or shared IPv4 address detected.", "当前未检测到可用的私有或共享 IPv4 地址。"))
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 11))
                }

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Account routing", "账号路由")).font(.subheadline.weight(.semibold))
                        Text(L("How CPA chooses among ready accounts.", "CPA 如何在可用账号之间进行选择。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $draftSettings.routingStrategy) {
                        Text(L("Round robin", "轮询")).tag(CLIProxyRoutingStrategy.roundRobin)
                        Text(L("Fill first", "优先用满")).tag(CLIProxyRoutingStrategy.fillFirst)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Request retries", "请求重试")).font(.subheadline.weight(.semibold))
                                Text(L("Retries across eligible accounts after a request failure.", "请求失败后在可用账号间重试。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Stepper(value: $draftSettings.requestRetry, in: 0...10) {
                                Text("\(draftSettings.requestRetry)").monospacedDigit()
                            }
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text(L("Upstream proxy URL", "上游代理 URL")).font(.subheadline.weight(.semibold))
                            TextField("http://127.0.0.1:7890", text: $draftSettings.proxyURL)
                                .textFieldStyle(.roundedBorder)
                            Text(L("Optional. Leave empty for a direct connection.", "可选；留空表示直接连接。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        settingToggle(
                            title: L("Enable CPA official plugins", "启用 CPA 官方插件"),
                            detail: L(
                                "Allows installed provider plugins. Plugin availability is controlled separately by CPA.",
                                "允许已安装的提供商插件；具体插件是否可用仍由 CPA 单独控制。"
                            ),
                            isOn: $draftSettings.enablePlugins
                        )
                    }
                    .padding(.top, 14)
                } label: {
                    Label(L("Advanced runtime settings", "高级运行设置"), systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
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
                        Label(L("Apply Settings", "应用设置"), systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnappliedChanges || runtime.state.isTransitioning)
                }
            }
        }
    }

    private var updateCard: some View {
        GatewayCard {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Independent CPA updates", "CPA 独立更新")).font(.headline)
                        Text(L(
                            "CPA can update inside AIUsage without waiting for a new AIUsage release.",
                            "CPA 可直接在 AIUsage 内更新，无需等待 AIUsage 发布新版本。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manager.hasUpdate {
                        GatewayStatusPill(
                            text: L("Update available", "有可用更新"),
                            color: .orange,
                            systemImage: "arrow.down.circle.fill"
                        )
                    } else if manager.isInstalled, manager.latestRelease != nil {
                        GatewayStatusPill(
                            text: L("Up to date", "已是最新"),
                            color: .green,
                            systemImage: "checkmark.circle.fill"
                        )
                    } else if manager.isInstalled {
                        GatewayStatusPill(
                            text: L("Not checked", "尚未检查"),
                            color: .secondary,
                            systemImage: "clock"
                        )
                    }
                }

                HStack(spacing: 12) {
                    versionValue(title: L("Installed", "当前版本"), value: manager.currentVersion.map { "v\($0)" } ?? L("Not installed", "尚未安装"))
                    versionValue(title: L("Latest official", "最新官方版本"), value: manager.latestRelease.map { "v\($0.version)" } ?? "—")
                }

                if manager.operation.isBusy {
                    ProgressView(operationLabel)
                }

                HStack {
                    if let checkedAt = manager.lastCheckedAt {
                        Text(L("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))",
                               "检查于 \(checkedAt.formatted(date: .abbreviated, time: .shortened))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Check", "检查更新")) { Task { await manager.checkForUpdates() } }
                        .disabled(manager.operation.isBusy)
                    Button(primaryUpdateActionTitle) { Task { await manager.installOrUpdateLatest() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            manager.operation.isBusy ||
                            (manager.latestRelease != nil && !manager.hasUpdate && manager.isInstalled)
                        )
                }
            }
        }
    }

    private var installedVersionsCard: some View {
        GatewayCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Installed versions & rollback", "已安装版本与回退")).font(.headline)
                    Text(L(
                        "Activating a rollback copy safely stops and restarts the managed runtime.",
                        "切换回退版本时会安全停止并重新启动托管运行时。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if manager.installedVersions.isEmpty {
                    Text(L("No CPA versions are installed yet.", "尚未安装任何 CPA 版本。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    VStack(spacing: 0) {
                        ForEach(manager.installedVersions) { version in
                            HStack(spacing: 11) {
                                Image(systemName: version.isCurrent ? "checkmark.seal.fill" : "shippingbox")
                                    .foregroundStyle(version.isCurrent ? .green : .secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("v\(version.version)").font(.subheadline.weight(.semibold).monospacedDigit())
                                    Text(version.installedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if version.isCurrent {
                                    GatewayStatusPill(text: L("Active", "当前"), color: .green, systemImage: nil)
                                }
                                Spacer()
                                if !version.isCurrent {
                                    Button(L("Activate", "切换")) { Task { await manager.activate(version) } }
                                    Button(role: .destructive) { pendingVersionDeletion = version } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L("Delete rollback copy", "删除回退副本"))
                                    .accessibilityLabel(L("Delete CPA version \(version.version)", "删除 CPA 版本 \(version.version)"))
                                }
                            }
                            .padding(.vertical, 10)
                            if version.id != manager.installedVersions.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        GatewayCard {
            DisclosureGroup(isExpanded: $showLogs) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        Text(runtime.recentLogs.isEmpty
                             ? L("No runtime logs yet.", "暂无运行日志。")
                             : runtime.recentLogs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                            .padding(12)
                    }
                    .frame(maxHeight: 260)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Text(L("Secret values are redacted before display.", "密钥会在显示前完成脱敏。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { manager.revealStorage() } label: {
                            Label(L("Show Managed Files", "显示托管文件"), systemImage: "folder")
                        }
                    }
                    HStack(spacing: 14) {
                        Link(L("Official repository", "官方仓库"),
                             destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!)
                        Button(L("Third-party notices", "第三方许可")) { manager.openThirdPartyNotices() }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                }
                .padding(.top, 14)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Diagnostics", "诊断")).font(.headline)
                    Text(L("Recent redacted runtime logs and managed storage.", "最近的脱敏运行日志与托管存储。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func settingToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    private func versionValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold).monospacedDigit())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var hasUnappliedChanges: Bool { draftSettings.normalized != runtime.settings.normalized }

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
        if !manager.isInstalled { return L("Install Latest CPA", "安装最新 CPA") }
        if manager.latestRelease == nil { return L("Check & Update", "检查并更新") }
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
