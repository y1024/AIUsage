import CryptoKit
import Foundation

nonisolated enum CLIProxyArchitecture: String, Codable, Sendable {
    case arm64
    case x86_64

    static var current: CLIProxyArchitecture {
#if arch(arm64)
        .arm64
#elseif arch(x86_64)
        .x86_64
#else
#error("CLIProxyAPI updater only supports Apple Silicon and Intel macOS builds")
#endif
    }

    var releaseToken: String {
        switch self {
        case .arm64: "aarch64"
        case .x86_64: "amd64"
        }
    }

    var acceptedReleaseTokens: [String] {
        switch self {
        case .arm64: ["aarch64", "arm64"]
        case .x86_64: ["amd64", "x86_64"]
        }
    }

    var lipoToken: String { rawValue }
}

nonisolated struct CLIProxyGitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
        case size
    }

    var sha256: String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return nil }
        let value = String(digest.dropFirst(prefix.count)).lowercased()
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        return value
    }
}

nonisolated struct CLIProxyGitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [CLIProxyGitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case prerelease
        case publishedAt = "published_at"
        case assets
    }

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    func fullMacOSAsset(for architecture: CLIProxyArchitecture) -> CLIProxyGitHubAsset? {
        return assets.first { asset in
            matchesFullMacOSAsset(asset, architecture: architecture) && asset.sha256 != nil
        }
    }

    func hasFullMacOSAsset(for architecture: CLIProxyArchitecture) -> Bool {
        assets.contains { matchesFullMacOSAsset($0, architecture: architecture) }
    }

    private func matchesFullMacOSAsset(
        _ asset: CLIProxyGitHubAsset,
        architecture: CLIProxyArchitecture
    ) -> Bool {
        let lowercased = asset.name.lowercased()
        guard !lowercased.contains("no-plugin") else { return false }
        return architecture.acceptedReleaseTokens.contains { token in
            lowercased.hasSuffix("_darwin_\(token).tar.gz")
        }
    }
}

nonisolated struct CLIProxyRelease: Identifiable, Sendable, Equatable {
    let tagName: String
    let version: String
    let assetName: String
    let downloadURL: URL
    let sha256: String
    let size: Int64
    let releaseNotes: String?
    let publishedAt: Date?

    var id: String { version }

    init(
        tagName: String,
        version: String,
        assetName: String,
        downloadURL: URL,
        sha256: String,
        size: Int64,
        releaseNotes: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.tagName = tagName
        self.version = version
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
    }

    init?(githubRelease: CLIProxyGitHubRelease, architecture: CLIProxyArchitecture) {
        guard !githubRelease.prerelease,
              CLIProxyVersion.isSafePathComponent(githubRelease.version),
              let asset = githubRelease.fullMacOSAsset(for: architecture),
              let sha256 = asset.sha256 else {
            return nil
        }
        tagName = githubRelease.tagName
        version = githubRelease.version
        assetName = asset.name
        downloadURL = asset.browserDownloadURL
        self.sha256 = sha256
        size = asset.size
        releaseNotes = githubRelease.body
        publishedAt = githubRelease.publishedAt
    }
}

nonisolated struct CLIProxyInstalledVersion: Identifiable, Sendable, Equatable {
    let version: String
    let binaryURL: URL
    let installedAt: Date
    let isCurrent: Bool

    var id: String { version }
}

nonisolated enum CLIProxyGatewayOperation: Equatable {
    case idle
    case checking
    case downloading(version: String)
    case verifying(version: String)
    case installing(version: String)
    case activating(version: String)

    var isBusy: Bool { self != .idle }
}

nonisolated enum CLIProxyRoutingStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case roundRobin = "round-robin"
    case fillFirst = "fill-first"

    var id: String { rawValue }
}

nonisolated struct CLIProxyGatewaySettings: Codable, Equatable, Sendable {
    var port: Int = 14420
    var autoStart: Bool = false
    var allowLANAccess: Bool = false
    var routingStrategy: CLIProxyRoutingStrategy = .roundRobin
    var requestRetry: Int = 2
    var proxyURL: String = ""
    var enablePlugins: Bool = false

    static let `default` = CLIProxyGatewaySettings()

    init(
        port: Int = 14420,
        autoStart: Bool = false,
        allowLANAccess: Bool = false,
        routingStrategy: CLIProxyRoutingStrategy = .roundRobin,
        requestRetry: Int = 2,
        proxyURL: String = "",
        enablePlugins: Bool = false
    ) {
        self.port = port
        self.autoStart = autoStart
        self.allowLANAccess = allowLANAccess
        self.routingStrategy = routingStrategy
        self.requestRetry = requestRetry
        self.proxyURL = proxyURL
        self.enablePlugins = enablePlugins
    }

    enum CodingKeys: String, CodingKey {
        case port, autoStart, allowLANAccess, routingStrategy, requestRetry, proxyURL, enablePlugins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 14420
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        allowLANAccess = try container.decodeIfPresent(Bool.self, forKey: .allowLANAccess) ?? false
        routingStrategy = try container.decodeIfPresent(CLIProxyRoutingStrategy.self, forKey: .routingStrategy) ?? .roundRobin
        requestRetry = try container.decodeIfPresent(Int.self, forKey: .requestRetry) ?? 2
        proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        enablePlugins = try container.decodeIfPresent(Bool.self, forKey: .enablePlugins) ?? false
    }

    var normalized: CLIProxyGatewaySettings {
        var value = self
        value.port = min(max(value.port, 1_024), 65_535)
        value.requestRetry = min(max(value.requestRetry, 0), 10)
        value.proxyURL = value.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    var bindHost: String { allowLANAccess ? "0.0.0.0" : "127.0.0.1" }

    /// Three-way merge for settings edited in one tab while another CPA action
    /// updates runtime settings. Fields the user changed relative to `base`
    /// remain in the draft; untouched fields follow the latest runtime value.
    func mergingExternalChange(
        from base: CLIProxyGatewaySettings,
        to external: CLIProxyGatewaySettings
    ) -> CLIProxyGatewaySettings {
        var merged = self
        if port == base.port { merged.port = external.port }
        if autoStart == base.autoStart { merged.autoStart = external.autoStart }
        if allowLANAccess == base.allowLANAccess { merged.allowLANAccess = external.allowLANAccess }
        if routingStrategy == base.routingStrategy { merged.routingStrategy = external.routingStrategy }
        if requestRetry == base.requestRetry { merged.requestRetry = external.requestRetry }
        if proxyURL == base.proxyURL { merged.proxyURL = external.proxyURL }
        if enablePlugins == base.enablePlugins { merged.enablePlugins = external.enablePlugins }
        return merged
    }
}

nonisolated struct CLIProxySecrets: Sendable, Equatable {
    let managementKey: String
    let clientAPIKey: String
}

nonisolated enum CLIProxyRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32)
    case stopping
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isTransitioning: Bool {
        self == .starting || self == .stopping
    }
}

nonisolated struct CLIProxyRecentRequest: Codable, Equatable, Sendable {
    let time: String
    let success: Int64
    let failed: Int64

    enum CodingKeys: String, CodingKey {
        case time, success, failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = container.lossyString(forKey: .time) ?? ""
        success = container.lossyInt64(forKey: .success) ?? 0
        failed = container.lossyInt64(forKey: .failed) ?? 0
    }
}

nonisolated struct CLIProxyAuthFile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let authIndex: String?
    let name: String
    let type: String?
    let provider: String?
    let label: String?
    let email: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool
    let unavailable: Bool
    let runtimeOnly: Bool
    let source: String?
    let path: String?
    let size: Int64?
    let modTime: Date?
    let updatedAt: Date?
    let createdAt: Date?
    let lastRefresh: Date?
    let nextRetryAfter: Date?
    let projectID: String?
    let accountType: String?
    let account: String?
    let priority: Int?
    let note: String?
    let websockets: Bool?
    let success: Int64
    let failed: Int64
    let recentRequests: [CLIProxyRecentRequest]

    enum CodingKeys: String, CodingKey {
        case id, name, type, provider, label, email, status, disabled, unavailable, source, path, size
        case priority, note, websockets, success, failed
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case modTime = "modtime"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case lastRefresh = "last_refresh"
        case nextRetryAfter = "next_retry_after"
        case projectID = "project_id"
        case accountType = "account_type"
        case account
        case recentRequests = "recent_requests"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "unknown.json"
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name
        authIndex = container.lossyString(forKey: .authIndex)
        type = container.lossyString(forKey: .type)
        provider = container.lossyString(forKey: .provider)
        label = container.lossyString(forKey: .label)
        email = container.lossyString(forKey: .email)
        status = container.lossyString(forKey: .status)
        statusMessage = container.lossyString(forKey: .statusMessage)
        disabled = container.lossyBool(forKey: .disabled) ?? false
        unavailable = container.lossyBool(forKey: .unavailable) ?? false
        runtimeOnly = container.lossyBool(forKey: .runtimeOnly) ?? false
        source = container.lossyString(forKey: .source)
        path = container.lossyString(forKey: .path)
        size = container.lossyInt64(forKey: .size)
        modTime = container.lossyDate(forKey: .modTime)
        updatedAt = container.lossyDate(forKey: .updatedAt)
        createdAt = container.lossyDate(forKey: .createdAt)
        lastRefresh = container.lossyDate(forKey: .lastRefresh)
        nextRetryAfter = container.lossyDate(forKey: .nextRetryAfter)
        projectID = container.lossyString(forKey: .projectID)
        accountType = container.lossyString(forKey: .accountType)
        account = container.lossyString(forKey: .account)
        priority = container.lossyInt(forKey: .priority)
        note = container.lossyString(forKey: .note)
        websockets = container.lossyBool(forKey: .websockets)
        success = container.lossyInt64(forKey: .success) ?? 0
        failed = container.lossyInt64(forKey: .failed) ?? 0
        recentRequests = (try? container.decodeIfPresent([CLIProxyRecentRequest].self, forKey: .recentRequests)) ?? []
    }

    init(openAICompatible provider: CLIProxyOpenAICompatibleProvider) {
        let normalizedName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        id = "openai-compatible:\(normalizedName.lowercased())"
        authIndex = nil
        name = "openai-compatible-\(normalizedName).runtime"
        type = "openai-compatibility"
        self.provider = "openai-compatibility"
        label = normalizedName
        email = nil
        status = provider.disabled ? "disabled" : "ready"
        statusMessage = nil
        disabled = provider.disabled
        unavailable = false
        runtimeOnly = true
        source = "config"
        path = nil
        size = nil
        modTime = nil
        updatedAt = nil
        createdAt = nil
        lastRefresh = nil
        nextRetryAfter = nil
        projectID = nil
        accountType = "openai-compatible"
        account = normalizedName
        priority = provider.priority
        note = nil
        websockets = nil
        success = 0
        failed = 0
        recentRequests = []
    }

    var displayProvider: String { provider ?? type ?? "unknown" }
    var displayLabel: String { email ?? label ?? name }
    var isOpenAICompatibleRuntime: Bool {
        let value = (provider ?? type ?? "").lowercased()
        return runtimeOnly && (value == "openai-compatibility" || value.hasPrefix("openai-compatible-"))
    }
}

nonisolated struct CLIProxyModel: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String?
    let type: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type
        case displayName = "display_name"
        case ownedBy = "owned_by"
    }

    init(id: String, displayName: String? = nil, type: String? = nil, ownedBy: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.ownedBy = ownedBy
    }
}

nonisolated enum CLIProxyModelProtocol: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openAI
    case anthropic
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        }
    }

    var sortOrder: Int {
        switch self {
        case .openAI: 0
        case .anthropic: 1
        case .gemini: 2
        }
    }
}

nonisolated struct CLIProxyModelCatalogEntry: Identifiable, Equatable, Sendable {
    let model: CLIProxyModel
    let protocols: Set<CLIProxyModelProtocol>

    var id: String { model.id }
}

nonisolated struct CLIProxyModelCatalogSnapshot: Equatable, Sendable {
    let openAIModels: [CLIProxyModel]
    let entries: [CLIProxyModelCatalogEntry]
    let unavailableProtocols: Set<CLIProxyModelProtocol>
}

nonisolated struct CLIProxyPluginMetadata: Codable, Equatable, Sendable {
    let name: String?
    let version: String?
    let author: String?
    let githubRepository: String?
    let logo: String?

    enum CodingKeys: String, CodingKey {
        case name, version, author, logo
        case githubRepository = "github_repository"
    }
}

nonisolated struct CLIProxyPlugin: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let supportsOAuth: Bool
    let oauthProvider: String?
    let logo: String?
    let metadata: CLIProxyPluginMetadata?

    enum CodingKeys: String, CodingKey {
        case id, configured, registered, enabled, logo, metadata
        case effectiveEnabled = "effective_enabled"
        case supportsOAuth = "supports_oauth"
        case oauthProvider = "oauth_provider"
    }

    var displayName: String {
        guard let value = metadata?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return id }
        return value
    }
    var providerID: String {
        guard let value = oauthProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return id }
        return value
    }
}

nonisolated struct CLIProxyPluginStoreEntry: Codable, Identifiable, Equatable, Sendable {
    let storeID: String
    let sourceID: String
    let id: String
    let name: String
    let description: String
    let author: String
    let version: String
    let repository: String
    let logo: String?
    let homepage: String?
    let license: String?
    let tags: [String]
    let installed: Bool
    let installedVersion: String?
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let updateAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, author, version, repository, logo, homepage, license, tags
        case installed, configured, registered, enabled
        case storeID = "store_id"
        case sourceID = "source_id"
        case installedVersion = "installed_version"
        case effectiveEnabled = "effective_enabled"
        case updateAvailable = "update_available"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        storeID = try container.decodeIfPresent(String.self, forKey: .storeID) ?? "official"
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? storeID
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? ""
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        registered = try container.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        effectiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .effectiveEnabled) ?? false
        updateAvailable = try container.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
    }

    var isProvider: Bool { tags.contains { $0.caseInsensitiveCompare("provider") == .orderedSame } }
}

nonisolated struct CLIProxyOpenAICompatibleProvider: Codable, Equatable, Sendable {
    struct APIKeyEntry: Codable, Equatable, Sendable {
        let apiKey: String
        let proxyURL: String?

        enum CodingKeys: String, CodingKey {
            case apiKey = "api-key"
            case proxyURL = "proxy-url"
        }
    }

    struct Model: Codable, Equatable, Sendable {
        let name: String
        let alias: String
        let forceMapping: Bool

        init(name: String, alias: String = "", forceMapping: Bool = false) {
            self.name = name
            self.alias = alias
            self.forceMapping = forceMapping
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
            forceMapping = try container.decodeIfPresent(Bool.self, forKey: .forceMapping) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case name, alias
            case forceMapping = "force-mapping"
        }
    }

    let name: String
    let priority: Int
    let disabled: Bool
    let prefix: String
    let baseURL: String
    let apiKeyEntries: [APIKeyEntry]
    let models: [Model]
    let headers: [String: String]?
    let disableCooling: Bool

    enum CodingKeys: String, CodingKey {
        case name, priority, disabled, prefix, models, headers
        case baseURL = "base-url"
        case apiKeyEntries = "api-key-entries"
        case disableCooling = "disable-cooling"
    }

    init(
        name: String,
        priority: Int = 0,
        disabled: Bool = false,
        prefix: String = "",
        baseURL: String,
        apiKeyEntries: [APIKeyEntry] = [],
        models: [Model] = [],
        headers: [String: String]? = nil,
        disableCooling: Bool = false
    ) {
        self.name = name
        self.priority = priority
        self.disabled = disabled
        self.prefix = prefix
        self.baseURL = baseURL
        self.apiKeyEntries = apiKeyEntries
        self.models = models
        self.headers = headers
        self.disableCooling = disableCooling
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKeyEntries = try container.decodeIfPresent([APIKeyEntry].self, forKey: .apiKeyEntries) ?? []
        models = try container.decodeIfPresent([Model].self, forKey: .models) ?? []
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        disableCooling = try container.decodeIfPresent(Bool.self, forKey: .disableCooling) ?? false
    }
}

nonisolated enum CLIProxyOAuthProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case anthropic
    case antigravity
    case kimi
    case xai

    var id: String { rawValue }
    var endpoint: String { self == .anthropic ? "anthropic-auth-url" : "\(rawValue)-auth-url" }

    /// CPA writes Anthropic OAuth credentials with the historical `claude` provider value.
    var authFileProviderIDs: Set<String> {
        self == .anthropic ? ["anthropic", "claude"] : [rawValue]
    }
}

nonisolated struct CLIProxyOAuthSession: Decodable, Equatable, Sendable {
    let status: String
    let url: URL
    let state: String
    let flow: String?
    let userCode: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case status, url, state, flow
        case userCode = "user_code"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lossyString(forKey: .status) ?? "ok"
        state = try container.decode(String.self, forKey: .state)
        if let decodedURL = try? container.decode(URL.self, forKey: .url) {
            url = decodedURL
        } else if let rawURL = container.lossyString(forKey: .url), let decodedURL = URL(string: rawURL) {
            url = decodedURL
        } else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "invalid OAuth URL")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "unsupported OAuth URL scheme")
        }
        flow = container.lossyString(forKey: .flow)
        userCode = container.lossyString(forKey: .userCode)
        expiresIn = container.lossyInt(forKey: .expiresIn)
    }

    var isDeviceFlow: Bool { flow?.caseInsensitiveCompare("device") == .orderedSame }
}

nonisolated struct CLIProxyOAuthStatus: Decodable, Sendable {
    let status: String
    let error: String?
}

nonisolated enum CLIProxyOAuthFlowState: Equatable, Sendable {
    case idle
    case starting(CLIProxyOAuthProvider)
    case waiting(CLIProxyOAuthProvider, CLIProxyOAuthSession)
    case succeeded(CLIProxyOAuthProvider)
    case cancelled(CLIProxyOAuthProvider?)
    case failed(CLIProxyOAuthProvider?, String)
    case pluginStarting(String)
    case pluginWaiting(String, CLIProxyOAuthSession)
    case pluginSucceeded(String)
    case pluginFailed(String, String)

    var isActive: Bool {
        switch self {
        case .starting, .waiting, .pluginStarting, .pluginWaiting: true
        default: false
        }
    }
}

nonisolated struct CLIProxyAccountSyncCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let providerId: String
    let label: String
    let credentialId: String
    let compatibility: Compatibility

    nonisolated enum Compatibility: Equatable, Sendable {
        case compatible
        case unsupported(String)
    }
}

nonisolated enum CLIProxyAccountSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manualCopy
    case keepUpdated

    var id: String { rawValue }
}

nonisolated enum CLIProxyAccountSyncState: String, Codable, Equatable, Sendable {
    case notSynced
    case current
    case sourceChanged
    case cpaChanged
    case conflict
    case missing
}

/// Contains only identity metadata and one-way content fingerprints. Credential JSON is never persisted here.
nonisolated struct CLIProxyAccountSyncRecord: Codable, Identifiable, Equatable, Sendable {
    let providerId: String
    let credentialId: String
    let authFileName: String
    let sourceFingerprint: String
    let lastCopiedFingerprint: String
    let lastSyncedAt: Date
    var mode: CLIProxyAccountSyncMode

    var id: String { "\(providerId):\(credentialId)" }
}

nonisolated struct CLIProxyAccountSyncManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var records: [CLIProxyAccountSyncRecord]

    static let empty = CLIProxyAccountSyncManifest(schemaVersion: 1, records: [])
}

/// Canonicalizes JSON before hashing so formatting and object-key order do not look like credential changes.
nonisolated enum CLIProxyJSONFingerprint {
    static func canonicalData(_ data: Data, requireObject: Bool = false) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CLIProxyGatewayError.invalidResponse("auth file is not valid JSON")
        }
        if requireObject, !(object is [String: Any]) {
            throw CLIProxyGatewayError.invalidResponse("auth file must contain a JSON object")
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIProxyGatewayError.invalidResponse("auth file contains unsupported JSON values")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func hash(_ data: Data, requireObject: Bool = false) throws -> String {
        let digest = SHA256.hash(data: try canonicalData(data, requireObject: requireObject))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CLIProxyVersion {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        let normalized = normalized(value)
        guard !normalized.isEmpty, normalized.count <= 64 else { return false }
        return normalized.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789.-_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0)
        } && normalized != "." && normalized != ".."
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ value: String) -> [Int] {
        normalized(value)
            .split(whereSeparator: { !$0.isNumber })
            .map { Int($0) ?? 0 }
    }
}

nonisolated enum CLIProxyGatewayError: LocalizedError {
    case invalidRelease(String)
    case incompatibleAsset
    case missingDigest
    case network(String)
    case invalidHTTPStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchive(String)
    case extractionFailed(String)
    case signingFailed(String)
    case incompatibleBinary(String)
    case dryRunFailed(String)
    case versionNotInstalled(String)
    case cannotDeleteCurrentVersion
    case fileSystem(String)
    case notInstalled
    case alreadyRunning
    case invalidPort(Int)
    case portInUse(Int, String)
    case secretStorage(String)
    case configuration(String)
    case process(String)
    case managementAPI(Int, String)
    case invalidResponse(String)
    case unsupportedAccount(String)
    case invalidAuthFile(String)
    case authFileTooLarge(maxBytes: Int)
    case authFileConflict(String)
    case syncConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease(let reason): "Invalid CLIProxyAPI release: \(reason)"
        case .incompatibleAsset: "No full CLIProxyAPI macOS asset matches this Mac."
        case .missingDigest: "The selected release asset does not include a valid SHA-256 digest."
        case .network(let reason): "CLIProxyAPI update request failed: \(reason)"
        case .invalidHTTPStatus(let status): "CLIProxyAPI update server returned HTTP \(status)."
        case .checksumMismatch(let expected, let actual):
            "CLIProxyAPI checksum mismatch (expected \(expected), got \(actual))."
        case .unsafeArchive(let reason): "Unsafe CLIProxyAPI archive: \(reason)"
        case .extractionFailed(let reason): "Could not extract CLIProxyAPI: \(reason)"
        case .signingFailed(let reason): "Could not sign CLIProxyAPI: \(reason)"
        case .incompatibleBinary(let reason): "Incompatible CLIProxyAPI binary: \(reason)"
        case .dryRunFailed(let reason): "CLIProxyAPI dry run failed: \(reason)"
        case .versionNotInstalled(let version): "CLIProxyAPI \(version) is not installed."
        case .cannotDeleteCurrentVersion: "The active CLIProxyAPI version cannot be deleted."
        case .fileSystem(let reason): "CLIProxyAPI storage error: \(reason)"
        case .notInstalled: "CLIProxyAPI is not installed."
        case .alreadyRunning: "CLIProxyAPI is already running."
        case .invalidPort(let port): "CLIProxyAPI port \(port) is invalid."
        case .portInUse(let port, let owner): "CLIProxyAPI port \(port) is already used by \(owner)."
        case .secretStorage(let reason): "CLIProxyAPI secret storage failed: \(reason)"
        case .configuration(let reason): "CLIProxyAPI configuration failed: \(reason)"
        case .process(let reason): "CLIProxyAPI process failed: \(reason)"
        case .managementAPI(let status, let reason): "CLIProxyAPI Management API returned HTTP \(status): \(reason)"
        case .invalidResponse(let reason): "CLIProxyAPI returned an invalid response: \(reason)"
        case .unsupportedAccount(let reason): "This account cannot be synchronized to CLIProxyAPI: \(reason)"
        case .invalidAuthFile(let reason): "Invalid CLIProxyAPI auth file: \(reason)"
        case .authFileTooLarge(let maxBytes): "The auth file exceeds the \(maxBytes / 1_048_576) MB import limit."
        case .authFileConflict(let name): "An auth file named \(name) already exists in CLIProxyAPI."
        case .syncConflict(let reason): "The AIUsage and CLIProxyAPI copies both changed: \(reason)"
        }
    }
}

nonisolated private extension KeyedDecodingContainer {
    func lossyString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func lossyInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = lossyString(forKey: key) { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    func lossyInt64(forKey key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int64(value) }
        if let value = lossyString(forKey: key) { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    func lossyBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = lossyInt(forKey: key) { return value != 0 }
        guard let value = lossyString(forKey: key)?.lowercased() else { return nil }
        switch value {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    func lossyDate(forKey key: Key) -> Date? {
        if let seconds = try? decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let value = lossyString(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

nonisolated private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
