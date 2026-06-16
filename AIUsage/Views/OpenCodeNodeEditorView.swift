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
    /// 行式模型编辑。模型 ID 可编辑，不能充当 ForEach 身份（打字即重建行、丢焦点），
    /// 故用稳定 UUID 行号包装。
    @State private var modelRows: [ModelRow]
    /// 已展开 modalities 配置面板的模型行 id 集合（issue #24，每模型独立配置模态）。
    @State private var expandedModalityRows: Set<UUID> = []
    @StateObject private var modelFetch = ModelFetchState()
    @State private var connectivity: ConnectivityResult = .idle
    @State private var selectedTab: OpenCodeEditorTab = .settings
    /// 生成参数的文本镜像：temperature/topP/penalty 的 0 是合法值，用文本输入避免 0 哨兵歧义，
    /// 解析为可选 Double（空/非法 = nil）。maxOutputTokens 直接绑定 node（Int，0 = 不写）。
    @State private var temperatureText: String
    @State private var topPText: String
    @State private var frequencyPenaltyText: String
    @State private var presencePenaltyText: String
    private let isNew: Bool

    struct ModelRow: Identifiable {
        let id = UUID()
        var entry: OpenCodeModelEntry
    }

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
        _modelRows = State(initialValue: node.modelEntries.map { ModelRow(entry: $0) })
        _temperatureText = State(initialValue: Self.decimalText(node.temperature))
        _topPText = State(initialValue: Self.decimalText(node.topP))
        _frequencyPenaltyText = State(initialValue: Self.decimalText(node.frequencyPenalty))
        _presencePenaltyText = State(initialValue: Self.decimalText(node.presencePenalty))
        isNew = node.name.isEmpty && node.baseURL.isEmpty && node.modelEntries.isEmpty
    }

    /// 可选 Double → 输入框文本（nil → 空串；用 %g 紧凑显示，0.7 → "0.7"、1 → "1"）。
    private static func decimalText(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    /// 输入框文本 → 可选 Double（去空白后空串/非法 = nil）。
    private func parsedOptionalDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    /// 把文本镜像解析并夹到合法区间后写回节点的生成参数（草稿预览与保存共用，口径一致）。
    private func applyParsedParameters(to node: inout OpenCodeNode) {
        node.temperature = parsedOptionalDouble(temperatureText).map { min(max($0, 0), 2) }
        node.topP = parsedOptionalDouble(topPText).map { min(max($0, 0), 1) }
        node.frequencyPenalty = parsedOptionalDouble(frequencyPenaltyText).map { min(max($0, -2), 2) }
        node.presencePenalty = parsedOptionalDouble(presencePenaltyText).map { min(max($0, -2), 2) }
        node.maxOutputTokens = max(0, node.maxOutputTokens)
    }

    /// 行内容 → 模型条目（去空白、去重、保持顺序）。
    private var parsedEntries: [OpenCodeModelEntry] {
        var seen = Set<String>()
        return modelRows.compactMap { row in
            var entry = row.entry
            entry.id = entry.id.trimmingCharacters(in: .whitespaces)
            guard !entry.id.isEmpty, seen.insert(entry.id).inserted else { return nil }
            return entry
        }
    }

    private var parsedModels: [String] { parsedEntries.map(\.id) }

    private var canSave: Bool {
        node.baseURL.trimmingCharacters(in: .whitespaces).nilIfBlank != nil
    }

    /// 编辑中的草稿节点（模型来自行编辑的即时解析），供连通性测试与 JSON 预览。
    private var draftNode: OpenCodeNode {
        var draft = node
        draft.modelEntries = parsedEntries
        applyParsedParameters(to: &draft)
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
                            parametersSection
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
        // 与 Claude/Codex 编辑器同尺寸（设置 750、JSON 预览 1100，高 800）。
        .frame(width: selectedTab == .jsonPreview ? 1100 : 750, height: 800)
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
    // 分层最终预览（与 Claude 编辑器「最终 JSON」同款）：合并策略选择器 +
    // 行级来源标注（无标=用户原文 / C=通用 / N=受管 / O=通用覆盖原文）。

    /// 草稿节点的合并策略下，应并入的通用配置片段（nil = 不合并）。
    private var draftCommonSettings: [String: Any]? {
        let store = OpenCodeNodeStore.shared
        let mode = node.commonConfigMode ?? .followGlobal
        guard mode.shouldMerge(globalEnabled: store.globalConfig.enabled),
              !store.globalConfig.settings.isEmpty else { return nil }
        return store.globalConfig.settings
    }

    private var jsonPreviewTab: some View {
        let manager = OpenCodeConfigManager.shared
        let baseURLOverride = node.proxyEnabled ? node.proxyLocalBaseURL : nil
        let common = draftCommonSettings
        // 干净原文只读一次盘，预览合并与行标注共用，避免同次刷新双次读盘。
        let pristine = manager.pristineConfig()
        let merged = manager.previewMergedConfig(
            node: draftNode,
            baseURLOverride: baseURLOverride,
            commonSettings: common,
            pristine: pristine
        )
        let jsonText = OpenCodeConfigManager.jsonString(merged)
        let markers = OpenCodeConfigLayering.lineMarkers(
            text: jsonText,
            pristine: pristine,
            common: common ?? [:],
            managed: manager.managedLayer(node: draftNode, baseURLOverride: baseURLOverride)
        )

        return VStack(alignment: .leading, spacing: 10) {
            mergePolicySection

            HStack(spacing: 8) {
                Text(L("opencode.json after activation", "激活后的 opencode.json"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                sourceLegend(L("Original", "用户原文"), .secondary.opacity(0.35))
                sourceLegend(L("Common", "通用配置"), .blue)
                sourceLegend(L("Managed", "节点受管"), .green)
                sourceLegend(L("Override", "通用覆盖"), .orange)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(jsonText, forType: .string)
                } label: {
                    Label(L("Copy", "复制"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            JSONRawEditorView(
                jsonText: .constant(jsonText),
                error: .constant(nil),
                title: "opencode.json",
                isEditable: false,
                showsActions: false,
                lineMarkers: markers
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private var mergePolicySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Common Config", "通用配置"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: OpenCodeNodeStore.shared.globalConfig.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(OpenCodeNodeStore.shared.globalConfig.enabled ? .green : .secondary)
                Text(OpenCodeNodeStore.shared.globalConfig.enabled
                     ? L("Global switch on", "全局开关已开启")
                     : L("Global switch off", "全局开关已关闭"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Picker("", selection: Binding(
                get: { node.commonConfigMode ?? .followGlobal },
                set: { node.commonConfigMode = $0 }
            )) {
                ForEach(CommonConfigMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text((node.commonConfigMode ?? .followGlobal).description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func sourceLegend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.25))
                .frame(width: 16, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
            SecureKeyField("sk-...", text: $node.apiKey)

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

    // MARK: - Models（行式：单选默认模型 + 每模型独立定价）

    private var showsPriceColumns: Bool { node.pricingCurrency != .none }

    /// 当前 CNY/USD 汇率的紧凑文本（如 7、7.3），用于定价说明里实时回显用户在设置里配置的汇率。
    private var cnyRateText: String { String(format: "%g", AppSettings.cnyPerUSD) }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                fieldLabel(L("Models & Pricing", "模型与定价"), required: true)
                Spacer()
                if showsPriceColumns {
                    Button {
                        autoFillCachePrices()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                            Text(L("Auto-fill Cache (1.25× / 0.1×)", "自动填充缓存（1.25×/0.1×）"))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .help(L(
                        "Set cache-write = 1.25× input and cache-read = 0.1× input for every model with an input price.",
                        "为所有已填输入价的模型按 ×1.25 / ×0.1 计算缓存写入与读取单价。"
                    ))
                }
                Picker("", selection: $node.pricingCurrency) {
                    ForEach(OpenCodePricingCurrency.allCases, id: \.self) { currency in
                        Text(currency.label).tag(currency)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
            }

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

            if !modelRows.isEmpty {
                modelColumnHeaders
                ForEach($modelRows) { $row in
                    modelRowView($row)
                }
                // 不在每次按键时校验默认模型：编辑模型 ID 的中途态会被误判为失配而跳走单选。
                // 默认模型在增行(appendModels)、删行(modelRowView 删除按钮)与保存(save)时已兜底校验。
            }

            Button {
                modelRows.append(ModelRow(entry: OpenCodeModelEntry(id: "")))
            } label: {
                Label(L("Add Model", "添加模型"), systemImage: "plus.circle")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)

            Text(showsPriceColumns
                 ? L(
                     "Pick the default model with the radio button — switchable from the node card anytime. Prices are per million tokens (\(node.pricingCurrency == .cny ? "CNY, converted to USD at ≈\(cnyRateText) when written" : "USD")); OpenCode records real spend per message.",
                     "单选钮选默认模型——节点卡片上也可随时切换。单价为每百万 token（\(node.pricingCurrency == .cny ? "人民币，写入时按 ≈\(cnyRateText) 折算为美元" : "美元")），OpenCode 据此逐条记录真实消费。"
                 )
                 : L(
                     "Pick the default model with the radio button — switchable from the node card anytime. Pricing is off (cost stays $0); choose USD/CNY to price each model.",
                     "单选钮选默认模型——节点卡片上也可随时切换。当前不计价（费用恒为 $0）；选择 USD/CNY 后可为每个模型单独定价。"
                 ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelColumnHeaders: some View {
        HStack(spacing: 6) {
            Text(L("Default", "默认")).frame(width: 30)
            Text(L("Model ID", "模型 ID")).frame(maxWidth: .infinity, alignment: .leading)
            if showsPriceColumns {
                Group {
                    Text(L("Input", "输入"))
                    Text(L("Output", "输出"))
                    Text(L("Cache W", "缓存写"))
                    Text(L("Cache R", "缓存读"))
                }
                .frame(width: 64, alignment: .leading)
            }
            Spacer().frame(width: 20)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    }

    private func modelRowView(_ row: Binding<OpenCodeNodeEditorView.ModelRow>) -> some View {
        let modelId = row.wrappedValue.entry.id.trimmingCharacters(in: .whitespaces)
        let isDefault = !modelId.isEmpty && node.defaultModel == modelId
        let rowId = row.wrappedValue.id
        let isExpanded = expandedModalityRows.contains(rowId)
        let hasModalities = row.wrappedValue.entry.hasModalities
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    guard !modelId.isEmpty else { return }
                    node.defaultModel = modelId
                } label: {
                    Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isDefault ? Self.brand : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .frame(width: 30)
                .help(L("Use as default model", "设为默认模型"))

                TextField("deepseek-chat", text: row.entry.id)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .autocorrectionDisabled()

                if showsPriceColumns {
                    priceField(row.entry.priceInputPerMillion)
                    priceField(row.entry.priceOutputPerMillion)
                    priceField(row.entry.priceCacheWritePerMillion)
                    priceField(row.entry.priceCacheReadPerMillion)
                }

                Button {
                    if isExpanded { expandedModalityRows.remove(rowId) }
                    else { expandedModalityRows.insert(rowId) }
                } label: {
                    Image(systemName: hasModalities ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        .font(.system(size: 12))
                        .foregroundStyle(hasModalities ? Self.brand : Color.secondary.opacity(isExpanded ? 0.9 : 0.5))
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(L("Configure modalities for this model", "为该模型配置模态（输入/输出）"))

                Button {
                    modelRows.removeAll { $0.id == row.wrappedValue.id }
                    expandedModalityRows.remove(rowId)
                    ensureDefaultModelValid()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(L("Remove model", "移除模型"))
            }

            if isExpanded {
                modalityEditor(row)
            }
        }
    }

    /// 单个模型的 modalities 配置面板：输入/输出两组可多选的模态芯片（issue #24）。
    private func modalityEditor(_ row: Binding<OpenCodeNodeEditorView.ModelRow>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            modalityRow(
                title: L("Input", "输入"),
                options: OpenCodeModality.allCases,
                selection: row.entry.inputModalities
            )
            modalityRow(
                title: L("Output", "输出"),
                options: OpenCodeModality.outputCases,
                selection: row.entry.outputModalities
            )
            Text(L(
                "Leave empty to use the model's defaults. Written into the model's modalities block in opencode.json.",
                "留空则使用模型默认值。会写入 opencode.json 中该模型的 modalities 块。"
            ))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .padding(.leading, 30)
    }

    private func modalityRow(
        title: String,
        options: [OpenCodeModality],
        selection: Binding<[OpenCodeModality]>
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(options) { modality in
                    modalityChip(modality, selection: selection)
                }
            }
        }
    }

    private func modalityChip(
        _ modality: OpenCodeModality,
        selection: Binding<[OpenCodeModality]>
    ) -> some View {
        let isOn = selection.wrappedValue.contains(modality)
        return Button {
            if isOn {
                selection.wrappedValue.removeAll { $0 == modality }
            } else if !selection.wrappedValue.contains(modality) {
                selection.wrappedValue.append(modality)
            }
        } label: {
            Text(modality.label)
                .font(.system(size: 10, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isOn ? Self.brand : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func priceField(_ value: Binding<Double>) -> some View {
        TextField("0", value: value, format: .number.precision(.fractionLength(0...4)))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 64)
    }

    private func autoFillCachePrices() {
        for index in modelRows.indices where modelRows[index].entry.priceInputPerMillion > 0 {
            let input = modelRows[index].entry.priceInputPerMillion
            modelRows[index].entry.priceCacheWritePerMillion = input * OpenCodeNode.cacheWriteMultiplier
            modelRows[index].entry.priceCacheReadPerMillion = input * OpenCodeNode.cacheReadMultiplier
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

    // MARK: - Generation Parameters
    // 节点级生成参数（可选）：统一写入每个模型的 options 块，OpenCode 透传给上游。
    // 留空 = 不写、由上游取默认；与「上限」（limit.context/output）相互独立。

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Model Parameters (optional, blank = upstream default)", "模型参数（可选，留空 = 由上游取默认）"), required: false)
            HStack(spacing: 12) {
                decimalParamField("temperature", placeholder: "0.7", text: $temperatureText)
                decimalParamField("top_p", placeholder: "1.0", text: $topPText)
                labeledNumberField("max_tokens", value: $node.maxOutputTokens)
            }
            HStack(spacing: 12) {
                decimalParamField("frequency_penalty", placeholder: "0", text: $frequencyPenaltyText)
                decimalParamField("presence_penalty", placeholder: "0", text: $presencePenaltyText)
                Spacer()
            }
            Text(L(
                "Applied to every model's options block (temperature / top_p / max_tokens / …) and forwarded to the upstream. Independent from the limits above.",
                "统一写入每个模型的 options 块（temperature / top_p / max_tokens / …），由 OpenCode 透传给上游；与上方「上限」相互独立。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func decimalParamField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 76)
                .autocorrectionDisabled()
        }
    }

    // MARK: - Proxy

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

            // 端口常驻显示（CC 同款），未开启代理时禁用。
            HStack(spacing: 6) {
                Text(L("Port", "端口"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("\(OpenCodeNode.defaultProxyPort)", value: $node.proxyPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .disabled(!node.proxyEnabled)
                Text(node.proxyEnabled
                     ? L("OpenCode will connect to 127.0.0.1:\(String(node.proxyPort)).", "OpenCode 将连接 127.0.0.1:\(String(node.proxyPort))。")
                     : L("Enable the proxy to edit the port.", "开启代理后可修改端口。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .opacity(node.proxyEnabled ? 1 : 0.55)

            if node.proxyEnabled, node.protocolType == .openAIResponses, node.apiKey.nilIfBlank == nil {
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

    /// 把获取到的模型追加为新行（跳过已有项，保持原有行不动）。
    private func appendModels(_ models: [String]) {
        let existing = Set(parsedModels)
        let additions = models.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        modelRows.append(contentsOf: additions.map { ModelRow(entry: OpenCodeModelEntry(id: $0)) })
        ensureDefaultModelValid()
    }

    private func save() {
        var saved = node
        saved.name = node.name.trimmingCharacters(in: .whitespaces)
        saved.baseURL = node.baseURL.trimmingCharacters(in: .whitespaces)
        saved.apiKey = node.apiKey.trimmingCharacters(in: .whitespaces)
        saved.modelEntries = parsedEntries.map { entry in
            var clamped = entry
            clamped.priceInputPerMillion = max(0, clamped.priceInputPerMillion)
            clamped.priceOutputPerMillion = max(0, clamped.priceOutputPerMillion)
            clamped.priceCacheReadPerMillion = max(0, clamped.priceCacheReadPerMillion)
            clamped.priceCacheWritePerMillion = max(0, clamped.priceCacheWritePerMillion)
            return clamped
        }
        if !saved.models.contains(saved.defaultModel) {
            saved.defaultModel = saved.models.first ?? ""
        }
        if !(1...65_535).contains(saved.proxyPort) {
            saved.proxyPort = OpenCodeNode.defaultProxyPort
        }
        applyParsedParameters(to: &saved)
        onSave(saved)
        dismiss()
    }
}

#Preview {
    OpenCodeNodeEditorView(node: OpenCodeNode()) { _ in }
}
