import Foundation

// MARK: - Proxy Configuration for QuotaBackend

public enum ProxyMode: String, Sendable {
    case openaiConvert
    case anthropicPassthrough
}

public enum OpenAIUpstreamAPI: String, Sendable, Codable, CaseIterable {
    case chatCompletions = "chat_completions"
    case responses

    public static func fromEnvironment(_ value: String?) -> OpenAIUpstreamAPI {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "responses", "response":
            return .responses
        default:
            return .chatCompletions
        }
    }
}

public struct ClaudeProxyConfiguration: Sendable {
    public let enabled: Bool
    /// TCP port this proxy configuration is intended to bind on (1–65535).
    public let bindPort: Int
    public let mode: ProxyMode
    public let upstreamBaseURL: String
    public let openAIUpstreamAPI: OpenAIUpstreamAPI
    public let upstreamAPIKey: String
    public let expectedClientKey: String?
    public let bigModel: String
    public let middleModel: String
    public let smallModel: String
    public let maxOutputTokens: Int?
    public let enableModelAliasMapping: Bool
    /// Active node model ids made available to Claude Science. Empty for normal
    /// Claude Code proxy processes, so `/v1/models` remains unexposed there.
    public let availableModels: [String]
    public let defaultModel: String?
    public let exposeScienceModelCatalog: Bool
    /// Science may retain a raw model id in browser storage. When enabled, an
    /// exact active-catalog id wins over the legacy opus/sonnet/haiku mapping.
    public let preferExactCatalogModels: Bool
    private let scienceModelProtocol: ScienceModelProtocolAdapter
    /// 全局统一代理（OpenCode anthropic 接口）模式下，把入站请求体的 `model` 无条件改写为该真实上游模型名，
    /// 优先于三层别名映射。nil = 不强制（普通 Claude Code 轨）。
    public let forcedModel: String?
    public let requestTimeout: TimeInterval
    public let customHeaders: [String: String]
    public let interceptor: (any PassthroughInterceptor)?

    public init(
        enabled: Bool,
        bindPort: Int = 4318,
        mode: ProxyMode = .openaiConvert,
        upstreamBaseURL: String,
        openAIUpstreamAPI: OpenAIUpstreamAPI = .chatCompletions,
        upstreamAPIKey: String,
        expectedClientKey: String? = nil,
        bigModel: String = "gpt-4o",
        middleModel: String = "gpt-4o-mini",
        smallModel: String = "gpt-3.5-turbo",
        maxOutputTokens: Int? = nil,
        enableModelAliasMapping: Bool = false,
        availableModels: [String] = [],
        defaultModel: String? = nil,
        exposeScienceModelCatalog: Bool = false,
        preferExactCatalogModels: Bool = false,
        forcedModel: String? = nil,
        requestTimeout: TimeInterval = 60,
        customHeaders: [String: String] = [:],
        interceptor: (any PassthroughInterceptor)? = nil
    ) {
        self.enabled = enabled
        self.bindPort = bindPort
        self.mode = mode
        self.upstreamBaseURL = mode == .openaiConvert
            ? Self.normalizeOpenAIBaseURL(upstreamBaseURL)
            : upstreamBaseURL
        self.openAIUpstreamAPI = openAIUpstreamAPI
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.bigModel = bigModel
        self.middleModel = middleModel
        self.smallModel = smallModel
        self.maxOutputTokens = maxOutputTokens
        self.enableModelAliasMapping = enableModelAliasMapping
        let scienceModelProtocol = ScienceModelProtocolAdapter(
            upstreamModels: availableModels,
            requestedDefault: defaultModel
        )
        self.scienceModelProtocol = scienceModelProtocol
        self.availableModels = scienceModelProtocol.models.map(\.upstreamModel)
        let trimmedDefault = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultModel = (trimmedDefault?.isEmpty == false) ? trimmedDefault : nil
        self.exposeScienceModelCatalog = exposeScienceModelCatalog && !self.availableModels.isEmpty
        self.preferExactCatalogModels = preferExactCatalogModels
        let trimmedForced = forcedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcedModel = (trimmedForced?.isEmpty == false) ? trimmedForced : nil
        self.requestTimeout = requestTimeout
        self.customHeaders = customHeaders
        self.interceptor = interceptor
    }

    /// Reduces a Claude-style model id to a coarse family label (`haiku`, `sonnet`, `opus`) when detectable.
    public static func normalizeModelName(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("haiku") {
            return "haiku"
        } else if lower.contains("sonnet") {
            return "sonnet"
        } else if lower.contains("opus") {
            return "opus"
        }
        return model
    }

    public func mapToUpstreamModel(_ requestModel: String) -> String {
        if exposeScienceModelCatalog,
           let resolved = scienceModelProtocol.resolveRequestModel(
               requestModel,
               acceptingRawUpstreamIDs: preferExactCatalogModels
           ) {
            return resolved
        }
        if preferExactCatalogModels, availableModels.contains(requestModel) {
            return requestModel
        }
        let normalized = requestModel.lowercased()
        if normalized.contains("opus") {
            return bigModel
        } else if normalized.contains("sonnet") {
            return middleModel
        } else if normalized.contains("haiku") {
            return smallModel
        } else if normalized.contains("claude") {
            return middleModel
        }
        return requestModel
    }

    public var effectiveCatalogDefault: String {
        scienceModelProtocol.defaultUpstreamModel ?? middleModel
    }

    public var scienceCatalogModels: [ScienceModelProtocolAdapter.Model] {
        scienceModelProtocol.models
    }

    public var scienceDefaultModelID: String? {
        scienceModelProtocol.defaultModelID
    }

    public static func normalizeOpenAIBaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if var components = URLComponents(string: trimmed) {
            var segments = components.path.split(separator: "/").map(String.init)
            let normalizedSegments = segments.map { $0.lowercased() }

            if normalizedSegments.suffix(3) == ["v1", "chat", "completions"] {
                segments.removeLast(3)
            } else if normalizedSegments.suffix(2) == ["v1", "responses"] {
                segments.removeLast(2)
            } else if normalizedSegments.suffix(2) == ["v1", "models"] {
                segments.removeLast(2)
            } else if normalizedSegments.last == "v1" {
                segments.removeLast()
            }

            components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
            return components.string ?? trimmed
        }

        let legacySuffixes = [
            "/v1/chat/completions",
            "/v1/responses",
            "/v1/models",
            "/v1/",
            "/v1"
        ]

        for suffix in legacySuffixes where trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            return String(trimmed.dropLast(suffix.count))
        }

        return trimmed
    }

    public func validate() throws {
        if upstreamAPIKey.isEmpty {
            throw ConfigurationError.missingAPIKey
        }
        if upstreamBaseURL.isEmpty {
            throw ConfigurationError.invalidURL
        }
        guard (1...65_535).contains(bindPort) else {
            throw ConfigurationError.invalidPort
        }
    }

    public var expectedClientAPIKey: String? {
        return expectedClientKey
    }

    public static func loadFromEnvironment() -> ClaudeProxyConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let catalogModels: [String] = environment["AIUSAGE_SCIENCE_MODELS_JSON"]
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            ?? []
        let catalogDefault = environment["AIUSAGE_SCIENCE_DEFAULT_MODEL"]
        let exposeCatalog = environment["AIUSAGE_SCIENCE_MODEL_CATALOG"] == "1"
        let preferExactCatalog = environment["AIUSAGE_SCIENCE_EXACT_MODELS"] == "1"
        let proxyModeStr = ProcessInfo.processInfo.environment["PROXY_MODE"] ?? "openai"
        let proxyMode: ProxyMode = proxyModeStr == "passthrough" ? .anthropicPassthrough : .openaiConvert

        if proxyMode == .anthropicPassthrough {
            let baseURL = ProcessInfo.processInfo.environment["ANTHROPIC_UPSTREAM_URL"] ?? "https://api.anthropic.com"
            let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_UPSTREAM_KEY"] ?? ""
            let clientKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]

            let enableRewrite = ProcessInfo.processInfo
                .environment["ENABLE_THINKING_REWRITE"] == "1"
            let aliasMapping = ProcessInfo.processInfo
                .environment["ENABLE_MODEL_ALIAS_MAPPING"] == "1"
            let bigModel = ProcessInfo.processInfo.environment["BIG_MODEL"] ?? "claude-opus-4-6"
            let middleModel = ProcessInfo.processInfo.environment["MIDDLE_MODEL"] ?? "claude-sonnet-4-6"
            let smallModel = ProcessInfo.processInfo.environment["SMALL_MODEL"] ?? "claude-haiku-4-5"
            // 全局统一代理（OpenCode anthropic 接口）随启动注入初始真实模型 → 无条件改写入站 model。
            let forcedModel = ProcessInfo.processInfo.environment["ANTHROPIC_FORCED_MODEL"]

            return ClaudeProxyConfiguration(
                enabled: true,
                mode: .anthropicPassthrough,
                upstreamBaseURL: baseURL,
                upstreamAPIKey: apiKey,
                expectedClientKey: clientKey,
                bigModel: bigModel,
                middleModel: middleModel,
                smallModel: smallModel,
                enableModelAliasMapping: aliasMapping,
                availableModels: catalogModels,
                defaultModel: catalogDefault,
                exposeScienceModelCatalog: exposeCatalog,
                preferExactCatalogModels: preferExactCatalog,
                forcedModel: forcedModel,
                interceptor: enableRewrite ? AnyRouterInterceptor() : nil
            )
        }

        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            return nil
        }

        let baseURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"] ?? "https://api.openai.com"
        let openAIUpstreamAPI = OpenAIUpstreamAPI.fromEnvironment(
            ProcessInfo.processInfo.environment["OPENAI_API_MODE"]
        )
        let clientKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        let bigModel = ProcessInfo.processInfo.environment["BIG_MODEL"] ?? "gpt-4o"
        let middleModel = ProcessInfo.processInfo.environment["MIDDLE_MODEL"] ?? "gpt-4o-mini"
        let smallModel = ProcessInfo.processInfo.environment["SMALL_MODEL"] ?? "gpt-3.5-turbo"
        let maxOutputTokens = ProcessInfo.processInfo.environment["MAX_OUTPUT_TOKENS"].flatMap { Int($0) }

        return ClaudeProxyConfiguration(
            enabled: true,
            mode: .openaiConvert,
            upstreamBaseURL: baseURL,
            openAIUpstreamAPI: openAIUpstreamAPI,
            upstreamAPIKey: apiKey,
            expectedClientKey: clientKey,
            bigModel: bigModel,
            middleModel: middleModel,
            smallModel: smallModel,
            maxOutputTokens: maxOutputTokens,
            availableModels: catalogModels,
            defaultModel: catalogDefault,
            exposeScienceModelCatalog: exposeCatalog,
            preferExactCatalogModels: preferExactCatalog
        )
    }
}

// MARK: - Configuration Error

public enum ConfigurationError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL
    case invalidModel
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing API key"
        case .invalidURL:
            return "Invalid upstream URL"
        case .invalidModel:
            return "Invalid model configuration"
        case .invalidPort:
            return "Invalid bind port; use a value from 1 through 65535"
        }
    }
}
