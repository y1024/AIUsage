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

    private var nodes: [ProxyConfiguration] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusLine
            if nodes.isEmpty {
                Text(L("Create a Codex node first to use the global proxy.", "请先创建 Codex 节点后再使用全局代理。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                nodePicker
                settingsRow
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
                .stroke(isEnabled ? Self.codexBrand.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear(perform: syncFromConfig)
    }

    // MARK: - Header (title + master toggle)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14))
                .foregroundStyle(Self.codexBrand)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Global Proxy", "全局代理"))
                    .font(.headline.weight(.bold))
                Text(L("Fixed endpoint; switch active node with zero restart.", "固定入口，切换激活节点零重启、CLI 无感。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isBusy {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: enableBinding)
                .labelsHidden()
                .toggleStyle(ProxyActivationToggleStyle(brandColor: Self.codexBrand, isBusy: manager.isBusy))
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
                Text("·")
                    .foregroundStyle(.secondary)
                Text(L("Active: \(name)", "激活：\(name)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.codexBrand)
            }
        }
    }

    // MARK: - Node Picker (active node; hot-switch when enabled)

    private var nodePicker: some View {
        HStack(spacing: 8) {
            Text(L("Active Node", "激活节点"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("", selection: nodeBinding) {
                ForEach(nodes) { node in
                    Text(node.name).tag(node.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(manager.isBusy)
            Spacer()
        }
    }

    // MARK: - Settings (port / virtual model; editable only while disabled)

    private var settingsRow: some View {
        HStack(spacing: 12) {
            field(label: L("Port", "端口"), width: 90) {
                TextField("4399", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .disabled(isEnabled)
                    .onChange(of: portText) { _, _ in commitSettings() }
            }
            field(label: L("Virtual Model", "虚拟模型"), width: 200) {
                TextField(GlobalProxyConfig.defaultVirtualModel, text: $virtualModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .disabled(isEnabled)
                    .onChange(of: virtualModel) { _, _ in commitSettings() }
            }
            Spacer()
        }
        .opacity(isEnabled ? 0.6 : 1)
    }

    private func field<Content: View>(label: String, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
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

    private var activeNodeName: String? {
        manager.node(for: manager.activeNodeId)?.name
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
