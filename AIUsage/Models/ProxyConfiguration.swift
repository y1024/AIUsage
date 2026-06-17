import Foundation
import SwiftUI
import QuotaBackend

// MARK: - Node Type

enum NodeType: String, Codable, CaseIterable {
    case anthropicDirect
    case openaiProxy
    case codexProxy

    /// Codex 节点：把 OpenAI 兼容上游接入 Codex（写 ~/.codex/config.toml，本地起 QuotaServer）。
    var isCodex: Bool { self == .codexProxy }
}

// MARK: - Node Family
// 节点家族决定它们在 UI / 激活轨道上的归属：
// Claude 家族写 ~/.claude/settings.json，Codex 家族写 ~/.codex/config.toml，二者互不影响。

enum ProxyNodeFamily: Hashable {
    case claude   // anthropicDirect + openaiProxy
    case codex    // codexProxy

    func contains(_ type: NodeType) -> Bool {
        switch self {
        case .claude: return type != .codexProxy
        case .codex: return type == .codexProxy
        }
    }

    var isCodex: Bool { self == .codex }
}

// MARK: - Proxy Configuration

struct ProxyConfiguration: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var nodeType: NodeType
    var isEnabled: Bool

    // Anthropic Direct fields
    var anthropicBaseURL: String
    var anthropicAPIKey: String
    var usePassthroughProxy: Bool

    // OpenAI Proxy fields
    var host: String
    var port: Int
    var allowLAN: Bool
    var upstreamBaseURL: String
    var openAIUpstreamAPI: OpenAIUpstreamAPI
    var upstreamAPIKey: String
    var expectedClientKey: String
    var defaultModel: String
    var modelMapping: ModelMapping
    /// 模型库：节点内预配置的「模型名 + 独立定价」清单（与 OpenCode 的 modelEntries 同构）。
    /// 定价唯一来源（查询顺序见 pricingForModel）；槽位/默认模型从库中点选即可切换，
    /// 无需重填名称与价格。旧档案无此字段时为空，计价自动回退槽位价格。
    var modelLibrary: [MappedModel]
    var maxOutputTokens: Int // 0 = no cap, pass through original value
    var enableModelAliasMapping: Bool
    var enableHTTPS: Bool
    var httpsPort: Int?
    var createdAt: Date
    var lastUsedAt: Date?

    enum PricingCurrency: String, Codable, CaseIterable {
        case usd
        case cny
    }

    struct ModelPricing: Codable, Equatable {
        var inputPerMillion: Double         // per 1M input tokens (in configured currency)
        var outputPerMillion: Double        // per 1M output tokens
        var cacheCreatePerMillion: Double   // per 1M cache write tokens (~1.25× input by default)
        var cacheReadPerMillion: Double     // per 1M cache read tokens (~0.1× input by default)
        var currency: PricingCurrency

        static let defaultCacheWriteMultiplier: Double = 1.25
        static let defaultCacheReadMultiplier: Double = 0.1

        static var zero: ModelPricing {
            ModelPricing(inputPerMillion: 0, outputPerMillion: 0, cacheCreatePerMillion: 0, cacheReadPerMillion: 0, currency: .usd)
        }

        /// CNY → USD 折算用用户配置的全局汇率（AppSettings.cnyPerUSD，默认 7），
        /// 与 OpenCode 定价、费用显示共用同一汇率，保证录入与显示口径一致。
        private static var cnyToUsdRate: Double { 1.0 / AppSettings.cnyPerUSD }

        var inputPerMillionUSD: Double {
            currency == .usd ? inputPerMillion : inputPerMillion * Self.cnyToUsdRate
        }
        var outputPerMillionUSD: Double {
            currency == .usd ? outputPerMillion : outputPerMillion * Self.cnyToUsdRate
        }
        var cacheCreatePerMillionUSD: Double {
            currency == .usd ? cacheCreatePerMillion : cacheCreatePerMillion * Self.cnyToUsdRate
        }
        var cacheReadPerMillionUSD: Double {
            currency == .usd ? cacheReadPerMillion : cacheReadPerMillion * Self.cnyToUsdRate
        }

        /// `input` must be non-cached input. Cached input is charged only through
        /// `cacheRead`; callers should normalize provider usage before pricing.
        func costForTokens(input: Int, output: Int, cacheRead: Int, cacheCreate: Int) -> Double {
            (Double(input) * inputPerMillionUSD
             + Double(output) * outputPerMillionUSD
             + Double(cacheCreate) * cacheCreatePerMillionUSD
             + Double(cacheRead) * cacheReadPerMillionUSD) / 1_000_000
        }

        init(
            inputPerMillion: Double = 0,
            outputPerMillion: Double = 0,
            cacheCreatePerMillion: Double = 0,
            cacheReadPerMillion: Double = 0,
            currency: PricingCurrency = .usd
        ) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cacheCreatePerMillion = cacheCreatePerMillion
            self.cacheReadPerMillion = cacheReadPerMillion
            self.currency = currency
        }

        private enum CodingKeys: String, CodingKey {
            case inputPerMillion
            case outputPerMillion
            case cachePerMillion             // legacy (combined cache)
            case cacheCreatePerMillion
            case cacheReadPerMillion
            case currency
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputPerMillion = try container.decode(Double.self, forKey: .inputPerMillion)
            outputPerMillion = try container.decode(Double.self, forKey: .outputPerMillion)

            let legacy = try container.decodeIfPresent(Double.self, forKey: .cachePerMillion)
            let splitWrite = try container.decodeIfPresent(Double.self, forKey: .cacheCreatePerMillion)
            let splitRead = try container.decodeIfPresent(Double.self, forKey: .cacheReadPerMillion)

            // Prefer split fields; fall back to legacy scalar: treat it as a blended cache price,
            // then synthesize cache-read = legacy and cache-write = legacy × 1.25.
            if splitWrite != nil || splitRead != nil {
                cacheCreatePerMillion = splitWrite ?? ((legacy ?? 0) * Self.defaultCacheWriteMultiplier)
                cacheReadPerMillion = splitRead ?? (legacy ?? 0)
            } else if let legacy, legacy > 0 {
                cacheReadPerMillion = legacy
                cacheCreatePerMillion = legacy * Self.defaultCacheWriteMultiplier
            } else {
                cacheReadPerMillion = 0
                cacheCreatePerMillion = 0
            }

            currency = try container.decodeIfPresent(PricingCurrency.self, forKey: .currency) ?? .usd
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(inputPerMillion, forKey: .inputPerMillion)
            try container.encode(outputPerMillion, forKey: .outputPerMillion)
            try container.encode(cacheCreatePerMillion, forKey: .cacheCreatePerMillion)
            try container.encode(cacheReadPerMillion, forKey: .cacheReadPerMillion)
            try container.encode(cacheReadPerMillion, forKey: .cachePerMillion)
            try container.encode(currency, forKey: .currency)
        }
    }

    struct MappedModel: Codable, Equatable {
        var name: String
        var pricing: ModelPricing

        init(name: String, pricing: ModelPricing = .zero) {
            self.name = name
            self.pricing = pricing
        }
    }

    struct ModelMapping: Codable, Equatable {
        var bigModel: MappedModel      // opus -> this
        var middleModel: MappedModel   // sonnet -> this
        var smallModel: MappedModel    // haiku -> this

        static var openAIDefault: ModelMapping {
            ModelMapping(
                bigModel: MappedModel(name: "gpt-5.5"),
                middleModel: MappedModel(name: "gpt-5.4-mini"),
                smallModel: MappedModel(name: "gpt-4o-mini")
            )
        }

        static var anthropicDefault: ModelMapping {
            ModelMapping(
                bigModel: MappedModel(name: "claude-opus-4-6"),
                middleModel: MappedModel(name: "claude-sonnet-4-6"),
                smallModel: MappedModel(name: "claude-haiku-4-5")
            )
        }

        /// Codex 节点只有一个有效模型（存 bigModel），middle/small 留空不参与定价/统计。
        static var codexDefault: ModelMapping {
            ModelMapping(
                bigModel: MappedModel(name: "gpt-5.5"),
                middleModel: MappedModel(name: ""),
                smallModel: MappedModel(name: "")
            )
        }

        static var `default`: ModelMapping { openAIDefault }

        func pricingForUpstreamModel(_ model: String) -> ModelPricing? {
            if bigModel.name == model { return bigModel.pricing }
            if middleModel.name == model { return middleModel.pricing }
            if smallModel.name == model { return smallModel.pricing }
            return nil
        }

        func pricingForFamily(of model: String) -> ModelPricing? {
            guard let family = ProxyConfiguration.modelFamilyHint(for: model) else { return nil }
            if ProxyConfiguration.modelFamilyHint(for: bigModel.name) == family { return bigModel.pricing }
            if ProxyConfiguration.modelFamilyHint(for: middleModel.name) == family { return middleModel.pricing }
            if ProxyConfiguration.modelFamilyHint(for: smallModel.name) == family { return smallModel.pricing }
            return nil
        }
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        nodeType: NodeType = .openaiProxy,
        isEnabled: Bool = false,
        anthropicBaseURL: String = "https://api.anthropic.com",
        anthropicAPIKey: String = "",
        usePassthroughProxy: Bool = false,
        host: String = "127.0.0.1",
        port: Int = 8080,
        allowLAN: Bool = false,
        upstreamBaseURL: String = "https://api.openai.com",
        openAIUpstreamAPI: OpenAIUpstreamAPI = .chatCompletions,
        upstreamAPIKey: String = "",
        expectedClientKey: String = "",
        defaultModel: String = "",
        modelMapping: ModelMapping = .default,
        modelLibrary: [MappedModel] = [],
        maxOutputTokens: Int = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        enableModelAliasMapping: Bool = false,
        enableHTTPS: Bool = false,
        httpsPort: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.nodeType = nodeType
        self.isEnabled = isEnabled
        self.anthropicBaseURL = anthropicBaseURL
        self.anthropicAPIKey = anthropicAPIKey
        self.usePassthroughProxy = usePassthroughProxy
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.upstreamBaseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
        self.openAIUpstreamAPI = openAIUpstreamAPI
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.defaultModel = defaultModel
        self.modelMapping = modelMapping
        self.modelLibrary = modelLibrary
        self.maxOutputTokens = maxOutputTokens
        self.enableModelAliasMapping = enableModelAliasMapping
        self.enableHTTPS = enableHTTPS
        self.httpsPort = httpsPort
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nodeType = try container.decodeIfPresent(NodeType.self, forKey: .nodeType) ?? .openaiProxy
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        anthropicBaseURL = try container.decodeIfPresent(String.self, forKey: .anthropicBaseURL) ?? "https://api.anthropic.com"
        anthropicAPIKey = try container.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
        usePassthroughProxy = try container.decodeIfPresent(Bool.self, forKey: .usePassthroughProxy) ?? false
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        allowLAN = try container.decode(Bool.self, forKey: .allowLAN)
        upstreamBaseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(
            try container.decode(String.self, forKey: .upstreamBaseURL)
        )
        openAIUpstreamAPI = try container.decodeIfPresent(OpenAIUpstreamAPI.self, forKey: .openAIUpstreamAPI) ?? .chatCompletions
        upstreamAPIKey = try container.decode(String.self, forKey: .upstreamAPIKey)
        expectedClientKey = try container.decode(String.self, forKey: .expectedClientKey)
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        modelMapping = try container.decode(ModelMapping.self, forKey: .modelMapping)
        modelLibrary = try container.decodeIfPresent([MappedModel].self, forKey: .modelLibrary) ?? []
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 0
        enableModelAliasMapping = try container.decodeIfPresent(Bool.self, forKey: .enableModelAliasMapping) ?? false
        enableHTTPS = try container.decodeIfPresent(Bool.self, forKey: .enableHTTPS) ?? false
        httpsPort = try container.decodeIfPresent(Int.self, forKey: .httpsPort)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    var bindAddress: String {
        allowLAN ? "0.0.0.0" : host
    }

    var displayURL: String {
        switch nodeType {
        case .anthropicDirect:
            return usePassthroughProxy ? "http://\(host):\(port)" : anthropicBaseURL
        case .openaiProxy, .codexProxy:
            return "http://\(host):\(port)"
        }
    }

    var effectiveHTTPSPort: Int { httpsPort ?? (port + 1) }

    /// 该节点代理进程实际监听的端口集合（用于跨轨端口仲裁）：HTTP 入站端口恒占用；
    /// 开启 HTTPS 时进程会额外监听 HTTPS 端口（QuotaServer 同时起 HTTP + HTTPS 两个 listener）。
    /// 非代理节点（直连）不起进程、不占端口，返回空。
    var listeningPorts: [Int] {
        guard needsProxyProcess else { return [] }
        var ports = [port]
        if enableHTTPS { ports.append(effectiveHTTPSPort) }
        return ports
    }

    var needsProxyProcess: Bool {
        nodeType == .openaiProxy
            || nodeType == .codexProxy
            || (nodeType == .anthropicDirect && usePassthroughProxy)
    }

    /// Codex 节点：单一模型 + 价格存放在 `modelMapping.bigModel`。
    /// 该模型同时作为写入 `config.toml` 的 `model`、上游模型名与定价键。
    var codexModel: String {
        modelMapping.bigModel.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 客户端向本地代理鉴权用的 key；留空时回退到约定的 "proxy-key"。
    var effectiveClientKey: String {
        expectedClientKey.isEmpty ? "proxy-key" : expectedClientKey
    }

    /// 计价查询：模型库精确匹配 → 槽位精确匹配 → 槽位家族匹配 → 模型库家族匹配。
    /// 模型库是定价唯一来源；旧档案（库为空）自动回退槽位价格，行为不变。
    func pricingForModel(_ model: String) -> ModelPricing? {
        if let p = modelLibrary.first(where: { $0.name == model })?.pricing { return p }
        if let p = modelMapping.pricingForUpstreamModel(model) { return p }
        if let p = modelMapping.pricingForFamily(of: model) { return p }
        if let family = Self.modelFamilyHint(for: model),
           let p = modelLibrary.first(where: { Self.modelFamilyHint(for: $0.name) == family })?.pricing {
            return p
        }
        return nil
    }

    var normalizedUpstreamBaseURL: String {
        ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
    }

    func normalizedForPersistence() -> ProxyConfiguration {
        var copy = self
        copy.upstreamBaseURL = normalizedUpstreamBaseURL
        return copy
    }

    private static func modelFamilyHint(for model: String) -> String? {
        let normalized = model.lowercased()
        if normalized.contains("opus") { return "opus" }
        if normalized.contains("sonnet") { return "sonnet" }
        if normalized.contains("haiku") { return "haiku" }
        return nil
    }
}

// MARK: - Proxy Statistics

struct ProxyStatistics: Codable, Equatable {
    var totalRequests: Int
    var successfulRequests: Int
    var failedRequests: Int
    var totalTokensInput: Int
    var totalTokensOutput: Int
    var totalTokensCacheRead: Int
    var totalTokensCacheCreation: Int
    var estimatedCostUSD: Double
    var requestsByModel: [String: Int]
    var lastRequestAt: Date?
    /// 整段响应平均总耗时（ms），受输出长度影响。
    var averageResponseTime: Double
    /// 平均首字时间 TTFT（ms），仅基于带 firstTokenMs 的流式请求。
    var averageFirstTokenTime: Double
    /// 参与 TTFT 平均的样本数（非流式 / 旧日志不计入）。
    var firstTokenSamples: Int

    static var empty: ProxyStatistics {
        ProxyStatistics(
            totalRequests: 0,
            successfulRequests: 0,
            failedRequests: 0,
            totalTokensInput: 0,
            totalTokensOutput: 0,
            totalTokensCacheRead: 0,
            totalTokensCacheCreation: 0,
            estimatedCostUSD: 0,
            requestsByModel: [:],
            lastRequestAt: nil,
            averageResponseTime: 0,
            averageFirstTokenTime: 0,
            firstTokenSamples: 0
        )
    }

    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(successfulRequests) / Double(totalRequests) * 100
    }

    var totalTokensCache: Int { totalTokensCacheRead + totalTokensCacheCreation }

    var totalTokens: Int {
        totalTokensInput + totalTokensOutput + totalTokensCache
    }

    /// Cache hit rate: cache_read / (input + cache_read + cache_creation).
    /// Measures how much of the billable input surface is served from cache.
    var cacheHitRate: Double {
        let denom = totalTokensInput + totalTokensCacheRead + totalTokensCacheCreation
        guard denom > 0 else { return 0 }
        return Double(totalTokensCacheRead) / Double(denom) * 100
    }

    private enum CodingKeys: String, CodingKey {
        case totalRequests
        case successfulRequests
        case failedRequests
        case totalTokensInput
        case totalTokensOutput
        case totalTokensCache             // legacy combined cache
        case totalTokensCacheRead
        case totalTokensCacheCreation
        case estimatedCostUSD
        case requestsByModel
        case lastRequestAt
        case averageResponseTime
        case averageFirstTokenTime
        case firstTokenSamples
    }

    init(
        totalRequests: Int,
        successfulRequests: Int,
        failedRequests: Int,
        totalTokensInput: Int,
        totalTokensOutput: Int,
        totalTokensCacheRead: Int,
        totalTokensCacheCreation: Int,
        estimatedCostUSD: Double,
        requestsByModel: [String: Int],
        lastRequestAt: Date?,
        averageResponseTime: Double,
        averageFirstTokenTime: Double = 0,
        firstTokenSamples: Int = 0
    ) {
        self.totalRequests = totalRequests
        self.successfulRequests = successfulRequests
        self.failedRequests = failedRequests
        self.totalTokensInput = totalTokensInput
        self.totalTokensOutput = totalTokensOutput
        self.totalTokensCacheRead = totalTokensCacheRead
        self.totalTokensCacheCreation = totalTokensCacheCreation
        self.estimatedCostUSD = estimatedCostUSD
        self.requestsByModel = requestsByModel
        self.lastRequestAt = lastRequestAt
        self.averageResponseTime = averageResponseTime
        self.averageFirstTokenTime = averageFirstTokenTime
        self.firstTokenSamples = firstTokenSamples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalRequests = try c.decode(Int.self, forKey: .totalRequests)
        successfulRequests = try c.decode(Int.self, forKey: .successfulRequests)
        failedRequests = try c.decode(Int.self, forKey: .failedRequests)
        totalTokensInput = try c.decode(Int.self, forKey: .totalTokensInput)
        totalTokensOutput = try c.decode(Int.self, forKey: .totalTokensOutput)

        let legacyCache = try c.decodeIfPresent(Int.self, forKey: .totalTokensCache)
        let splitRead = try c.decodeIfPresent(Int.self, forKey: .totalTokensCacheRead)
        let splitCreate = try c.decodeIfPresent(Int.self, forKey: .totalTokensCacheCreation)

        if splitRead != nil || splitCreate != nil {
            totalTokensCacheRead = splitRead ?? 0
            totalTokensCacheCreation = splitCreate ?? 0
        } else {
            // Legacy migration: attribute the old combined total to cache-read (no way to split historical data).
            totalTokensCacheRead = legacyCache ?? 0
            totalTokensCacheCreation = 0
        }

        estimatedCostUSD = try c.decode(Double.self, forKey: .estimatedCostUSD)
        requestsByModel = try c.decode([String: Int].self, forKey: .requestsByModel)
        lastRequestAt = try c.decodeIfPresent(Date.self, forKey: .lastRequestAt)
        averageResponseTime = try c.decode(Double.self, forKey: .averageResponseTime)
        averageFirstTokenTime = try c.decodeIfPresent(Double.self, forKey: .averageFirstTokenTime) ?? 0
        firstTokenSamples = try c.decodeIfPresent(Int.self, forKey: .firstTokenSamples) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(totalRequests, forKey: .totalRequests)
        try c.encode(successfulRequests, forKey: .successfulRequests)
        try c.encode(failedRequests, forKey: .failedRequests)
        try c.encode(totalTokensInput, forKey: .totalTokensInput)
        try c.encode(totalTokensOutput, forKey: .totalTokensOutput)
        try c.encode(totalTokensCacheRead, forKey: .totalTokensCacheRead)
        try c.encode(totalTokensCacheCreation, forKey: .totalTokensCacheCreation)
        try c.encode(totalTokensCacheRead + totalTokensCacheCreation, forKey: .totalTokensCache)
        try c.encode(estimatedCostUSD, forKey: .estimatedCostUSD)
        try c.encode(requestsByModel, forKey: .requestsByModel)
        try c.encodeIfPresent(lastRequestAt, forKey: .lastRequestAt)
        try c.encode(averageResponseTime, forKey: .averageResponseTime)
        try c.encode(averageFirstTokenTime, forKey: .averageFirstTokenTime)
        try c.encode(firstTokenSamples, forKey: .firstTokenSamples)
    }
}

// MARK: - Proxy Request Log

struct ProxyRequestLog: Codable, Identifiable {
    let id: String
    let configId: String
    let timestamp: Date
    let method: String
    let path: String
    let claudeModel: String
    let upstreamModel: String
    let success: Bool
    /// 整段响应总耗时（请求开始到流式结束）。衡量「这次答了多长」，受输出长度影响。
    let responseTimeMs: Double
    /// 首字时间 TTFT（请求开始到收到第一个上游响应分片）。衡量「响应快不快」。
    /// 仅流式代理路径可采，非流式 / 旧日志为 nil。
    let firstTokenMs: Double?
    let tokensInput: Int
    let tokensOutput: Int
    let tokensCacheRead: Int
    let tokensCacheCreation: Int
    let estimatedCostUSD: Double
    let pricingResolved: Bool
    let errorMessage: String?
    let errorType: String?
    let statusCode: Int?
    /// 是否来自「全局统一代理」（一个常驻进程随激活节点轮转）。OpenCode 轨用它区分两类日志：
    /// 全局代理日志是该节点用量/成功率/最近请求的唯一来源（opencode.db 不记全局流量）；
    /// 而每节点「仅代理 / 路线 B」日志仅作观测（成功明细以 opencode.db 为准），故展示口径不同。
    /// 旧档案缺该键时解码为 false（向后兼容）。
    let isGlobalProxy: Bool

    /// Combined cache total (read + creation). Retained for display and aggregation convenience.
    var tokensCache: Int { tokensCacheRead + tokensCacheCreation }

    init(
        id: String = UUID().uuidString,
        configId: String,
        timestamp: Date = Date(),
        method: String,
        path: String,
        claudeModel: String,
        upstreamModel: String,
        success: Bool,
        responseTimeMs: Double,
        firstTokenMs: Double? = nil,
        tokensInput: Int = 0,
        tokensOutput: Int = 0,
        tokensCacheRead: Int = 0,
        tokensCacheCreation: Int = 0,
        estimatedCostUSD: Double = 0,
        pricingResolved: Bool = false,
        errorMessage: String? = nil,
        errorType: String? = nil,
        statusCode: Int? = nil,
        isGlobalProxy: Bool = false
    ) {
        self.id = id
        self.configId = configId
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.claudeModel = claudeModel
        self.upstreamModel = upstreamModel
        self.success = success
        self.responseTimeMs = responseTimeMs
        self.firstTokenMs = firstTokenMs
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
        self.tokensCacheRead = tokensCacheRead
        self.tokensCacheCreation = tokensCacheCreation
        self.estimatedCostUSD = estimatedCostUSD
        self.pricingResolved = pricingResolved
        self.errorMessage = errorMessage
        self.errorType = errorType
        self.statusCode = statusCode
        self.isGlobalProxy = isGlobalProxy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case configId
        case timestamp
        case method
        case path
        case claudeModel
        case upstreamModel
        case success
        case responseTimeMs
        case firstTokenMs
        case tokensInput
        case tokensOutput
        case tokensCache              // legacy combined cache
        case tokensCacheRead
        case tokensCacheCreation
        case estimatedCostUSD
        case pricingResolved
        case errorMessage
        case errorType
        case statusCode
        case isGlobalProxy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        configId = try c.decode(String.self, forKey: .configId)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        method = try c.decode(String.self, forKey: .method)
        path = try c.decode(String.self, forKey: .path)
        claudeModel = try c.decode(String.self, forKey: .claudeModel)
        upstreamModel = try c.decode(String.self, forKey: .upstreamModel)
        success = try c.decode(Bool.self, forKey: .success)
        responseTimeMs = try c.decode(Double.self, forKey: .responseTimeMs)
        firstTokenMs = try c.decodeIfPresent(Double.self, forKey: .firstTokenMs)
        tokensInput = try c.decode(Int.self, forKey: .tokensInput)
        tokensOutput = try c.decode(Int.self, forKey: .tokensOutput)

        let legacyCache = try c.decodeIfPresent(Int.self, forKey: .tokensCache)
        let splitRead = try c.decodeIfPresent(Int.self, forKey: .tokensCacheRead)
        let splitCreate = try c.decodeIfPresent(Int.self, forKey: .tokensCacheCreation)
        if splitRead != nil || splitCreate != nil {
            tokensCacheRead = splitRead ?? 0
            tokensCacheCreation = splitCreate ?? 0
        } else {
            tokensCacheRead = legacyCache ?? 0
            tokensCacheCreation = 0
        }

        estimatedCostUSD = try c.decode(Double.self, forKey: .estimatedCostUSD)
        pricingResolved = try c.decodeIfPresent(Bool.self, forKey: .pricingResolved) ?? (estimatedCostUSD > 0)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorType = try c.decodeIfPresent(String.self, forKey: .errorType)
        statusCode = try c.decodeIfPresent(Int.self, forKey: .statusCode)
        isGlobalProxy = try c.decodeIfPresent(Bool.self, forKey: .isGlobalProxy) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(configId, forKey: .configId)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(method, forKey: .method)
        try c.encode(path, forKey: .path)
        try c.encode(claudeModel, forKey: .claudeModel)
        try c.encode(upstreamModel, forKey: .upstreamModel)
        try c.encode(success, forKey: .success)
        try c.encode(responseTimeMs, forKey: .responseTimeMs)
        try c.encodeIfPresent(firstTokenMs, forKey: .firstTokenMs)
        try c.encode(tokensInput, forKey: .tokensInput)
        try c.encode(tokensOutput, forKey: .tokensOutput)
        try c.encode(tokensCacheRead, forKey: .tokensCacheRead)
        try c.encode(tokensCacheCreation, forKey: .tokensCacheCreation)
        try c.encode(tokensCacheRead + tokensCacheCreation, forKey: .tokensCache)
        try c.encode(estimatedCostUSD, forKey: .estimatedCostUSD)
        try c.encode(pricingResolved, forKey: .pricingResolved)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encodeIfPresent(errorType, forKey: .errorType)
        try c.encodeIfPresent(statusCode, forKey: .statusCode)
        if isGlobalProxy { try c.encode(isGlobalProxy, forKey: .isGlobalProxy) }
    }
}
