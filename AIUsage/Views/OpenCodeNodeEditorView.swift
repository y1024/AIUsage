import SwiftUI

// MARK: - OpenCode Node Editor
// 新建/编辑 OpenCode 接入节点的 sheet：名称、Base URL、API Key、模型列表（每行一个，
// 支持从上游获取后逐个/批量添加）、连通性测试、默认模型与可选的上下文/输出上限。
// 保存交由调用方落库；激活节点的编辑会即时重写 opencode.json。

struct OpenCodeNodeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (OpenCodeNode) -> Void

    @State private var node: OpenCodeNode
    @State private var modelsText: String
    @State private var showAPIKey = false
    @StateObject private var modelFetch = ModelFetchState()
    @State private var connectivity: ConnectivityResult = .idle
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicSection
                    modelsSection
                    limitsSection
                    proxySection
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 640)
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

    private func runConnectivityTest() {
        guard let model = parsedModels.first,
              let url = Self.testEndpointURL(baseURL: node.baseURL, protocolType: node.protocolType) else { return }
        connectivity = .testing
        let apiKey = node.apiKey
        let protocolType = node.protocolType

        Task {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                if protocolType == .anthropic {
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                } else {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: Self.testBody(model: model, protocolType: protocolType))

            let start = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    connectivity = .success(ms: elapsed)
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let bodyText = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    connectivity = .failure("HTTP \(status): \(String(bodyText.prefix(160)))")
                }
            } catch {
                connectivity = .failure(String(error.localizedDescription.prefix(160)))
            }
        }
    }

    /// 连通性测试端点：base 末尾已含 /v1 则直接拼协议路径，否则补 /v1。
    private static func testEndpointURL(baseURL: String, protocolType: OpenCodeProtocol) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.lowercased().hasSuffix("/v1")
            ? protocolType.requestPath
            : "/v1" + protocolType.requestPath
        return URL(string: trimmed + path)
    }

    /// 各协议最小可行的 1-token 探测请求体。
    private static func testBody(model: String, protocolType: OpenCodeProtocol) -> [String: Any] {
        switch protocolType {
        case .openAICompatible:
            return [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
                "stream": false,
            ]
        case .anthropic:
            return [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
            ]
        case .openAIResponses:
            // Responses API 要求 max_output_tokens ≥ 16。
            return [
                "model": model,
                "input": "ping",
                "max_output_tokens": 16,
                "stream": false,
            ]
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
