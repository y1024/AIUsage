import SwiftUI

// MARK: - OpenCode Node Editor
// 新建/编辑 OpenCode 接入节点的 sheet，与 Claude/Codex 编辑器同款 Tab 结构：
// 「节点设置」（名称/协议/Base URL/Key/模型/上限/代理模式）+「JSON 预览」
// （激活后 opencode.json 的最终内容，只读，便于核对受管块）。
// 保存交由调用方落库；激活节点的编辑会即时重写 opencode.json。

/// 编辑器顶部标签页（避免与 Claude 编辑器的全局 EditorTab 重名）。
enum OpenCodeEditorTab: CaseIterable {
    case settings
    case jsonPreview

    var label: String {
        switch self {
        case .settings: return L("Settings", "节点设置")
        case .jsonPreview: return L("JSON Preview", "JSON 预览")
        }
    }

    var icon: String {
        switch self {
        case .settings: return "slider.horizontal.3"
        case .jsonPreview: return "curlybraces"
        }
    }
}

struct OpenCodeNodeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (OpenCodeNode) -> Void

    @State private var node: OpenCodeNode
    @State private var modelsText: String
    @State private var showAPIKey = false
    @StateObject private var modelFetch = ModelFetchState()
    @State private var connectivity: ConnectivityResult = .idle
    @State private var selectedTab: OpenCodeEditorTab = .settings
    private let isNew: Bool

    private enum ConnectivityResult: Equatable {
        case idle
        case testing
        case success(ms: Int)
        case failure(String)
    }

    private static let brand = OpenCodeManagementView.brand

    init(node: OpenCodeNode, onSave: @escaping (OpenCodeNode) -> Void) {
        self.onSave = onSave
        _node = State(initialValue: node)
        _modelsText = State(initialValue: node.models.joined(separator: "\n"))
        isNew = node.name.isEmpty && node.baseURL.isEmpty && node.models.isEmpty
    }

    private var parsedModels: [String] {
        var seen = Set<String>()
        return modelsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var canSave: Bool {
        node.baseURL.trimmingCharacters(in: .whitespaces).nilIfBlank != nil
    }

    /// 编辑中的草稿节点（模型列表来自文本框的即时解析），供连通性测试与 JSON 预览。
    private var draftNode: OpenCodeNode {
        var draft = node
        draft.models = parsedModels
        return draft
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()

            Group {
                switch selectedTab {
                case .settings:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            basicSection
                            modelsSection
                            limitsSection
                            proxySection
                        }
                        .padding(18)
                    }
                case .jsonPreview:
                    jsonPreviewTab
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: selectedTab == .jsonPreview ? 720 : 480, height: 640)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            ProviderIconView("opencode", size: 18)
            Text(isNew ? L("New OpenCode Node", "新建 OpenCode 节点") : L("Edit OpenCode Node", "编辑 OpenCode 节点"))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: - Tab Bar (Claude/Codex 编辑器同款)

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(OpenCodeEditorTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.label)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.white : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(selectedTab == tab ? Self.brand : Color.clear)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - JSON Preview Tab

    private var jsonPreviewTab: some View {
        let merged = OpenCodeConfigManager.shared.previewMergedConfig(
            node: draftNode,
            baseURLOverride: node.proxyEnabled ? node.proxyLocalBaseURL : nil
        )
        let jsonText = OpenCodeConfigManager.jsonString(merged)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("opencode.json after activation", "激活后的 opencode.json"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(jsonText, forType: .string)
                } label: {
                    Label(L("Copy", "复制"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(jsonText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )

            Text(node.proxyEnabled
                 ? L(
                     "Read-only preview, merged with your existing config. Proxy mode: baseURL points to the local proxy and the real key stays in the proxy process.",
                     "只读预览，已与现有配置合并。代理模式：baseURL 指向本地代理，真实 Key 保留在代理进程内。"
                 )
                 : L(
                     "Read-only preview, merged with your existing config (managed provider block + top-level model).",
                     "只读预览，已与现有配置合并（受管 provider 块 + 顶层 model 指向）。"
                 ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(18)
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Node Name", "节点名称"), required: false)
            TextField(L("e.g. DeepSeek Official", "如：DeepSeek 官方"), text: $node.name)
                .textFieldStyle(.roundedBorder)

            fieldLabel(L("Protocol", "上游协议"), required: false)
            Picker("", selection: $node.protocolType) {
                ForEach(OpenCodeProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: node.protocolType) { _, _ in
                connectivity = .idle
            }

            fieldLabel(L("Base URL", "Base URL"), required: true)
            TextField(baseURLPlaceholder, text: $node.baseURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text(L(
                "OpenCode appends \(node.protocolType.requestPath) to it.",
                "OpenCode 会在其后拼接 \(node.protocolType.requestPath)。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)

            fieldLabel(L("API Key", "API Key"), required: false)
            HStack(spacing: 6) {
                Group {
                    if showAPIKey {
                        TextField("sk-...", text: $node.apiKey)
                    } else {
                        SecureField("sk-...", text: $node.apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(L("Show / hide key", "显示 / 隐藏密钥"))
            }

            connectivityRow
        }
    }

    private var baseURLPlaceholder: String {
        switch node.protocolType {
        case .openAICompatible: return "https://api.example.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAIResponses: return "https://api.openai.com/v1"
        }
    }

    // MARK: - Connectivity Test

    private var connectivityRow: some View {
        HStack(spacing: 8) {
            Button {
                runConnectivityTest()
            } label: {
                HStack(spacing: 4) {
                    if connectivity == .testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal")
                    }
                    Text(L("Test Connection", "测试连通"))
                }
                .font(.caption.weight(.semibold))
            }
            .disabled(!canTestConnectivity || connectivity == .testing)
            .help(L(
                "Sends a 1-token chat request to the endpoint using the first model in the list.",
                "用列表中的第一个模型向接入点发送一条 1 token 的对话请求。"
            ))

            switch connectivity {
            case .idle, .testing:
                EmptyView()
            case .success(let ms):
                Label(L("OK (\(ms) ms)", "连通正常（\(ms) ms）"), systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            case .failure(let message):
                Text(message)
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var canTestConnectivity: Bool {
        node.baseURL.trimmingCharacters(in: .whitespaces).nilIfBlank != nil && !parsedModels.isEmpty
    }

    /// 委托共享的 OpenCodeConnectivityTester（与管理页卡片同一套协议分支）。
    private func runConnectivityTest() {
        connectivity = .testing
        let draft = draftNode
        Task {
            let state = await OpenCodeConnectivityTester.test(node: draft)
            if state.lastSucceeded == true {
                connectivity = .success(ms: state.latencyMs ?? 0)
            } else {
                let prefix = state.statusCode.map { "HTTP \($0): " } ?? ""
                let detail = state.message ?? L("Unknown error", "未知错误")
                connectivity = .failure(String((prefix + detail).prefix(200)))
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Models (one per line)", "模型列表（每行一个）"), required: true)

            ModelFetchControls(
                state: modelFetch,
                baseURL: node.baseURL,
                apiKey: node.apiKey,
                style: node.protocolType == .anthropic ? .anthropic : .openAICompatible,
                requiresAPIKey: false
            )

            FetchedModelAppendList(
                state: modelFetch,
                existingModels: Set(parsedModels),
                onAppend: { appendModels([$0]) },
                onAppendAll: { appendModels($0) }
            )

            TextEditor(text: $modelsText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )

            if !parsedModels.isEmpty {
                fieldLabel(L("Default Model", "默认模型"), required: false)
                Picker("", selection: $node.defaultModel) {
                    ForEach(parsedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onAppear(perform: ensureDefaultModelValid)
                .onChange(of: modelsText) { _, _ in ensureDefaultModelValid() }
            }
        }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Limits (optional, 0 = OpenCode default)", "上限（可选，0 = 由 OpenCode 取默认）"), required: false)
            HStack(spacing: 12) {
                labeledNumberField(L("Context", "上下文"), value: $node.contextLimit)
                labeledNumberField(L("Output", "输出"), value: $node.outputLimit)
            }
            Text(L(
                "Written into each model's limit block, e.g. 200000 / 65536.",
                "写入每个模型的 limit 块，例如 200000 / 65536。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $node.proxyEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Local proxy (request logs)", "本地代理（请求日志）"))
                        .font(.caption.weight(.semibold))
                    Text(L(
                        "Route OpenCode through a local passthrough proxy to capture per-request logs. Usage costs still come from OpenCode's own records.",
                        "让 OpenCode 经本地透传代理访问上游，以获得逐条请求日志。用量费用仍以 OpenCode 自身记录为准。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if node.proxyEnabled {
                HStack(spacing: 6) {
                    Text(L("Port", "端口"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("\(OpenCodeNode.defaultProxyPort)", value: $node.proxyPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text(L("OpenCode will connect to 127.0.0.1:\(String(node.proxyPort)).", "OpenCode 将连接 127.0.0.1:\(String(node.proxyPort))。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if node.protocolType == .openAIResponses, node.apiKey.nilIfBlank == nil {
                    Label(
                        L(
                            "Proxy mode with the OpenAI Responses protocol requires an API key.",
                            "OpenAI Responses 协议的代理模式需要填写 API Key。"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("Cancel", "取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Save", "保存")) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Self.brand)
                .disabled(!canSave)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func fieldLabel(_ title: String, required: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if required {
                Text("*")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
    }

    private func labeledNumberField(_ title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }

    private func ensureDefaultModelValid() {
        let models = parsedModels
        if !models.contains(node.defaultModel) {
            node.defaultModel = models.first ?? ""
        }
    }

    /// 把获取到的模型追加进多行列表（跳过已有项，保持原有内容不动）。
    private func appendModels(_ models: [String]) {
        let existing = Set(parsedModels)
        let additions = models.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        var text = modelsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { text += "\n" }
        text += additions.joined(separator: "\n")
        modelsText = text
        ensureDefaultModelValid()
    }

    private func save() {
        var saved = node
        saved.name = node.name.trimmingCharacters(in: .whitespaces)
        saved.baseURL = node.baseURL.trimmingCharacters(in: .whitespaces)
        saved.apiKey = node.apiKey.trimmingCharacters(in: .whitespaces)
        saved.models = parsedModels
        if !saved.models.contains(saved.defaultModel) {
            saved.defaultModel = saved.models.first ?? ""
        }
        if !(1...65_535).contains(saved.proxyPort) {
            saved.proxyPort = OpenCodeNode.defaultProxyPort
        }
        onSave(saved)
        dismiss()
    }
}

#Preview {
    OpenCodeNodeEditorView(node: OpenCodeNode()) { _ in }
}
