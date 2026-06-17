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
        VStack(alignment: .leading, spacing: 12) {
            header
            statusLine
            if nodes.isEmpty {
                Text(L("Create a Claude node first to use the global proxy.", "请先创建 Claude 节点后再使用全局代理。"))
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
                .stroke(isEnabled ? Self.claudeBrand.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear(perform: syncFromConfig)
    }

    // MARK: - Header (title + master toggle)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14))
                .foregroundStyle(Self.claudeBrand)
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
                .toggleStyle(ProxyActivationToggleStyle(brandColor: Self.claudeBrand, isBusy: manager.isBusy))
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
                    .foregroundStyle(Self.claudeBrand)
            }
        }
    }

    // MARK: - Config Body (active node + port inline; three models in one row)
    // 激活节点可在运行时热切换；端口/三模型仅停用态可改。三层模型并排一行，省纵向空间。

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
                    TextField("14400", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(isEnabled)
                        .onChange(of: portText) { _, _ in commitSettings() }
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
                modelColumn(L("Opus", "Opus"), placeholder: GlobalProxyConfig.defaultClaudeOpus, text: $opusModel)
                modelColumn(L("Sonnet", "Sonnet"), placeholder: GlobalProxyConfig.defaultClaudeSonnet, text: $sonnetModel)
                modelColumn(L("Haiku", "Haiku"), placeholder: GlobalProxyConfig.defaultClaudeHaiku, text: $haikuModel)
            }
            Text(L(
                "These three names are just fixed tier entries Claude Code sends — name them anything. Each is rewritten to the active node's real big / middle / small upstream model.",
                "三层模型名仅作 Claude Code 固定入口名，可任意取名；请求会按层改写为激活节点真实的 大 / 中 / 小 上游模型。"
            ))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一列模型：小标签在上、输入框在下，三列等宽填满整行。
    private func modelColumn(_ tier: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("\(tier) Model", "\(tier) 模型"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .disabled(isEnabled)
                .onChange(of: text.wrappedValue) { _, _ in commitSettings() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
