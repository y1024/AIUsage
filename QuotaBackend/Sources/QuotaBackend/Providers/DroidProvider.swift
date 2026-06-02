import Foundation

// MARK: - Droid Provider
// Reads saved Droid/Factory sessions, browser cookies, and legacy auth files.

public struct DroidProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "droid"
    public let displayName = "Droid"
    public let description = "Factory Droid token quota usage"

    public struct StoredSessionSnapshot {
        public let accessToken: String?
        public let refreshToken: String?
        public let organizationId: String?
        public let cookieHeader: String?
    }

    let homeDirectory: String
    let timeoutSeconds: Double

    // 数据接口托管在 app.factory.ai / api.factory.ai（两者都返回 401 需要鉴权）。
    // auth.factory.ai 只负责 OAuth，对这些路径一律返回 404，放进来只会让每次抓取都先
    // 白白多打两次无效请求、拖慢甚至触发整体超时——所以这里只保留真正承载数据的两个域名，
    // 并把最常命中的 app.factory.ai 放在第一位，让正常情况下首个请求即可返回。
    static let baseURLs = [
        "https://app.factory.ai",
        "https://api.factory.ai"
    ]
    static let workOSRefreshURL = "https://api.workos.com/user_management/authenticate"
    static let workOSClientID = "client_01HNM792M5G5G1A2THWPXKFMXB"
    static let keyringServiceName = "Factory CLI"
    static let keyringAccountName = "auth-encryption-key"
    static let unlimitedThreshold: Int = 1_000_000_000_000
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    static let sessionCookieNames: Set<String> = [
        "wos-session",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "__Host-authjs.csrf-token",
        "authjs.session-token",
        "session",
        "access-token"
    ]
    static let authSessionCookieNames: Set<String> = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
        "__Host-authjs.csrf-token"
    ]
    static let staleTokenCookieNames: Set<String> = [
        "access-token",
        "__recent_auth"
    ]

    public var supportedAuthMethods: [AuthMethod] { [.apiKey, .cookie, .token, .authFile, .auto] }

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeoutSeconds: Double = 15
    ) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public static func loadStoredSessionSnapshot(
        at path: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> StoredSessionSnapshot? {
        let provider = DroidProvider(homeDirectory: homeDirectory)
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let session = provider.loadSessionFile(at: expandedPath) else { return nil }
        return StoredSessionSnapshot(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            organizationId: session.organizationId,
            cookieHeader: session.cookieHeader
        )
    }

    public static func managedSessionData(
        from path: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Data? {
        guard let snapshot = loadStoredSessionSnapshot(at: path, homeDirectory: homeDirectory) else {
            return nil
        }

        var json: [String: Any] = [:]
        if let accessToken = snapshot.accessToken { json["access_token"] = accessToken }
        if let refreshToken = snapshot.refreshToken { json["refresh_token"] = refreshToken }
        if let organizationId = snapshot.organizationId { json["organization_id"] = organizationId }
        if let cookieHeader = snapshot.cookieHeader { json["cookie_header"] = cookieHeader }
        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let auth = try await resolveAuth()
        let (authInfo, usageInfo, resolvedAuth) = try await fetchSnapshot(auth: auth, persistencePath: nil)
        return parseResponse(authInfo: authInfo, usageInfo: usageInfo, auth: resolvedAuth)
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        let auth = try await resolveAuth(from: credential)
        let persistencePath: String?
        if credential.authMethod == .authFile {
            persistencePath = NSString(string: credential.credential).expandingTildeInPath
        } else {
            persistencePath = nil
        }
        let (authInfo, usageInfo, resolvedAuth) = try await fetchSnapshot(auth: auth, persistencePath: persistencePath)
        return parseResponse(authInfo: authInfo, usageInfo: usageInfo, auth: resolvedAuth)
    }

    // MARK: - Browser Session Discovery

    static func browserProfiles(home: String) -> [(name: String, profileName: String, cookiesPath: String, keychainService: String)] {
        [
            ("Chrome", "Default", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies", "Chrome Safe Storage"),
            ("Chrome", "Profile 1", "\(home)/Library/Application Support/Google/Chrome/Profile 1/Cookies", "Chrome Safe Storage"),
            ("Chrome", "Profile 2", "\(home)/Library/Application Support/Google/Chrome/Profile 2/Cookies", "Chrome Safe Storage"),
            ("Arc", "Default", "\(home)/Library/Application Support/Arc/User Data/Default/Cookies", "Arc Safe Storage"),
            ("Edge", "Default", "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies", "Microsoft Edge Safe Storage"),
            ("Brave", "Default", "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies", "Brave Safe Storage"),
            ("Cursor", "Browser", "\(home)/Library/Application Support/Cursor/Partitions/cursor-browser/Cookies", "Cursor Safe Storage"),
            ("Cursor", "Main", "\(home)/Library/Application Support/Cursor/Cookies", "Cursor Safe Storage"),
        ]
    }

    public static func discoverBrowserSessions(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [BrowserDiscovery.DiscoveredSession] {
        var seen = Set<String>()
        return browserProfiles(home: homeDirectory).compactMap { profile in
            guard FileManager.default.fileExists(atPath: profile.cookiesPath),
                  let header = extractDroidCookieHeader(
                    dbPath: profile.cookiesPath,
                    keychainService: profile.keychainService
                  ) else {
                return nil
            }

            let normalizedHeader = normalizeCookieHeader(header)
            guard !normalizedHeader.isEmpty, seen.insert(normalizedHeader).inserted else { return nil }

            let accountHint = jwtEmail(from: bearerToken(fromCookieHeader: normalizedHeader))
            return BrowserDiscovery.DiscoveredSession(
                browserName: profile.name,
                profileName: profile.profileName,
                cookieHeader: normalizedHeader,
                accountHint: accountHint
            )
        }
    }

    // MARK: - Internal Types (extensions)

    struct DroidAuth {
        let cookieHeader: String?
        let bearerToken: String?
        let refreshToken: String?
        let organizationId: String?
        let userId: String?
        let source: SourceInfo
    }

    struct SessionFile {
        let accessToken: String?
        let refreshToken: String?
        let organizationId: String?
        let cookieHeader: String?
    }

    struct RefreshedAuth {
        let accessToken: String
        let refreshToken: String?
        let organizationId: String?
    }

    struct TokenUsage {
        let userTokens: Int
        let totalAllowance: Int
        let usedPercent: Double
        let remainingPercent: Double
        let unlimited: Bool
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        switch self {
        case .some(let value):
            return value.nilIfBlank
        case .none:
            return nil
        }
    }
}
