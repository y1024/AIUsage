import SwiftUI

// MARK: - Claude Global Proxy Section
// Claude Code 轨「全局统一代理」配置卡片：常驻固定端口对外暴露稳定入口（端口 + client key + 三层虚拟模型），
// Claude Code 一次性指向它即可（写 ~/.claude/settings.json 的 ANTHROPIC_BASE_URL/AUTH_TOKEN 与三模型）。
// 切换激活节点走进程内热替换（opus/sonnet/haiku → 节点真实 big/middle/small），CLI 无感、端口不变。
// 启用期间接管 settings.json，并禁用每节点单独激活（节点开关由本卡片统一切换激活节点）。

struct ClaudeGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.claude
    @ObservedObject private var runtime = GlobalProxyRuntime.claude
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var opusModel: String = ""
    @State private var sonnetModel: String = ""
    @State private var haikuModel: String = ""
    @State private var selectedNodeId: String = ""
    @State private var pendingSharedRouteNodeId: String?

    private static let claudeBrand = Color(red: 0.85, green: 0.45, blue: 0.25)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }
    private var isRuntimeOwnedByDesktop: Bool { manager.isRuntimeEnabled && !isEnabled }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.claudeBrand,
            title: "Claude Gateway",
            subtitle: gatewaySubtitle,
            isEnabled: isEnabled,
            isRunning: runtime.isRunning,
            isRuntimeOwnedByAnotherConsumer: isRuntimeOwnedByDesktop,
            otherConsumerStatus: L("Desktop active", "Desktop 使用中"),
            isBusy: manager.isBusy,
            port: manager.config.port,
            bindHost: manager.config.effectiveClaudeDesktopEnabled
                ? "127.0.0.1" : manager.config.displayBindHost,
            allowLAN: allowLANBinding,
            hasNodes: !nodes.isEmpty,
            emptyHint: L("Create a Claude node first to use the global proxy.", "请先创建 Claude 节点后再使用全局代理。"),
            errorText: manager.operationError,
            toggle: enableBinding,
            nodeControl: { nodeControl },
            config: { configContent },
            runningSummary: { runningSummary }
        )
        .onAppear(perform: syncFromConfig)
        .confirmationDialog(
            L("Switch the shared Claude route?", "切换 Claude 共享路由？"),
            isPresented: Binding(
                get: { pendingSharedRouteNodeId != nil },
                set: { if !$0 { pendingSharedRouteNodeId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Switch Code + Desktop", "同时切换 Code + Desktop")) {
                guard let nodeId = pendingSharedRouteNodeId else { return }
                selectedNodeId = nodeId
                pendingSharedRouteNodeId = nil
                Task { await manager.switchActiveNode(to: nodeId) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingSharedRouteNodeId = nil
            }
        } message: {
            Text(L(
                "Code and Desktop are attached to the same Gateway route. Both products will use the new node immediately.",
                "Code 与 Desktop 正在使用同一条 Gateway 路由；切换后两端会立即改用新节点。"
            ))
        }
    }

    // MARK: - Active Node (header; hot-switch when enabled)

    private var nodeControl: some View {
        HStack(spacing: 6) {
            GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
            GlobalProxyChipMenu(
                brand: Self.claudeBrand,
                title: currentNodeName,
                systemImage: "bolt.fill",
                isDisabled: manager.isBusy || isRuntimeOwnedByDesktop,
                items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                selectedId: nodeBinding.wrappedValue,
                onSelect: { nodeBinding.wrappedValue = $0 }
            )
        }
        .help(isRuntimeOwnedByDesktop
              ? L("Desktop owns this route. Switch it from the Desktop tab, or attach Code to share it.",
                  "当前路由由 Desktop 使用；请在 Desktop 页签切换，或接入 Code 后共享。")
              : L("Choose the Claude Gateway route", "选择 Claude Gateway 路由"))
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - Running Summary (read-only chips when enabled)

    @ViewBuilder private var runningSummary: some View {
        GlobalProxySummaryChip(
            label: "Code",
            value: manager.config.effectiveClaudeCodeEnabled ? L("Attached", "已接入") : L("Independent", "独立")
        )
        GlobalProxySummaryChip(
            label: "Desktop",
            value: manager.config.effectiveClaudeDesktopEnabled ? L("Attached", "已接入") : L("Off", "未接入")
        )
        GlobalProxySummaryChip(label: L("Opus", "Opus"), value: manager.config.claudeOpus)
        GlobalProxySummaryChip(label: L("Sonnet", "Sonnet"), value: manager.config.claudeSonnet)
        GlobalProxySummaryChip(label: L("Haiku", "Haiku"), value: manager.config.claudeHaiku)
    }

    // MARK: - Configuration (port + three-tier models; editable only while disabled)
    // 三层模型并排一行，省纵向空间；端口/三模型仅停用态可改。

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField(
                        "14400",
                        value: portBinding,
                        format: IntegerFormatStyle<Int>.number.grouping(.never)
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                modelColumn(L("Opus", "Opus"), placeholder: GlobalProxyConfig.defaultClaudeOpus, text: $opusModel)
                modelColumn(L("Sonnet", "Sonnet"), placeholder: GlobalProxyConfig.defaultClaudeSonnet, text: $sonnetModel)
                modelColumn(L("Haiku", "Haiku"), placeholder: GlobalProxyConfig.defaultClaudeHaiku, text: $haikuModel)
                Spacer(minLength: 0)
            }
            GlobalProxyTip(text: L(
                "These three names are just fixed tier entries Claude Code sends — name them anything. Each is rewritten to the active node's real big / middle / small upstream model.",
                "三层模型名仅作 Claude Code 固定入口名，可任意取名；请求会按层改写为激活节点真实的 大 / 中 / 小 上游模型。"
            ))
        }
    }

    /// 一列模型：小标签在上、输入框在下，固定宽度左对齐，与其它模型框一致。
    private func modelColumn(_ tier: String, placeholder: String, text: Binding<String>) -> some View {
        GlobalProxyField(label: L("\(tier) Model", "\(tier) 模型")) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, idealWidth: 150, maxWidth: 160)
                .onChange(of: text.wrappedValue) { _, _ in commitSettings() }
        }
    }

    private var allowLANBinding: Binding<Bool> {
        Binding(
            get: {
                manager.config.effectiveClaudeDesktopEnabled
                    ? false : manager.config.effectiveAllowLAN
            },
            set: { manager.updateAllowLAN($0) }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { manager.config.port },
            set: {
                manager.updateClaudeModels(
                    port: $0,
                    opus: opusModel,
                    sonnet: sonnetModel,
                    haiku: haikuModel
                )
            }
        )
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                if newValue {
                    let target = resolvedSelection
                    guard !target.isEmpty else { return }
                    Task { await manager.enable(activeNodeId: target) }
                } else {
                    Task { await manager.disable() }
                }
            }
        )
    }

    private var nodeBinding: Binding<String> {
        Binding(
            get: { manager.isRuntimeEnabled ? (manager.activeNodeId ?? resolvedSelection) : resolvedSelection },
            set: { newId in
                if isEnabled, manager.config.effectiveClaudeDesktopEnabled,
                   newId != manager.activeNodeId {
                    pendingSharedRouteNodeId = newId
                } else {
                    selectedNodeId = newId
                }
                if manager.isRuntimeEnabled && pendingSharedRouteNodeId == nil {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    // MARK: - Helpers

    /// 当前选定节点（兜底到首个可用节点），保证 Picker/启用按钮总有合法目标。
    private var resolvedSelection: String {
        // When Desktop already owns the Gateway, attaching Code must join the
        // live shared route. A stale local picker draft must never switch
        // Desktop as a side effect of turning Code on.
        if manager.isRuntimeEnabled,
           let active = manager.activeNodeId,
           nodes.contains(where: { $0.id == active }) {
            return active
        }
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    private var gatewaySubtitle: String {
        switch (manager.config.effectiveClaudeCodeEnabled, manager.config.effectiveClaudeDesktopEnabled) {
        case (true, true):
            return L(
                "Code and Desktop share one stable route; switching affects both.",
                "Code 与 Desktop 共享一条固定路由；切换会同时影响两端。"
            )
        case (true, false):
            return L("Claude Code is attached to a stable local route.", "Claude Code 已接入固定本机路由。")
        case (false, true):
            return L(
                "Desktop is using the Gateway; Code can stay direct or join this route.",
                "Desktop 正在使用 Gateway；Code 可保持直连，也可加入此路由。"
            )
        case (false, false):
            return L("Attach Code to a stable route with hot node switching.", "让 Code 接入可热切换节点的固定路由。")
        }
    }

    private func syncFromConfig() {
        opusModel = manager.config.claudeOpus
        sonnetModel = manager.config.claudeSonnet
        haikuModel = manager.config.claudeHaiku
        selectedNodeId = resolvedSelection
    }

    private func commitSettings() {
        guard !manager.isRuntimeEnabled else { return }
        manager.updateClaudeModels(
            port: manager.config.port,
            opus: opusModel,
            sonnet: sonnetModel,
            haiku: haikuModel
        )
    }
}
