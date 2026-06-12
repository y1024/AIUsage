import Foundation

// MARK: - OpenCode Node
// OpenCode 接入节点：一个上游接入点（baseURL + API Key + 模型列表 + 协议）。
// 激活时由 OpenCodeConfigManager 注入 ~/.config/opencode/opencode.json 的受管 provider 块，
// 协议由受管块的 npm 字段决定（OpenCode 据此选择 AI SDK 包）。
// 直连模式: OpenCode 原生直连上游，无本地代理进程。
// 代理模式（路线 B）: 本地 QuotaServer 按协议复用对应透传轨道（chat/completions、
//   responses、Anthropic passthrough），opencode.json 指向 127.0.0.1:<proxyPort>，
//   借此获得请求级日志（仅观测，不参与计费）。
// 持久化: ~/.config/aiusage/opencode-nodes.json（OpenCodeNodeStore）。

/// 节点上游协议：决定受管 provider 块的 npm 包与代理模式复用的透传轨道。
enum OpenCodeProtocol: String, Codable, CaseIterable {
    /// OpenAI chat/completions（绝大多数兼容上游：DeepSeek、Ollama、LM Studio…）。
    case openAICompatible = "openai-compatible"
    /// Anthropic v1/messages（官方或 Anthropic 兼容网关）。
    case anthropic = "anthropic"
    /// OpenAI Responses API（官方 /v1/responses 或同协议网关）。
    case openAIResponses = "openai-responses"

    /// 受管 provider 块写入的 AI SDK 包名。
    var npmPackage: String {
        switch self {
        case .openAICompatible: return "@ai-sdk/openai-compatible"
        case .anthropic: return "@ai-sdk/anthropic"
        case .openAIResponses: return "@ai-sdk/openai"
        }
    }

    /// SDK 在 baseURL 后拼接的请求路径（同时也是代理模式的入站路径）。
    var requestPath: String {
        switch self {
        case .openAICompatible: return "/chat/completions"
        case .anthropic: return "/messages"
        case .openAIResponses: return "/responses"
        }
    }

    var displayName: String {
        switch self {
        case .openAICompatible:
            return AppSettings.shared.t("OpenAI Compatible", "OpenAI 兼容")
        case .anthropic:
            return "Anthropic"
        case .openAIResponses:
            return "OpenAI Responses"
        }
    }

    /// 卡片徽章用短名（与 Claude/Codex 页「OpenAI Proxy / Anthropic Direct」措辞对齐）。
    var badgeName: String {
        switch self {
        case .openAICompatible: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openAIResponses: return "Responses"
        }
    }
}

struct OpenCodeNode: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    /// 上游协议（决定 npm 包与代理轨道）；旧档案缺省为 OpenAI 兼容。
    var protocolType: OpenCodeProtocol
    /// 模型 ID 列表（顺序即展示顺序），至少一个。
    var models: [String]
    /// 顶层 `model` 指向的默认模型（必须在 models 中）。
    var defaultModel: String
    /// 受管 provider 的节点标识（进 opencode.db 的 providerID，统计按它归因到节点）。
    /// 首次保存时生成并保持稳定（改名不变，历史归因不断档）；旧档案缺省为 nil。
    var providerSlug: String?
    /// 写进每个模型 `limit.context` 的上下文窗口；0 = 不写，由 OpenCode 取默认。
    var contextLimit: Int
    /// 写进每个模型 `limit.output` 的输出上限；0 = 不写。
    var outputLimit: Int
    /// 代理模式：激活时启动本地透传代理并把 opencode.json 指向它（请求级日志）。
    var proxyEnabled: Bool
    /// 本地透传代理监听端口。
    var proxyPort: Int
    /// 定价（USD / 百万 token，0 = 未设置）。写入受管块每个模型的 `cost` 字段，
    /// OpenCode 据此把每条消息的费用算进 opencode.db——统计金额即真实消费。
    var priceInputPerMillion: Double
    var priceOutputPerMillion: Double
    var priceCacheReadPerMillion: Double
    var priceCacheWritePerMillion: Double
    var createdAt: Date
    var lastUsedAt: Date?
    var sortOrder: Int

    static let defaultProxyPort = 4321

    /// Anthropic 惯例：缓存写入 ≈ 输入 ×1.25，缓存读取 ≈ 输入 ×0.1。
    static let cacheWriteMultiplier = 1.25
    static let cacheReadMultiplier = 0.1

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        protocolType: OpenCodeProtocol = .openAICompatible,
        models: [String] = [],
        defaultModel: String = "",
        providerSlug: String? = nil,
        contextLimit: Int = 0,
        outputLimit: Int = 0,
        proxyEnabled: Bool = false,
        proxyPort: Int = OpenCodeNode.defaultProxyPort,
        priceInputPerMillion: Double = 0,
        priceOutputPerMillion: Double = 0,
        priceCacheReadPerMillion: Double = 0,
        priceCacheWritePerMillion: Double = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sortOrder: Int = Int.max
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.protocolType = protocolType
        self.models = models
        self.defaultModel = defaultModel
        self.providerSlug = providerSlug
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.proxyEnabled = proxyEnabled
        self.proxyPort = proxyPort
        self.priceInputPerMillion = priceInputPerMillion
        self.priceOutputPerMillion = priceOutputPerMillion
        self.priceCacheReadPerMillion = priceCacheReadPerMillion
        self.priceCacheWritePerMillion = priceCacheWritePerMillion
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
    }

    /// 兼容旧档案（无 protocolType/proxyEnabled/proxyPort 字段）的解码。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        protocolType = try c.decodeIfPresent(OpenCodeProtocol.self, forKey: .protocolType) ?? .openAICompatible
        models = try c.decode([String].self, forKey: .models)
        defaultModel = try c.decode(String.self, forKey: .defaultModel)
        providerSlug = try c.decodeIfPresent(String.self, forKey: .providerSlug)
        contextLimit = try c.decode(Int.self, forKey: .contextLimit)
        outputLimit = try c.decode(Int.self, forKey: .outputLimit)
        proxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? Self.defaultProxyPort
        priceInputPerMillion = try c.decodeIfPresent(Double.self, forKey: .priceInputPerMillion) ?? 0
        priceOutputPerMillion = try c.decodeIfPresent(Double.self, forKey: .priceOutputPerMillion) ?? 0
        priceCacheReadPerMillion = try c.decodeIfPresent(Double.self, forKey: .priceCacheReadPerMillion) ?? 0
        priceCacheWritePerMillion = try c.decodeIfPresent(Double.self, forKey: .priceCacheWritePerMillion) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
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

    /// 是否配置了定价（任一单价 > 0 即写入受管块 cost 字段）。
    var hasPricing: Bool {
        priceInputPerMillion > 0 || priceOutputPerMillion > 0
            || priceCacheReadPerMillion > 0 || priceCacheWritePerMillion > 0
    }

    /// 代理模式下写入 opencode.json 的本地 baseURL。三种协议的 SDK 在其后分别拼接
    /// /chat/completions、/messages、/responses，均命中 QuotaServer 的对应入站路径。
    var proxyLocalBaseURL: String {
        "http://127.0.0.1:\(proxyPort)/v1"
    }

    /// 去掉末尾 /v1 的 baseURL。Anthropic passthrough 轨道按「上游根 + 入站完整路径
    /// /v1/messages」拼 URL，而节点 baseURL 习惯含 /v1（SDK 语义），需剥掉避免重复。
    var baseURLWithoutV1Suffix: String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.lowercased().hasSuffix("/v1") {
            trimmed = String(trimmed.dropLast(3))
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
        }
        return trimmed
    }

    // MARK: - Managed Provider Id

    /// 注入 opencode.json 的 provider 键，形如 `aiusage-deepseek`。
    /// opencode.db 的每条消息会带上它作为 providerID，统计页据此区分节点。
    var managedProviderId: String {
        "aiusage-" + (providerSlug?.nilIfBlank ?? String(id.prefix(6)).lowercased())
    }

    /// 从名称/host 生成 slug（小写 ASCII 字母数字 + 连字符），不可用时返回 nil。
    static func makeSlug(from source: String) -> String? {
        var slug = ""
        var previousWasHyphen = true // 抑制开头的连字符
        for character in source.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                slug.append("-")
                previousWasHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.nilIfBlank
    }

    /// 为本节点生成首选 slug：名称 → baseURL host → 短 id。
    func preferredSlug() -> String {
        if let slug = Self.makeSlug(from: name) { return slug }
        if let host = URL(string: baseURL)?.host, let slug = Self.makeSlug(from: host) { return slug }
        return String(id.prefix(6)).lowercased()
    }
}
