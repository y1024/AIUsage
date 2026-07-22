import SwiftUI
import QuotaBackend

// MARK: - Editor Tabs

enum EditorTab: String, CaseIterable {
    case proxy
    case settings
    case json

    var label: String {
        switch self {
        case .proxy: return L("Proxy", "代理设置")
        case .settings: return L("Settings", "可视化配置")
        case .json: return L("JSON", "JSON 编辑")
        }
    }

    var icon: String {
        switch self {
        case .proxy: return "network"
        case .settings: return "slider.horizontal.3"
        case .json: return "curlybraces"
        }
    }
}

private enum NodeEditorSection: String, CaseIterable, Identifiable {
    case identity
    case connection
    case models
    case security

    var id: String { rawValue }
    var title: String {
        switch self {
        case .identity: return L("Identity", "节点身份")
        case .connection: return L("Connection", "连接")
        case .models: return L("Models", "模型能力")
        case .security: return L("Security", "安全")
        }
    }
    var symbol: String {
        switch self {
        case .identity: return "fingerprint"
        case .connection: return "arrow.left.arrow.right"
        case .models: return "square.stack.3d.up"
        case .security: return "lock.shield"
        }
    }
    var help: String {
        switch self {
        case .identity:
            return L("Choose the upstream API protocol and give this reusable node a recognizable name.", "选择上游 API 协议，并为可复用节点设置清晰名称。")
        case .connection:
            return L("Every node owns one fixed local host and port. Code, Desktop and Science connect through their own gateways and share this endpoint.", "每个节点固定占用一个本地主机与端口；Code、Desktop、Science 通过各自网关共享该端点。")
        case .models:
            return L("The library lists exact upstream model IDs and prices. Product gateways resolve aliases before requests arrive here.", "模型库只保存真实上游模型 ID 与价格；模型别名由各应用网关在请求到达节点前解析。")
        case .security:
            return L("The client key protects access to this local node. Upstream credentials remain inside the node process.", "客户端密钥用于保护该本地节点；上游凭据始终留在节点进程内。")
        }
    }
}

// MARK: - Interface Choice
// 接口类型三选一（与 OpenCode 的三卡片一致）。openaiProxy 内部的 Chat/Responses
// 子选项在此被拍平成两张卡，映射到 (nodeType, openAIUpstreamAPI)。
enum ClaudeInterfaceChoice: Hashable {
    case anthropic
    case openAIChatCompletions
    case openAIResponses
}

// MARK: - Proxy Config Editor

struct ProxyConfigEditorView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // 注：部分 @State 为 internal（去掉 private），以便 JSON 标签页/定价子区拆分到
    // ProxyConfigEditorView+JSONTab.swift / +Pricing.swift 后仍可访问（Swift private 为文件级）。
    @State var profile: NodeProfile
    @State private var isNew: Bool
    @State var selectedTab: EditorTab = .proxy
    @StateObject private var modelFetch = ModelFetchState()
    @State var jsonText: String = ""
    @State var jsonError: String?
    @State var finalJSONText: String = ""
    @State var finalJSONError: String?
    @State var globalConfigDraftSettings: [String: Any]?
    @State var isApplyingFinalJSONEdit = false
    @State private var selectedSection: NodeEditorSection = .identity
    @State private var helpSection: NodeEditorSection?
    @State private var isModelLibraryPresented = false

    init(profile: NodeProfile? = nil) {
        if var profile {
            // 旧档案迁移：库为空时用槽位价格播种，打开编辑器即看到完整模型库。
            profile.metadata.proxy.seedModelLibraryIfEmpty()
            _profile = State(initialValue: profile)
            _isNew = State(initialValue: false)
            _jsonText = State(initialValue: profile.settingsJSONString)
            _pricingCurrency = State(initialValue: profile.metadata.proxy.modelLibrary?.first?.pricing.currency
                ?? profile.metadata.proxy.modelMapping.bigModel.pricing.currency)
        } else {
            var newProfile = NodeProfile.defaultProfile()
            newProfile.metadata.proxy.port = NodeProfileStore.shared.nextAvailablePort()
            newProfile.metadata.proxy.seedModelLibraryIfEmpty()
            _profile = State(initialValue: newProfile)
            _isNew = State(initialValue: true)
            _jsonText = State(initialValue: newProfile.settingsJSONString)
            _pricingCurrency = State(initialValue: .usd)
        }
    }

    /// Legacy init wrapping a ProxyConfiguration for callers not yet migrated.
    init(config: ProxyConfiguration) {
        var p = NodeProfile.fromLegacyConfiguration(config)
        p.metadata.proxy.seedModelLibraryIfEmpty()
        _profile = State(initialValue: p)
        _isNew = State(initialValue: false)
        _jsonText = State(initialValue: p.settingsJSONString)
        _pricingCurrency = State(initialValue: p.metadata.proxy.modelLibrary?.first?.pricing.currency
            ?? config.modelMapping.bigModel.pricing.currency)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            proxyTab
            .frame(maxHeight: .infinity)

            Divider()
            footerBar
        }
        .frame(width: 780, height: 620)
        .sheet(isPresented: $isModelLibraryPresented) {
            modelLibrarySheet
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? L("New Node", "新建节点") : L("Edit Node", "编辑节点"))
                        .font(.title2.weight(.bold))
                    Text(L("A reusable protocol endpoint for every Claude product", "供所有 Claude 应用复用的协议端点"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            routePreview
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(EditorTab.allCases, id: \.self) { tab in
                Button {
                    if selectedTab == .json && tab != .json {
                        syncFromJSON()
                    }
                    if tab == .json && selectedTab != .json {
                        syncToJSON()
                    }
                    // 平滑过渡窗口宽度（JSON 双栏 1100 ↔ 表单 750），避免切换时骤变。
                    withAnimation(.easeInOut(duration: 0.28)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                        Text(tab.label)
                    }
                    .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if !isNew {
                Button(L("Delete", "删除"), role: .destructive) {
                    Task {
                        await viewModel.deleteConfiguration(profile.id)
                        dismiss()
                    }
                }
            }
            Spacer()
            Button(L("Cancel", "取消")) { dismiss() }
            Button(isNew ? L("Create", "创建") : L("Save", "保存")) {
                saveProfile()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid || (selectedTab == .json && finalJSONError != nil))
        }
        .padding(16)
    }

    // MARK: - Tab 1: Proxy Settings

    private var proxyTab: some View {
        HStack(spacing: 0) {
            sectionRail
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let providerName = linkedProviderName {
                        InheritanceBanner(providerName: providerName) {
                            let providerId = profile.metadata.linkedProviderId
                            dismiss()
                            if let providerId {
                                Task { await APIProviderDistributor.shared.resetToInherit(providerId: providerId, target: .claude) }
                            }
                        }
                    }
                    sectionHeader(selectedSection)
                    sectionContent
                }
                .padding(18)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sectionRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(NodeEditorSection.allCases) { section in
                let selected = selectedSection == section
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selectedSection = section }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: section.symbol).frame(width: 18)
                        Text(section.title)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.teal : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.teal.opacity(0.10) : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Label(L("Fixed endpoint", "固定端点"), systemImage: "pin.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
        }
        .padding(10)
        .frame(width: 148)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case .identity:
            nodeTypeSection
            basicSection
        case .connection:
            networkSection
            upstreamCredentialsSection
        case .models:
            modelMappingSection
        case .security:
            securitySection
        }
    }

    private func sectionHeader(_ section: NodeEditorSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(section.title, systemImage: section.symbol)
                .font(.title3.weight(.bold))
            Spacer()
            Button {
                helpSection = section
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { helpSection == section },
                set: { if !$0 { helpSection = nil } }
            ), arrowEdge: .top) {
                Text(section.help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: 330, alignment: .leading)
            }
        }
    }

    private var routePreview: some View {
        HStack(spacing: 0) {
            routeChip("rectangle.3.group", L("Product gateways", "应用网关"), tint: .indigo)
            routePreviewLine
            routeChip("network", "\(profile.metadata.proxy.host):\(profile.metadata.proxy.port)", tint: .teal)
            routePreviewLine
            routeChip("cloud", upstreamPreviewLabel, tint: .orange)
        }
    }

    private func routeChip(_ symbol: String, _ text: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.10)))
    }

    private var routePreviewLine: some View {
        Rectangle().fill(Color.secondary.opacity(0.24)).frame(height: 1).frame(maxWidth: .infinity)
    }

    private var upstreamPreviewLabel: String {
        let raw = profile.metadata.nodeType == .anthropicDirect
            ? profile.metadata.proxy.anthropicBaseURL : profile.metadata.proxy.normalizedUpstreamBaseURL
        return URL(string: raw)?.host ?? L("Upstream", "上游")
    }

    // MARK: - Tab 2: Visual Settings

    private var settingsVisualTab: some View {
        SettingsVisualEditorView(settings: $profile.settings)
    }

    // MARK: - Node Type Section

    private var nodeTypeSection: some View {
        EditorCard(L("Interface Type", "接口类型")) {
            CapsuleInterfacePicker(
                options: [
                    SelectableCardOption(
                        ClaudeInterfaceChoice.anthropic,
                        title: "Anthropic",
                        subtitle: L("Connect to Anthropic or a compatible API.",
                                    "连接 Anthropic 或兼容 API。"),
                        systemImage: "bolt.horizontal.fill",
                        tint: ProxyBrand.anthropic
                    ),
                    SelectableCardOption(
                        ClaudeInterfaceChoice.openAIChatCompletions,
                        title: L("OpenAI Chat", "OpenAI Chat"),
                        subtitle: L("Convert to OpenAI /chat/completions via a local proxy.",
                                    "经本地代理转成 OpenAI /chat/completions。"),
                        systemImage: "arrow.triangle.swap",
                        tint: ProxyBrand.openAI
                    ),
                    SelectableCardOption(
                        ClaudeInterfaceChoice.openAIResponses,
                        title: L("OpenAI Responses", "OpenAI Responses"),
                        subtitle: L("Convert to OpenAI /responses via a local proxy.",
                                    "经本地代理转成 OpenAI /responses。"),
                        systemImage: "arrow.up.forward.app.fill",
                        tint: ProxyBrand.codex
                    )
                ],
                selection: interfaceChoice,
                fillWidth: false
            )
        }
    }

    /// 接口类型三卡片 ↔ (nodeType, openAIUpstreamAPI) 的双向映射。
    private var interfaceChoice: Binding<ClaudeInterfaceChoice> {
        Binding(
            get: {
                switch profile.metadata.nodeType {
                case .anthropicDirect: return .anthropic
                case .openaiProxy:
                    return profile.metadata.proxy.openAIUpstreamAPI == .responses
                        ? .openAIResponses : .openAIChatCompletions
                case .codexProxy:
                    return .openAIChatCompletions
                }
            },
            set: { choice in
                let oldType = profile.metadata.nodeType
                switch choice {
                case .anthropic:
                    profile.metadata.nodeType = .anthropicDirect
                case .openAIChatCompletions:
                    profile.metadata.nodeType = .openaiProxy
                    profile.metadata.proxy.openAIUpstreamAPI = .chatCompletions
                case .openAIResponses:
                    profile.metadata.nodeType = .openaiProxy
                    profile.metadata.proxy.openAIUpstreamAPI = .responses
                }
                // 新建时仅在接口族切换（Anthropic ↔ OpenAI）时重置默认模型/映射；
                // Chat ↔ Responses 同属 openaiProxy，不重置用户已填的模型。
                if isNew, oldType != profile.metadata.nodeType {
                    switch profile.metadata.nodeType {
                    case .anthropicDirect:
                        profile.metadata.proxy.modelMapping = .anthropicDefault
                        profile.metadata.proxy.defaultModel = "claude-sonnet-4-6"
                    case .openaiProxy:
                        profile.metadata.proxy.modelMapping = .openAIDefault
                        profile.metadata.proxy.defaultModel = "gpt-5.5"
                    case .codexProxy:
                        break
                    }
                }
                profile.syncEnvFromProxy()
            }
        )
    }

    // MARK: - Basic Section

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Basic Information", "基本信息"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Name", "名称"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    profile.metadata.nodeType == .anthropicDirect
                        ? L("e.g., Anthropic Official", "例如：Anthropic 官方")
                        : L("e.g., OpenAI / DeepSeek", "例如：OpenAI / DeepSeek"),
                    text: $profile.metadata.name
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Anthropic Direct Section

    private var anthropicDirectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Upstream · Anthropic Messages", "上游 · Anthropic Messages"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Base URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://api.anthropic.com", text: $profile.metadata.proxy.anthropicBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 430)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureKeyField("sk-ant-...", text: $profile.metadata.proxy.anthropicAPIKey)
                    .frame(width: 430)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Network Section (OpenAI Proxy)

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Fixed Node Endpoint", "固定节点端点"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Host", "主机")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $profile.metadata.proxy.host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Port", "端口")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("8080", value: $profile.metadata.proxy.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }

            Toggle(L("Allow LAN Access (0.0.0.0)", "允许局域网访问 (0.0.0.0)"), isOn: $profile.metadata.proxy.allowLAN)
                .font(.caption.weight(.medium))

            if profile.metadata.proxy.allowLAN {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L("Warning: This will expose the proxy to your local network",
                           "警告：这将把代理暴露到你的局域网"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder private var upstreamCredentialsSection: some View {
        switch profile.metadata.nodeType {
        case .anthropicDirect:
            anthropicDirectSection
        case .openaiProxy, .codexProxy:
            upstreamSection
        }
    }

    // MARK: - Upstream Section (OpenAI Proxy)

    private var upstreamSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Upstream Provider", "上游服务"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Base URL", "基础 URL")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("https://api.openai.com", text: $profile.metadata.proxy.upstreamBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 430)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureKeyField("sk-...", text: $profile.metadata.proxy.upstreamAPIKey)
                    .frame(width: 430)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Model Configuration Section

    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Exact Model Catalog", "真实模型目录"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Default Upstream Model", "默认上游模型")).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    modelTextField(text: $profile.metadata.proxy.defaultModel,
                                   placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.5" : "claude-sonnet-4-6")
                    ModelLibrarySlotPicker(selection: $profile.metadata.proxy.defaultModel, library: currentModelLibrary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Capability Defaults", "能力默认值")).font(.subheadline.weight(.semibold))
                modelSlotRow(label: "Opus", binding: $profile.metadata.proxy.modelMapping.bigModel.name,
                             placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.5" : "claude-opus-4-6")
                modelSlotRow(label: "Sonnet", binding: $profile.metadata.proxy.modelMapping.middleModel.name,
                             placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.4-mini" : "claude-sonnet-4-6")
                modelSlotRow(label: "Haiku", binding: $profile.metadata.proxy.modelMapping.smallModel.name,
                             placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-4o-mini" : "claude-haiku-4-5")
            }

            Divider()
            modelLibrarySummary

            if profile.metadata.nodeType == .openaiProxy {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Max Output Tokens", "最大输出 Token")).font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("0", value: $profile.metadata.proxy.maxOutputTokens, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                        Text(L("0 = unlimited", "0 = 不限制")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func modelSlotRow(label: String, binding: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            modelTextField(text: binding, placeholder: placeholder)
            ModelLibrarySlotPicker(selection: binding, library: currentModelLibrary)
        }
    }

    private func modelTextField(text: Binding<String>, placeholder: String) -> some View {
        ModelSuggestionField(text: text, placeholder: placeholder, state: modelFetch)
            .frame(width: 380)
    }

    /// 槽位下拉用的当前模型库（已过滤空名）。
    var currentModelLibrary: [ProxyConfiguration.MappedModel] {
        (profile.metadata.proxy.modelLibrary ?? []).filter { !$0.name.isEmpty }
    }

    private var modelLibrarySummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.teal)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.teal.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Model Library & Pricing", "模型库与定价"))
                    .font(.subheadline.weight(.semibold))
                Text(L(
                    "\(currentModelLibrary.count) exact models · opens in a focused editor",
                    "\(currentModelLibrary.count) 个真实模型 · 在独立编辑器中管理"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Manage Library…", "管理模型库…")) {
                isModelLibraryPresented = true
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.035)))
    }

    private var modelLibrarySheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Model Library & Pricing", "模型库与定价"))
                        .font(.title3.weight(.bold))
                    Text(L(
                        "Exact upstream identities used by every product gateway",
                        "供所有应用网关使用的真实上游模型"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done", "完成")) { isModelLibraryPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modelLibraryFetchPanel
                    modelLibrarySection
                }
                .padding(16)
            }
        }
        .frame(width: 760, height: 560)
    }

    private var modelLibraryFetchPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.teal)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.teal.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Import from upstream", "从上游获取模型"))
                    .font(.subheadline.weight(.semibold))
                Text(upstreamPreviewLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            modelLibraryFetchControl
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder private var modelLibraryFetchControl: some View {
        if profile.metadata.nodeType == .anthropicDirect {
            ModelFetchControls(
                state: modelFetch,
                baseURL: profile.metadata.proxy.anthropicBaseURL,
                apiKey: profile.metadata.proxy.anthropicAPIKey,
                style: .anthropic,
                requiresAPIKey: false
            )
        } else {
            ModelFetchControls(
                state: modelFetch,
                baseURL: profile.metadata.proxy.normalizedUpstreamBaseURL,
                apiKey: profile.metadata.proxy.upstreamAPIKey,
                style: .openAICompatible
            )
        }
    }

    // MARK: - Pricing Sub-section

    @State var pricingCurrency: ProxyConfiguration.PricingCurrency = .usd

    /// 模型库与定价（共享组件）；币种切换时同步槽位的遗留价格币种，保持回退路径一致。
    var modelLibrarySection: some View {
        ProxyModelLibraryEditor(
            library: Binding(
                get: { profile.metadata.proxy.modelLibrary ?? [] },
                set: { profile.metadata.proxy.modelLibrary = $0.isEmpty ? nil : $0 }
            ),
            currency: $pricingCurrency,
            modelFetch: modelFetch
        )
        .onChange(of: pricingCurrency) { _, newCurrency in
            profile.metadata.proxy.modelMapping.bigModel.pricing.currency = newCurrency
            profile.metadata.proxy.modelMapping.middleModel.pricing.currency = newCurrency
            profile.metadata.proxy.modelMapping.smallModel.pricing.currency = newCurrency
        }
    }

    // MARK: - Security Section (OpenAI Proxy)

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Local Access", "本地访问")).font(.headline.weight(.bold))
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Client API Key", "客户端 API Key"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureKeyField(L("Empty uses proxy-key", "留空则使用 proxy-key"), text: $profile.metadata.proxy.expectedClientKey)
                    .frame(width: 400)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                Text(L("Product gateways use this key to authenticate to the node.",
                       "各应用网关使用此密钥访问该节点。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Validation

    private var isValid: Bool {
        let nameValid = !profile.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let proxy = profile.metadata.proxy

        switch profile.metadata.nodeType {
        case .anthropicDirect:
            return nameValid && !proxy.anthropicBaseURL.isEmpty && !proxy.anthropicAPIKey.isEmpty
                && !proxy.host.isEmpty && proxy.port > 0 && proxy.port < 65536
        case .openaiProxy:
            return nameValid &&
                !proxy.host.isEmpty &&
                proxy.port > 0 && proxy.port < 65536 &&
                !proxy.normalizedUpstreamBaseURL.isEmpty &&
                !proxy.upstreamAPIKey.isEmpty &&
                !proxy.modelMapping.bigModel.name.isEmpty &&
                !proxy.modelMapping.middleModel.name.isEmpty &&
                !proxy.modelMapping.smallModel.name.isEmpty
        case .codexProxy:
            // Codex 单模型：仅校验 bigModel（middle/small 留空）。
            return nameValid &&
                !proxy.host.isEmpty &&
                proxy.port > 0 && proxy.port < 65536 &&
                !proxy.normalizedUpstreamBaseURL.isEmpty &&
                !proxy.upstreamAPIKey.isEmpty &&
                !proxy.modelMapping.bigModel.name.isEmpty
        }
    }

    /// 链接到的「API 提供商」名称（非链接节点为 nil）。
    private var linkedProviderName: String? {
        guard let id = profile.metadata.linkedProviderId,
              let master = APIProviderStore.shared.provider(id: id) else { return nil }
        return master.displayName
    }

    // MARK: - Save

    private func saveProfile() {
        if selectedTab == .json {
            guard validateAndApplyJSON() else { return }
            guard finalJSONError == nil else { return }
        } else {
            profile.syncEnvFromProxy()
        }
        profile.metadata.proxy.expectedClientKey = profile.metadata.proxy.expectedClientKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Node Runtime is now mandatory for every Claude protocol. Alias
        // mapping belongs to Code/Desktop/Science gateways, never the node.
        profile.metadata.proxy.usePassthroughProxy = true
        profile.metadata.proxy.enableModelAliasMapping = false
        // Claude Desktop now owns one stable HTTPS gateway endpoint. Per-node
        // HTTPS remains decodable for old profiles, but editing a node migrates
        // it to the simpler HTTP-only local-node contract used by Code.
        profile.metadata.proxy.enableHTTPS = false
        profile.metadata.proxy.httpsPort = nil
        profile.metadata.proxy.syncSlotPricingFromLibrary()
        // 链接节点：与主配置比对，标记本次编辑产生的本地覆盖（未链接则清空）。
        profile = APIProviderDistributor.shared.stampOverrides(profile)

        Task {
            if isNew {
                viewModel.addProfile(profile)
            } else {
                await viewModel.updateProfile(profile)
            }
            if let globalConfigDraftSettings {
                var draft = viewModel.profileStore.globalConfig
                draft.settings = globalConfigDraftSettings
                viewModel.profileStore.saveGlobalConfig(draft)
            }
            dismiss()
        }
    }
}

#Preview {
    ProxyConfigEditorView()
        .environmentObject(ProxyViewModel())
        .environmentObject(AppState.shared)
}
