import SwiftUI

// MARK: - Codex Global Proxy Section
// Codex 轨「全局统一代理」配置卡片：常驻固定端口对外暴露一个稳定入口（端口 + client key + 虚拟模型），
// Codex CLI 一次性指向它即可。切换激活节点走进程内热替换，CLI 无感（无需重启 / 端口不变）。
// 启用期间接管 config.toml，并禁用每节点单独激活（节点列表开关由本卡片统一切换激活节点）。

struct CodexGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.shared
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var portText: String = ""
    @State private var virtualModel: String = ""
    @State private var selectedNodeId: String = ""

    private static let codexBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.codexBrand,
            subtitle: L("Fixed endpoint; switch active node with zero restart.", "固定入口，切换激活节点零重启、CLI 无感。"),
            isEnabled: isEnabled,
            isBusy: manager.isBusy,
            port: manager.config.port,
            hasNodes: !nodes.isEmpty,
            emptyHint: L("Create a Codex node first to use the global proxy.", "请先创建 Codex 节点后再使用全局代理。"),
            errorText: manager.operationError,
            toggle: enableBinding,
            nodeControl: { nodeControl },
            config: { configContent }
        )
        .onAppear(perform: syncFromConfig)
    }

    // MARK: - Active Node (header; hot-switch when enabled)

    private var nodeControl: some View {
        HStack(spacing: 6) {
            GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
            Picker("", selection: nodeBinding) {
                ForEach(nodes) { node in
                    Text(node.name).tag(node.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(minWidth: 120)
            .disabled(manager.isBusy)
        }
    }

    // MARK: - Configuration (port / virtual model; editable only while disabled)

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField("14399", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(isEnabled)
                        .onChange(of: portText) { _, _ in commitSettings() }
                }
                GlobalProxyField(label: L("Model", "模型")) {
                    TextField(GlobalProxyConfig.defaultVirtualModel, text: $virtualModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(isEnabled)
                        .onChange(of: virtualModel) { _, _ in commitSettings() }
                }
                Spacer()
            }
            GlobalProxyTip(text: L(
                "Model is just the fixed entry name Codex sends — name it anything. Each request is rewritten to the active node's real upstream model.",
                "模型仅作 Codex 固定入口名，可任意取名；每次请求会被改写为激活节点的真实上游模型。"
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
        virtualModel = manager.config.virtualModel
        selectedNodeId = resolvedSelection
    }

    private func commitSettings() {
        guard !isEnabled else { return }
        let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? manager.config.port
        manager.updateSettings(port: port, virtualModel: virtualModel, clientKey: manager.config.clientKey)
    }
}
