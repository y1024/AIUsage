import Foundation

// MARK: - OpenCode Node
// OpenCode 接入节点：一个 OpenAI 兼容上游（baseURL + API Key + 模型列表）。
// 激活时由 OpenCodeConfigManager 注入 ~/.config/opencode/opencode.json 的受管 provider 块，
// OpenCode 原生直连上游，无本地代理进程（与 Claude/Codex 代理节点体系相互独立）。
// 持久化: ~/.config/aiusage/opencode-nodes.json（OpenCodeNodeStore）。

struct OpenCodeNode: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    /// 模型 ID 列表（顺序即展示顺序），至少一个。
    var models: [String]
    /// 顶层 `model` 指向的默认模型（必须在 models 中）。
    var defaultModel: String
    /// 写进每个模型 `limit.context` 的上下文窗口；0 = 不写，由 OpenCode 取默认。
    var contextLimit: Int
    /// 写进每个模型 `limit.output` 的输出上限；0 = 不写。
    var outputLimit: Int
    var createdAt: Date
    var lastUsedAt: Date?
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        models: [String] = [],
        defaultModel: String = "",
        contextLimit: Int = 0,
        outputLimit: Int = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sortOrder: Int = Int.max
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.defaultModel = defaultModel
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
    }

    /// 展示名：未命名时回退到 baseURL 的 host。
    var displayName: String {
        if let name = name.nilIfBlank { return name }
        if let host = URL(string: baseURL)?.host { return host }
        return AppSettings.shared.t("Untitled Node", "未命名节点")
    }

    /// 实际生效的默认模型：defaultModel 失配时回退到列表首个。
    var effectiveDefaultModel: String? {
        if models.contains(defaultModel) { return defaultModel }
        return models.first
    }

    /// 节点是否填齐了激活所需字段。
    var isComplete: Bool {
        baseURL.nilIfBlank != nil && effectiveDefaultModel != nil
    }
}
