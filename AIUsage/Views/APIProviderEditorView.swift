import SwiftUI

// MARK: - API Provider Editor
// 新建/编辑「API 提供商」主配置的 sheet：名称 / 格式 / Base URL / API Key /
// 模型库与定价（复用 ProxyModelLibraryEditor）/ 默认模型 / 共享高级参数 + 「分发到」勾选。
// 保存交由调用方（APIProviderListView）落库并触发分发/同步。

struct APIProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (APIProvider, Set<ProxyTarget>) -> Void

    @State private var draft: APIProvider
    @State private var library: [ProxyConfiguration.MappedModel]
    @State private var currency: ProxyConfiguration.PricingCurrency
    @State private var defaultModel: String
    @State private var selectedTargets: Set<ProxyTarget>
    @State private var temperatureText: String
    @State private var topPText: String
    @State private var showAdvanced = false
    @StateObject private var modelFetch = ModelFetchState()
    private let isNew: Bool

    init(
        provider: APIProvider,
        initialTargets: Set<ProxyTarget>,
        onSave: @escaping (APIProvider, Set<ProxyTarget>) -> Void
    ) {
        self.onSave = onSave
        _draft = State(initialValue: provider)
        _library = State(initialValue: provider.models)
        _currency = State(initialValue: provider.models.first?.pricing.currency ?? .usd)
        _defaultModel = State(initialValue: provider.defaultModel)
        _selectedTargets = State(initialValue: initialTargets)
        _temperatureText = State(initialValue: Self.decimalText(provider.temperature))
        _topPText = State(initialValue: Self.decimalText(provider.topP))
        isNew = provider.name.isEmpty && provider.baseURL.isEmpty && provider.models.isEmpty
    }

    private static func decimalText(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    private func parsedOptionalDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private var fetchStyle: ModelListEndpointStyle {
        draft.format == .anthropic ? .anthropic : .openAICompatible
    }

    private var canSave: Bool {
        draft.baseURL.trimmingCharacters(in: .whitespaces).nilIfBlank != nil && !library.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EditorCard(L("API Format", "接口格式")) { formatSection }
                    EditorCard(L("Basic Information", "基本信息")) { basicSection }
                    EditorCard { modelsSection }
                    EditorCard { advancedSection }
                    EditorCard(L("Distribute To", "分发到")) { distributionSection }
                }
                .padding(18)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 760, height: 820)
        .onChange(of: draft.format) { _, newFormat in
            // 格式变更后去掉不兼容的分发目标（如切到非 Responses 时移除 Codex）。
            selectedTargets = selectedTargets.filter { $0.supports(newFormat) }
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Color.accentColor)
            Text(isNew ? L("New API Provider", "新建 API 提供商") : L("Edit API Provider", "编辑 API 提供商"))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("Cancel", "取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("Save", "保存")) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var formatSection: some View {
        CapsuleInterfacePicker(
            options: [
                SelectableCardOption(
                    APIFormat.openAIChatCompletions,
                    title: "OpenAI Chat",
                    subtitle: L("OpenAI /chat/completions (DeepSeek, Ollama, gateways…).",
                                "OpenAI /chat/completions（DeepSeek、Ollama、第三方网关…）。"),
                    systemImage: "arrow.triangle.swap",
                    tint: ProxyBrand.openAI
                ),
                SelectableCardOption(
                    APIFormat.anthropic,
                    title: "Anthropic",
                    subtitle: L("Anthropic /v1/messages (official or compatible gateways).",
                                "Anthropic /v1/messages（官方或兼容网关）。"),
                    systemImage: "bolt.horizontal.fill",
                    tint: ProxyBrand.anthropic
                ),
                SelectableCardOption(
                    APIFormat.openAIResponses,
                    title: "OpenAI Responses",
                    subtitle: L("OpenAI /v1/responses (the only format Codex accepts).",
                                "OpenAI /v1/responses（Codex 仅支持此格式）。"),
                    systemImage: "arrow.up.forward.app.fill",
                    tint: ProxyBrand.codex
                )
            ],
            selection: $draft.format
        )
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("Name", "名称"), required: false)
                TextField(L("e.g. DeepSeek Official", "如：DeepSeek 官方"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("Base URL", "Base URL"), required: true)
                TextField("https://api.example.com/v1", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("API Key", "API Key"), required: false)
                SecureKeyField("sk-...", text: $draft.apiKey)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelFetchControls(
                state: modelFetch,
                baseURL: draft.baseURL,
                apiKey: draft.apiKey,
                style: fetchStyle,
                requiresAPIKey: false
            )

            ProxyModelLibraryEditor(library: $library, currency: $currency, modelFetch: modelFetch)

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(L("Default Model", "默认模型"), required: false)
                HStack(spacing: 6) {
                    TextField(L("falls back to first model", "缺省回退到首个模型"), text: $defaultModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    ModelLibrarySlotPicker(selection: $defaultModel, library: library)
                }
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L(
                    "These generation defaults only apply to OpenCode-distributed nodes.",
                    "以下生成参数仅对分发到 OpenCode 的节点生效。"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)

                HStack(spacing: 12) {
                    labeledIntField(L("Context Limit", "上下文上限"), value: $draft.contextLimit)
                    labeledIntField(L("Output Limit", "输出上限"), value: $draft.outputLimit)
                    labeledIntField(L("Max Output Tokens", "最大输出 token"), value: $draft.maxOutputTokens)
                }
                HStack(spacing: 12) {
                    labeledTextField(L("Temperature", "温度"), text: $temperatureText, placeholder: "0.7")
                    labeledTextField(L("Top P", "Top P"), text: $topPText, placeholder: "1")
                    Spacer()
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L("Advanced Parameters", "高级参数"))
                .font(.subheadline.weight(.semibold))
        }
    }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(
                "Selected proxies get a linked node mapped from this provider. Unchecking removes that proxy's linked node.",
                "勾选的代理会生成一个由本提供商映射的链接节点；取消勾选会移除该代理下的链接节点。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(ProxyTarget.allCases) { target in
                distributionRow(target)
            }
        }
    }

    private func distributionRow(_ target: ProxyTarget) -> some View {
        let supported = target.supports(draft.format)
        return HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(
                get: { selectedTargets.contains(target) },
                set: { on in
                    if on { selectedTargets.insert(target) } else { selectedTargets.remove(target) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName)
                        .font(.body)
                    if let reason = target.incompatibilityReason(for: draft.format) {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!supported)
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ title: String, required: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if required {
                Text("*").font(.caption.weight(.bold)).foregroundStyle(.red)
            }
        }
    }

    private func labeledIntField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        }
    }

    private func labeledTextField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        }
    }

    // MARK: - Save

    private func save() {
        var provider = draft
        provider.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.models = library
        provider.defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.temperature = parsedOptionalDouble(temperatureText).map { min(max($0, 0), 2) }
        provider.topP = parsedOptionalDouble(topPText).map { min(max($0, 0), 1) }
        provider.maxOutputTokens = max(0, provider.maxOutputTokens)
        provider.contextLimit = max(0, provider.contextLimit)
        provider.outputLimit = max(0, provider.outputLimit)
        onSave(provider, selectedTargets)
        dismiss()
    }
}
