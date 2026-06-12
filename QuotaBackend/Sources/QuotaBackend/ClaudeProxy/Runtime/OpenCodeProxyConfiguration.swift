import Foundation

// MARK: - OpenCode Proxy Configuration
// OpenCode 透传代理：入站 OpenAI chat/completions → 原样转发到 OpenAI 兼容上游。
// 不做协议转换、不做模型映射——代理只为「请求级日志」提供观测点（路线 B），
// 用量成本仍以 opencode.db（Phase 1 Provider）为准，请求日志只记录不计费。
//
// 进程模型: 每个 OpenCode 节点（代理模式）启动独立的 QuotaServer 进程，
// 通过环境变量 PROXY_TARGET=opencode 区分。

public struct OpenCodeProxyConfiguration: Sendable {
    public let enabled: Bool
    /// TCP port this proxy configuration is intended to bind on (1–65535).
    public let bindPort: Int
    public let upstreamBaseURL: String
    /// 上游 API Key。允许为空（本地上游如 Ollama / LM Studio 无需鉴权）。
    public let upstreamAPIKey: String
    public let expectedClientKey: String?
    public let requestTimeout: TimeInterval
    public let customHeaders: [String: String]

    public init(
        enabled: Bool,
        bindPort: Int = 4321,
        upstreamBaseURL: String,
        upstreamAPIKey: String,
        expectedClientKey: String? = nil,
        requestTimeout: TimeInterval = 120,
        customHeaders: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.bindPort = bindPort
        self.upstreamBaseURL = ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey?.nilIfBlank
        self.requestTimeout = requestTimeout
        self.customHeaders = customHeaders
    }

    public var expectedClientAPIKey: String? { expectedClientKey }

    public func validate() throws {
        if upstreamBaseURL.isEmpty {
            throw ConfigurationError.invalidURL
        }
        guard (1...65_535).contains(bindPort) else {
            throw ConfigurationError.invalidPort
        }
    }

    /// 复用 OpenAICompatibleClient（它接受 ClaudeProxyConfiguration），把本配置投影为上游客户端配置。
    /// 注意: 这里的 ClaudeProxyConfiguration 实际充当「OpenAI 上游配置」，与 Claude 入站无关（技术债，见 docs）。
    public func makeUpstreamClientConfiguration() -> ClaudeProxyConfiguration {
        ClaudeProxyConfiguration(
            enabled: enabled,
            bindPort: bindPort,
            mode: .openaiConvert,
            upstreamBaseURL: upstreamBaseURL,
            openAIUpstreamAPI: .chatCompletions,
            upstreamAPIKey: upstreamAPIKey,
            expectedClientKey: expectedClientKey,
            requestTimeout: requestTimeout,
            customHeaders: customHeaders
        )
    }

    public static func loadFromEnvironment() -> OpenCodeProxyConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PROXY_TARGET"]?.lowercased() == "opencode" else {
            return nil
        }
        guard let baseURL = environment["OPENAI_BASE_URL"]?.nilIfBlank else {
            return nil
        }

        let apiKey = environment["OPENAI_API_KEY"] ?? ""
        let clientKey = environment["OPENCODE_CLIENT_KEY"]?.nilIfBlank

        return OpenCodeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: baseURL,
            upstreamAPIKey: apiKey,
            expectedClientKey: clientKey
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
