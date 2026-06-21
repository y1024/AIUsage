import Combine
import SwiftUI

// MARK: - Shared Model Fetch & Suggestion Components
// 三个代理编辑器（Claude / Codex / OpenCode）共用的「获取模型 + 输入补全」组件，
// 取代原先 ProxyConfigEditorView 与 CodexProxyEditorView 里的两份重复实现。
// 数据来源: 上游 GET /v1/models（OpenAI 兼容）或 GET <base>/models（Anthropic 风格）。

/// 模型列表端点风格。两种风格的端点路径都是 <root>/v1/models
/// （base 末尾已含 /v1 则拼 /models，否则拼 /v1/models），区别在认证头。
enum ModelListEndpointStyle {
    /// OpenAI 兼容：Authorization: Bearer。
    case openAICompatible
    /// Anthropic 风格：附加 x-api-key + anthropic-version 头。
    case anthropic
}

/// 拉取到的模型列表与请求状态（每个编辑器持有一个实例）。
@MainActor
final class ModelFetchState: ObservableObject {
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var isFetching = false
    @Published private(set) var errorMessage: String?

    static func modelsURL(baseURL: String, style: ModelListEndpointStyle) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }

        let path = trimmed.lowercased().hasSuffix("/v1") ? "/models" : "/v1/models"
        return URL(string: trimmed + path)
    }

    func fetch(baseURL: String, apiKey: String, style: ModelListEndpointStyle) async {
        guard let url = Self.modelsURL(baseURL: baseURL, style: style) else { return }
        guard !isFetching else { return }

        isFetching = true
        errorMessage = nil
        defer { isFetching = false }

        var request = URLRequest(url: url, timeoutInterval: 10)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if style == .anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                errorMessage = "Invalid response"
                return
            }
            let models = dataArr.compactMap { $0["id"] as? String }.sorted()
            availableModels = models
            errorMessage = models.isEmpty ? "No models found" : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func filteredModels(for text: String) -> [String] {
        guard !text.isEmpty else { return availableModels }
        return availableModels.filter { $0.localizedCaseInsensitiveContains(text) }
    }
}

// MARK: - Fetch Button + Status Row

struct ModelFetchControls: View {
    @ObservedObject var state: ModelFetchState
    let baseURL: String
    let apiKey: String
    var style: ModelListEndpointStyle = .openAICompatible
    /// 上游必须配 Key 才允许拉取（本地上游如 Ollama 可置 false）。
    var requiresAPIKey = true

    private var disabled: Bool {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (requiresAPIKey && apiKey.isEmpty)
            || state.isFetching
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await state.fetch(baseURL: baseURL, apiKey: apiKey, style: style) }
            } label: {
                HStack(spacing: 4) {
                    if state.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(L("Fetch Models", "获取模型"))
                }
                .font(.caption.weight(.semibold))
            }
            .disabled(disabled)

            if !state.availableModels.isEmpty {
                Text(L("\(state.availableModels.count) models available", "已获取 \(state.availableModels.count) 个模型"))
                    .font(.caption2).foregroundStyle(.green)
            } else if let error = state.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Text Field with Suggestions

/// 单模型输入框 + 已获取模型的内联补全下拉。
struct ModelSuggestionField: View {
    @Binding var text: String
    let placeholder: String
    @ObservedObject var state: ModelFetchState

    var body: some View {
        let suggestions = state.filteredModels(for: text)
        let showSuggestions = !state.availableModels.isEmpty && !text.isEmpty && !suggestions.isEmpty
            && !suggestions.contains(where: { $0 == text })

        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            if showSuggestions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions.prefix(8), id: \.self) { model in
                            Button {
                                text = model
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
}

// MARK: - Fetched Model Picker List (search + full-row append)

/// 已获取模型的可搜索列表：顶部搜索框 + 计数 + 全部添加；整行点击即添加，
/// 左侧状态图标（加号→对勾），hover 高亮，右侧留白避开滚动条，字号更大、行高更舒展。
/// 四端共用（OpenCode 直接用；Claude/Codex/API 提供商经 ProxyModelLibraryEditor 间接用）。
struct FetchedModelAppendList: View {
    @ObservedObject var state: ModelFetchState
    /// 当前已在列表中的模型（用于标记「已添加」并禁止重复添加）。
    let existingModels: Set<String>
    let onAppend: (String) -> Void
    let onAppendAll: ([String]) -> Void

    @State private var query = ""
    @State private var hovered: String?

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return state.availableModels }
        return state.availableModels.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var addedCount: Int {
        state.availableModels.filter { existingModels.contains($0) }.count
    }

    private var allAdded: Bool {
        !state.availableModels.isEmpty && state.availableModels.allSatisfy { existingModels.contains($0) }
    }

    var body: some View {
        if !state.availableModels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                listBody
            }
        }
    }

    // MARK: Header (search + counts + add all)

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L("Search models", "搜索模型"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 240)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            Text(L("\(state.availableModels.count) fetched · \(addedCount) added",
                   "已获取 \(state.availableModels.count) · 已添加 \(addedCount)"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Button {
                onAppendAll(state.availableModels.filter { !existingModels.contains($0) })
            } label: {
                Label(L("Add All", "全部添加"), systemImage: "plus.square.on.square")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(allAdded)
        }
    }

    // MARK: List

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if filtered.isEmpty {
                    Text(L("No models match \"\(query)\"", "没有匹配「\(query)」的模型"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                } else {
                    ForEach(filtered, id: \.self) { model in
                        row(model)
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 10)
            .padding(.leading, 5)
        }
        .frame(maxHeight: 220)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }

    private func row(_ model: String) -> some View {
        let added = existingModels.contains(model)
        let isHovered = hovered == model
        return Button {
            guard !added else { return }
            onAppend(model)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(added ? Color.green : Color.accentColor)
                Text(model)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(added ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if added {
                    Text(L("Added", "已添加"))
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered && !added ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(added)
        .onHover { hovering in
            hovered = hovering ? model : (hovered == model ? nil : hovered)
        }
    }
}
