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
        VStack(alignment: .leading, spacing: 12) {
            header
            statusLine
            interfaceRow
            if nodes.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                configGrid
            }
            if let error = manager.operationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isEnabled ? Self.brand.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear(perform: syncFromConfig)
        // 节点列表/接口变化后，保证选择项仍有效。
        .onChange(of: store.nodes.count) { _, _ in selectedNodeId = resolvedSelection }
    }

    // MARK: - Header (title + master toggle)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14))
                .foregroundStyle(Self.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Global Proxy", "全局代理"))
                    .font(.headline.weight(.bold))
                Text(L("Fixed endpoint; switch active node within one interface, zero restart.", "固定入口，同接口内切换激活节点零重启、CLI 无感。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isBusy {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: enableBinding)
                .labelsHidden()
                .toggleStyle(ProxyActivationToggleStyle(brandColor: Self.brand, isBusy: manager.isBusy))
                .disabled(nodes.isEmpty || manager.isBusy)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(isEnabled
                 ? L("Running on 127.0.0.1:\(manager.config.port)", "运行中 · 127.0.0.1:\(manager.config.port)")
                 : L("Stopped", "已停用"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if isEnabled, let name = activeNodeName {
                Text("·").foregroundStyle(.secondary)
                Text(L("Active: \(name)", "激活：\(name)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.brand)
            }
        }
    }

    // MARK: - Interface Picker (locked while enabled)
    // 接口决定 npm 包 / 后端透传轨道 / 可切换的节点集合；启用后锁定（换接口需先停用）。

    private var interfaceRow: some View {
        HStack(spacing: 8) {
            Text(L("Interface", "接口"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("", selection: interfaceBinding) {
                ForEach(OpenCodeProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(isEnabled || manager.isBusy)
            Spacer()
        }
    }

    // MARK: - Config Body (active node + port inline; single virtual model)

    private var configGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                inlineField(L("Active Node", "激活节点")) {
                    Picker("", selection: nodeBinding) {
                        ForEach(nodes) { node in
                            Text(node.name).tag(node.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(minWidth: 140)
                    .disabled(manager.isBusy)
                }
                inlineField(L("Port", "端口")) {
                    TextField("14401", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(isEnabled)
                        .onChange(of: portText) { _, _ in commitSettings() }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Model", "模型"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(GlobalProxyConfig.defaultOpenCodeModel, text: $modelText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .disabled(isEnabled)
                    .onChange(of: modelText) { _, _ in commitSettings() }
                Text(L(
                    "Just the fixed entry name the CLI sends — name it anything. Each request is rewritten to the active node's real upstream model.",
                    "仅作 CLI 固定入口名，可任意取名；每次请求会被改写为激活节点的真实上游模型。"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 标签在前、控件在后的紧凑内联字段（用于激活节点 / 端口）。
    private func inlineField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
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

    private var activeNodeName: String? {
        manager.node(for: manager.activeNodeId)?.name
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
