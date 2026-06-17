import Foundation
import QuotaBackend

// MARK: - API Provider
// 「API 提供商」是一份与具体代理无关的统一上游配置（baseURL + apiKey + 格式 + 模型/定价）。
// 它是分发到 Codex / Claude / OpenCode 三套代理的「主配置/真相源」：
//   - distribute：把主配置映射成各代理的节点（链接节点，携带 linkedProviderId）。
//   - 同步模型（继承 + 局部覆盖）：主配置改了，链接节点里未被局部覆盖的共享字段跟随同步；
//     代理专属字段（端口、Claude 槽位、OpenCode slug/生成参数等）始终本地独立。
// 持久化: ~/.config/aiusage/api-providers.json（APIProviderStore）。

/// API 接口格式：决定可分发到哪些代理、以及映射出的节点类型/上游协议。
enum APIFormat: String, Codable, CaseIterable, Identifiable {
    /// OpenAI Chat Completions（绝大多数兼容上游：DeepSeek、Ollama、第三方网关…）。
    case openAIChatCompletions = "openai-chat-completions"
    /// Anthropic Messages（官方或 Anthropic 兼容网关）。
    case anthropic = "anthropic"
    /// OpenAI Responses（官方 /v1/responses 或同协议网关；Codex 仅支持此格式）。
    case openAIResponses = "openai-responses"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIChatCompletions: return AppSettings.shared.t("OpenAI Chat Completions", "OpenAI Chat Completions")
        case .anthropic: return "Anthropic"
        case .openAIResponses: return "OpenAI Responses"
        }
    }

    var badgeName: String {
        switch self {
        case .openAIChatCompletions: return "OpenAI Chat"
        case .anthropic: return "Anthropic"
        case .openAIResponses: return "Responses"
        }
    }

    /// 映射到 OpenCode 受管 provider 协议。
    var openCodeProtocol: OpenCodeProtocol {
        switch self {
        case .openAIChatCompletions: return .openAICompatible
        case .anthropic: return .anthropic
        case .openAIResponses: return .openAIResponses
        }
    }

    /// 映射到 OpenAI 上游接口模式（Anthropic 格式无对应，返回 nil）。
    var openAIUpstreamAPI: OpenAIUpstreamAPI? {
        switch self {
        case .openAIChatCompletions: return .chatCompletions
        case .openAIResponses: return .responses
        case .anthropic: return nil
        }
    }
}

/// 可分发到的代理目标。
enum ProxyTarget: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude
    case openCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .openCode: return "OpenCode"
        }
    }

    /// 兼容性：Codex 上游锁定 Responses，故只接受 openAIResponses；Claude/OpenCode 三格式皆可
    /// （Claude：OpenAI 格式→转换代理，Anthropic→透传代理）。
    func supports(_ format: APIFormat) -> Bool {
        switch self {
        case .codex: return format == .openAIResponses
        case .claude: return true
        case .openCode: return true
        }
    }

    /// 该格式不被支持时给用户的原因说明。
    func incompatibilityReason(for format: APIFormat) -> String? {
        guard !supports(format) else { return nil }
        switch self {
        case .codex:
            return AppSettings.shared.t(
                "Codex only speaks the OpenAI Responses API upstream.",
                "Codex 上游仅支持 OpenAI Responses 接口。"
            )
        default:
            return AppSettings.shared.t("Incompatible format.", "格式不兼容。")
        }
    }
}

/// 可被用户在链接节点上「局部覆盖」、覆盖后不再跟随主配置同步的共享字段键。
/// 格式（format）决定节点类型，不可单独覆盖，始终跟随主配置。
enum APIProviderSharedKey {
    static let name = "name"
    static let baseURL = "baseURL"
    static let apiKey = "apiKey"
    static let models = "models"
    static let defaultModel = "defaultModel"

    static let all: Set<String> = [name, baseURL, apiKey, models, defaultModel]
}

struct APIProvider: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var format: APIFormat
    /// 模型库（模型名 + 独立定价，复用 Claude/Codex 的 MappedModel 以共用定价编辑器）。
    var models: [ProxyConfiguration.MappedModel]
    /// 顶层默认模型（应在 models 中）。
    var defaultModel: String

    // MARK: 可选共享参数（主要用于 OpenCode 映射，Codex/Claude 节点不消费）
    var contextLimit: Int
    var outputLimit: Int
    var temperature: Double?
    var topP: Double?
    var maxOutputTokens: Int
    var frequencyPenalty: Double?
    var presencePenalty: Double?

    var createdAt: Date
    var lastUsedAt: Date?
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        format: APIFormat = .openAIChatCompletions,
        models: [ProxyConfiguration.MappedModel] = [],
        defaultModel: String = "",
        contextLimit: Int = 0,
        outputLimit: Int = 0,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int = 0,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sortOrder: Int = Int.max
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.format = format
        self.models = models
        self.defaultModel = defaultModel
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, format, models, defaultModel
        case contextLimit, outputLimit, temperature, topP, maxOutputTokens, frequencyPenalty, presencePenalty
        case createdAt, lastUsedAt, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        format = try c.decodeIfPresent(APIFormat.self, forKey: .format) ?? .openAIChatCompletions
        models = try c.decodeIfPresent([ProxyConfiguration.MappedModel].self, forKey: .models) ?? []
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        contextLimit = try c.decodeIfPresent(Int.self, forKey: .contextLimit) ?? 0
        outputLimit = try c.decodeIfPresent(Int.self, forKey: .outputLimit) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 0
        frequencyPenalty = try c.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
        presencePenalty = try c.decodeIfPresent(Double.self, forKey: .presencePenalty)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? Int.max
    }

    // MARK: - Derived

    /// 展示名：未命名时回退到 baseURL 的 host。
    var displayName: String {
        if let name = name.nilIfBlank { return name }
        if let host = URL(string: baseURL)?.host { return host }
        return AppSettings.shared.t("Untitled Provider", "未命名提供商")
    }

    /// 实际生效的默认模型：defaultModel 失配时回退到列表首个。
    var effectiveDefaultModel: String {
        let names = models.map(\.name)
        if names.contains(defaultModel) { return defaultModel }
        return names.first ?? defaultModel
    }

    /// 是否填齐分发所需字段。
    var isComplete: Bool {
        baseURL.nilIfBlank != nil && !models.contains(where: { $0.name.nilIfBlank == nil }) && !models.isEmpty
    }

    /// 兼容的分发目标。
    var compatibleTargets: [ProxyTarget] {
        ProxyTarget.allCases.filter { $0.supports(format) }
    }
}
