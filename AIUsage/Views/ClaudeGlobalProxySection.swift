import SwiftUI

// MARK: - Code Gateway Section
// Claude Code 轨「全局统一代理」配置卡片：常驻固定端口对外暴露稳定入口。
// Claude Code 一次性指向它即可；四路模型映射由上方 Code 模型卡负责。
// 启用期间接管 settings.json，并禁用每节点单独激活（节点开关由本卡片统一切换激活节点）。

struct ClaudeGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.claude
    @ObservedObject private var runtime = GlobalProxyRuntime.claude
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var localSelectedNodeId = ""
    private let externalSelectedNodeId: Binding<String>?
    @State private var pendingRestartNodeId: String?

    private static let claudeBrand = Color.indigo

    init(selectedNodeId: Binding<String>? = nil) {
        externalSelectedNodeId = selectedNodeId
    }

    private var selectedNodeId: String {
        get { externalSelectedNodeId?.wrappedValue ?? localSelectedNodeId }
        nonmutating set {
            if let externalSelectedNodeId {
                externalSelectedNodeId.wrappedValue = newValue
            } else {
                localSelectedNodeId = newValue
            }
        }
    }

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }
    private var modelMode: ClaudeDesktopCatalogMode { manager.config.effectiveClaudeCodeCatalogMode }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.claudeBrand,
            title: L("Code Gateway", "Code 网关"),
            subtitle: gatewaySubtitle,
            isEnabled: isEnabled,
            isRunning: runtime.isRunning,
            isRuntimeOwnedByAnotherConsumer: false,
            otherConsumerStatus: "",
            isBusy: manager.isBusy,
            port: manager.config.port,
            bindHost: manager.config.displayBindHost,
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
            L("Switch Code to another node?", "切换 Code 节点？"),
            isPresented: Binding(
                get: { pendingRestartNodeId != nil },
                set: { if !$0 { pendingRestartNodeId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Switch Node", "切换节点")) {
                guard let nodeId = pendingRestartNodeId else { return }
                selectedNodeId = nodeId
                pendingRestartNodeId = nil
                Task { await manager.switchActiveNode(to: nodeId) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingRestartNodeId = nil
            }
        } message: {
            Text(L(
                "Node models expose real model names. The route will switch now; restart running Claude Code sessions so they reload the new catalog.",
                "“节点模型”会暴露真实模型名。路由将立即切换；请重启正在运行的 Claude Code 会话以重新加载模型目录。"
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
                isDisabled: manager.isBusy,
                items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                selectedId: nodeBinding.wrappedValue,
                onSelect: { nodeBinding.wrappedValue = $0 }
            )
        }
        .help(L("Choose the Code Gateway route", "选择 Code 网关路由"))
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - Running Summary (read-only chips when enabled)

    @ViewBuilder private var runningSummary: some View {
        GlobalProxySummaryChip(
            label: L("Mode", "模式"),
            value: modelMode == .smartRoutes ? L("Hot switch", "热切换") : L("Node models", "节点模型")
        )
        if let active = proxyVM.configurations.first(where: { $0.id == manager.activeNodeId }) {
            let models = manager.config.effectiveClaudeCodeModels(for: active)
            GlobalProxySummaryChip(label: L("Default", "默认"), value: models.defaultModel)
            GlobalProxySummaryChip(label: "Opus", value: models.opus)
            GlobalProxySummaryChip(label: "Sonnet", value: models.sonnet)
            GlobalProxySummaryChip(label: "Haiku", value: models.haiku)
            if modelMode == .fullNodeCatalog {
                GlobalProxySummaryChip(label: L("Catalog", "目录"), value: "\(active.runtimeModelCatalog.count)")
            }
        }
    }

    // MARK: - Configuration

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField(
                        "14400",
                        value: portBinding,
                        format: IntegerFormatStyle<Int>.number.grouping(.never)
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Text(L(
                    "Model routes are configured in the Code models card below.",
                    "模型映射请在下方“Code 模型”卡片中配置。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var allowLANBinding: Binding<Bool> {
        Binding(
            get: { manager.config.effectiveAllowLAN },
            set: { manager.updateAllowLAN($0) }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { manager.config.port },
            set: {
                manager.updateClaudeModels(
                    port: $0,
                    opus: manager.config.claudeOpus,
                    sonnet: manager.config.claudeSonnet,
                    haiku: manager.config.claudeHaiku
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
                if isEnabled, modelMode == .fullNodeCatalog,
                   newId != manager.activeNodeId {
                    pendingRestartNodeId = newId
                } else {
                    selectedNodeId = newId
                }
                if manager.isRuntimeEnabled && pendingRestartNodeId == nil {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    // MARK: - Helpers

    /// 当前选定节点（兜底到首个可用节点），保证 Picker/启用按钮总有合法目标。
    private var resolvedSelection: String {
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
        modelMode == .smartRoutes
            ? L("Code · stable aliases · hot switch", "Code · 固定别名 · 热切换")
            : L("Code · real model names · restart on node change", "Code · 真实模型名 · 切换节点需重启")
    }

    private func syncFromConfig() {
        selectedNodeId = resolvedSelection
    }
}
