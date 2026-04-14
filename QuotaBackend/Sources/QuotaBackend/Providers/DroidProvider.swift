import Foundation
import CommonCrypto
import CryptoKit

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

    static let baseURLs = [
        "https://auth.factory.ai",
        "https://api.factory.ai",
        "https://app.factory.ai"
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

    public var supportedAuthMethods: [AuthMethod] { [.cookie, .token, .authFile, .auto] }

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

    // MARK: - Auth Resolution

    private struct DroidAuth {
        let cookieHeader: String?
        let bearerToken: String?
        let refreshToken: String?
        let organizationId: String?
        let userId: String?
        let source: SourceInfo
    }

    private func resolveAuth() async throws -> DroidAuth {
        if let env = ProcessInfo.processInfo.environment["DROID_COOKIE_HEADER"].nilIfBlank {
            let normalizedCookie = Self.normalizeCookieHeader(env)
            let token = Self.bearerToken(fromCookieHeader: normalizedCookie)
            let claims = parseJWTClaims(token ?? "")
            return DroidAuth(
                cookieHeader: normalizedCookie,
                bearerToken: token,
                refreshToken: nil,
                organizationId: claims["org_id"] as? String,
                userId: claims["sub"] as? String,
                source: SourceInfo(mode: "manual", type: "cookie-header")
            )
        }

        if let browserSession = Self.discoverBrowserSessions(homeDirectory: homeDirectory).first {
            let token = Self.bearerToken(fromCookieHeader: browserSession.cookieHeader)
            let claims = parseJWTClaims(token ?? "")
            var source = SourceInfo(mode: "auto", type: "browser-cookie")
            source.browserName = browserSession.browserName
            source.profile = browserSession.profileName
            return DroidAuth(
                cookieHeader: browserSession.cookieHeader,
                bearerToken: token,
                refreshToken: nil,
                organizationId: claims["org_id"] as? String,
                userId: claims["sub"] as? String,
                source: source
            )
        }

        if let session = loadSessionFile() {
            return try await resolveStoredSession(
                session,
                source: SourceInfo(mode: "auto", type: "auth-file"),
                persistencePath: nil
            )
        }

        throw ProviderError(
            "not_logged_in",
            "No Droid login state found. Log in to app.factory.ai in Chrome, Arc, Edge, Brave, or Cursor and connect that session in AIUsage."
        )
    }

    private func resolveAuth(from credential: AccountCredential) async throws -> DroidAuth {
        switch credential.authMethod {
        case .cookie:
            let normalizedCookie = Self.normalizeCookieHeader(credential.credential)
            guard !normalizedCookie.isEmpty else {
                throw ProviderError("missing_cookie", "Droid cookie header is empty.")
            }

            let token = Self.bearerToken(fromCookieHeader: normalizedCookie)
            let claims = parseJWTClaims(token ?? "")
            return DroidAuth(
                cookieHeader: normalizedCookie,
                bearerToken: token,
                refreshToken: nil,
                organizationId: claims["org_id"] as? String,
                userId: claims["sub"] as? String,
                source: SourceInfo(mode: "manual", type: "browser-cookie")
            )

        case .token:
            let token = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ProviderError("missing_token", "Droid bearer token is empty.")
            }
            let claims = parseJWTClaims(token)
            return DroidAuth(
                cookieHeader: nil,
                bearerToken: token,
                refreshToken: nil,
                organizationId: claims["org_id"] as? String,
                userId: claims["sub"] as? String,
                source: SourceInfo(mode: "manual", type: "bearer-token")
            )

        case .authFile:
            let path = NSString(string: credential.credential).expandingTildeInPath
            guard let session = loadSessionFile(at: path) else {
                throw ProviderError("not_logged_in", "Could not read the Droid auth file.")
            }
            return try await resolveStoredSession(
                session,
                source: SourceInfo(mode: "manual", type: "auth-file"),
                persistencePath: path
            )

        case .auto:
            return try await resolveAuth()

        default:
            throw ProviderError("unsupported_auth_method", "Droid does not support \(credential.authMethod.rawValue) credentials.")
        }
    }

    private struct SessionFile {
        let accessToken: String?
        let refreshToken: String?
        let organizationId: String?
        let cookieHeader: String?
    }

    private func loadSessionFile() -> SessionFile? {
        loadSessionFile(at: nil)
    }

    private func loadSessionFile(at pathOverride: String?) -> SessionFile? {
        let paths = pathOverride.map { [$0] } ?? [
            "\(homeDirectory)/.factory/auth.v2.file",
            "\(homeDirectory)/.factory/auth.v2.keyring",
            "\(homeDirectory)/.factory/auth.encrypted",
            "\(homeDirectory)/.config/factory/auth.json",
            "\(homeDirectory)/.factory/auth.json",
            "\(homeDirectory)/.config/droid/auth.json"
        ]

        for path in paths {
            guard let session = loadSingleSessionFile(at: path) else { continue }
            return session
        }
        return nil
    }

    // MARK: - Token Exchange

    private struct RefreshedAuth {
        let accessToken: String
        let refreshToken: String?
        let organizationId: String?
    }

    private func exchangeRefreshToken(_ refreshToken: String, orgId: String?) async throws -> RefreshedAuth {
        guard let url = URL(string: Self.workOSRefreshURL) else {
            throw ProviderError("invalid_url", "Droid token refresh URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.workOSClientID)
        ]
        if let orgId = orgId?.nilIfBlank {
            queryItems.append(URLQueryItem(name: "organization_id", value: orgId))
        }

        var components = URLComponents()
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)?.nilIfBlank ?? "Failed to refresh Droid token."
            throw ProviderError("refresh_failed", message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = firstNonEmpty(
                json["accessToken"] as? String,
                json["access_token"] as? String
              ) else {
            throw ProviderError("refresh_failed", "Failed to refresh Droid token.")
        }

        return RefreshedAuth(
            accessToken: accessToken,
            refreshToken: firstNonEmpty(
                json["refreshToken"] as? String,
                json["refresh_token"] as? String,
                refreshToken
            ),
            organizationId: firstNonEmpty(
                json["organizationId"] as? String,
                json["organization_id"] as? String,
                orgId
            )
        )
    }

    // MARK: - API Requests

    private func fetchSnapshot(
        auth: DroidAuth,
        persistencePath: String?
    ) async throws -> ([String: Any], [String: Any], DroidAuth) {
        var lastError: Error = ProviderError("not_logged_in", "Could not connect to the Droid API.")

        for candidateAuth in authVariants(for: auth) {
            for baseURL in Self.baseURLs {
                do {
                    let authInfo = try await requestAuthInfo(baseURL: baseURL, auth: candidateAuth)
                    let usageInfo = try await requestUsageInfo(baseURL: baseURL, auth: candidateAuth)
                    return (authInfo, usageInfo, candidateAuth)
                } catch {
                    lastError = error
                }
            }
        }

        if let providerError = lastError as? ProviderError,
           providerError.code == "invalid_credentials",
           let refreshedAuth = try? await refreshAuth(auth, persistencePath: persistencePath) {
            for candidateAuth in authVariants(for: refreshedAuth) {
                for baseURL in Self.baseURLs {
                    do {
                        let authInfo = try await requestAuthInfo(baseURL: baseURL, auth: candidateAuth)
                        let usageInfo = try await requestUsageInfo(baseURL: baseURL, auth: candidateAuth)
                        return (authInfo, usageInfo, candidateAuth)
                    } catch {
                        lastError = error
                    }
                }
            }
        }

        throw lastError
    }

    private func authVariants(for auth: DroidAuth) -> [DroidAuth] {
        guard let cookieHeader = auth.cookieHeader.nilIfBlank else { return [auth] }

        var variants: [DroidAuth] = [auth]
        if auth.bearerToken != nil {
            variants.append(rebuildAuth(auth, withCookieHeader: cookieHeader, includeAuthorization: false))
        }

        let withoutStale = Self.filteredCookieHeader(cookieHeader, removing: Self.staleTokenCookieNames)
        if withoutStale != cookieHeader, !withoutStale.isEmpty {
            variants.append(rebuildAuth(auth, withCookieHeader: withoutStale, includeAuthorization: true))
            variants.append(rebuildAuth(auth, withCookieHeader: withoutStale, includeAuthorization: false))
        }

        let authOnly = Self.filteredCookieHeader(
            cookieHeader,
            keeping: Self.authSessionCookieNames.union(["session", "wos-session"])
        )
        if !authOnly.isEmpty,
           authOnly != cookieHeader,
           !variants.contains(where: { $0.cookieHeader == authOnly && $0.bearerToken == nil }) {
            variants.append(rebuildAuth(auth, withCookieHeader: authOnly, includeAuthorization: true))
            variants.append(rebuildAuth(auth, withCookieHeader: authOnly, includeAuthorization: false))
        }

        var seen = Set<String>()
        return variants.filter { variant in
            let key = "\(variant.cookieHeader ?? "")|auth:\(variant.bearerToken ?? "")"
            return seen.insert(key).inserted
        }
    }

    private func rebuildAuth(_ auth: DroidAuth, withCookieHeader cookieHeader: String, includeAuthorization: Bool) -> DroidAuth {
        let normalizedCookie = Self.normalizeCookieHeader(cookieHeader)
        let token = includeAuthorization ? Self.bearerToken(fromCookieHeader: normalizedCookie) : nil
        let claims = parseJWTClaims(token ?? "")
        return DroidAuth(
            cookieHeader: normalizedCookie,
            bearerToken: token,
            refreshToken: auth.refreshToken,
            organizationId: auth.organizationId ?? claims["org_id"] as? String,
            userId: auth.userId ?? claims["sub"] as? String,
            source: auth.source
        )
    }

    private func requestAuthInfo(baseURL: String, auth: DroidAuth) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)/api/app/auth/me") else {
            throw ProviderError("invalid_url", "Droid auth URL is invalid.")
        }
        return try await requestDroidJSON(url: url, method: "GET", body: nil, auth: auth)
    }

    private func requestUsageInfo(baseURL: String, auth: DroidAuth) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)/api/organization/subscription/usage") else {
            throw ProviderError("invalid_url", "Droid usage URL is invalid.")
        }
        var body: [String: Any] = ["useCache": true]
        if let userId = auth.userId { body["userId"] = userId }
        return try await requestDroidJSON(url: url, method: "POST", body: body, auth: auth)
    }

    private func requestDroidJSON(
        url: URL,
        method: String,
        body: [String: Any]?,
        auth: DroidAuth
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader = auth.cookieHeader.nilIfBlank {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let token = auth.bearerToken.nilIfBlank {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError("invalid_credentials", "Droid login state is invalid or expired.")
            }
            if !(200...299).contains(http.statusCode) {
                let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
                throw ProviderError("api_error", "Droid API returned HTTP \(http.statusCode): \(body)")
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Droid API returned invalid JSON.")
        }
        return json
    }

    // MARK: - Response Parsing

    private func parseResponse(authInfo: [String: Any], usageInfo: [String: Any], auth: DroidAuth) -> ProviderUsage {
        let claims = parseJWTClaims(auth.bearerToken ?? "")
        let usageData = usageInfo["usage"] as? [String: Any] ?? [:]
        let userInfo = authInfo["user"] as? [String: Any]

        let periodStart = parseFactoryDate(usageData["startDate"])
        let periodEnd = parseFactoryDate(usageData["endDate"])
        let resetDesc = periodEnd.map { formatResetDescription($0) } ?? "Reset date unknown"

        let standard = normalizeTokenUsage(usageData["standard"] as? [String: Any])
        let premium = normalizeTokenUsage(usageData["premium"] as? [String: Any])

        var usage = ProviderUsage(provider: "droid", label: "Droid")
        usage.accountEmail = (claims["email"] as? String)
            ?? (userInfo?["email"] as? String)
        usage.usageAccountId = (claims["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (userInfo?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        usage.source = auth.source

        usage.primary = createUsageWindow(standard, periodEnd: periodEnd, resetDesc: resetDesc)
        usage.secondary = createUsageWindow(premium, periodEnd: periodEnd, resetDesc: resetDesc)

        let org = authInfo["organization"] as? [String: Any]
        let subscription = org?["subscription"] as? [String: Any]
        let orbSub = subscription?["orbSubscription"] as? [String: Any]
        let planName = subscription?["planName"] as? String
            ?? orbSub?["planName"] as? String
            ?? orbSub?["name"] as? String
            ?? orbSub?["plan"] as? String
            ?? ""

        usage.extra["planName"] = AnyCodable(planName)
        usage.extra["organizationName"] = AnyCodable(org?["name"] as? String ?? "")
        usage.extra["periodStart"] = AnyCodable(periodStart.map { SharedFormatters.iso8601String(from: $0) } ?? "")
        usage.extra["periodEnd"] = AnyCodable(periodEnd.map { SharedFormatters.iso8601String(from: $0) } ?? "")

        usage.extra["standard.userTokens"] = AnyCodable(standard.userTokens)
        usage.extra["standard.totalAllowance"] = AnyCodable(standard.totalAllowance)
        usage.extra["standard.unlimited"] = AnyCodable(standard.unlimited)
        usage.extra["premium.userTokens"] = AnyCodable(premium.userTokens)
        usage.extra["premium.totalAllowance"] = AnyCodable(premium.totalAllowance)
        usage.extra["premium.unlimited"] = AnyCodable(premium.unlimited)

        return usage
    }

    private struct TokenUsage {
        let userTokens: Int
        let totalAllowance: Int
        let usedPercent: Double
        let remainingPercent: Double
        let unlimited: Bool
    }

    private func normalizeTokenUsage(_ value: [String: Any]?) -> TokenUsage {
        guard let value else {
            return TokenUsage(
                userTokens: 0,
                totalAllowance: 0,
                usedPercent: 0,
                remainingPercent: 100,
                unlimited: false
            )
        }

        let userTokens = intValue(value["userTokens"]) ?? 0
        let totalAllowance = intValue(value["totalAllowance"]) ?? 0
        let usedRatio = doubleValue(value["usedRatio"])
        let unlimited = totalAllowance > Self.unlimitedThreshold

        let usedPercent: Double
        if let usedRatio {
            if usedRatio >= -0.001 && usedRatio <= 1.001 {
                usedPercent = min(100, max(0, usedRatio * 100))
            } else if usedRatio >= -0.1 && usedRatio <= 100.1 {
                usedPercent = min(100, max(0, usedRatio))
            } else if totalAllowance > 0 {
                usedPercent = min(100, Double(userTokens) / Double(totalAllowance) * 100)
            } else {
                usedPercent = 0
            }
        } else if totalAllowance > 0 {
            usedPercent = min(100, Double(userTokens) / Double(totalAllowance) * 100)
        } else {
            usedPercent = 0
        }

        return TokenUsage(
            userTokens: userTokens,
            totalAllowance: totalAllowance,
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            unlimited: unlimited
        )
    }

    private func createUsageWindow(_ usage: TokenUsage, periodEnd: Date?, resetDesc: String) -> RawQuotaWindow {
        var window = RawQuotaWindow()
        window.usedPercent = usage.usedPercent
        window.remainingPercent = usage.remainingPercent
        window.resetAt = periodEnd.map { SharedFormatters.iso8601String(from: $0) }
        window.resetDescription = resetDesc
        window.unlimited = usage.unlimited
        return window
    }

    private func formatResetDescription(_ date: Date) -> String {
        let day = DateFormat.string(from: date, format: "MMM d")
        let time = DateFormat.string(from: date, format: "h:mma")
        return "Resets \(day) at \(time)"
    }

    // MARK: - Helpers

    private static func extractDroidCookieHeader(dbPath: String, keychainService: String) -> String? {
        let tempPath = NSTemporaryDirectory() + "droid_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 10000...99999)).db"
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
            try? FileManager.default.removeItem(atPath: tempPath + "-wal")
            try? FileManager.default.removeItem(atPath: tempPath + "-shm")
        }
        do { try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath) } catch { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: dbPath + "-wal") {
            try? fm.copyItem(atPath: dbPath + "-wal", toPath: tempPath + "-wal")
        }
        if fm.fileExists(atPath: dbPath + "-shm") {
            try? fm.copyItem(atPath: dbPath + "-shm", toPath: tempPath + "-shm")
        }

        let query = """
        SELECT name, expires_utc, hex(encrypted_value), value
        FROM cookies
        WHERE name IN (\(Self.sessionCookieNames.map { "'\($0)'" }.joined(separator: ",")))
          AND (host_key = 'factory.ai' OR host_key = '.factory.ai' OR host_key LIKE '%.factory.ai')
        ORDER BY expires_utc DESC
        LIMIT 40;
        """

        guard let rows = querySQLite(db: tempPath, sql: query) else { return nil }
        guard !rows.isEmpty else { return nil }

        let aesKey = chromiumAESKey(keychainService: keychainService)
        var cookiesByName: [String: String] = [:]

        for row in rows {
            guard row.count >= 4 else { continue }
            let name = row[0]
            guard Self.sessionCookieNames.contains(name), cookiesByName[name] == nil else { continue }

            let hexBlob = row[2]
            let plainValue = row[3]

            if let plain = plainValue.nilIfBlank, isCookieSafeASCII(plain) {
                cookiesByName[name] = plain
                continue
            }

            if let aesKey, let decrypted = CursorProvider.decryptChromiumCookie(blob: hexBlob, key: aesKey) {
                cookiesByName[name] = decrypted
            }
        }

        guard !cookiesByName.isEmpty else { return nil }

        let orderedPairs = cookiesByName
            .sorted { lhs, rhs in
                let leftPriority = cookieNamePriority(lhs.key)
                let rightPriority = cookieNamePriority(rhs.key)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { "\($0.key)=\($0.value)" }

        return orderedPairs.joined(separator: "; ")
    }

    private static func cookieNamePriority(_ name: String) -> Int {
        switch name {
        case "access-token": return 0
        case "wos-session": return 1
        case "__Secure-next-auth.session-token": return 2
        case "next-auth.session-token": return 3
        case "__Secure-authjs.session-token": return 4
        case "authjs.session-token": return 5
        case "__Host-authjs.csrf-token": return 6
        case "session": return 7
        default: return 100
        }
    }

    private static func querySQLite(db: String, sql: String) -> [[String]]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-separator", "\t", db, sql]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }

    private static func chromiumAESKey(keychainService: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }

        let password = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !password.isEmpty, let passwordData = password.data(using: .utf8) else { return nil }

        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: 16)
        let status = derivedKey.withUnsafeMutableBytes { derivedPtr in
            passwordData.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress, passwordData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedPtr.baseAddress, 16
                    )
                }
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }

    private static func normalizeCookieHeader(_ rawHeader: String) -> String {
        let pairs = cookiePairs(from: rawHeader)
        guard !pairs.isEmpty else { return "" }

        var byName: [String: String] = [:]
        for pair in pairs where byName[pair.name] == nil {
            byName[pair.name] = pair.value
        }

        return byName
            .sorted { lhs, rhs in
                let leftPriority = cookieNamePriority(lhs.key)
                let rightPriority = cookieNamePriority(rhs.key)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func filteredCookieHeader(_ rawHeader: String, removing names: Set<String>) -> String {
        cookiePairs(from: rawHeader)
            .filter { !names.contains($0.name) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func filteredCookieHeader(_ rawHeader: String, keeping names: Set<String>) -> String {
        cookiePairs(from: rawHeader)
            .filter { names.contains($0.name) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func cookiePairs(from header: String) -> [(name: String, value: String)] {
        header
            .split(separator: ";")
            .compactMap { segment in
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.firstIndex(of: "=") else { return nil }
                let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { return nil }
                return (name, value)
            }
    }

    private static func bearerToken(fromCookieHeader cookieHeader: String?) -> String? {
        guard let cookieHeader else { return nil }
        let pairs = cookiePairs(from: cookieHeader)

        for preferredName in ["access-token", "__Secure-next-auth.session-token", "next-auth.session-token", "__Secure-authjs.session-token", "authjs.session-token", "session"] {
            guard let pair = pairs.first(where: { $0.name == preferredName }) else {
                continue
            }
            let token = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                continue
            }
            if token.contains(".") || preferredName == "access-token" {
                return token
            }
        }

        return nil
    }

    private static func jwtEmail(from token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    private func parseFactoryDate(_ value: Any?) -> Date? {
        switch value {
        case let number as Int:
            return number > 0 ? Date(timeIntervalSince1970: Double(number) / 1000) : nil
        case let number as Double:
            return number > 0 ? Date(timeIntervalSince1970: number / 1000) : nil
        case let string as String:
            return Double(string).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        default:
            return nil
        }
    }

    private func parseJWTClaims(_ token: String) -> [String: Any] {
        guard token.contains(".") else { return [:] }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0.nilIfBlank }.first
    }

    private func loadSingleSessionFile(at path: String) -> SessionFile? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return sessionFile(from: json)
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        if filename == "auth.v2.file" {
            let keyPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("auth.v2.key").path
            guard let keyData = loadFactoryKeyFile(at: keyPath),
                  let plaintext = decryptFactoryCredentials(payload: data, key: keyData),
                  let jsonData = plaintext.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            return sessionFile(from: json)
        }

        if filename == "auth.v2.keyring" {
            guard let keyData = loadFactoryKeyringKey(),
                  let plaintext = decryptFactoryCredentials(payload: data, key: keyData),
                  let jsonData = plaintext.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            return sessionFile(from: json)
        }

        if filename == "auth.encrypted" {
            guard let keyData = loadFactoryKeyringKey(),
                  let plaintext = decryptFactoryCredentials(payload: data, key: keyData),
                  let jsonData = plaintext.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            return sessionFile(from: json)
        }

        return nil
    }

    private func sessionFile(from json: [String: Any]) -> SessionFile {
        SessionFile(
            accessToken: firstNonEmpty(
                json["accessToken"] as? String,
                json["access_token"] as? String,
                json["token"] as? String
            ),
            refreshToken: firstNonEmpty(
                json["refreshToken"] as? String,
                json["refresh_token"] as? String
            ),
            organizationId: firstNonEmpty(
                json["organizationId"] as? String,
                json["organization_id"] as? String,
                json["orgId"] as? String
            ),
            cookieHeader: firstNonEmpty(
                json["cookieHeader"] as? String,
                json["cookie_header"] as? String,
                json["cookie"] as? String
            )
        )
    }

    private func resolveStoredSession(
        _ session: SessionFile,
        source: SourceInfo,
        persistencePath: String?
    ) async throws -> DroidAuth {
        let normalizedCookie = session.cookieHeader.nilIfBlank.map(Self.normalizeCookieHeader)
        let cookieToken = Self.bearerToken(fromCookieHeader: normalizedCookie)
        let preferredToken = session.accessToken.nilIfBlank ?? cookieToken
        let refreshToken = session.refreshToken.nilIfBlank

        if let preferredToken,
           !shouldRefreshAccessToken(preferredToken, refreshToken: refreshToken) {
            return makeAuth(
                cookieHeader: normalizedCookie,
                accessToken: preferredToken,
                refreshToken: refreshToken,
                organizationId: session.organizationId,
                source: source
            )
        }

        if let refreshToken {
            return try await refreshStoredSession(
                refreshToken: refreshToken,
                currentSession: session,
                source: source,
                persistencePath: persistencePath
            )
        }

        if let normalizedCookie {
            return makeAuth(
                cookieHeader: normalizedCookie,
                accessToken: preferredToken,
                refreshToken: nil,
                organizationId: session.organizationId,
                source: source
            )
        }

        throw ProviderError("missing_tokens", "Droid auth file does not contain a usable cookie or token.")
    }

    private func refreshAuth(_ auth: DroidAuth, persistencePath: String?) async throws -> DroidAuth {
        guard let refreshToken = auth.refreshToken.nilIfBlank else {
            throw ProviderError("refresh_failed", "Droid refresh token is missing.")
        }

        return try await refreshStoredSession(
            refreshToken: refreshToken,
            currentSession: SessionFile(
                accessToken: auth.bearerToken,
                refreshToken: auth.refreshToken,
                organizationId: auth.organizationId,
                cookieHeader: auth.cookieHeader
            ),
            source: auth.source,
            persistencePath: persistencePath
        )
    }

    private func refreshStoredSession(
        refreshToken: String,
        currentSession: SessionFile,
        source: SourceInfo,
        persistencePath: String?
    ) async throws -> DroidAuth {
        let refreshed = try await exchangeRefreshToken(refreshToken, orgId: currentSession.organizationId)
        let updatedSession = SessionFile(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            organizationId: refreshed.organizationId ?? currentSession.organizationId,
            cookieHeader: nil
        )
        if let persistencePath {
            persistSessionFile(updatedSession, to: persistencePath)
        }
        return makeAuth(
            cookieHeader: nil,
            accessToken: updatedSession.accessToken,
            refreshToken: updatedSession.refreshToken,
            organizationId: updatedSession.organizationId,
            source: source
        )
    }

    private func makeAuth(
        cookieHeader: String?,
        accessToken: String?,
        refreshToken: String?,
        organizationId: String?,
        source: SourceInfo
    ) -> DroidAuth {
        let normalizedCookie = cookieHeader.nilIfBlank.map(Self.normalizeCookieHeader)
        let token = accessToken.nilIfBlank ?? Self.bearerToken(fromCookieHeader: normalizedCookie)
        let claims = parseJWTClaims(token ?? "")
        return DroidAuth(
            cookieHeader: normalizedCookie,
            bearerToken: token,
            refreshToken: refreshToken.nilIfBlank,
            organizationId: organizationId ?? claims["org_id"] as? String,
            userId: claims["sub"] as? String,
            source: source
        )
    }

    private func shouldRefreshAccessToken(_ token: String, refreshToken: String?) -> Bool {
        guard refreshToken.nilIfBlank != nil else { return false }
        let claims = parseJWTClaims(token)
        guard let exp = claims["exp"] as? Double ?? (claims["exp"] as? Int).map(Double.init) else {
            return true
        }
        return Date().timeIntervalSince1970 >= exp - 60
    }

    private func persistSessionFile(_ session: SessionFile, to path: String) {
        var json: [String: Any] = [:]
        if let accessToken = session.accessToken { json["access_token"] = accessToken }
        if let refreshToken = session.refreshToken { json["refresh_token"] = refreshToken }
        if let organizationId = session.organizationId { json["organization_id"] = organizationId }
        if let cookieHeader = session.cookieHeader { json["cookie_header"] = cookieHeader }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadFactoryKeyFile(at path: String) -> Data? {
        guard let rawKey = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank else {
            return nil
        }
        return Data(base64Encoded: rawKey)
    }

    private func loadFactoryKeyringKey() -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = [
            "find-generic-password",
            "-s", Self.keyringServiceName,
            "-a", Self.keyringAccountName,
            "-w"
        ]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let rawKey = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawKey = rawKey.nilIfBlank else { return nil }
        return Data(base64Encoded: rawKey)
    }

    private func decryptFactoryCredentials(payload: Data, key: Data) -> String? {
        guard let text = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return nil
        }
        let components = text.split(separator: ":").map(String.init)
        guard components.count == 3,
              let nonceData = Data(base64Encoded: components[0]),
              let tagData = Data(base64Encoded: components[1]),
              let ciphertext = Data(base64Encoded: components[2]) else {
            return nil
        }

        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else { return nil }
        let key = SymmetricKey(data: key)
        guard let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData),
              let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
            return nil
        }
        return String(data: plaintext, encoding: .utf8)
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as Double:
            return Int(number)
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func isCookieSafeASCII(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        for scalar in string.unicodeScalars {
            let value = scalar.value
            let allowed = value == 0x21
                || (value >= 0x23 && value <= 0x2b)
                || (value >= 0x2d && value <= 0x3a)
                || (value >= 0x3c && value <= 0x5b)
                || (value >= 0x5d && value <= 0x7e)
            if !allowed { return false }
        }
        return true
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
