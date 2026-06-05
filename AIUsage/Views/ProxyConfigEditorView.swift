import SwiftUI
import QuotaBackend

// MARK: - Editor Tabs

private enum EditorTab: String, CaseIterable {
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

// MARK: - Proxy Config Editor

struct ProxyConfigEditorView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var profile: NodeProfile
    @State private var isNew: Bool
    @State private var selectedTab: EditorTab = .proxy
    @State private var availableModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchModelsError: String?
    @State private var jsonText: String = ""
    @State private var jsonError: String?
    @State private var finalJSONText: String = ""
    @State private var finalJSONError: String?
    @State private var globalConfigDraftSettings: [String: Any]?
    @State private var isApplyingFinalJSONEdit = false

    init(profile: NodeProfile? = nil) {
        if let profile {
            _profile = State(initialValue: profile)
            _isNew = State(initialValue: false)
            _jsonText = State(initialValue: profile.settingsJSONString)
            _pricingCurrency = State(initialValue: profile.metadata.proxy.modelMapping.bigModel.pricing.currency)
        } else {
            let newProfile = NodeProfile.defaultProfile()
            _profile = State(initialValue: newProfile)
            _isNew = State(initialValue: true)
            _jsonText = State(initialValue: newProfile.settingsJSONString)
            _pricingCurrency = State(initialValue: .usd)
        }
    }

    /// Legacy init wrapping a ProxyConfiguration for callers not yet migrated.
    init(config: ProxyConfiguration) {
        let p = NodeProfile.fromLegacyConfiguration(config)
        _profile = State(initialValue: p)
        _isNew = State(initialValue: false)
        _jsonText = State(initialValue: p.settingsJSONString)
        _pricingCurrency = State(initialValue: config.modelMapping.bigModel.pricing.currency)
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
                    selectedTab = tab
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
                nodeTypeSection
                basicSection
                switch profile.metadata.nodeType {
                case .anthropicDirect:
                    anthropicDirectSection
                    modelMappingSection
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

    private var commonConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Common Config", "通用配置"))
                .font(.headline.weight(.bold))

            Picker("", selection: Binding(
                get: { profile.metadata.proxy.commonConfigMode ?? .followGlobal },
                set: {
                    profile.metadata.proxy.commonConfigMode = $0
                    refreshFinalSettingsPreview()
                }
            )) {
                ForEach(CommonConfigMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text((profile.metadata.proxy.commonConfigMode ?? .followGlobal).description)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: viewModel.profileStore.globalConfig.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.profileStore.globalConfig.enabled ? .green : .secondary)
                Text(viewModel.profileStore.globalConfig.enabled
                     ? L("Global common config is enabled.", "全局通用配置已开启。")
                     : L("Global common config is disabled.", "全局通用配置已关闭。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                sourceLegend(L("Common", "通用配置"), .blue)
                sourceLegend(L("Node", "节点配置"), .green)
                sourceLegend(L("Override", "节点覆盖"), .orange)
                Spacer()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func sourceLegend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.18))
                .frame(width: 22, height: 10)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tab 3: JSON Editor

    private var jsonEditorTab: some View {
        VStack(spacing: 12) {
            commonConfigSection
                .padding(.horizontal, 16)
                .padding(.top, 12)

            HStack(spacing: 12) {
                JSONRawEditorView(
                    jsonText: $jsonText,
                    error: $jsonError,
                    title: L("Node settings.json", "节点 settings.json")
                )

                JSONRawEditorView(
                    jsonText: Binding(
                        get: { finalJSONText.isEmpty ? finalSettingsPreviewText : finalJSONText },
                        set: { applyFinalJSONEdit($0) }
                    ),
                    error: $finalJSONError,
                    title: L("Layered final settings", "分层最终配置"),
                    isEditable: true,
                    showsActions: true,
                    lineMarkers: finalJSONLineMarkers
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear {
            ensureGlobalDraft()
            refreshFinalSettingsPreview()
        }
        .onChange(of: jsonText) { _, _ in
            guard selectedTab == .json, !isApplyingFinalJSONEdit else { return }
            refreshFinalSettingsPreview()
        }
    }

    private var finalSettingsPreviewText: String {
        let finalSettings = shouldMergeCommonConfig
            ? GlobalConfig.deepMerge(
                base: currentGlobalSettings,
                override: currentNodeSettings
            )
            : currentNodeSettings
        return prettyJSONString(finalSettings)
    }

    private var currentGlobalSettings: [String: Any] {
        globalConfigDraftSettings ?? viewModel.profileStore.globalConfig.settings
    }

    private var currentNodeSettings: [String: Any] {
        parsedJSONSettings(from: jsonText) ?? profile.settings
    }

    private var shouldMergeCommonConfig: Bool {
        profile.metadata.proxy.shouldMergeClaudeCommonConfig(
            globalEnabled: viewModel.profileStore.globalConfig.enabled
        )
    }

    private var finalJSONLineMarkers: [Int: String] {
        lineMarkers(
            for: finalJSONText.isEmpty ? finalSettingsPreviewText : finalJSONText,
            global: currentGlobalSettings,
            node: currentNodeSettings,
            shouldMerge: shouldMergeCommonConfig
        )
    }

    // MARK: - JSON Sync

    private func syncToJSON() {
        profile.syncEnvFromProxy()
        jsonText = profile.settingsJSONString
        jsonError = nil
        ensureGlobalDraft()
        refreshFinalSettingsPreview()
    }

    private func syncFromJSON() {
        guard let obj = parsedJSONSettings(from: jsonText) else {
            return
        }
        profile.settings = obj
        profile.syncProxyFromSettings()
        refreshFinalSettingsPreview()
    }

    /// Validate JSON, apply to profile, and reverse-sync metadata. Returns false on invalid JSON.
    private func validateAndApplyJSON() -> Bool {
        guard let data = jsonText.data(using: .utf8) else {
            jsonError = L("Invalid text encoding", "文本编码无效")
            return false
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                jsonError = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                return false
            }
            profile.settings = dict
            profile.syncProxyFromSettings()
            jsonError = nil
            return true
        } catch {
            jsonError = error.localizedDescription
            return false
        }
    }

    private func parsedJSONSettings(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func ensureGlobalDraft() {
        if globalConfigDraftSettings == nil {
            globalConfigDraftSettings = viewModel.profileStore.globalConfig.settings
        }
    }

    private func refreshFinalSettingsPreview() {
        finalJSONText = finalSettingsPreviewText
        finalJSONError = nil
    }

    private func applyFinalJSONEdit(_ text: String) {
        finalJSONText = text
        guard let finalSettings = parsedJSONSettings(from: text) else {
            finalJSONError = L("Final settings must be valid JSON before it can update common/node config.",
                               "最终配置必须是有效 JSON，才能回写通用配置/节点配置。")
            return
        }

        finalJSONError = nil
        ensureGlobalDraft()
        let split = splitFinalSettingsEdit(
            finalSettings,
            global: currentGlobalSettings,
            node: currentNodeSettings,
            shouldMerge: shouldMergeCommonConfig
        )

        isApplyingFinalJSONEdit = true
        globalConfigDraftSettings = split.global
        jsonText = prettyJSONString(split.node)
        profile.settings = split.node
        profile.syncProxyFromSettings()
        isApplyingFinalJSONEdit = false
    }

    private func prettyJSONString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
        let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private enum SettingsSource {
        case common
        case node
        case override

        var marker: String {
            switch self {
            case .common: return "C"
            case .node: return "N"
            case .override: return "O"
            }
        }
    }

    private struct SettingsSourceScope {
        let depth: Int
        let key: String
        let source: SettingsSource
    }

    private func splitFinalSettingsEdit(
        _ finalSettings: [String: Any],
        global: [String: Any],
        node: [String: Any],
        shouldMerge: Bool
    ) -> (global: [String: Any], node: [String: Any]) {
        var nextGlobal = global
        var nextNode = node

        let oldFinal = shouldMerge
            ? GlobalConfig.deepMerge(base: global, override: node)
            : node
        let oldLeaves = flattenedJSONLeaves(oldFinal)
        let newLeaves = flattenedJSONLeaves(finalSettings)

        for path in oldLeaves.keys where newLeaves[path] == nil {
            switch sourceForPath(path, global: global, node: node, shouldMerge: shouldMerge) {
            case .common:
                removeJSONValue(at: path, from: &nextGlobal)
            case .node, .override:
                removeJSONValue(at: path, from: &nextNode)
            }
        }

        for (path, value) in newLeaves {
            let source = oldLeaves[path] == nil
                ? (shouldMerge ? SettingsSource.common : SettingsSource.node)
                : sourceForPath(path, global: global, node: node, shouldMerge: shouldMerge)
            switch source {
            case .common:
                setJSONValue(value, at: path, in: &nextGlobal)
            case .node, .override:
                setJSONValue(value, at: path, in: &nextNode)
            }
        }

        return (nextGlobal, nextNode)
    }

    private func lineMarkers(
        for text: String,
        global: [String: Any],
        node: [String: Any],
        shouldMerge: Bool
    ) -> [Int: String] {
        var markers: [Int: String] = [:]
        var stack: [SettingsSourceScope] = []
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " }.count
            let depth = max(0, indent / 2)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("}") || trimmed.hasPrefix("]") {
                if let source = stack.last?.source {
                    markers[index + 1] = source.marker
                }
                while let last = stack.last, last.depth >= depth {
                    stack.removeLast()
                }
                continue
            }

            while let last = stack.last, last.depth >= depth {
                stack.removeLast()
            }

            guard let key = jsonKey(in: line) else {
                if let source = stack.last?.source {
                    markers[index + 1] = source.marker
                }
                continue
            }

            let path = stack.map(\.key) + [key]
            let source = sourceForPath(path, global: global, node: node, shouldMerge: shouldMerge)
            markers[index + 1] = source.marker

            if lineContainsContainerStart(line) {
                stack.append(SettingsSourceScope(depth: depth, key: key, source: source))
            }
        }

        return markers
    }

    private func sourceForPath(
        _ path: [String],
        global: [String: Any],
        node: [String: Any],
        shouldMerge: Bool
    ) -> SettingsSource {
        guard shouldMerge else { return .node }
        let hasGlobal = jsonValue(at: path, in: global) != nil
        let hasNode = jsonValue(at: path, in: node) != nil
        if hasGlobal && hasNode { return .override }
        if hasNode { return .node }
        return .common
    }

    private func flattenedJSONLeaves(_ object: [String: Any]) -> [[String]: Any] {
        var result: [[String]: Any] = [:]
        flattenJSONValue(object, path: [], into: &result)
        return result
    }

    private func flattenJSONValue(_ value: Any, path: [String], into result: inout [[String]: Any]) {
        if let dict = value as? [String: Any], !dict.isEmpty {
            for (key, child) in dict {
                flattenJSONValue(child, path: path + [key], into: &result)
            }
            return
        }
        result[path] = value
    }

    private func jsonValue(at path: [String], in object: [String: Any]) -> Any? {
        guard !path.isEmpty else { return object }
        var current: Any = object
        for key in path {
            guard let dict = current as? [String: Any],
                  let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func setJSONValue(_ value: Any, at path: [String], in object: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object[first] = value
            return
        }
        var child = object[first] as? [String: Any] ?? [:]
        setJSONValue(value, at: Array(path.dropFirst()), in: &child)
        object[first] = child
    }

    private func removeJSONValue(at path: [String], from object: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object.removeValue(forKey: first)
            return
        }
        guard var child = object[first] as? [String: Any] else { return }
        removeJSONValue(at: Array(path.dropFirst()), from: &child)
        if child.isEmpty {
            object.removeValue(forKey: first)
        } else {
            object[first] = child
        }
    }

    private func jsonKey(in line: String) -> String? {
        let pattern = #"^\s*"((?:\\.|[^"\\])*)"\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        let raw = String(line[range])
        if let data = "\"\(raw)\"".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String {
            return decoded
        }
        return raw
    }

    private func lineContainsContainerStart(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let tail = line[line.index(after: colon)...]
        return tail.contains("{") || tail.contains("[")
    }

    // MARK: - Node Type Section

    private var nodeTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Node Type", "节点类型"))
                .font(.headline.weight(.bold))

            Picker("", selection: $profile.metadata.nodeType) {
                Label {
                    Text("Anthropic Direct")
                } icon: {
                    Image(systemName: "bolt.horizontal.fill")
                }
                .tag(NodeType.anthropicDirect)

                Label {
                    Text("OpenAI Proxy")
                } icon: {
                    Image(systemName: "arrow.triangle.swap")
                }
                .tag(NodeType.openaiProxy)
            }
            .pickerStyle(.segmented)
            .onChange(of: profile.metadata.nodeType) { _, newType in
                if isNew {
                    switch newType {
                    case .anthropicDirect:
                        profile.metadata.proxy.modelMapping = .anthropicDefault
                        profile.metadata.proxy.defaultModel = "claude-sonnet-4-6"
                    case .openaiProxy:
                        profile.metadata.proxy.modelMapping = .openAIDefault
                        profile.metadata.proxy.defaultModel = "gpt-5.5"
                    case .codexProxy:
                        profile.metadata.proxy.modelMapping = .codexDefault
                        profile.metadata.proxy.defaultModel = ProxyConfiguration.ModelMapping.codexDefault.bigModel.name
                    }
                    profile.syncEnvFromProxy()
                }
            }

            Text(profile.metadata.nodeType == .anthropicDirect
                 ? L("Connect directly to Anthropic or compatible API. No proxy process needed.",
                     "直接连接 Anthropic 或兼容 API，无需代理进程。")
                 : L("Translate Claude API to OpenAI-compatible API via local proxy.",
                     "通过本地代理将 Claude API 转换为 OpenAI 兼容 API。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
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
                        : L("e.g., OpenAI Proxy", "例如：OpenAI 代理"),
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
                SecureField("sk-ant-...", text: $profile.metadata.proxy.anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

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
                Text(L("Upstream API", "上游接口")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $profile.metadata.proxy.openAIUpstreamAPI) {
                    Text("Chat Completions").tag(OpenAIUpstreamAPI.chatCompletions)
                    Text("Responses").tag(OpenAIUpstreamAPI.responses)
                }
                .pickerStyle(.segmented)
                Text(L(
                    "Responses is recommended for new OpenAI integrations. Keep Chat Completions for older compatible providers that only implement /v1/chat/completions.",
                    "官方新的 OpenAI 集成更推荐 Responses；如果你的兼容服务仍只实现 /v1/chat/completions，请继续选择 Chat Completions。"
                ))
                .font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureField("sk-...", text: $profile.metadata.proxy.upstreamAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button {
                    fetchModels()
                } label: {
                    HStack(spacing: 4) {
                        if isFetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(L("Fetch Models", "获取模型"))
                    }
                    .font(.caption.weight(.semibold))
                }
                .disabled(profile.metadata.proxy.normalizedUpstreamBaseURL.isEmpty || profile.metadata.proxy.upstreamAPIKey.isEmpty || isFetchingModels)

                if !availableModels.isEmpty {
                    Text(L("\(availableModels.count) models available", "已获取 \(availableModels.count) 个模型"))
                        .font(.caption2).foregroundStyle(.green)
                } else if let error = fetchModelsError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
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
                modelTextField(text: $profile.metadata.proxy.defaultModel,
                               placeholder: profile.metadata.nodeType == .openaiProxy ? "gpt-5.5" : "claude-sonnet-4-6")
                Text(L("The model field in settings.json. Claude Code uses this as the active model.",
                       "settings.json 中的 model 字段，Claude Code 以此作为当前使用的模型。"))
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
                modelPricingSection
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
        }
    }

    private func modelTextField(text: Binding<String>, placeholder: String) -> some View {
        let suggestions = filteredModels(for: text.wrappedValue)
        let showSuggestions = !availableModels.isEmpty && !text.wrappedValue.isEmpty && !suggestions.isEmpty
            && !suggestions.contains(where: { $0 == text.wrappedValue })

        return VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            if showSuggestions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions.prefix(8), id: \.self) { model in
                            Button {
                                text.wrappedValue = model
                            } label: {
                                Text(model)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.04))
                        }
                    }
                }
                .frame(maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    // MARK: - Pricing Sub-section

    @State private var pricingCurrency: ProxyConfiguration.PricingCurrency = .usd

    private var modelPricingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Pricing", "定价")).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    applyCacheAutoFill()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text(L("Auto-fill Cache (1.25× / 0.1×)", "自动填充缓存（1.25×/0.1×）"))
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help(L(
                    "Set cache-write = 1.25× input and cache-read = 0.1× input for all three models.",
                    "按输入价格自动计算三个模型的缓存写入（×1.25）与缓存读取（×0.1）单价。"
                ))
                Picker("", selection: $pricingCurrency) {
                    Text("USD ($)").tag(ProxyConfiguration.PricingCurrency.usd)
                    Text("CNY (¥)").tag(ProxyConfiguration.PricingCurrency.cny)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: pricingCurrency) { _, newCurrency in
                    profile.metadata.proxy.modelMapping.bigModel.pricing.currency = newCurrency
                    profile.metadata.proxy.modelMapping.middleModel.pricing.currency = newCurrency
                    profile.metadata.proxy.modelMapping.smallModel.pricing.currency = newCurrency
                }
            }

            if profile.metadata.nodeType == .anthropicDirect {
                Text(L("This node uses the pricing here for spend statistics. In Anthropic passthrough mode, you only need to configure this once.",
                       "这个节点会直接使用这里的价格做消费统计。在 Anthropic 透传模式下，只需要配置这一处。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text(L(
                "Anthropic bills cache writes at ~1.25× input and cache reads at ~0.1× input (5-minute TTL). Adjust per upstream if your provider differs.",
                "Anthropic 的缓存写入约为输入价格的 1.25×，缓存读取约为 0.1×（5 分钟 TTL）。如上游计费方式不同可自行调整。"
            ))
            .font(.caption2).foregroundStyle(.tertiary)

            HStack(spacing: 0) {
                Text("").frame(width: 56, alignment: .trailing)
                Spacer().frame(width: 10)
                Text(L("Input", "输入")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Output", "输出")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Cache Write", "缓存写入")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Cache Read", "缓存读取")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("/ M tokens", "/ 百万")).frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)

            pricingRow(label: "Opus", pricing: $profile.metadata.proxy.modelMapping.bigModel.pricing)
            pricingRow(label: "Sonnet", pricing: $profile.metadata.proxy.modelMapping.middleModel.pricing)
            pricingRow(label: "Haiku", pricing: $profile.metadata.proxy.modelMapping.smallModel.pricing)
        }
    }

    private func applyCacheAutoFill() {
        func fill(_ p: inout ProxyConfiguration.ModelPricing) {
            guard p.inputPerMillion > 0 else { return }
            p.cacheCreatePerMillion = p.inputPerMillion * ProxyConfiguration.ModelPricing.defaultCacheWriteMultiplier
            p.cacheReadPerMillion = p.inputPerMillion * ProxyConfiguration.ModelPricing.defaultCacheReadMultiplier
        }
        fill(&profile.metadata.proxy.modelMapping.bigModel.pricing)
        fill(&profile.metadata.proxy.modelMapping.middleModel.pricing)
        fill(&profile.metadata.proxy.modelMapping.smallModel.pricing)
    }

    private func pricingRow(label: String, pricing: Binding<ProxyConfiguration.ModelPricing>) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            Spacer().frame(width: 10)
            TextField("0", value: pricing.inputPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 6)
            TextField("0", value: pricing.outputPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 6)
            TextField("0", value: pricing.cacheCreatePerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 6)
            TextField("0", value: pricing.cacheReadPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 64)
        }
    }

    // MARK: - Security Section (OpenAI Proxy)

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Security", "安全设置")).font(.headline.weight(.bold))
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Expected Client API Key (Optional)", "客户端 API Key（可选）"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SecureField(L("Leave empty to accept any key", "留空则接受任意 Key"), text: $profile.metadata.proxy.expectedClientKey)
                    .textFieldStyle(.roundedBorder)
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

    // MARK: - Model Fetching

    private func fetchModels() {
        let baseURL: String
        let apiKey: String

        if profile.metadata.nodeType == .openaiProxy {
            baseURL = profile.metadata.proxy.normalizedUpstreamBaseURL
            apiKey = profile.metadata.proxy.upstreamAPIKey
        } else {
            baseURL = profile.metadata.proxy.anthropicBaseURL
            apiKey = profile.metadata.proxy.anthropicAPIKey
        }

        guard !baseURL.isEmpty, !apiKey.isEmpty else { return }

        let urlString: String
        if profile.metadata.nodeType == .openaiProxy {
            urlString = baseURL.hasSuffix("/") ? baseURL + "v1/models" : baseURL + "/v1/models"
        } else {
            urlString = baseURL.hasSuffix("/") ? baseURL + "models" : baseURL + "/models"
        }
        guard let url = URL(string: urlString) else { return }

        isFetchingModels = true
        fetchModelsError = nil
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { DispatchQueue.main.async { isFetchingModels = false } }
            if let error = error {
                DispatchQueue.main.async { fetchModelsError = error.localizedDescription }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                DispatchQueue.main.async { fetchModelsError = "Invalid response" }
                return
            }
            let models = dataArr.compactMap { $0["id"] as? String }.sorted()
            DispatchQueue.main.async {
                availableModels = models
                fetchModelsError = models.isEmpty ? "No models found" : nil
            }
        }.resume()
    }

    private func filteredModels(for text: String) -> [String] {
        guard !text.isEmpty else { return availableModels }
        return availableModels.filter { $0.localizedCaseInsensitiveContains(text) }
    }

    // MARK: - Save

    private func saveProfile() {
        if selectedTab == .json {
            guard validateAndApplyJSON() else { return }
            guard finalJSONError == nil else { return }
        } else {
            profile.syncEnvFromProxy()
        }

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
