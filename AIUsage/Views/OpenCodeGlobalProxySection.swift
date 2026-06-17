import SwiftUI
import QuotaBackend

// MARK: - OpenCode Global Proxy Section
// OpenCode 轨「全局统一代理」配置卡片：常驻固定端口对外暴露稳定入口（接口 + 端口 + client key + 固定虚拟模型），
// opencode.json 一次性指向它即可（受管 provider 块 + 顶层 model）。启用时先选定接口协议
// （OpenAI 兼容 / Anthropic / OpenAI Responses），只能在「同接口」节点间热切换以保证 wire 格式兼容；
// 切换激活节点走进程内热替换（改写 model 为节点真实模型），CLI 无感、端口不变。
// 启用期间接管 opencode.json，并禁用每节点单独激活（由本卡片统一切换激活节点）。
// 成本/用量走代理日志按节点定价归因（不依赖 opencode.db），与 Claude/Codex 全局代理同口径。

struct OpenCodeGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.opencode
    @ObservedObject private var store = OpenCodeNodeStore.shared

    @State private var portText: String = ""
    @State private var modelText: String = ""
    @State private var selectedNodeId: String = ""

    private static let brand = Color(red: 0.18, green: 0.83, blue: 0.75)

    private var interface: OpenCodeProtocol { manager.config.effectiveOpenCodeInterface }
    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.brand,
            subtitle: L("Fixed endpoint; switch active node within one interface, zero restart.", "固定入口，同接口内切换激活节点零重启、CLI 无感。"),
            isEnabled: isEnabled,
            isBusy: manager.isBusy,
            port: manager.config.port,
            hasNodes: !nodes.isEmpty,
            emptyHint: emptyHint,
            errorText: manager.operationError,
            toggle: enableBinding,
            nodeControl: { nodeControl },
            config: { configContent },
            runningSummary: { runningSummary }
        )
        .onAppear(perform: syncFromConfig)
        // 节点列表/接口变化后，保证选择项仍有效。
        .onChange(of: store.nodes.count) { _, _ in selectedNodeId = resolvedSelection }
    }

    // MARK: - Active Node (header; hot-switch when enabled)

    private var nodeControl: some View {
        HStack(spacing: 6) {
            GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
            GlobalProxyChipMenu(
                brand: Self.brand,
                title: currentNodeName,
                systemImage: "bolt.fill",
                isDisabled: manager.isBusy
            ) {
                ForEach(nodes) { node in
                    Button {
                        nodeBinding.wrappedValue = node.id
                    } label: {
                        if node.id == nodeBinding.wrappedValue {
                            Label(node.name, systemImage: "checkmark")
                        } else {
                            Text(node.name)
                        }
                    }
                }
            }
        }
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    // MARK: - Running Summary (read-only chips when enabled)

    @ViewBuilder private var runningSummary: some View {
        GlobalProxySummaryChip(label: L("Interface", "接口"), value: interface.displayName)
        GlobalProxySummaryChip(label: L("Port", "端口"), value: "\(manager.config.port)")
        GlobalProxySummaryChip(label: L("Model", "模型"), value: manager.config.virtualModel)
    }

    // MARK: - Configuration (interface + port + single virtual model)
    // 接口决定 npm 包 / 后端透传轨道 / 可切换的节点集合；启用后锁定（换接口需先停用），故归入折叠配置区。

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField("14401", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(isEnabled)
                        .onChange(of: portText) { _, _ in commitSettings() }
                }
                GlobalProxyField(label: L("Interface", "接口")) {
                    GlobalProxyChipMenu(
                        brand: Self.brand,
                        title: interface.displayName,
                        systemImage: "arrow.left.arrow.right",
                        isDisabled: isEnabled || manager.isBusy
                    ) {
                        ForEach(OpenCodeProtocol.allCases, id: \.self) { proto in
                            Button {
                                interfaceBinding.wrappedValue = proto
                            } label: {
                                if proto == interface {
                                    Label(proto.displayName, systemImage: "checkmark")
                                } else {
                                    Text(proto.displayName)
                                }
                            }
                        }
                    }
                }
                Spacer()
            }
            GlobalProxyField(label: L("Model", "模型")) {
                TextField(GlobalProxyConfig.defaultOpenCodeModel, text: $modelText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .disabled(isEnabled)
                    .onChange(of: modelText) { _, _ in commitSettings() }
            }
            GlobalProxyTip(text: L(
                "Just the fixed entry name the CLI sends — name it anything. Each request is rewritten to the active node's real upstream model.",
                "仅作 CLI 固定入口名，可任意取名；每次请求会被改写为激活节点的真实上游模型。"
            ))
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

    private var interfaceBinding: Binding<OpenCodeProtocol> {
        Binding(
            get: { interface },
            set: { newValue in
                manager.updateOpenCodeInterface(newValue)
                selectedNodeId = resolvedSelection
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

    private var emptyHint: String {
        L("No \(interface.displayName) node to use this interface. Create one, or pick another interface.",
          "没有可用于「\(interface.displayName)」接口的节点。请新建对应协议的节点，或切换其它接口。")
    }

    /// 当前选定节点（兜底到首个可用节点），保证 Picker/启用按钮总有合法目标。
    private var resolvedSelection: String {
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    private func syncFromConfig() {
        portText = "\(manager.config.port)"
        modelText = manager.config.virtualModel
        selectedNodeId = resolvedSelection
    }

    private func commitSettings() {
        guard !isEnabled else { return }
        let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? manager.config.port
        manager.updateSettings(port: port, virtualModel: modelText, clientKey: manager.config.clientKey)
    }
}
