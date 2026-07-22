import SwiftUI
import AppKit

// MARK: - Claude Science Proxy Management View
// 「Claude Science 代理」主视图，与 Codex/OpenCode 菜单同一套观感（卡片 + 品牌描边 + 胶囊控件）。
// Hero 卡片：一键开始/停止 + 激活节点热切换；配置卡：端口、工作区、目录；接管开关收进高级区。

struct ScienceProxyManagementView: View {
    @ObservedObject private var manager = ScienceProxyManager.shared
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var proxyPortText = ""
    @State private var sciencePortText = ""
    @State private var selectedNodeId = ""
    @State private var adoptReal = false
    @State private var allowLAN = false
    @State private var showAdvanced = false
    @State private var showWorkspaceHelp = false
    @State private var showAllModels = false
    @State private var showNewWorkspaceAlert = false
    @State private var showRenameWorkspaceAlert = false
    @State private var showDeleteWorkspaceConfirm = false
    @State private var showResetWorkspaceConfirm = false
    @State private var workspaceNameDraft = ""
    @State private var workspacePendingRenameId: String?

    static let brand = Color(red: 0.55, green: 0.36, blue: 0.96)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }
    private var workspaces: [ScienceWorkspace] { manager.config.effectiveScienceWorkspaces }
    private var activeWorkspace: ScienceWorkspace { manager.config.effectiveActiveScienceWorkspace }
    private var workspaceControlsEnabled: Bool { !adoptReal }
    private var selectedModelCatalog: ScienceModelCatalog? {
        guard !resolvedSelection.isEmpty else { return nil }
        return manager.modelCatalog(for: resolvedSelection)
    }

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
                modelCatalogCard
                configCard
            }
            .frame(maxWidth: 900)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncFromConfig)
        .onChange(of: resolvedSelection) { _, _ in showAllModels = false }
        .alert(L("New Workspace", "新建工作区"), isPresented: $showNewWorkspaceAlert) {
            TextField(L("Name", "名称"), text: $workspaceNameDraft)
            Button(L("Cancel", "取消"), role: .cancel) { workspaceNameDraft = "" }
            Button(L("Create", "创建")) {
                manager.addWorkspace(named: workspaceNameDraft)
                workspaceNameDraft = ""
            }
        } message: {
            Text(L("Each workspace keeps its own conversations and local login.",
                     "每个工作区有独立的对话与本地登录状态。"))
        }
        .alert(L("Rename Workspace", "重命名工作区"), isPresented: $showRenameWorkspaceAlert) {
            TextField(L("Name", "名称"), text: $workspaceNameDraft)
            Button(L("Cancel", "取消"), role: .cancel) {
                workspaceNameDraft = ""
                workspacePendingRenameId = nil
            }
            Button(L("Save", "保存")) {
                if let id = workspacePendingRenameId {
                    manager.renameWorkspace(id: id, to: workspaceNameDraft)
                }
                workspaceNameDraft = ""
                workspacePendingRenameId = nil
            }
        }
        .confirmationDialog(
            L("Delete this workspace?", "删除此工作区？"),
            isPresented: $showDeleteWorkspaceConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Delete", "删除"), role: .destructive) {
                manager.deleteWorkspace(id: activeWorkspace.id)
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L("Its local data folder will be removed. This cannot be undone.",
                     "将删除其本地数据目录，且不可恢复。"))
        }
        .confirmationDialog(
            L("Reset this workspace?", "重置当前工作区？"),
            isPresented: $showResetWorkspaceConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Reset", "重置"), role: .destructive) {
                manager.resetSandbox()
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L(
                "Conversations and local login in “\(displayName(for: activeWorkspace))” will be cleared. The workspace itself stays.",
                "将清空「\(displayName(for: activeWorkspace))」中的对话与本地登录，工作区本身保留。"
            ))
        }
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

    // MARK: - Model Catalog

    private var modelCatalogCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.brand)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Self.brand.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Science models", "Science 模型"))
                        .font(.headline)
                    Text(L(
                        "The catalog currently exposed by the selected node",
                        "当前节点实际提供给 Science 的模型目录"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let catalog = selectedModelCatalog {
                    Text(L("\(catalog.models.count) models", "\(catalog.models.count) 个模型"))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Self.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Self.brand.opacity(0.10)))
                }
            }

            if let catalog = selectedModelCatalog, !catalog.models.isEmpty {
                ClaudeModelCatalogGrid(
                    items: catalog.models.map { model in
                        ClaudeModelCatalogItem(
                            id: model.id,
                            title: model.displayName,
                            subtitle: model.upstreamModel,
                            help: model.description,
                            isDefault: model.id == catalog.defaultModelID
                        )
                    },
                    brand: Self.brand,
                    showAll: $showAllModels
                )
            } else {
                Text(L(
                    "Choose a node whose Model Library contains at least one model.",
                    "请选择模型库中至少包含一个模型的节点。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }

            ClaudeEffortOwnershipRow(
                productName: "Science",
                brand: Self.brand,
                detail: L(
                    "Preserves the reasoning choice made by the Science session",
                    "保留 Science 会话自身选择的思考策略"
                )
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
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
                    GlobalProxySummaryChip(
                        label: L("Mode", "模式"),
                        value: manager.adoptReal ? L("Real instance", "真实实例") : L("Sandbox", "隔离沙箱")
                    )
                    if !manager.adoptReal {
                        GlobalProxySummaryChip(
                            label: L("Workspace", "工作区"),
                            value: displayName(for: activeWorkspace)
                        )
                    }
                    GlobalProxySummaryChip(label: L("Proxy Port", "代理端口"), value: "\(manager.config.port)")
                    GlobalProxySummaryChip(label: L("Science Port", "Science 端口"), value: "\(manager.listenPort)")
                }
            } else {
                workspaceSection

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

                lanAccessToggle

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        adoptToggle
                        dataLocationRow
                    }
                    .padding(.top, 8)
                } label: {
                    Text(L("Advanced", "高级"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .tint(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Workspace

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GlobalProxyInlineLabel(text: L("Workspace", "工作区"))
                GlobalProxyChipMenu(
                    brand: Self.brand,
                    title: displayName(for: activeWorkspace),
                    systemImage: "square.stack.3d.up.fill",
                    isDisabled: !workspaceControlsEnabled || manager.isBusy,
                    items: workspaces.map {
                        GlobalProxyPickerItem(id: $0.id, name: displayName(for: $0))
                    },
                    selectedId: activeWorkspace.id,
                    onSelect: { id in
                        Task { await manager.selectWorkspace(id: id) }
                    },
                    footerActions: workspaceFooterActions,
                    emptyMessage: L("No workspaces", "暂无工作区")
                )
                Button {
                    manager.openSandboxFolder()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(L("Show in Finder", "在 Finder 中显示"))
                .disabled(!workspaceControlsEnabled)

                workspaceHelpButton
                Spacer(minLength: 0)
            }
            if adoptReal {
                Text(L("Workspaces are available in sandbox mode only.", "工作区仅在隔离沙箱模式下可用。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private var workspaceFooterActions: [GlobalProxyChipMenuAction] {
        [
            GlobalProxyChipMenuAction(
                id: "new",
                title: L("New Workspace…", "新建工作区…"),
                systemImage: "plus",
                action: {
                    workspaceNameDraft = ""
                    showNewWorkspaceAlert = true
                }
            ),
            GlobalProxyChipMenuAction(
                id: "rename",
                title: L("Rename…", "重命名…"),
                systemImage: "pencil",
                isDisabled: workspaces.isEmpty,
                action: {
                    workspacePendingRenameId = activeWorkspace.id
                    workspaceNameDraft = displayName(for: activeWorkspace)
                    showRenameWorkspaceAlert = true
                }
            ),
            GlobalProxyChipMenuAction(
                id: "reset",
                title: L("Reset Workspace…", "重置工作区…"),
                systemImage: "arrow.counterclockwise",
                isDestructive: true,
                isDisabled: isEnabled,
                action: { showResetWorkspaceConfirm = true }
            ),
            GlobalProxyChipMenuAction(
                id: "delete",
                title: L("Delete…", "删除…"),
                systemImage: "trash",
                isDestructive: true,
                isDisabled: workspaces.count <= 1 || isEnabled,
                action: { showDeleteWorkspaceConfirm = true }
            ),
        ]
    }

    private var dataLocationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Data folder", "数据目录"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                Text(manager.sandboxHome.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(L("Copy", "复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.sandboxHome, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .opacity(adoptReal ? 0.45 : 1)
    }

    private func displayName(for workspace: ScienceWorkspace) -> String {
        if workspace.id == GlobalProxyConfig.defaultScienceWorkspaceId,
           workspace.name == GlobalProxyConfig.defaultScienceWorkspaceName {
            return L("Default", "默认")
        }
        return workspace.name
    }

    private var workspaceHelpButton: some View {
        Button {
            showWorkspaceHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L("About workspaces", "关于工作区"))
        .popover(isPresented: $showWorkspaceHelp, arrowEdge: .bottom) {
            workspaceHelpBubble
        }
    }

    private var workspaceHelpBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Sandbox workspaces", "沙箱工作区"), systemImage: "square.stack.3d.up.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.brand)
            helpRow("externaldrive", L("Each workspace has its own data folder and conversation history.",
                                       "每个工作区有独立数据目录与对话历史。"))
            helpRow("wifi.slash", L("Local login only — never contacts Anthropic.",
                                    "仅本地登录，绝不联系 Anthropic。"))
            helpRow("arrow.triangle.2.circlepath", L("Switching workspaces restarts Science with that folder.",
                                                     "切换工作区会用对应目录重启 Science。"))
            helpRow("trash", L("Reset clears only the current workspace.",
                               "重置只清空当前工作区。"))
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
                        "Also makes the double-clicked Claude Science.app login-free (uses port 8765). Workspaces are disabled while this is on.",
                        "让双击 Claude Science.app 也免登录（占用 8765）。开启后工作区不可用。"
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
        adoptReal = manager.adoptReal
        allowLAN = manager.config.effectiveAllowLAN
        selectedNodeId = resolvedSelection
        showAdvanced = manager.adoptReal
    }

    private func commitSettings() {
        guard !isEnabled else { return }
        let proxyPort = Int(proxyPortText.trimmingCharacters(in: .whitespaces)) ?? manager.config.port
        let sciencePort = Int(sciencePortText.trimmingCharacters(in: .whitespaces)) ?? manager.config.effectiveSciencePort
        manager.updateSettings(proxyPort: proxyPort, sciencePort: sciencePort)
    }
}

#Preview {
    ScienceProxyManagementView()
        .frame(width: 900, height: 700)
}
