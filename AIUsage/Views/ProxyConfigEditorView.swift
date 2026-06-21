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
            tabBar
            Divider()

            Group {
                switch selectedTab {
                case .proxy:
                    proxyTab
                case .settings:
                    settingsVisualTab
                case .json:
                    jsonEditorTab
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footerBar
        }
        .frame(width: selectedTab == .json ? 1100 : 750, height: 800)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text(isNew ? L("New Node", "新建节点") : L("Edit Node", "编辑节点"))
                .font(.title2.weight(.bold))
            Spacer()
            Button(L("Cancel", "取消")) { dismiss() }
        }
        .padding(20)
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
        .padding(20)
    }

    // MARK: - Tab 1: Proxy Settings

    private var proxyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let providerName = linkedProviderName {
                    InheritanceBanner(providerName: providerName) {
                        let providerId = profile.metadata.linkedProviderId
                        dismiss()
                        if let providerId {
                            Task { await APIProviderDistributor.shared.resetToInherit(providerId: providerId, target: .claude) }
                        }
                    }
                }
                nodeTypeSection
                basicSection
                switch profile.metadata.nodeType {
                case .anthropicDirect:
                    anthropicDirectSection
                    modelMappingSection
                    if profile.metadata.proxy.usePassthroughProxy {
                        securitySection
                    }
                case .openaiProxy, .codexProxy:
                    networkSection
                    upstreamSection
                    modelMappingSection
                    securitySection
                }
            }
            .padding(20)
        }
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
                selection: interfaceChoice
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
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Anthropic Direct Section

    private var anthropicDirectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Anthropic API", "Anthropic API"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Base URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://api.anthropic.com", text: $profile.metadata.proxy.anthropicBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureKeyField("sk-ant-...", text: $profile.metadata.proxy.anthropicAPIKey)
            }

            ModelFetchControls(
                state: modelFetch,
                baseURL: profile.metadata.proxy.anthropicBaseURL,
                apiKey: profile.metadata.proxy.anthropicAPIKey,
                style: .anthropic,
                requiresAPIKey: false
            )

            Divider()

            Toggle(isOn: $profile.metadata.proxy.usePassthroughProxy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Transparent Proxy (Log Usage)", "透明代理（记录用量）"))
                        .font(.subheadline.weight(.semibold))
                    Text(L("Route requests through a local proxy to log token usage without modifying the API format.",
                           "请求经由本地代理透传，记录 Token 用量但不修改 API 格式。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if profile.metadata.proxy.usePassthroughProxy {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Host", "主机")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("127.0.0.1", text: $profile.metadata.proxy.host).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Port", "端口")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("8080", value: $profile.metadata.proxy.port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 80)
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

                Divider()

                Toggle(isOn: Binding(
                    get: { profile.metadata.proxy.enableModelAliasMapping ?? false },
                    set: { profile.metadata.proxy.enableModelAliasMapping = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Model Alias Mapping", "模型别名映射"))
                            .font(.subheadline.weight(.semibold))
                        Text(L("Replace Opus/Sonnet/Haiku aliases in the request with model slot values before forwarding. Useful when the upstream supports non-Claude models via Anthropic API format.",
                               "转发前将请求中的 Opus/Sonnet/Haiku 别名替换为模型槽位中配置的值。适用于上游通过 Anthropic API 格式支持非 Claude 模型的场景。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                httpsToggle

                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.teal)
                    Text(L("ANTHROPIC_BASE_URL will point to the local proxy. Requests are forwarded to the upstream API as-is.",
                           "ANTHROPIC_BASE_URL 将指向本地代理，请求原样转发至上游 API。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text(L("These values will be written to ~/.claude/settings.json when activated.",
                           "激活时会将这些值写入 ~/.claude/settings.json。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Network Section (OpenAI Proxy)

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Local Proxy", "本地代理"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Host", "主机")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $profile.metadata.proxy.host).textFieldStyle(.roundedBorder)
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

            httpsToggle
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
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
                Text(L(
                    "Enter only the provider root URL. AIUsage will append /v1 and the selected endpoint automatically, and older values ending in /v1 or /v1/chat/completions remain compatible.",
                    "这里只填写服务根地址即可。AIUsage 会根据所选接口自动补上 /v1 和具体端点，旧版本里以 /v1 或 /v1/chat/completions 结尾的配置也会自动兼容。"
                ))
                .font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureKeyField("sk-...", text: $profile.metadata.proxy.upstreamAPIKey)
            }

            ModelFetchControls(
                state: modelFetch,
                baseURL: profile.metadata.nodeType == .openaiProxy
                    ? profile.metadata.proxy.normalizedUpstreamBaseURL
                    : profile.metadata.proxy.anthropicBaseURL,
                apiKey: profile.metadata.nodeType == .openaiProxy
                    ? profile.metadata.proxy.upstreamAPIKey
                    : profile.metadata.proxy.anthropicAPIKey,
                style: profile.metadata.nodeType == .openaiProxy ? .openAICompatible : .anthropic
            )
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Model Configuration Section

    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Model Configuration", "模型配置"))
                .font(.headline.weight(.bold))

            Text(L("These model names will be written to ~/.claude/settings.json and used directly by Claude Code for requests and statistics.",
                   "这些模型名将写入 ~/.claude/settings.json，Claude Code 会直接使用它们发起请求和统计用量。"))
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Default Model", "主模型")).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    modelTextField(text: $profile.metadata.proxy.defaultModel,
                                   placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.5" : "claude-sonnet-4-6")
                    ModelLibrarySlotPicker(selection: $profile.metadata.proxy.defaultModel, library: currentModelLibrary)
                }
                Text(L("The model field in settings.json. Claude Code uses this as the active model. Switchable from the node card when the library has multiple models.",
                       "settings.json 中的 model 字段，Claude Code 以此作为当前使用的模型。模型库有多个模型时，节点卡片上可随时切换。"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Model Slots", "模型槽位")).font(.subheadline.weight(.semibold))
                modelSlotRow(label: "Opus", binding: $profile.metadata.proxy.modelMapping.bigModel.name,
                             placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.5" : "claude-opus-4-6")
                modelSlotRow(label: "Sonnet", binding: $profile.metadata.proxy.modelMapping.middleModel.name,
                             placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.4-mini" : "claude-sonnet-4-6")
                modelSlotRow(label: "Haiku", binding: $profile.metadata.proxy.modelMapping.smallModel.name,
                             placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-4o-mini" : "claude-haiku-4-5")
            }

            if profile.metadata.proxy.needsProxyProcess(nodeType: profile.metadata.nodeType) {
                Divider()
                modelLibrarySection
            }

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

    // MARK: - HTTPS Toggle

    private var httpsToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Toggle(isOn: Binding(
                get: { profile.metadata.proxy.enableHTTPS ?? false },
                set: { profile.metadata.proxy.enableHTTPS = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HTTPS")
                        .font(.subheadline.weight(.semibold))
                    Text(L("Enable HTTPS listener with a self-signed certificate. Clients that require HTTPS can connect via the HTTPS port.",
                           "启用 HTTPS 监听（自签名证书）。要求 HTTPS 的客户端可通过 HTTPS 端口连接。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if profile.metadata.proxy.enableHTTPS ?? false {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("HTTPS Port", "HTTPS 端口")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("\(profile.metadata.proxy.port + 1)",
                                  value: Binding(
                                    get: { profile.metadata.proxy.httpsPort ?? (profile.metadata.proxy.port + 1) },
                                    set: { profile.metadata.proxy.httpsPort = $0 }
                                  ),
                                  format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("HTTPS URL", "HTTPS 地址")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        let httpsPort = profile.metadata.proxy.httpsPort ?? (profile.metadata.proxy.port + 1)
                        Text(verbatim: "https://\(profile.metadata.proxy.host):\(httpsPort)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
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
    }

    /// 槽位下拉用的当前模型库（已过滤空名）。
    var currentModelLibrary: [ProxyConfiguration.MappedModel] {
        (profile.metadata.proxy.modelLibrary ?? []).filter { !$0.name.isEmpty }
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
            Text(L("Security", "安全设置")).font(.headline.weight(.bold))
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Expected Client API Key (Optional)", "客户端 API Key（可选）"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureKeyField(L("Leave empty to accept any key", "留空则接受任意 Key"), text: $profile.metadata.proxy.expectedClientKey)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                Text(L("If set, clients must provide this key in x-api-key or Authorization header",
                       "设置后，客户端需在 x-api-key 或 Authorization 头中提供此 Key"))
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
            let baseValid = nameValid && !proxy.anthropicBaseURL.isEmpty && !proxy.anthropicAPIKey.isEmpty
            if proxy.usePassthroughProxy {
                return baseValid && !proxy.host.isEmpty && proxy.port > 0 && proxy.port < 65536
            }
            return baseValid
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
