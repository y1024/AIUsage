import SwiftUI

// MARK: - Claude Science Proxy Management View
// 「Claude Science 代理」主视图，与 Codex/OpenCode 菜单同一套观感（卡片 + 品牌描边 + 胶囊控件）。
// Hero 卡片承载「一键开始 / 停止」+ 激活节点热切换 + 运行状态；配置卡片（停用态可编辑）承载
// 代理端口 / Science 端口 / 账号 / 目录 / 接管开关。

struct ScienceProxyManagementView: View {
    @ObservedObject private var manager = ScienceProxyManager.shared
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var proxyPortText = ""
    @State private var sciencePortText = ""
    @State private var emailText = ""
    @State private var selectedNodeId = ""
    @State private var adoptReal = false
    @State private var allowLAN = false
    @State private var showAccountHelp = false

    static let brand = Color(red: 0.55, green: 0.36, blue: 0.96)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = manager.operationError {
                    errorBanner(error)
                }
                if !manager.scienceInstalled {
                    notInstalledCard
                }
                heroCard
                if nodes.isEmpty {
                    noNodesCard
                }
                configCard
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncFromConfig)
    }

    private var notInstalledCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(L(
                "Claude Science is not installed. Install it to /Applications first.",
                "未检测到 Claude Science，请先安装到「应用程序」。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "atom")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Self.brand)
                Text("Claude Science")
                    .font(.headline.weight(.bold))
                Spacer(minLength: 12)
                if !nodes.isEmpty {
                    HStack(spacing: 6) {
                        GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
                        GlobalProxyChipMenu(
                            brand: Self.brand,
                            title: currentNodeName,
                            systemImage: "bolt.fill",
                            isDisabled: manager.isBusy,
                            items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                            selectedId: nodeBinding.wrappedValue,
                            onSelect: { nodeBinding.wrappedValue = $0 }
                        )
                    }
                }
                if manager.isBusy { ProgressView().controlSize(.small) }
            }

            statusLine

            HStack(spacing: 10) {
                primaryButton
                if isEnabled {
                    Button {
                        manager.openInBrowser()
                    } label: {
                        Label(L("Open in Browser", "打开浏览器"), systemImage: "safari")
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isEnabled ? Self.brand.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            if isEnabled {
                let sciLabel = manager.adoptReal
                    ? L("real instance 127.0.0.1:\(manager.listenPort)", "真实实例 127.0.0.1:\(manager.listenPort)")
                    : L("sandbox 127.0.0.1:\(manager.listenPort)", "沙箱 127.0.0.1:\(manager.listenPort)")
                Text(L(
                    "Running · proxy \(manager.config.displayBindHost):\(manager.config.port) · \(sciLabel)",
                    "运行中 · 代理 \(manager.config.displayBindHost):\(manager.config.port) · \(sciLabel)"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                if !manager.sandboxHealthy {
                    Text(L("(starting…)", "（启动中…）"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(L("Stopped", "已停用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isEnabled {
            Button {
                Task { await manager.stop() }
            } label: {
                Label(L("Stop", "停止"), systemImage: "stop.fill")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(manager.isBusy)
        } else {
            Button {
                let target = resolvedSelection
                guard !target.isEmpty else { return }
                Task { await manager.start(activeNodeId: target) }
            } label: {
                Label(L("One-Click Start", "一键开始"), systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Self.brand)
            .disabled(manager.isBusy || nodes.isEmpty || !manager.scienceInstalled)
        }
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - No Nodes

    private var noNodesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("No upstream node yet", "还没有可用的上游节点"))
                .font(.subheadline.weight(.semibold))
            Text(L(
                "Claude Science reuses your Claude family nodes. Add one on the “Claude Code Proxy” page first (any OpenAI-compatible or Anthropic upstream).",
                "Claude Science 复用你的 Claude 家族节点。请先在「Claude Code 代理」页添加一个上游节点（任意 OpenAI 兼容 / Anthropic 上游）。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Config Card

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Configuration", "配置"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            if isEnabled {
                GlobalProxyFlowLayout(spacing: 6) {
                    if manager.config.effectiveAllowLAN {
                        GlobalProxySummaryChip(
                            label: L("LAN Access", "局域网访问"),
                            value: L("Enabled", "已启用")
                        )
                    }
                    GlobalProxySummaryChip(label: L("Mode", "模式"),
                                           value: manager.adoptReal ? L("Real instance", "真实实例") : L("Sandbox", "隔离沙箱"))
                    GlobalProxySummaryChip(label: L("Proxy Port", "代理端口"), value: "\(manager.config.port)")
                    GlobalProxySummaryChip(label: L("Science Port", "Science 端口"), value: "\(manager.listenPort)")
                    GlobalProxySummaryChip(label: L("Account", "账号"), value: manager.config.effectiveSandboxEmail)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    GlobalProxyField(label: L("Proxy Port", "代理端口")) {
                        TextField("14402", text: $proxyPortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onChange(of: proxyPortText) { _, _ in commitSettings() }
                    }
                    GlobalProxyField(label: L("Science Port", "Science 端口")) {
                        TextField("14410", text: $sciencePortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onChange(of: sciencePortText) { _, _ in commitSettings() }
                    }
                    Spacer(minLength: 0)
                }
                GlobalProxyField(label: L("Account", "账号"), fillWidth: true) {
                    HStack(spacing: 6) {
                        TextField("aiusage@cslocal.invalid", text: $emailText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .disabled(adoptReal)
                            .onChange(of: emailText) { _, _ in commitSettings() }
                        accountHelpButton
                    }
                }

                lanAccessToggle

                Divider().padding(.vertical, 2)

                adoptToggle
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(manager.sandboxHome.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(L("Open", "打开")) { manager.openSandboxFolder() }
                    .buttonStyle(.link)
                    .font(.caption)
                Button(L("Reset", "重置")) { manager.resetSandbox() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(isEnabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var lanAccessToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Allow LAN Access (0.0.0.0)", "允许局域网访问 (0.0.0.0)"), isOn: Binding(
                get: { allowLAN },
                set: { newValue in
                    allowLAN = newValue
                    manager.updateAllowLAN(newValue)
                }
            ))
            .font(.caption.weight(.medium))

            if allowLAN {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L(
                        "Warning: This will expose the proxy to your local network",
                        "警告：这将把代理暴露到你的局域网"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }
        }
    }

    private var adoptToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { adoptReal },
                set: { newValue in
                    adoptReal = newValue
                    manager.setAdoptReal(newValue)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Adopt real instance (desktop app login-free)", "接管真实实例（桌面 app 也免登录）"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L(
                        "Also makes the double-clicked Claude Science.app login-free (uses port 8765).",
                        "让双击 Claude Science.app 也免登录（占用 8765）。"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Self.brand)

            if adoptReal {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(L(
                        "Runs an isolated daemon and only rewrites the runtime lock; your real login is never touched.",
                        "在独立目录起 daemon，仅改写运行期锁文件，不触碰你的真实登录。"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Account Help Bubble

    private var accountHelpButton: some View {
        Button {
            showAccountHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("About the local account", "关于本地账号"))
        .popover(isPresented: $showAccountHelp, arrowEdge: .bottom) {
            accountHelpBubble
        }
    }

    private var accountHelpBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Local fake account", "本地假账号"), systemImage: "person.badge.key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.brand)
            helpRow("wifi.slash", L("Never goes online — used only to pass the local login gate.",
                                    "绝不联网，只用于越过本地登录门。"))
            helpRow("checkmark.seal", L("Must end with .invalid — a reserved domain that can never resolve.",
                                       "必须以 .invalid 结尾——保留域名，永不可解析。"))
            helpRow("externaldrive", L("Each account gets its own isolated data-dir and conversation history.",
                                       "每个账号有独立 data-dir 与对话历史。"))
            helpRow("arrow.triangle.2.circlepath", L("Switching the address keeps your existing conversations.",
                                                     "更换地址不会清空已有对话。"))
        }
        .padding(14)
        .frame(width: 288, alignment: .leading)
    }

    private func helpRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.10)))
    }

    // MARK: - Bindings

    private var nodeBinding: Binding<String> {
        Binding(
            get: { isEnabled ? (manager.activeNodeId ?? resolvedSelection) : resolvedSelection },
            set: { newId in
                selectedNodeId = newId
                if isEnabled {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    private var resolvedSelection: String {
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    // MARK: - Helpers

    private func syncFromConfig() {
        proxyPortText = "\(manager.config.port)"
        sciencePortText = "\(manager.config.effectiveSciencePort)"
        emailText = manager.config.effectiveSandboxEmail
        adoptReal = manager.adoptReal
        allowLAN = manager.config.effectiveAllowLAN
        selectedNodeId = resolvedSelection
    }

    private func commitSettings() {
        guard !isEnabled else { return }
        let proxyPort = Int(proxyPortText.trimmingCharacters(in: .whitespaces)) ?? manager.config.port
        let sciencePort = Int(sciencePortText.trimmingCharacters(in: .whitespaces)) ?? manager.config.effectiveSciencePort
        manager.updateSettings(proxyPort: proxyPort, sciencePort: sciencePort, email: emailText)
    }
}

#Preview {
    ScienceProxyManagementView()
        .frame(width: 900, height: 700)
}
