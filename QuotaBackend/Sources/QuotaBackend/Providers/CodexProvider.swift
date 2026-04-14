import Foundation

// MARK: - Codex Provider
// Reads ~/.codex/auth.json and ~/.cli-proxy-api/codex-*.json, refreshes OAuth
// when needed, and fetches ChatGPT Codex quota windows for one or many accounts.

public struct CodexProvider: MultiAccountProviderFetcher, CredentialAcceptingProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public let description = "OpenAI Codex CLI quota windows"

    let homeDirectory: String
    let timeoutSeconds: Double
    static let refreshURL = "https://auth.openai.com/oauth/token"
    static let oauthClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let defaultBaseURL = "https://chatgpt.com/backend-api/"

    public var supportedAuthMethods: [AuthMethod] { [.token, .authFile, .auto] }

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeoutSeconds: Double = 20
    ) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let authContext = try resolvePrimaryAuthContext()
        return try await fetchForAuthContext(authContext)
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        let creds: Credentials
        let source: SourceInfo
        let credentialPath: String?

        switch credential.authMethod {
        case .authFile:
            let path = NSString(string: credential.credential).expandingTildeInPath
            creds = try loadCredentials(from: path)
            source = sourceInfo(for: URL(fileURLWithPath: path), mode: "manual")
            credentialPath = path
        case .token, .apiKey:
            let token = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ProviderError("missing_token", "Codex token is empty.")
            }
            let label = normalizedLabel(credential.accountLabel)
            creds = Credentials(
                authFile: "manual-token",
                accessToken: token,
                refreshToken: nil,
                idToken: nil,
                accountId: label,
                accountEmail: label,
                needsRefresh: false,
                isApiKeyMode: true
            )
            source = SourceInfo(mode: "manual", type: "api-token")
            credentialPath = nil
        default:
            throw ProviderError("unsupported_auth_method", "Codex does not support \(credential.authMethod.rawValue) credentials.")
        }

        var effectiveCreds = creds
        if !creds.isApiKeyMode, creds.needsRefresh, let refreshToken = creds.refreshToken {
            effectiveCreds = try await refreshCredentials(creds, refreshToken: refreshToken)
            if let path = credentialPath { persistRefreshedCredentials(effectiveCreds, to: path) }
        }

        let usageURL = try resolveUsageURL()

        do {
            let response = try await requestUsage(creds: effectiveCreds, url: usageURL)
            return parseResponse(
                response,
                accountId: effectiveCreds.accountId ?? normalizedLabel(credential.accountLabel),
                source: source,
                fallbackEmail: effectiveCreds.accountEmail ?? normalizedLabel(credential.accountLabel)
            )
        } catch let error as ProviderError where error.code == "unauthorized" {
            guard !effectiveCreds.isApiKeyMode,
                  let refreshToken = effectiveCreds.refreshToken ?? creds.refreshToken else { throw error }
            let refreshed = try await refreshCredentials(effectiveCreds, refreshToken: refreshToken)
            if let path = credentialPath { persistRefreshedCredentials(refreshed, to: path) }
            let response = try await requestUsage(creds: refreshed, url: usageURL)
            return parseResponse(
                response,
                accountId: refreshed.accountId ?? normalizedLabel(credential.accountLabel),
                source: source,
                fallbackEmail: refreshed.accountEmail ?? normalizedLabel(credential.accountLabel)
            )
        }
    }

    public func fetchAllAccounts() async -> [AccountFetchResult] {
        let contexts: [AuthContext]
        do {
            contexts = try resolveAllAuthContexts()
        } catch {
            return [AccountFetchResult(accountId: "default", accountLabel: nil, result: .failure(error))]
        }

        guard !contexts.isEmpty else {
            return [AccountFetchResult(
                accountId: "default",
                accountLabel: nil,
                result: .failure(ProviderError("not_logged_in", "No Codex auth files found. Run `codex login` and sign in with ChatGPT first."))
            )]
        }

        return await withTaskGroup(of: AccountFetchResult.self) { group in
            for context in contexts {
                group.addTask {
                    let accountId = context.creds.accountId
                        ?? context.creds.accountEmail
                        ?? context.url.lastPathComponent
                    do {
                        let usage = try await fetchForAuthContext(context)
                        return AccountFetchResult(
                            accountId: accountId,
                            accountLabel: context.creds.accountEmail,
                            result: .success(usage)
                        )
                    } catch {
                        return AccountFetchResult(
                            accountId: accountId,
                            accountLabel: context.creds.accountEmail,
                            result: .failure(error)
                        )
                    }
                }
            }

            var results: [AccountFetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    // MARK: - Credentials

    private struct Credentials {
        let authFile: String
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let accountId: String?
        let accountEmail: String?
        let needsRefresh: Bool
        let isApiKeyMode: Bool
    }

    private struct AuthContext {
        let url: URL
        let creds: Credentials
    }

    private func resolvePrimaryAuthContext() throws -> AuthContext {
        let contexts = try resolveAllAuthContexts()
        if let first = contexts.first {
            return first
        }

        let fallbackURL = URL(fileURLWithPath: "\(homeDirectory)/.codex/auth.json")
        return AuthContext(url: fallbackURL, creds: try loadCredentials(from: fallbackURL.path))
    }

    private func resolveAllAuthContexts() throws -> [AuthContext] {
        let env = ProcessInfo.processInfo.environment

        if let explicitFile = env["CODEX_AUTH_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitFile.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: explicitFile).expandingTildeInPath)
            return [AuthContext(url: url, creds: try loadCredentials(from: url.path))]
        }

        var candidates: [URL] = []

        let defaultAuthFile = URL(fileURLWithPath: "\(homeDirectory)/.codex/auth.json")
        if FileManager.default.fileExists(atPath: defaultAuthFile.path) {
            candidates.append(defaultAuthFile)
        }

        let authDirectory = env["CODEX_AUTH_DIR"].map { NSString(string: $0).expandingTildeInPath }
            ?? "\(homeDirectory)/.cli-proxy-api"
        let directoryURL = URL(fileURLWithPath: authDirectory, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        candidates.append(contentsOf: files.filter {
            $0.lastPathComponent.hasPrefix("codex-") && $0.pathExtension == "json"
        })

        var seen = Set<String>()
        return candidates
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
            .compactMap { url in
                let standardized = url.standardizedFileURL.path
                guard seen.insert(standardized).inserted else { return nil }
                guard let creds = try? loadCredentials(from: standardized) else { return nil }
                return AuthContext(url: URL(fileURLWithPath: standardized), creds: creds)
            }
    }

    private func loadCredentials(from path: String) throws -> Credentials {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProviderError("not_logged_in", "\(path) not found. Run `codex login` and sign in with ChatGPT first.")
        }
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("invalid_auth_file", "\(path) could not be parsed.")
        }

        if let apiKey = stringValue(json["OPENAI_API_KEY"]) {
            return Credentials(
                authFile: path,
                accessToken: apiKey,
                refreshToken: nil,
                idToken: nil,
                accountId: nil,
                accountEmail: stringValue(json["email"]),
                needsRefresh: false,
                isApiKeyMode: true
            )
        }

        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let accessToken = stringValue(tokens["access_token"])
            ?? stringValue(tokens["accessToken"])
            ?? stringValue(json["access_token"])
            ?? stringValue(json["accessToken"])

        guard let accessToken else {
            throw ProviderError("missing_tokens", "\(path) exists but has no access token.")
        }

        let refreshToken = stringValue(tokens["refresh_token"])
            ?? stringValue(tokens["refreshToken"])
            ?? stringValue(json["refresh_token"])
            ?? stringValue(json["refreshToken"])
        let idToken = stringValue(tokens["id_token"])
            ?? stringValue(tokens["idToken"])
            ?? stringValue(json["id_token"])
            ?? stringValue(json["idToken"])
        let accountId = stringValue(tokens["account_id"])
            ?? stringValue(tokens["accountId"])
            ?? stringValue(json["account_id"])
            ?? stringValue(json["accountId"])
            ?? decodeAccountId(fromJWT: idToken)
        let accountEmail = stringValue(json["email"])
            ?? decodeEmail(fromJWT: idToken)
            ?? decodeEmail(fromJWT: accessToken)

        let lastRefresh = stringValue(json["last_refresh"]).flatMap(parseDate)
        let expiryDate = stringValue(json["expired"]).flatMap(parseDate)
        var needsRefresh: Bool
        if let expiryDate {
            needsRefresh = expiryDate.timeIntervalSinceNow <= 300
        } else if let lastRefresh {
            needsRefresh = Date().timeIntervalSince(lastRefresh) > 8 * 86400
        } else {
            needsRefresh = true
        }

        if !needsRefresh, let payload = decodeJWTPayload(token: accessToken),
           let exp = payload["exp"] as? Double, Date(timeIntervalSince1970: exp).timeIntervalSinceNow <= 60 {
            needsRefresh = true
        }

        return Credentials(
            authFile: path,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            accountEmail: accountEmail,
            needsRefresh: needsRefresh,
            isApiKeyMode: false
        )
    }

    private func refreshCredentials(_ creds: Credentials, refreshToken: String) async throws -> Credentials {
        guard let url = URL(string: Self.refreshURL) else {
            throw ProviderError("invalid_url", "Codex OAuth refresh URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.oauthClientId,
            "refresh_token": refreshToken
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = stringValue(json["access_token"]) else {
            return creds
        }

        let newRefresh = stringValue(json["refresh_token"]) ?? refreshToken
        return Credentials(
            authFile: creds.authFile,
            accessToken: newAccess,
            refreshToken: newRefresh,
            idToken: stringValue(json["id_token"]) ?? creds.idToken,
            accountId: creds.accountId,
            accountEmail: creds.accountEmail,
            needsRefresh: false,
            isApiKeyMode: false
        )
    }

    private func persistRefreshedCredentials(_ creds: Credentials, to path: String) {
        guard !creds.isApiKeyMode else { return }
        guard var json = (FileManager.default.contents(atPath: path).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) else { return }

        if var tokens = json["tokens"] as? [String: Any] {
            tokens["access_token"] = creds.accessToken
            if let rt = creds.refreshToken { tokens["refresh_token"] = rt }
            if let it = creds.idToken { tokens["id_token"] = it }
            json["tokens"] = tokens
        } else {
            json["access_token"] = creds.accessToken
            if let rt = creds.refreshToken { json["refresh_token"] = rt }
            if let it = creds.idToken { json["id_token"] = it }
        }
        json["last_refresh"] = SharedFormatters.iso8601String(from: Date())

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func resolveUsageURL() throws -> URL {
        let configPath = "\(homeDirectory)/.codex/config.toml"
        var baseURL = Self.defaultBaseURL
        if let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for key in ["apiBaseUrl", "api_base_url", "base_url"] where trimmed.lowercased().hasPrefix(key.lowercased()) && trimmed.contains("=") {
                    let value = trimmed
                        .components(separatedBy: "=")
                        .dropFirst()
                        .joined(separator: "=")
                        .trimmingCharacters(in: .init(charactersIn: " \t\"'"))
                    if value.hasPrefix("http") {
                        baseURL = value
                        break
                    }
                }
            }
        }
        let path = baseURL.contains("/backend-api") ? "wham/usage" : "api/codex/usage"
        let normalized = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        guard let url = URL(string: "\(normalized)\(path)") else {
            throw ProviderError("invalid_url", "Codex usage URL is invalid.")
        }
        return url
    }

    private func requestUsage(creds: Credentials, url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError("unauthorized", "Codex OAuth token is invalid or expired.")
            }
            if !((200..<300).contains(http.statusCode)) {
                throw ProviderError("api_error", "Codex usage API returned HTTP \(http.statusCode).")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Codex usage API returned invalid JSON.")
        }
        return json
    }

    private func fetchForAuthContext(_ authContext: AuthContext) async throws -> ProviderUsage {
        var creds = authContext.creds

        if !creds.isApiKeyMode, creds.needsRefresh, let refreshToken = creds.refreshToken {
            creds = try await refreshCredentials(creds, refreshToken: refreshToken)
            persistRefreshedCredentials(creds, to: authContext.url.path)
        }

        let usageURL = try resolveUsageURL()

        do {
            let response = try await requestUsage(creds: creds, url: usageURL)
            return parseResponse(
                response,
                accountId: creds.accountId,
                source: sourceInfo(for: authContext.url, mode: "oauth"),
                fallbackEmail: creds.accountEmail
            )
        } catch let error as ProviderError where error.code == "unauthorized" {
            guard !creds.isApiKeyMode,
                  let refreshToken = creds.refreshToken ?? authContext.creds.refreshToken else { throw error }
            let refreshed = try await refreshCredentials(creds, refreshToken: refreshToken)
            persistRefreshedCredentials(refreshed, to: authContext.url.path)
            let response = try await requestUsage(creds: refreshed, url: usageURL)
            return parseResponse(
                response,
                accountId: refreshed.accountId,
                source: sourceInfo(for: authContext.url, mode: "oauth"),
                fallbackEmail: refreshed.accountEmail
            )
        }
    }

    private func parseResponse(
        _ json: [String: Any],
        accountId: String?,
        source: SourceInfo,
        fallbackEmail: String?
    ) -> ProviderUsage {
        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]
        let codeReviewLimit = json["code_review_rate_limit"] as? [String: Any] ?? [:]

        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.accountEmail = stringValue(json["email"]) ?? fallbackEmail
        usage.usageAccountId = stringValue(json["account_id"]) ?? accountId
        usage.accountPlan = stringValue(json["plan_type"])

        usage.primary = parseWindow(rateLimit["primary_window"] as? [String: Any])
        usage.secondary = parseWindow(rateLimit["secondary_window"] as? [String: Any])
        usage.tertiary = parseWindow(codeReviewLimit["primary_window"] as? [String: Any])
        usage.source = source

        return usage
    }

    private func parseWindow(_ window: [String: Any]?) -> RawQuotaWindow? {
        guard let window,
              let usedPercent = window["used_percent"] as? Double else {
            return nil
        }
        var result = RawQuotaWindow()
        result.usedPercent = usedPercent
        result.remainingPercent = max(0, 100 - usedPercent)

        if let resetAtRaw = window["reset_at"] as? Double, resetAtRaw > 0 {
            let resetDate = Date(timeIntervalSince1970: resetAtRaw)
            result.resetAt = SharedFormatters.iso8601String(from: resetDate)
            result.resetDescription = formatResetDescription(resetDate)
        }
        return result
    }

    private func formatResetDescription(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "Resets soon" }
        let totalMinutes = Int(diff / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }

    private func parseDate(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func sourceInfo(for url: URL, mode: String) -> SourceInfo {
        let defaultAuthPath = "\(homeDirectory)/.codex/auth.json"
        var info = SourceInfo(
            mode: mode,
            type: url.path == defaultAuthPath ? "codex-auth-json" : "cli-proxy-auth-file"
        )
        info.roots = [url.path]
        return info
    }

    private func normalizedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodeJWTPayload(token: String?) -> [String: Any]? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func decodeEmail(fromJWT token: String?) -> String? {
        guard let payload = decodeJWTPayload(token: token) else { return nil }
        if let email = stringValue(payload["email"]) {
            return email
        }
        if let profile = payload["https://api.openai.com/profile"] as? [String: Any] {
            return stringValue(profile["email"])
        }
        return nil
    }

    private func decodeAccountId(fromJWT token: String?) -> String? {
        guard let payload = decodeJWTPayload(token: token) else { return nil }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any] {
            return stringValue(auth["chatgpt_account_id"])
        }
        return nil
    }
}

// ProviderUsage doesn't have accountId by default, add it via extra
extension ProviderUsage {
    var accountId: String? {
        get { extra["accountId"]?.value as? String }
        set { extra["accountId"] = newValue.map { AnyCodable($0) } }
    }
}
