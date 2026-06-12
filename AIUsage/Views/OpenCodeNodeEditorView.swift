import SwiftUI

// MARK: - OpenCode Node Editor
// 新建/编辑 OpenCode 接入节点的 sheet：名称、Base URL、API Key、模型列表（每行一个）、
// 默认模型与可选的上下文/输出上限。保存交由调用方落库；激活节点的编辑会即时重写 opencode.json。

struct OpenCodeNodeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (OpenCodeNode) -> Void

    @State private var node: OpenCodeNode
    @State private var modelsText: String
    @State private var showAPIKey = false
    private let isNew: Bool

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
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
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

            fieldLabel(L("Base URL", "Base URL"), required: true)
            TextField("https://api.example.com/v1", text: $node.baseURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text(L(
                "OpenAI-compatible endpoint. OpenCode appends /chat/completions to it.",
                "OpenAI 兼容接入点，OpenCode 会在其后拼接 /chat/completions。"
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
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Models (one per line)", "模型列表（每行一个）"), required: true)
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

    private func save() {
        var saved = node
        saved.name = node.name.trimmingCharacters(in: .whitespaces)
        saved.baseURL = node.baseURL.trimmingCharacters(in: .whitespaces)
        saved.apiKey = node.apiKey.trimmingCharacters(in: .whitespaces)
        saved.models = parsedModels
        if !saved.models.contains(saved.defaultModel) {
            saved.defaultModel = saved.models.first ?? ""
        }
        onSave(saved)
        dismiss()
    }
}

#Preview {
    OpenCodeNodeEditorView(node: OpenCodeNode()) { _ in }
}
