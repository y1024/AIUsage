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
    var routingStrategy: CLIProxyRoutingStrategy = .roundRobin
    var requestRetry: Int = 2
    var proxyURL: String = ""
    var enablePlugins: Bool = false

    static let `default` = CLIProxyGatewaySettings()

    var normalized: CLIProxyGatewaySettings {
        var value = self
        value.port = min(max(value.port, 1_024), 65_535)
        value.requestRetry = min(max(value.requestRetry, 0), 10)
        value.proxyURL = value.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
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
    let priority: Int?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, provider, label, email, status, disabled, unavailable, source, priority, note
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "unknown.json"
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        runtimeOnly = try container.decodeIfPresent(Bool.self, forKey: .runtimeOnly) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    var displayProvider: String { provider ?? type ?? "unknown" }
    var displayLabel: String { email ?? label ?? name }
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
}

nonisolated enum CLIProxyOAuthProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case anthropic
    case antigravity
    case kimi
    case xai

    var id: String { rawValue }
    var endpoint: String { self == .anthropic ? "anthropic-auth-url" : "\(rawValue)-auth-url" }
}

nonisolated struct CLIProxyOAuthSession: Decodable, Sendable {
    let status: String
    let url: URL
    let state: String
}

nonisolated struct CLIProxyOAuthStatus: Decodable, Sendable {
    let status: String
    let error: String?
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
        }
    }
}

nonisolated private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
