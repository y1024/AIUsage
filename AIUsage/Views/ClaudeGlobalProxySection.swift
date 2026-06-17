import SwiftUI

// MARK: - Claude Global Proxy Section
// Claude Code 轨「全局统一代理」配置卡片：常驻固定端口对外暴露稳定入口（端口 + client key + 三层虚拟模型），
// Claude Code 一次性指向它即可（写 ~/.claude/settings.json 的 ANTHROPIC_BASE_URL/AUTH_TOKEN 与三模型）。
// 切换激活节点走进程内热替换（opus/sonnet/haiku → 节点真实 big/middle/small），CLI 无感、端口不变。
// 启用期间接管 settings.json，并禁用每节点单独激活（节点开关由本卡片统一切换激活节点）。

struct ClaudeGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.claude
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var portText: String = ""
    @State private var opusModel: String = ""
    @State private var sonnetModel: String = ""
    @State private var haikuModel: String = ""
    @State private var selectedNodeId: String = ""

    private static let claudeBrand = Color(red: 0.85, green: 0.45, blue: 0.25)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.claudeBrand,
            subtitle: L("Fixed endpoint; switch active node with zero restart.", "固定入口，切换激活节点零重启、CLI 无感。"),
            isEnabled: isEnabled,
            isBusy: manager.isBusy,
            port: manager.config.port,
            hasNodes: !nodes.isEmpty,
            emptyHint: L("Create a Claude node first to use the global proxy.", "请先创建 Claude 节点后再使用全局代理。"),
            errorText: manager.operationError,
            toggle: enableBinding,
            nodeControl: { nodeControl },
            config: { configContent },
            runningSummary: { runningSummary }
        )
        .onAppear(perform: syncFromConfig)
    }

    // MARK: - Active Node (header; hot-switch when enabled)

    private var nodeControl: some View {
        HStack(spacing: 6) {
            GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
            GlobalProxyChipMenu(
                brand: Self.claudeBrand,
                title: currentNodeName,
                systemImage: "bolt.fill",
                isDisabled: manager.isBusy,
                items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                selectedId: nodeBinding.wrappedValue,
                onSelect: { nodeBinding.wrappedValue = $0 }
            )
        }
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - Running Summary (read-only chips when enabled)

    @ViewBuilder private var runningSummary: some View {
        GlobalProxySummaryChip(label: L("Port", "端口"), value: "\(manager.config.port)")
        GlobalProxySummaryChip(label: L("Opus", "Opus"), value: manager.config.claudeOpus)
        GlobalProxySummaryChip(label: L("Sonnet", "Sonnet"), value: manager.config.claudeSonnet)
        GlobalProxySummaryChip(label: L("Haiku", "Haiku"), value: manager.config.claudeHaiku)
    }

    // MARK: - Configuration (port + three-tier models; editable only while disabled)
    // 三层模型并排一行，省纵向空间；端口/三模型仅停用态可改。

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField("14400", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(isEnabled)
                        .onChange(of: portText) { _, _ in commitSettings() }
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
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
                .frame(width: 160)
                .disabled(isEnabled)
                .onChange(of: text.wrappedValue) { _, _ in commitSettings() }
        }
    }

    // MARK: - Bindings

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
            get: { isEnabled ? (manager.activeNodeId ?? resolvedSelection) : resolvedSelection },
            set: { newId in
                selectedNodeId = newId
                if isEnabled {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    // MARK: - Helpers

    /// 当前选定节点（兜底到首个可用节点），保证 Picker/启用按钮总有合法目标。
    private var resolvedSelection: String {
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    private func syncFromConfig() {
        portText = "\(manager.config.port)"
        opusModel = manager.config.claudeOpus
        sonnetModel = manager.config.claudeSonnet
        haikuModel = manager.config.claudeHaiku
        selectedNodeId = resolvedSelection
    }

    private func commitSettings() {
        guard !isEnabled else { return }
        let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? manager.config.port
        manager.updateClaudeModels(port: port, opus: opusModel, sonnet: sonnetModel, haiku: haikuModel)
    }
}
