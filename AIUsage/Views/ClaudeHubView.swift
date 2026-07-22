import SwiftUI

enum ClaudeHubTab: String, CaseIterable, Identifiable {
    case node
    case code
    case desktop
    case science

    var id: String { rawValue }

    var title: String {
        switch self {
        case .node: return "Node"
        case .code: return "Code"
        case .desktop: return "Desktop"
        case .science: return "Science"
        }
    }

    var symbol: String {
        switch self {
        case .node: return "point.3.connected.trianglepath.dotted"
        case .code: return "terminal"
        case .desktop: return "macwindow"
        case .science: return "atom"
        }
    }

    var tint: Color {
        switch self {
        case .node: return .teal
        case .code: return .indigo
        case .desktop: return ClaudeDesktopIntegrationView.brand
        case .science: return ScienceProxyManagementView.brand
        }
    }
}

/// One Claude ecosystem entry with four explicit ownership boundaries: Node
/// runtimes plus independent Code, Desktop and Science product gateways.
struct ClaudeHubView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DefaultsKey.claudeHubSelectedTab) private var selectedTabRawValue = ClaudeHubTab.desktop.rawValue
    private let initialTab: ClaudeHubTab?

    init(initialTab: ClaudeHubTab? = nil) {
        self.initialTab = initialTab
    }

    private var selectedTab: ClaudeHubTab {
        ClaudeHubTab(rawValue: selectedTabRawValue) ?? .desktop
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch selectedTab {
                case .node:
                    ProxyManagementView(showsClaudeProductConfiguration: false)
                case .code:
                    ClaudeCodeRoutingView()
                case .desktop:
                    ClaudeDesktopIntegrationView()
                case .science:
                    ScienceProxyManagementView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // The normal sidebar entry restores the last product. Legacy routes may
            // still request a specific product and become the new remembered value.
            let restoredTab = initialTab ?? ClaudeHubTab(rawValue: selectedTabRawValue) ?? .desktop
            if selectedTabRawValue != restoredTab.rawValue {
                selectedTabRawValue = restoredTab.rawValue
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(ClaudeHubTab.allCases) { tab in
                productButton(tab)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func productButton(_ tab: ClaudeHubTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            if reduceMotion {
                selectedTabRawValue = tab.rawValue
            } else {
                withAnimation(.easeOut(duration: 0.18)) { selectedTabRawValue = tab.rawValue }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? tab.tint : Color.secondary)
                    .frame(width: 20, height: 22)
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? tab.tint.opacity(0.10) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? tab.tint.opacity(0.38) : Color.primary.opacity(0.055), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Claude \(tab.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Code owns only application configuration and its fixed product gateway.
/// Node creation, runtime state and upstream credentials live in the Node tab.
private struct ClaudeCodeRoutingView: View {
    @ObservedObject private var gateway = GlobalProxyManager.claude
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    @State private var showSettingsEditor = false
    @State private var showSettingsHelp = false
    @State private var showModelHelp = false
    @State private var selectedNodeID = ""
    @State private var showAllCodeModels = false
    @State private var effortLevel: ClaudeCodePersistentEffort = .auto
    @State private var effortError: String?

    private var nodes: [GlobalProxyNodeRef] { gateway.availableNodes() }

    private var resolvedNodeID: String? {
        if gateway.isRuntimeEnabled,
           let active = gateway.activeNodeId,
           nodes.contains(where: { $0.id == active }) { return active }
        if nodes.contains(where: { $0.id == selectedNodeID }) { return selectedNodeID }
        if let active = gateway.activeNodeId,
           nodes.contains(where: { $0.id == active }) { return active }
        return nodes.first?.id
    }

    private var selectedNode: ProxyConfiguration? {
        guard let resolvedNodeID else { return nil }
        return proxyVM.configurations.first(where: { $0.id == resolvedNodeID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 0) {
                    routeStep("terminal", "Claude Code", active: gateway.isEnabled)
                    routeLine
                    routeStep("arrow.triangle.branch", L("Code port :\(gateway.config.port)", "Code 端口 :\(gateway.config.port)"), active: gateway.isProxyRunning)
                    routeLine
                    routeStep("server.rack", gateway.node(for: gateway.activeNodeId)?.name ?? L("Choose Node", "选择节点"), active: gateway.activeNodeId != nil)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.indigo.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.indigo.opacity(0.18)))

                ClaudeGlobalProxySection(selectedNodeId: $selectedNodeID)
                codeModelsCard
                applicationConfigCard
            }
            .frame(maxWidth: 960)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if selectedNodeID.isEmpty { selectedNodeID = resolvedNodeID ?? "" }
            reloadEffortLevel()
        }
        .onChange(of: gateway.activeNodeId) { _, newValue in
            guard let newValue else { return }
            selectedNodeID = newValue
            showAllCodeModels = false
        }
        .onChange(of: gateway.config.effectiveClaudeCodeCatalogMode) { _, _ in
            showAllCodeModels = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadEffortLevel()
        }
        .sheet(isPresented: $showSettingsEditor) {
            LocalSettingsEditorView()
        }
    }

    private func routeStep(_ symbol: String, _ title: String, active: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(active ? Color.indigo : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(active ? Color.indigo.opacity(0.11) : Color.secondary.opacity(0.08)))
    }

    private var routeLine: some View {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).frame(maxWidth: .infinity)
    }

    private var applicationConfigCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.10)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Claude Code configuration", "Claude Code 配置"))
                        .font(.headline)
                    Text("~/.claude/settings.json")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showSettingsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettingsHelp, arrowEdge: .top) {
                    Text(L(
                        "AIUsage manages the Gateway endpoint, model routes and the startup effort default. A running Claude Code session keeps its current effort until you change it inside Claude Code.",
                        "AIUsage 管理 Gateway 地址、模型映射和启动默认强度。正在运行的 Claude Code 会话会保持当前强度，除非你在 Claude Code 内修改。"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: 340)
                }
                Button(L("Edit…", "编辑…")) { showSettingsEditor = true }
                    .buttonStyle(.bordered)
            }

            Divider()
            effortControl
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06)))
    }

    private var effortControl: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.indigo.opacity(0.10)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Default effort", "默认思考强度"))
                        .font(.caption.weight(.semibold))
                    Text(L(
                        "Takes effect the next time Claude Code starts · does not change the current session",
                        "下次启动 Claude Code 时生效 · 不会改变当前会话"
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("", selection: Binding(
                    get: { effortLevel },
                    set: { saveEffortLevel($0) }
                )) {
                    ForEach(ClaudeCodePersistentEffort.allCases) { level in
                        Text(effortTitle(level)).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)
            }

            if let effortError {
                Label(effortError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func effortTitle(_ level: ClaudeCodePersistentEffort) -> String {
        switch level {
        case .auto: return L("Auto", "自动")
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
    }

    private func reloadEffortLevel() {
        do {
            effortLevel = try ClaudeSettingsManager.shared.readPersistentEffort()
            effortError = nil
        } catch {
            effortError = error.localizedDescription
        }
    }

    private func saveEffortLevel(_ level: ClaudeCodePersistentEffort) {
        do {
            try ClaudeSettingsManager.shared.writePersistentEffort(level)
            effortLevel = level
            effortError = nil
        } catch {
            let failure = error.localizedDescription
            effortLevel = (try? ClaudeSettingsManager.shared.readPersistentEffort()) ?? .auto
            effortError = failure
        }
    }

    private var codeModelsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.indigo.opacity(0.11)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Code models", "Code 模型"))
                        .font(.headline)
                    Text(L(
                        "Application routes for the selected node",
                        "当前节点在 Code 中使用的应用侧路由"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let selectedNode {
                    Text(L(
                        "\(selectedNode.runtimeModelCatalog.count) models",
                        "\(selectedNode.runtimeModelCatalog.count) 个模型"
                    ))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.indigo.opacity(0.10)))
                }
                Button { showModelHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showModelHelp, arrowEdge: .top) {
                    codeModelHelpPopover
                }
            }

            ClaudeModelModeSelector(
                selection: gateway.config.effectiveClaudeCodeCatalogMode,
                brand: .indigo,
                nodeModelsDetail: L("Real names · restart Code", "真实名称 · 需重启 Code"),
                isDisabled: gateway.isBusy,
                onSelect: { mode in
                    Task { await gateway.updateClaudeCodeCatalogMode(mode) }
                }
            )

            Label(
                gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes
                    ? L(
                        "Claude Code saves stable AIUsage routes; the Gateway can change the real model without restarting the session.",
                        "Claude Code 只保存稳定的 AIUsage 路由；Gateway 可替换右侧真实模型，无需重启会话。"
                    )
                    : L(
                        "Claude Code sees real node model names. Restart Code after changing this catalog or its startup model.",
                        "Claude Code 会看到节点真实模型名；修改模型库或启动模型后需重启 Code。"
                    ),
                systemImage: gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes
                    ? "arrow.triangle.2.circlepath"
                    : "arrow.clockwise"
            )
            .font(.caption)
            .foregroundStyle(gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes ? Color.indigo : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.indigo.opacity(gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes ? 0.07 : 0.035))
            )

            if let node = selectedNode {
                let nodeDefaults = ClaudeAppResolvedModels(
                    defaultModel: node.defaultModel,
                    opus: node.modelMapping.bigModel.name,
                    sonnet: node.modelMapping.middleModel.name,
                    haiku: node.modelMapping.smallModel.name
                )
                let resolved = gateway.config.effectiveClaudeCodeModels(for: node)
                ClaudeModelRouteBoard(
                    productName: "Code",
                    brand: .indigo,
                    showsStableRouteNames: gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes,
                    catalog: node.runtimeModelCatalog,
                    nodeDefaults: nodeDefaults,
                    resolved: resolved,
                    overrides: gateway.config.claudeCodeModelOverride(for: node.id),
                    isDisabled: gateway.isBusy,
                    onSelect: { route, model in
                        Task {
                            await gateway.updateClaudeCodeModelOverride(
                                nodeID: node.id,
                                route: route,
                                model: model
                            )
                        }
                    },
                    onReset: {
                        Task { await gateway.resetClaudeCodeModelOverrides(nodeID: node.id) }
                    }
                )

                catalogLabel(
                    gateway.config.effectiveClaudeCodeCatalogMode == .smartRoutes
                        ? L("Models available for route mapping", "可用于映射的节点模型")
                        : L("Real model names discovered by Code", "Code 可发现的真实模型")
                )

                ClaudeModelCatalogGrid(
                    items: node.runtimeModelCatalog.map { model in
                        ClaudeModelCatalogItem(
                            id: model,
                            title: model,
                            help: model,
                            isDefault: model == resolved.defaultModel
                        )
                    },
                    brand: .indigo,
                    showAll: $showAllCodeModels
                )
            } else {
                Text(L(
                    "Choose a node with a configured Model Library.",
                    "请选择已配置模型库的节点。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func catalogLabel(_ title: String) -> some View {
        Label(title, systemImage: "list.bullet.rectangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var codeModelHelpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Code model ownership", "Code 模型归属"))
                .font(.headline)
            Label(
                L(
                    "Node defaults are shared and are never changed here.",
                    "节点默认配置仍由 Node 管理，此处不会修改。"
                ),
                systemImage: "server.rack"
            )
            Label(
                L(
                    "A Code override is stored only for this node and takes effect in the Code Gateway immediately.",
                    "Code 覆盖只属于当前节点的 Code 路由，并立即应用到 Code 网关。"
                ),
                systemImage: "terminal"
            )
            Label(
                L(
                    "Reset removes every override and follows the node defaults again.",
                    "恢复默认会删除覆盖，重新跟随节点配置。"
                ),
                systemImage: "arrow.counterclockwise"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

struct ClaudeDesktopIntegrationView: View {
    static let brand = Color(red: 0.78, green: 0.35, blue: 0.24)

    @ObservedObject private var manager = ClaudeDesktopIntegrationManager.shared
    @ObservedObject private var gateway = GlobalProxyManager.desktop
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    @State private var selectedNodeID = ""
    @State private var showConnectionHelp = false
    @State private var showModelModeHelp = false
    @State private var showModelManager = false
    @State private var isModelManagerHovered = false
    @State private var desktopPortDraft = ""
    @State private var portSaveMessage: String?
    @State private var portSaveError: String?
    @State private var pendingCatalogMode: ClaudeDesktopCatalogMode?
    @State private var showAllDesktopModels = false
    @FocusState private var isPortFieldFocused: Bool

    private var nodes: [GlobalProxyNodeRef] { gateway.availableNodes() }

    private var resolvedNodeID: String? {
        if nodes.contains(where: { $0.id == selectedNodeID }) { return selectedNodeID }
        if let active = gateway.activeNodeId, nodes.contains(where: { $0.id == active }) { return active }
        return nodes.first?.id
    }

    private var selectedNode: ProxyConfiguration? {
        guard let id = resolvedNodeID else { return nil }
        return proxyVM.configurations.first(where: { $0.id == id })
    }

    private var catalogMode: ClaudeDesktopCatalogMode {
        gateway.config.effectiveClaudeDesktopCatalogMode
    }

    private var previewModels: [ClaudeDesktopCatalogEntry] {
        if manager.isConfigured, !manager.configuredModels.isEmpty { return manager.configuredModels }
        guard let selectedNode else { return [] }
        return ClaudeDesktopProfileStore.catalog(
            for: selectedNode,
            mode: catalogMode,
            supports1M: gateway.config.claudeDesktopSupports1MModels(for: selectedNode.id),
            routes: gateway.config.effectiveClaudeDesktopModels(for: selectedNode)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                if nodes.isEmpty { noNodesCard }
                modelCard
                desktopPortCard
            }
            .frame(maxWidth: 900)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            manager.refreshInstallation()
            if selectedNodeID.isEmpty { selectedNodeID = resolvedNodeID ?? "" }
            if desktopPortDraft.isEmpty { syncDesktopPortDraft() }
        }
        .onChange(of: gateway.activeNodeId) { _, newValue in
            guard let newValue else { return }
            selectedNodeID = newValue
            showAllDesktopModels = false
        }
        .onChange(of: catalogMode) { _, _ in showAllDesktopModels = false }
        .onChange(of: gateway.config.effectiveClaudeDesktopHTTPSPort) { _, _ in
            if !isPortFieldFocused { syncDesktopPortDraft() }
        }
        .confirmationDialog(
            L("Change the Desktop model mode?", "切换 Desktop 模型模式？"),
            isPresented: Binding(
                get: { pendingCatalogMode != nil },
                set: { if !$0 { pendingCatalogMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(catalogModeConfirmationTitle) {
                guard let mode = pendingCatalogMode else { return }
                pendingCatalogMode = nil
                Task { await gateway.updateClaudeDesktopCatalogMode(mode) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingCatalogMode = nil
            }
        } message: {
            Text(catalogModeConfirmationMessage)
        }
        .sheet(isPresented: $showModelManager) {
            if let selectedNode {
                ClaudeDesktopModelManagerSheet(node: selectedNode)
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Self.brand.opacity(0.12))
                    Image(systemName: "macwindow")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(Self.brand)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Claude Desktop")
                            .font(.title3.weight(.bold))
                        Text("v\(manager.versionLabel)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.10)))
                    }
                    Text(L(
                        "Gateway routes and models",
                        "Gateway 路由与模型"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                statusBadge
            }

            sharedRoute

            HStack(spacing: 10) {
                primaryButton
                if manager.installation.isInstalled {
                    Button {
                        Task { await manager.openClaudeDesktop() }
                    } label: {
                        Label(L("Open Claude", "打开 Claude"), systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                    .disabled(manager.isBusy)
                }
                Spacer(minLength: 0)
            }

            stateMessage
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusColor.opacity(manager.isConfigured ? 0.45 : 0.12), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: manager.state)
    }

    private var sharedRoute: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    L("Desktop Gateway route", "Desktop 独立网关路由"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                GlobalProxyChipMenu(
                    brand: Self.brand,
                    title: nodes.first(where: { $0.id == resolvedNodeID })?.name ?? L("Choose node", "选择节点"),
                    systemImage: "bolt.fill",
                    isDisabled: manager.isBusy || nodes.isEmpty,
                    items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                    selectedId: resolvedNodeID ?? "",
                    onSelect: selectNode
                )
            }

            HStack(spacing: 0) {
                routeEndpoint(icon: "macwindow", title: "Desktop", active: manager.isConfigured)
                routeLine
                routeEndpoint(icon: "lock.shield.fill", title: ":\(gateway.config.effectiveClaudeDesktopHTTPSPort)", active: manager.isConfigured)
                routeLine
                routeEndpoint(icon: "server.rack", title: selectedNode?.name ?? L("Claude node", "Claude 节点"), active: selectedNode != nil)
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.primary.opacity(0.035)))
    }

    private func routeEndpoint(icon: String, title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(active ? Self.brand : Color.secondary)
            Text(title)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Capsule().fill(active ? Self.brand.opacity(0.10) : Color.secondary.opacity(0.08)))
    }

    private var routeLine: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var statusBadge: some View {
        Label(statusTitle, systemImage: statusSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(statusColor.opacity(0.11)))
    }

    @ViewBuilder
    private var primaryButton: some View {
        if manager.isConfigured {
            Button {
                Task { await manager.disconnect() }
            } label: {
                Label(
                    manager.isBusy ? L("Working…", "处理中…") : L("Disconnect & Restore", "断开并恢复"),
                    systemImage: "arrow.uturn.backward"
                )
                .frame(minWidth: 155)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(manager.isBusy)
        } else {
            Button {
                guard let nodeID = resolvedNodeID else { return }
                Task { await manager.connect(activeNodeId: nodeID) }
            } label: {
                Label(
                    manager.isBusy ? L("Connecting…", "正在连接…") : L("Connect to Desktop", "一键接入 Desktop"),
                    systemImage: "bolt.horizontal.fill"
                )
                .frame(minWidth: 155)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Self.brand)
            .disabled(manager.isBusy || resolvedNodeID == nil || !manager.installation.isInstalled)
        }
    }

    @ViewBuilder
    private var stateMessage: some View {
        switch manager.state {
        case .unavailable:
            messageRow(
                symbol: "exclamationmark.triangle.fill",
                text: L("Claude Desktop was not found in Applications.", "未在「应用程序」中找到 Claude Desktop。"),
                color: .orange
            )
        case .disconnected, .ready, .connected:
            EmptyView()
        case .preparing(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        case .conflict(let text):
            messageRow(symbol: "hand.raised.fill", text: text, color: .orange)
        case .failed(let text):
            messageRow(symbol: "xmark.octagon.fill", text: text, color: .red)
        }
    }

    private func messageRow(symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L("Desktop models", "Desktop 模型"))
                    .font(.headline)
                Spacer(minLength: 8)
                if !previewModels.isEmpty {
                    Label("\(previewModels.count)", systemImage: "square.stack.3d.up")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L("Models", "模型数"))
                    let contextCount = previewModels.filter(\.supports1M).count
                    if contextCount > 0 {
                        Text("\(contextCount) × 1M")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    showModelModeHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Model modes", "模型模式说明"))
                .popover(isPresented: $showModelModeHelp, arrowEdge: .top) {
                    modelModeHelpPopover
                }
            }

            catalogModeSelector

            if catalogMode == .smartRoutes, let node = selectedNode {
                let nodeDefaults = ClaudeAppResolvedModels(
                    defaultModel: node.defaultModel,
                    opus: node.modelMapping.bigModel.name,
                    sonnet: node.modelMapping.middleModel.name,
                    haiku: node.modelMapping.smallModel.name
                )
                ClaudeModelRouteBoard(
                    productName: "Desktop",
                    brand: Self.brand,
                    catalog: node.runtimeModelCatalog,
                    nodeDefaults: nodeDefaults,
                    resolved: gateway.config.effectiveClaudeDesktopModels(for: node),
                    overrides: gateway.config.claudeDesktopModelOverride(for: node.id),
                    isDisabled: gateway.isBusy || manager.isBusy,
                    onSelect: { route, model in
                        Task {
                            await gateway.updateClaudeDesktopModelOverride(
                                nodeID: node.id,
                                route: route,
                                model: model
                            )
                        }
                    },
                    onReset: {
                        Task { await gateway.resetClaudeDesktopModelOverrides(nodeID: node.id) }
                    }
                )
            }

            if previewModels.isEmpty {
                Text(L("Choose a node with a configured Model Library.", "请选择已配置模型库的节点。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                displayNamePreview
            }

            ClaudeEffortOwnershipRow(
                productName: "Desktop",
                brand: Self.brand,
                detail: L(
                    "Choose effort and Thinking in Desktop's model menu",
                    "请在 Desktop 的模型菜单中选择 Effort 与 Thinking"
                )
            )

            modelManagerButton
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var catalogModeSelector: some View {
        ClaudeModelModeSelector(
            selection: catalogMode,
            brand: Self.brand,
            nodeModelsDetail: L("Real names · reload Desktop", "真实名称 · 重载 Desktop"),
            isDisabled: gateway.isBusy || manager.isBusy,
            onSelect: requestCatalogMode
        )
    }

    private func requestCatalogMode(_ mode: ClaudeDesktopCatalogMode) {
        guard mode != catalogMode else { return }
        if manager.isConfigured {
            pendingCatalogMode = mode
        } else {
            Task { await gateway.updateClaudeDesktopCatalogMode(mode) }
        }
    }

    private var modelModeHelpPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Desktop model modes", "Desktop 模型模式"))
                .font(.headline)
            helpItem(
                symbol: "arrow.triangle.2.circlepath",
                title: L("Hot switch", "热切换"),
                detail: L(
                    "Desktop keeps four stable routes. Each can follow the node or use a Desktop-only override; node switches stay live.",
                    "Desktop 保留四条固定路由；每条都可跟随节点或使用 Desktop 独立覆盖，切换节点仍无需重启。"
                )
            )
            helpItem(
                symbol: "square.stack.3d.up",
                title: L("Node models", "节点模型"),
                detail: L(
                    "Desktop shows the selected node's real model names. AIUsage reloads Desktop when the visible catalog changes.",
                    "Desktop 显示所选节点的真实模型名称；可见目录变化时，AIUsage 会重载 Desktop。"
                )
            )
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
    }

    private var catalogModeConfirmationTitle: String {
        pendingCatalogMode == .smartRoutes
            ? L("Use hot switch", "使用热切换")
            : L("Show node models", "显示节点模型")
    }

    private var catalogModeConfirmationMessage: String {
        pendingCatalogMode == .smartRoutes
            ? L(
                "Desktop reloads once. Later node switches stay live.",
                "Desktop 将重载一次；之后切换节点无需重启。"
            )
            : L(
                "Desktop reloads now and whenever its visible model list changes.",
                "Desktop 现在会重载；以后可见模型列表变化时也会自动重载。"
            )
    }

    private var displayNamePreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.brand)
                Group {
                    if catalogMode == .smartRoutes {
                        Text(L("Stable route → active model", "固定路由 → 当前模型"))
                    } else {
                        Text(L("Desktop model → selected node", "Desktop 模型 → 当前节点"))
                    }
                }
                .font(.caption.weight(.semibold))
                Spacer()
            }

            ClaudeModelCatalogGrid(
                items: previewModels.map { model in
                    ClaudeModelCatalogItem(
                        id: model.id,
                        title: model.displayName,
                        subtitle: model.upstreamModel,
                        badge: model.supports1M ? "1M" : nil,
                        help: model.displayName == model.upstreamModel
                            ? model.displayName
                            : "\(model.displayName) → \(model.upstreamModel)",
                        isDefault: catalogMode == .smartRoutes
                            ? model.id == ClaudeDesktopProfileStore.defaultRouteID
                            : model.upstreamModel == selectedNode?.defaultModel
                    )
                },
                brand: Self.brand,
                showAll: $showAllDesktopModels
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelManagerButton: some View {
        Button {
            showModelManager = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Self.brand)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Self.brand.opacity(isModelManagerHovered ? 0.16 : 0.11))
                    )

                Text(L("Model settings", "模型设置"))
                    .font(.callout.weight(.semibold))

                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isModelManagerHovered ? Self.brand : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isModelManagerHovered ? Self.brand.opacity(0.055) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isModelManagerHovered ? Self.brand.opacity(0.30) : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedNode == nil)
        .opacity(selectedNode == nil ? 0.55 : 1)
        .onHover { isModelManagerHovered = $0 }
        .accessibilityHint(L(
            "Shows the current Desktop catalog and model capabilities.",
            "查看当前 Desktop 模型目录与模型能力。"
        ))
    }

    private var desktopPortCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "number.square.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.brand)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Self.brand.opacity(0.11)))
                Text(L("Desktop HTTPS port", "Desktop HTTPS 端口"))
                    .font(.headline)
                Spacer(minLength: 12)
                Button {
                    showConnectionHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Connection details", "接入说明"))
                .popover(isPresented: $showConnectionHelp, arrowEdge: .top) {
                    connectionHelpPopover
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Port", "端口"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("14403", text: $desktopPortDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.leading)
                        .frame(width: 118)
                        .focused($isPortFieldFocused)
                        .disabled(manager.isConfigured || manager.isBusy)
                        .onChange(of: desktopPortDraft) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(5))
                            if filtered != newValue { desktopPortDraft = filtered }
                            portSaveMessage = nil
                            portSaveError = nil
                        }
                }

                if manager.isConfigured {
                    Label(L("Attached", "接入中"), systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Self.brand.opacity(0.10)))
                        .padding(.bottom, 2)
                }

                Spacer(minLength: 4)

                if !manager.isConfigured {
                    Button(L("Restore default", "恢复默认")) {
                        desktopPortDraft = String(GlobalProxyConfig.defaultClaudeDesktopHTTPSPort)
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isBusy)

                    Button(L("Save", "保存")) {
                        saveDesktopPort()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Self.brand)
                    .disabled(!canSaveDesktopPort)
                }
            }

            if manager.isConfigured {
                EmptyView()
            } else if let portValidationMessage {
                inlinePortMessage(symbol: "exclamationmark.triangle.fill", text: portValidationMessage, color: .orange)
            } else if let portSaveError {
                inlinePortMessage(symbol: "xmark.circle.fill", text: portSaveError, color: .red)
            } else if let portSaveMessage {
                inlinePortMessage(symbol: "checkmark.circle.fill", text: portSaveMessage, color: .green)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var connectionHelpPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("About Desktop access", "关于 Desktop 接入"))
                .font(.headline)

            helpItem(
                symbol: "poweron",
                title: L("After restarting AIUsage", "AIUsage 重启后"),
                detail: L(
                    "An attached Desktop profile automatically restores its localhost HTTPS port. Attached means the profile and port are ready; Connected means a real Desktop request was observed during this launch.",
                    "已接入的 Desktop 会自动恢复本机 HTTPS 端口。“已接入”表示配置与端口就绪；“已连接”表示本次启动后已收到 Desktop 的真实请求。"
                )
            )

            helpItem(
                symbol: "shield.lefthalf.filled",
                title: L("Security boundary", "安全边界"),
                detail: L(
                    "The endpoint listens on localhost only, uses a dedicated Desktop key, and never exposes your upstream API key.",
                    "入口仅监听本机，使用 Desktop 独立密钥，不会向 Desktop 暴露上游 API Key。"
                )
            )

            helpItem(
                symbol: "arrow.uturn.backward",
                title: L("When you disconnect", "断开时会做什么"),
                detail: L(
                    "AIUsage restores the previous profile, closes only the Desktop gateway, and quits Desktop without reopening it. Code and Science are independent.",
                    "AIUsage 会恢复接入前配置，仅关闭 Desktop 网关，并退出 Desktop 且不再重开；Code 与 Science 不受影响。"
                )
            )

            Text(manager.endpointLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
    }

    private func helpItem(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.brand)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inlinePortMessage(symbol: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var parsedDesktopPort: Int? { Int(desktopPortDraft) }

    private var portValidationMessage: String? {
        guard let port = parsedDesktopPort else {
            return L("Enter a port from 1024 to 65535.", "请输入 1024 到 65535 之间的端口。")
        }
        guard (1_024...65_535).contains(port) else {
            return L("Port must be between 1024 and 65535.", "端口必须在 1024 到 65535 之间。")
        }
        guard port != gateway.config.port else {
            return L("Desktop HTTPS cannot share its internal gateway port.", "Desktop HTTPS 不能与内部网关端口相同。")
        }
        if let conflict = ProxyPortArbiter.conflict(
            forPorts: [port],
            excluding: "claude-desktop-port-settings"
        ) {
            let owner = conflict.label.isEmpty ? conflict.track : "\(conflict.track) · \(conflict.label)"
            return L(
                "Port \(port) is already used by \(owner).",
                "端口 \(port) 已被 \(owner) 使用。"
            )
        }
        return nil
    }

    private var canSaveDesktopPort: Bool {
        !manager.isConfigured
            && !manager.isBusy
            && portValidationMessage == nil
            && parsedDesktopPort != gateway.config.effectiveClaudeDesktopHTTPSPort
    }

    private func syncDesktopPortDraft() {
        desktopPortDraft = String(gateway.config.effectiveClaudeDesktopHTTPSPort)
        portSaveMessage = nil
        portSaveError = nil
    }

    private func saveDesktopPort() {
        guard let port = parsedDesktopPort, portValidationMessage == nil else { return }
        if gateway.updateClaudeDesktopHTTPSPort(port) {
            desktopPortDraft = String(port)
            portSaveError = nil
            portSaveMessage = L("Port saved. Desktop will use it on the next connection.", "端口已保存，下次接入 Desktop 时生效。")
        } else {
            portSaveMessage = nil
            portSaveError = gateway.operationError
                ?? L("Disconnect Desktop before changing this port.", "请先断开 Desktop，再修改端口。")
        }
    }

    private var noNodesCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.orange)
            Text(L(
                "No Claude node is available. Add one in the Node tab first.",
                "暂无可用的 Claude 节点，请先在 Node 页签添加。"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.08)))
    }

    private func selectNode(_ nodeID: String) {
        selectedNodeID = nodeID
        showAllDesktopModels = false
        if manager.isConfigured {
            Task { await gateway.switchActiveNode(to: nodeID) }
        }
    }

    private var statusTitle: String {
        switch manager.state {
        case .unavailable: return L("Not installed", "未安装")
        case .disconnected: return L("Not connected", "未接入")
        case .preparing: return L("Preparing", "准备中")
        case .ready: return L("Attached", "已接入")
        case .connected: return L("Connected", "已连接")
        case .conflict: return L("Protected", "已保护")
        case .failed: return L("Needs attention", "需要处理")
        }
    }

    private var statusSymbol: String {
        switch manager.state {
        case .connected: return "checkmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .preparing: return "arrow.triangle.2.circlepath"
        case .conflict: return "hand.raised.fill"
        case .failed: return "exclamationmark.octagon.fill"
        case .unavailable: return "app.dashed"
        case .disconnected: return "circle"
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .connected: return .green
        case .ready: return Self.brand
        case .preparing: return .orange
        case .conflict: return .orange
        case .failed: return .red
        case .unavailable, .disconnected: return .secondary
        }
    }
}

private struct ClaudeDesktopModelManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gateway = GlobalProxyManager.desktop
    let node: ProxyConfiguration

    @State private var searchText = ""
    @State private var enabled1M: Set<String> = []
    @State private var showHelp = false

    private var catalog: [ClaudeDesktopCatalogEntry] {
        ClaudeDesktopProfileStore.catalog(
            for: node,
            mode: gateway.config.effectiveClaudeDesktopCatalogMode,
            supports1M: enabled1M,
            routes: gateway.config.effectiveClaudeDesktopModels(for: node)
        )
    }

    private var filteredCatalog: [ClaudeDesktopCatalogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog }
        return catalog.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.upstreamModel.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            searchBar
            modelList
            Divider()
            footer
        }
        .frame(width: 720, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            enabled1M = gateway.config.claudeDesktopSupports1MModels(for: node.id)
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "macwindow.and.cursorarrow")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ClaudeDesktopIntegrationView.brand)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(ClaudeDesktopIntegrationView.brand.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(gateway.config.effectiveClaudeDesktopCatalogMode == .smartRoutes
                    ? L("Desktop hot-switch tiers", "Desktop 热切换三档")
                    : L("All node models", "节点全部模型"))
                    .font(.title3.weight(.bold))
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Model settings help", "模型设置说明"))
            .popover(isPresented: $showHelp, arrowEdge: .top) {
                modelHelpPopover
            }
            Button(L("Done", "完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var searchBar: some View {
        TextField(L("Search models", "搜索模型"), text: $searchText)
            .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredCatalog) { model in
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ClaudeDesktopIntegrationView.brand)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(ClaudeDesktopIntegrationView.brand.opacity(0.10)))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.displayName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            if model.displayName != model.upstreamModel {
                                Text(L("Current target · \(model.upstreamModel)", "当前目标 · \(model.upstreamModel)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            Text("Model ID · \(model.id)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 12)
                        Toggle("1M", isOn: Binding(
                            get: { enabled1M.contains(model.upstreamModel) },
                            set: { enabled in
                                if enabled {
                                    enabled1M.insert(model.upstreamModel)
                                } else {
                                    enabled1M.remove(model.upstreamModel)
                                }
                                Task {
                                    let saved = await gateway.updateClaudeDesktopSupports1M(
                                        nodeID: node.id,
                                        modelID: model.upstreamModel,
                                        enabled: enabled
                                    )
                                    if !saved {
                                        if enabled {
                                            enabled1M.remove(model.upstreamModel)
                                        } else {
                                            enabled1M.insert(model.upstreamModel)
                                        }
                                    }
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(gateway.isBusy)
                        .accessibilityLabel(L(
                            "Offer 1M-context variant for \(model.displayName)",
                            "为 \(model.displayName) 提供 1M 上下文版本"
                        ))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.primary.opacity(0.055), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .overlay {
            if filteredCatalog.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(gateway.config.effectiveClaudeDesktopCatalogMode == .smartRoutes
                 ? L("Hot switch", "热切换")
                 : L("Node models", "节点模型"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(L("\(catalog.count) models", "\(catalog.count) 个模型"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var modelHelpPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Model settings", "模型设置"))
                .font(.headline)
            Text(gateway.config.effectiveClaudeDesktopCatalogMode == .smartRoutes
                 ? L(
                    "Three stable model IDs are remapped inside Gateway. Ordinary node switches stay live.",
                    "三条固定模型 ID 在 Gateway 内完成映射，普通切换节点无需重启。"
                 )
                 : L(
                    "Desktop shows this node's real model names. Visible catalog changes reload Desktop.",
                    "Desktop 显示此节点的真实模型名称；可见目录变化时会重载 Desktop。"
                 ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("1M")
                .font(.caption.weight(.semibold))
            Text(L(
                "Enable only for targets that truly support a 1M context window. Capability changes refresh Desktop automatically.",
                "仅为确实支持 1M 上下文的目标开启；能力变化会自动刷新 Desktop。"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }
}
