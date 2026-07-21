import SwiftUI
import AppKit

enum ClaudeHubTab: String, CaseIterable, Identifiable {
    case code
    case desktop
    case science

    var id: String { rawValue }

    var title: String {
        switch self {
        case .code: return "Code"
        case .desktop: return "Desktop"
        case .science: return "Science"
        }
    }

    var symbol: String {
        switch self {
        case .code: return "terminal"
        case .desktop: return "macwindow"
        case .science: return "atom"
        }
    }

    var subtitle: String {
        switch self {
        case .code: return L("Proxy & nodes", "代理与节点")
        case .desktop: return L("Desktop access", "桌面端接入")
        case .science: return L("Research workspace", "研究工作台")
        }
    }

    var tint: Color {
        switch self {
        case .code: return .indigo
        case .desktop: return ClaudeDesktopIntegrationView.brand
        case .science: return ScienceProxyManagementView.brand
        }
    }
}

/// One Claude ecosystem entry in the sidebar. Code and Desktop share the same
/// gateway/node pool; Science remains an intentionally isolated runtime.
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
                case .code:
                    ProxyManagementView()
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
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude")
                    .font(.system(size: 23, weight: .bold))
                Text(L(
                    "One node library · Code, Desktop and Science",
                    "一套节点库 · Code、Desktop 与 Science"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 220, alignment: .leading)

            HStack(spacing: 7) {
                ForEach(ClaudeHubTab.allCases) { tab in
                    productButton(tab)
                }
            }
            .frame(maxWidth: 570)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
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
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? tab.tint : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? tab.tint.opacity(0.14) : Color.primary.opacity(0.045))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(tab.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? tab.tint.opacity(0.28) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tab.title), \(tab.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ClaudeDesktopIntegrationView: View {
    static let brand = Color(red: 0.78, green: 0.35, blue: 0.24)

    @ObservedObject private var manager = ClaudeDesktopIntegrationManager.shared
    @ObservedObject private var gateway = GlobalProxyManager.claude
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    @State private var selectedNodeID = ""
    @State private var showConnectionHelp = false
    @State private var showModelManager = false
    @State private var isModelManagerHovered = false
    @State private var desktopPortDraft = ""
    @State private var portSaveMessage: String?
    @State private var portSaveError: String?
    @State private var pendingSharedRouteNodeID: String?
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

    private var previewModels: [ClaudeDesktopCatalogEntry] {
        if manager.isConfigured, !manager.configuredModels.isEmpty { return manager.configuredModels }
        guard let selectedNode else { return [] }
        return ClaudeDesktopProfileStore.catalog(
            for: selectedNode,
            supports1M: gateway.config.claudeDesktopSupports1MModels(for: selectedNode.id)
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
        }
        .onChange(of: gateway.config.effectiveClaudeDesktopHTTPSPort) { _, _ in
            if !isPortFieldFocused { syncDesktopPortDraft() }
        }
        .confirmationDialog(
            L("Switch the shared Claude route?", "切换 Claude 共享路由？"),
            isPresented: Binding(
                get: { pendingSharedRouteNodeID != nil },
                set: { if !$0 { pendingSharedRouteNodeID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(sharedRouteSwitchButtonTitle) {
                guard let nodeID = pendingSharedRouteNodeID else { return }
                selectedNodeID = nodeID
                pendingSharedRouteNodeID = nil
                Task { await gateway.switchActiveNode(to: nodeID) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingSharedRouteNodeID = nil
            }
        } message: {
            Text(sharedRouteSwitchMessage)
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
                        "Stable Opus, Sonnet and Haiku routes switch upstream nodes instantly inside the Gateway.",
                        "Desktop 使用固定的 Opus、Sonnet、Haiku 路由；切换节点只在 Gateway 内即时生效。"
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
                    gateway.config.effectiveClaudeCodeEnabled
                        ? L("Shared Code + Desktop route", "Code + Desktop 共享路由")
                        : L("Desktop Gateway route", "Desktop Gateway 路由"),
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
                routeEndpoint(icon: "server.rack", title: selectedNode?.name ?? L("Claude node", "Claude 节点"), active: selectedNode != nil)
                routeLine
                routeEndpoint(icon: "lock.shield.fill", title: "HTTPS", active: manager.isConfigured)
                routeLine
                routeEndpoint(icon: "macwindow", title: "Desktop", active: manager.isConfigured)
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
            Text(L("Desktop Gateway routes", "Desktop Gateway 路由"))
                .font(.headline)

            if previewModels.isEmpty {
                Text(L("Choose a node with a configured Model Library.", "请选择已配置模型库的节点。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 10) {
                    catalogMetric(
                        value: "\(previewModels.count)",
                        label: L("Models", "模型"),
                        symbol: "square.stack.3d.up"
                    )
                    catalogMetric(
                        value: "\(previewModels.filter(\.supports1M).count)",
                        label: L("1M enabled", "已启用 1M"),
                        symbol: "text.line.first.and.arrowtriangle.forward"
                    )
                    Spacer(minLength: 0)
                }

                displayNamePreview
            }

            modelManagerButton
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var displayNamePreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "textformat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.brand)
                Text(L("Stable route → active model", "固定路由 → 当前模型"))
                    .font(.caption.weight(.semibold))
                Spacer()
                if previewModels.count > 3 {
                    Text(L(
                        "+\(previewModels.count - 3) more",
                        "另有 \(previewModels.count - 3) 个"
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(previewModels.prefix(3).enumerated()), id: \.element.id) { index, model in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(Self.brand.opacity(0.75))
                            .frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("→ \(model.upstreamModel)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)

                    if index < min(previewModels.count, 3) - 1 {
                        Divider().opacity(0.55)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
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
            "Shows the stable Desktop routes and their current upstream mappings.",
            "查看固定 Desktop 路由及其当前上游映射。"
        ))
    }

    private func catalogMetric(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(Self.brand)
                .frame(width: 25, height: 25)
                .background(RoundedRectangle(cornerRadius: 7).fill(Self.brand.opacity(0.11)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline.monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 112, minHeight: 58, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
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
                    "AIUsage restores the previous profile, closes the Desktop HTTPS listener, and quits Desktop without reopening it. Claude Code remains available when enabled.",
                    "AIUsage 会恢复接入前配置、关闭 Desktop HTTPS 监听，并退出 Desktop 且不再重开；已启用的 Claude Code 不受影响。"
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
            return L("Desktop HTTPS cannot share Claude Code's HTTP port.", "Desktop HTTPS 不能与 Claude Code 的 HTTP 端口相同。")
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
            portSaveError = L("Disconnect Desktop before changing this port.", "请先断开 Desktop，再修改端口。")
        }
    }

    private var noNodesCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.orange)
            Text(L(
                "No Claude proxy node is available. Add one in the Code tab first.",
                "暂无可用的 Claude 代理节点，请先在 Code 页签添加。"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.08)))
    }

    private func selectNode(_ nodeID: String) {
        if gateway.config.effectiveClaudeCodeEnabled,
           nodeID != gateway.activeNodeId {
            pendingSharedRouteNodeID = nodeID
            return
        }
        selectedNodeID = nodeID
        if manager.isConfigured {
            Task { await gateway.switchActiveNode(to: nodeID) }
        }
    }

    private var sharedRouteSwitchButtonTitle: String {
        manager.isConfigured
            ? L("Switch Code + Desktop", "同时切换 Code + Desktop")
            : L("Switch Code route", "切换 Code 路由")
    }

    private var sharedRouteSwitchMessage: String {
        manager.isConfigured
            ? L(
                "Claude Code is attached to this Gateway too. Both products will use the new node immediately.",
                "Claude Code 也已接入此 Gateway；切换后两端会立即改用新节点。"
            )
            : L(
                "Desktop will join Claude Code's Gateway route. Selecting another node changes Code immediately; Desktop will use it after connection.",
                "Desktop 将加入 Claude Code 当前的 Gateway 路由。选择其它节点会立即切换 Code；接入后 Desktop 也会使用该节点。"
            )
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
    @ObservedObject private var gateway = GlobalProxyManager.claude
    let node: ProxyConfiguration

    @State private var searchText = ""
    @State private var enabled1M: Set<String> = []

    private var catalog: [ClaudeDesktopCatalogEntry] {
        ClaudeDesktopProfileStore.catalog(for: node, supports1M: enabled1M)
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
                Text(L("Desktop Gateway routes", "Desktop Gateway 路由"))
                    .font(.title3.weight(.bold))
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Done", "完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(
                "Claude Desktop keeps these three route IDs. AIUsage remaps each route to the selected node inside the Gateway, so ordinary node switches do not require a Desktop restart.",
                "Claude Desktop 始终使用这三个固定路由；AIUsage 在 Gateway 内把它们映射到当前节点，普通切换无需重启 Desktop。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField(L("Search route, Model ID or upstream model", "搜索路由、Model ID 或上游模型"), text: $searchText)
                .textFieldStyle(.roundedBorder)
        }
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
                            Text(L("Current target · \(model.upstreamModel)", "当前目标 · \(model.upstreamModel)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
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
                                    await gateway.updateClaudeDesktopSupports1M(
                                        nodeID: node.id,
                                        modelID: model.upstreamModel,
                                        enabled: enabled
                                    )
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(L(
                "Enable 1M only when the current upstream really supports it. Changing visible capability metadata reloads a running Desktop; switching only the upstream route does not.",
                "仅在当前上游确实支持 1M 时开启。可见能力变化会重新加载正在运行的 Desktop；仅切换上游路由不会。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Text(L("\(catalog.count) models", "\(catalog.count) 个模型"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
