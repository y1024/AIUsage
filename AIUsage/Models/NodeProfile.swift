import Foundation
import QuotaBackend

// MARK: - Node Profile
// Each node profile is a standalone JSON file at ~/.config/aiusage/profiles/<id>.json.
// The file contains a `_metadata` wrapper (proxy config, name, timestamps) alongside
// the full settings.json content. Activating a profile writes everything except `_metadata`
// into ~/.claude/settings.json.

struct NodeProfile: Identifiable, Equatable {
    var metadata: Metadata
    var settings: [String: Any]

    var id: String { metadata.id }

    static func == (lhs: NodeProfile, rhs: NodeProfile) -> Bool {
        guard lhs.metadata == rhs.metadata else { return false }
        guard let lData = try? JSONSerialization.data(withJSONObject: lhs.settings, options: .sortedKeys),
              let rData = try? JSONSerialization.data(withJSONObject: rhs.settings, options: .sortedKeys) else {
            return false
        }
        return lData == rData
    }

    // MARK: - Metadata

    struct Metadata: Codable, Equatable {
        var id: String
        var name: String
        var nodeType: NodeType
        var createdAt: Date
        var lastUsedAt: Date?
        var sortOrder: Int
        var proxy: ProxySettings

        init(
            id: String = UUID().uuidString,
            name: String = "",
            nodeType: NodeType = .openaiProxy,
            createdAt: Date = Date(),
            lastUsedAt: Date? = nil,
            sortOrder: Int = Int.max,
            proxy: ProxySettings = .defaultOpenAI
        ) {
            self.id = id
            self.name = name
            self.nodeType = nodeType
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.sortOrder = sortOrder
            self.proxy = proxy
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            nodeType = try container.decode(NodeType.self, forKey: .nodeType)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? Int.max
            proxy = try container.decode(ProxySettings.self, forKey: .proxy)
        }
    }

    // MARK: Serialize / Deserialize

    private static let metadataKey = "_metadata"

    func toFileData() throws -> Data {
        var root = settings
        let metaData = try JSONEncoder.profileEncoder.encode(metadata)
        guard let metaObj = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            throw NodeProfileError.serializationFailed
        }
        root[Self.metadataKey] = metaObj
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func fromFileData(_ data: Data) throws -> NodeProfile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodeProfileError.invalidRootObject
        }
        guard let metaObj = root[metadataKey] as? [String: Any] else {
            throw NodeProfileError.missingMetadata
        }
        let metaData = try JSONSerialization.data(withJSONObject: metaObj)
        let metadata = try JSONDecoder.profileDecoder.decode(Metadata.self, from: metaData)

        var settings = root
        settings.removeValue(forKey: metadataKey)
        return NodeProfile(metadata: metadata, settings: settings)
    }

    /// Settings content suitable for writing into ~/.claude/settings.json (everything except _metadata).
    var settingsData: Data {
        get throws {
            try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        }
    }

    /// Readable JSON string of the settings portion (for the raw JSON editor).
    var settingsJSONString: String {
        guard let data = try? settingsData,
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: Factory

    static func defaultProfile(nodeType: NodeType = .openaiProxy) -> NodeProfile {
        let proxy: ProxySettings
        let defaultModel: String
        switch nodeType {
        case .openaiProxy:
            proxy = .defaultOpenAI
            defaultModel = "gpt-5.4"
        case .anthropicDirect:
            proxy = .defaultAnthropic
            defaultModel = "claude-sonnet-4-6"
        }

        let envConfig = proxy.buildEnvConfig(nodeType: nodeType)
        var settings: [String: Any] = [
            "$schema": "https://json.schemastore.org/claude-code-settings.json",
        ]
        if !defaultModel.isEmpty {
            settings["model"] = defaultModel
        }
        var env: [String: String] = [:]
        if let v = envConfig.baseURL { env["ANTHROPIC_BASE_URL"] = v }
        if let v = envConfig.authToken { env["ANTHROPIC_AUTH_TOKEN"] = v }
        if let v = envConfig.opusModel { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = v }
        if let v = envConfig.sonnetModel { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = v }
        if let v = envConfig.haikuModel { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = v }
        if !env.isEmpty { settings["env"] = env }

        return NodeProfile(
            metadata: Metadata(nodeType: nodeType, proxy: proxy),
            settings: settings
        )
    }

    // MARK: - Migration from legacy ProxyConfiguration

    static func fromLegacyConfiguration(_ config: ProxyConfiguration) -> NodeProfile {
        let proxy = ProxySettings(from: config)
        let metadata = Metadata(
            id: config.id,
            name: config.name,
            nodeType: config.nodeType,
            createdAt: config.createdAt,
            lastUsedAt: config.lastUsedAt,
            proxy: proxy
        )

        let envConfig = proxy.buildEnvConfig(nodeType: config.nodeType)
        var settings: [String: Any] = [
            "$schema": "https://json.schemastore.org/claude-code-settings.json",
        ]
        if !config.defaultModel.isEmpty {
            settings["model"] = config.defaultModel
        }
        var env: [String: String] = [:]
        if let v = envConfig.baseURL { env["ANTHROPIC_BASE_URL"] = v }
        if let v = envConfig.authToken { env["ANTHROPIC_AUTH_TOKEN"] = v }
        if let v = envConfig.opusModel { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = v }
        if let v = envConfig.sonnetModel { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = v }
        if let v = envConfig.haikuModel { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = v }
        if !env.isEmpty { settings["env"] = env }

        return NodeProfile(metadata: metadata, settings: settings)
    }

    // MARK: - Sync helpers

    /// Reverse-syncs model names from the settings dictionary into metadata.proxy.
    /// Called after applying JSON edits so that metadata stays consistent with settings content.
    mutating func syncProxyFromSettings() {
        if let model = settings["model"] as? String, !model.isEmpty {
            metadata.proxy.defaultModel = model
        }
        guard let env = settings["env"] as? [String: Any] else { return }
        if let opus = env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, !opus.isEmpty {
            metadata.proxy.modelMapping.bigModel.name = opus
        }
        if let sonnet = env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, !sonnet.isEmpty {
            metadata.proxy.modelMapping.middleModel.name = sonnet
        }
        if let haiku = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, !haiku.isEmpty {
            metadata.proxy.modelMapping.smallModel.name = haiku
        }
    }

    /// Rebuilds the `env` keys managed by the proxy from the current proxy settings,
    /// preserving any user-added env keys.
    mutating func syncEnvFromProxy() {
        let envConfig = metadata.proxy.buildEnvConfig(nodeType: metadata.nodeType)
        var env = settings["env"] as? [String: Any] ?? [:]

        let managedKeys = [
            "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        ]
        for key in managedKeys { env.removeValue(forKey: key) }

        let pairs: [(String, String?)] = [
            ("ANTHROPIC_BASE_URL", envConfig.baseURL),
            ("ANTHROPIC_AUTH_TOKEN", envConfig.authToken),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", envConfig.opusModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", envConfig.sonnetModel),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", envConfig.haikuModel),
        ]
        for (key, value) in pairs {
            if let value { env[key] = value }
        }
        settings["env"] = env.isEmpty ? nil : env

        if let dm = envConfig.defaultModel, !dm.isEmpty {
            settings["model"] = dm
        }
    }
}

// MARK: - Proxy Settings

/// Proxy-specific configuration extracted from the legacy ProxyConfiguration.
/// Stored inside `_metadata.proxy` in profile JSON files.
struct ProxySettings: Codable, Equatable {
    var host: String
    var port: Int
    var allowLAN: Bool
    var upstreamBaseURL: String
    var openAIUpstreamAPI: OpenAIUpstreamAPI
    var upstreamAPIKey: String
    var expectedClientKey: String
    var maxOutputTokens: Int
    var defaultModel: String
    var modelMapping: ProxyConfiguration.ModelMapping

    var anthropicBaseURL: String
    var anthropicAPIKey: String
    var usePassthroughProxy: Bool
    var enableModelAliasMapping: Bool?
    var enableHTTPS: Bool?
    var httpsPort: Int?

    var effectiveHTTPSPort: Int { httpsPort ?? (port + 1) }

    static var defaultOpenAI: ProxySettings {
        ProxySettings(
            host: "127.0.0.1", port: 8080, allowLAN: false,
            upstreamBaseURL: "https://api.openai.com",
            openAIUpstreamAPI: .chatCompletions,
            upstreamAPIKey: "", expectedClientKey: "",
            maxOutputTokens: 0, defaultModel: "gpt-5.4",
            modelMapping: .openAIDefault,
            anthropicBaseURL: "https://api.anthropic.com",
            anthropicAPIKey: "", usePassthroughProxy: false,
            enableModelAliasMapping: false,
            enableHTTPS: true, httpsPort: nil
        )
    }

    static var defaultAnthropic: ProxySettings {
        ProxySettings(
            host: "127.0.0.1", port: 8080, allowLAN: false,
            upstreamBaseURL: "https://api.openai.com",
            openAIUpstreamAPI: .chatCompletions,
            upstreamAPIKey: "", expectedClientKey: "",
            maxOutputTokens: 0, defaultModel: "claude-sonnet-4-6",
            modelMapping: .anthropicDefault,
            anthropicBaseURL: "https://api.anthropic.com",
            anthropicAPIKey: "", usePassthroughProxy: false,
            enableModelAliasMapping: false,
            enableHTTPS: true, httpsPort: nil
        )
    }

    init(from config: ProxyConfiguration) {
        host = config.host
        port = config.port
        allowLAN = config.allowLAN
        upstreamBaseURL = config.upstreamBaseURL
        openAIUpstreamAPI = config.openAIUpstreamAPI
        upstreamAPIKey = config.upstreamAPIKey
        expectedClientKey = config.expectedClientKey
        maxOutputTokens = config.maxOutputTokens
        defaultModel = config.defaultModel
        modelMapping = config.modelMapping
        anthropicBaseURL = config.anthropicBaseURL
        anthropicAPIKey = config.anthropicAPIKey
        usePassthroughProxy = config.usePassthroughProxy
        enableModelAliasMapping = config.enableModelAliasMapping
        enableHTTPS = config.enableHTTPS
        httpsPort = config.httpsPort
    }

    init(
        host: String, port: Int, allowLAN: Bool,
        upstreamBaseURL: String, openAIUpstreamAPI: OpenAIUpstreamAPI,
        upstreamAPIKey: String, expectedClientKey: String,
        maxOutputTokens: Int, defaultModel: String,
        modelMapping: ProxyConfiguration.ModelMapping,
        anthropicBaseURL: String, anthropicAPIKey: String, usePassthroughProxy: Bool,
        enableModelAliasMapping: Bool = false,
        enableHTTPS: Bool? = nil, httpsPort: Int? = nil
    ) {
        self.host = host
        self.port = port
        self.allowLAN = allowLAN
        self.upstreamBaseURL = upstreamBaseURL
        self.openAIUpstreamAPI = openAIUpstreamAPI
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.maxOutputTokens = maxOutputTokens
        self.defaultModel = defaultModel
        self.modelMapping = modelMapping
        self.anthropicBaseURL = anthropicBaseURL
        self.anthropicAPIKey = anthropicAPIKey
        self.usePassthroughProxy = usePassthroughProxy
        self.enableModelAliasMapping = enableModelAliasMapping
        self.enableHTTPS = enableHTTPS
        self.httpsPort = httpsPort
    }

    var bindAddress: String { allowLAN ? "0.0.0.0" : host }

    var displayURL: String { "http://\(host):\(port)" }

    var normalizedUpstreamBaseURL: String {
        ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
    }

    func needsProxyProcess(nodeType: NodeType) -> Bool {
        nodeType == .openaiProxy || (nodeType == .anthropicDirect && usePassthroughProxy)
    }

    func pricingForModel(_ model: String) -> ProxyConfiguration.ModelPricing? {
        if let p = modelMapping.pricingForUpstreamModel(model) { return p }
        if let p = modelMapping.pricingForFamily(of: model) { return p }
        return nil
    }

    /// Build the env config that will be written to settings.json.
    func buildEnvConfig(nodeType: NodeType) -> ClaudeSettingsManager.EnvConfig {
        let m = modelMapping
        let dm = defaultModel.isEmpty ? nil : defaultModel
        let opus = m.bigModel.name.isEmpty ? nil : m.bigModel.name
        let sonnet = m.middleModel.name.isEmpty ? nil : m.middleModel.name
        let haiku = m.smallModel.name.isEmpty ? nil : m.smallModel.name

        switch nodeType {
        case .anthropicDirect:
            if usePassthroughProxy {
                let proxyURL = "http://\(host):\(port)"
                return .init(baseURL: proxyURL, authToken: anthropicAPIKey,
                             defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
            }
            return .init(baseURL: anthropicBaseURL, authToken: anthropicAPIKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        case .openaiProxy:
            let proxyKey = expectedClientKey.isEmpty ? "proxy-key" : expectedClientKey
            return .init(baseURL: displayURL, authToken: proxyKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        }
    }

    /// Convert back to legacy ProxyConfiguration (for runtime compatibility).
    func toProxyConfiguration(metadata: NodeProfile.Metadata) -> ProxyConfiguration {
        ProxyConfiguration(
            id: metadata.id,
            name: metadata.name,
            nodeType: metadata.nodeType,
            isEnabled: false,
            anthropicBaseURL: anthropicBaseURL,
            anthropicAPIKey: anthropicAPIKey,
            usePassthroughProxy: usePassthroughProxy,
            host: host,
            port: port,
            allowLAN: allowLAN,
            upstreamBaseURL: upstreamBaseURL,
            openAIUpstreamAPI: openAIUpstreamAPI,
            upstreamAPIKey: upstreamAPIKey,
            expectedClientKey: expectedClientKey,
            defaultModel: defaultModel,
            modelMapping: modelMapping,
            maxOutputTokens: maxOutputTokens,
            createdAt: metadata.createdAt,
            lastUsedAt: metadata.lastUsedAt,
            enableModelAliasMapping: enableModelAliasMapping ?? false,
            enableHTTPS: enableHTTPS ?? false,
            httpsPort: httpsPort
        )
    }
}

// MARK: - Profile Errors

enum NodeProfileError: LocalizedError {
    case invalidRootObject
    case missingMetadata
    case serializationFailed
    case fileWriteFailed
    case directoryCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidRootObject:
            return AppSettings.shared.t("Profile JSON must be a top-level object.", "配置文件 JSON 必须是顶层对象。")
        case .missingMetadata:
            return AppSettings.shared.t("Profile is missing the _metadata field.", "配置文件缺少 _metadata 字段。")
        case .serializationFailed:
            return AppSettings.shared.t("Failed to serialize profile.", "序列化配置文件失败。")
        case .fileWriteFailed:
            return AppSettings.shared.t("Failed to write profile file.", "写入配置文件失败。")
        case .directoryCreationFailed:
            return AppSettings.shared.t("Failed to create profiles directory.", "创建配置文件目录失败。")
        }
    }
}

// MARK: - JSON Coder Helpers

extension JSONEncoder {
    static let profileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let profileDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
