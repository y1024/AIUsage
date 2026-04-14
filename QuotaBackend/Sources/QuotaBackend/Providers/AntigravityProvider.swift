import Foundation

// MARK: - Antigravity Provider
// 读取 ~/.cli-proxy-api/antigravity-*.json，必要时刷新 OAuth token，
// 再调用 Google Cloud Code Assist API 获取可用模型配额。

public struct AntigravityProvider: MultiAccountProviderFetcher, CredentialAcceptingProvider {
    public let id = "antigravity"
    public let displayName = "Antigravity"
    public let description = "Antigravity per-model quota usage"

    let homeDirectory: String
    let timeoutSeconds: Double

    static let quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    static let loadCodeAssistURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    static let oauthRefreshURL = "https://oauth2.googleapis.com/token"
    static let userAgent = "antigravity/1.11.3 Darwin/arm64"

    public var supportedAuthMethods: [AuthMethod] { [.authFile, .oauth, .auto] }

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeoutSeconds: Double = 15) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    /// Default single-account fetch (picks latest auth file for backward compat)
    public func fetchUsage() async throws -> ProviderUsage {
        let authContext = try resolveAuthContext()
        return try await fetchForAuthContext(authContext)
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard credential.authMethod == .authFile || credential.authMethod == .oauth else {
            throw ProviderError("unsupported_auth_method", "Antigravity currently supports auth file imports.")
        }

        let authContext = try resolveCredentialAuthContext(credential)
        var usage = try await fetchForAuthContext(authContext)
        usage.usageAccountId = authContext.authFile.email ?? authContext.url.lastPathComponent
        if usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            usage.accountEmail = credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return usage
    }

    /// Multi-account: fetch ALL auth files in parallel, returning one result per account
    public func fetchAllAccounts() async -> [AccountFetchResult] {
        let allContexts: [AuthContext]
        do {
            allContexts = try resolveAllAuthContexts()
        } catch {
            return [AccountFetchResult(
                accountId: "default",
                accountLabel: nil,
                result: .failure(error)
            )]
        }

        guard !allContexts.isEmpty else {
            return [AccountFetchResult(
                accountId: "default",
                accountLabel: nil,
                result: .failure(ProviderError("not_logged_in", "No Antigravity auth files found."))
            )]
        }

        if allContexts.count == 1 {
            let ctx = allContexts[0]
            do {
                let usage = try await fetchForAuthContext(ctx)
                return [AccountFetchResult(
                    accountId: ctx.authFile.email ?? ctx.url.lastPathComponent,
                    accountLabel: ctx.authFile.email,
                    result: .success(usage)
                )]
            } catch {
                return [AccountFetchResult(
                    accountId: ctx.authFile.email ?? ctx.url.lastPathComponent,
                    accountLabel: ctx.authFile.email,
                    result: .failure(error)
                )]
            }
        }

        return await withTaskGroup(of: AccountFetchResult.self) { group in
            for ctx in allContexts {
                group.addTask {
                    let accountId = ctx.authFile.email ?? ctx.url.lastPathComponent
                    do {
                        let usage = try await fetchForAuthContext(ctx)
                        return AccountFetchResult(accountId: accountId, accountLabel: ctx.authFile.email, result: .success(usage))
                    } catch {
                        return AccountFetchResult(accountId: accountId, accountLabel: ctx.authFile.email, result: .failure(error))
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

    /// Core fetch logic for a single auth context
    private func fetchForAuthContext(_ authContext: AuthContext) async throws -> ProviderUsage {
        let originalData = authContext.rawData
        var authFile = authContext.authFile
        var accessToken = authFile.accessToken

        if authFile.needsRefresh, let refreshToken = authFile.refreshToken, !refreshToken.isEmpty {
            if let refreshed = try? await refreshAccessToken(refreshToken: refreshToken) {
                accessToken = refreshed.accessToken
                authFile.accessToken = refreshed.accessToken
                authFile.expired = iso8601String(refreshed.expiryDate)
                persistRefreshedToken(at: authContext.url, originalData: originalData, refreshed: refreshed)
            }
        }

        let subscription = await loadCodeAssist(accessToken: accessToken)
        let quotaResponse = try await fetchAvailableModels(accessToken: accessToken, projectId: subscription.projectId)
        return buildUsage(
            authContext: authContext,
            authFile: authFile,
            subscription: subscription,
            quotaResponse: quotaResponse
        )
    }

    // MARK: - Auth Files

    private struct AuthContext {
        let url: URL
        let authFile: AntigravityAuthFile
        let rawData: Data
        let fileCount: Int
        let sourceDirectory: String
    }

    private struct AntigravityAuthFile: Codable {
        var accessToken: String
        var email: String?
        var expired: String?
        let expiresIn: Int?
        let refreshToken: String?
        let timestamp: Int?
        let type: String?
        let prefix: String?
        let projectId: String?
        let proxyUrl: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case email
            case expired
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case timestamp
            case type
            case prefix
            case projectId = "project_id"
            case proxyUrl = "proxy_url"
        }

        var expiryDate: Date? {
            if let expired, let parsed = AntigravityProvider.parseISO8601(expired) {
                return parsed
            }
            if let timestamp, let expiresIn {
                return Date(timeIntervalSince1970: Double(timestamp) / 1000 + Double(expiresIn))
            }
            return nil
        }

        var needsRefresh: Bool {
            guard let expiryDate else { return false }
            return expiryDate.timeIntervalSinceNow <= 60
        }
    }

    /// Resolve ALL auth contexts (one per auth file) for multi-account fetching
    private func resolveAllAuthContexts() throws -> [AuthContext] {
        let env = ProcessInfo.processInfo.environment

        if let explicitFile = env["ANTIGRAVITY_AUTH_FILE"], !explicitFile.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: explicitFile).expandingTildeInPath)
            return [try loadAuthContext(url: url, fileCount: 1, sourceDirectory: url.deletingLastPathComponent().path)]
        }

        let authDirectory = env["ANTIGRAVITY_AUTH_DIR"].map { NSString(string: $0).expandingTildeInPath }
            ?? "\(homeDirectory)/.cli-proxy-api"
        let directoryURL = URL(fileURLWithPath: authDirectory, isDirectory: true)

        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw ProviderError(
                "not_logged_in",
                "No Antigravity auth directory found. Expected \(directoryURL.path) or set ANTIGRAVITY_AUTH_FILE."
            )
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let matches = files.filter {
            $0.lastPathComponent.hasPrefix("antigravity-") && $0.pathExtension == "json"
        }

        guard !matches.isEmpty else {
            throw ProviderError(
                "not_logged_in",
                "No Antigravity auth files found under \(directoryURL.path). Expected antigravity-*.json."
            )
        }

        return matches
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
            .compactMap { try? loadAuthContext(url: $0, fileCount: matches.count, sourceDirectory: directoryURL.path) }
    }

    /// Legacy single-file resolution (picks latest modified)
    private func resolveAuthContext() throws -> AuthContext {
        let contexts = try resolveAllAuthContexts()
        guard let first = contexts.first else {
            throw ProviderError("not_logged_in", "No valid Antigravity auth files found.")
        }
        return first
    }

    private func loadAuthContext(url: URL, fileCount: Int, sourceDirectory: String) throws -> AuthContext {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError("not_logged_in", "Antigravity auth file not found at \(url.path).")
        }
        let data = try Data(contentsOf: url)
        var authFile = try JSONDecoder().decode(AntigravityAuthFile.self, from: data)
        if authFile.email?.isEmpty ?? true {
            authFile.email = emailFromFilename(url.lastPathComponent)
        }
        guard !authFile.accessToken.isEmpty else {
            throw ProviderError("missing_tokens", "Antigravity auth file exists but has no access token.")
        }
        return AuthContext(url: url, authFile: authFile, rawData: data, fileCount: fileCount, sourceDirectory: sourceDirectory)
    }

    private func resolveCredentialAuthContext(_ credential: AccountCredential) throws -> AuthContext {
        let path = NSString(string: credential.credential).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return try loadAuthContext(url: url, fileCount: 1, sourceDirectory: url.deletingLastPathComponent().path)
    }

    private func emailFromFilename(_ filename: String) -> String? {
        guard filename.hasPrefix("antigravity-"), filename.hasSuffix(".json") else { return nil }
        let value = filename
            .replacingOccurrences(of: "antigravity-", with: "")
            .replacingOccurrences(of: ".json", with: "")
        if value.contains("@") { return value }
        let restored = value
            .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")
            .replacingOccurrences(of: "_", with: ".")
        return restored.contains("@") ? restored : nil
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - OAuth

    private struct RefreshedToken {
        let accessToken: String
        let expiryDate: Date
        let expiresIn: Int
    }

    private func refreshAccessToken(refreshToken: String) async throws -> RefreshedToken {
        guard let (clientId, clientSecret) = resolveOAuthCredentials() else {
            throw ProviderError(
                "oauth_config_missing",
                "Could not find Antigravity OAuth client credentials. Keep Antigravity installed locally or set AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_ID / AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_SECRET."
            )
        }

        guard let url = URL(string: Self.oauthRefreshURL) else {
            throw ProviderError("invalid_url", "Antigravity OAuth refresh URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody([
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError("refresh_failed", "Failed to refresh Antigravity OAuth token.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = intValue(json["expires_in"]) else {
            throw ProviderError("refresh_failed", "Antigravity token refresh returned invalid JSON.")
        }

        return RefreshedToken(
            accessToken: accessToken,
            expiryDate: Date().addingTimeInterval(TimeInterval(expiresIn)),
            expiresIn: expiresIn
        )
    }

    private func persistRefreshedToken(at url: URL, originalData: Data, refreshed: RefreshedToken) {
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }
        json["access_token"] = refreshed.accessToken
        json["expired"] = iso8601String(refreshed.expiryDate)
        json["expires_in"] = refreshed.expiresIn
        json["timestamp"] = Int(Date().timeIntervalSince1970 * 1000)

        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        try? updated.write(to: url)
    }

    private func formURLEncodedBody(_ params: [String: String]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._* "))
        let body = params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }

    private func resolveOAuthCredentials() -> (String, String)? {
        let environment = ProcessInfo.processInfo.environment
        if let clientId = environment["AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let clientSecret = environment["AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clientId.isEmpty,
           !clientSecret.isEmpty {
            return (clientId, clientSecret)
        }

        for candidate in antigravityOAuthSourceCandidates() {
            guard let content = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let credentials = extractOAuthCredentials(from: content) {
                return credentials
            }
        }

        return nil
    }

    private func antigravityOAuthSourceCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appCandidates = [
            "/Applications/Antigravity.app",
            "\(home)/Applications/Antigravity.app"
        ]

        let relativeCandidates = [
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/app/out/cli.js"
        ]

        return appCandidates.flatMap { appPath in
            relativeCandidates.map { "\(appPath)/\($0)" }
        }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func extractOAuthCredentials(from content: String) -> (String, String)? {
        let focusedContent: String
        if let markerRange = content.range(of: "out-build/vs/platform/cloudCode/common/oauthClient.js") {
            focusedContent = String(content[markerRange.lowerBound...].prefix(4000))
        } else {
            focusedContent = String(content.prefix(8000))
        }

        let clientIds = extractMatches(
            using: #"([0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com)"#,
            from: focusedContent
        )
        let clientSecrets = extractMatches(
            using: #"(GOCSPX-[A-Za-z0-9_-]+)"#,
            from: focusedContent
        )

        guard let clientId = clientIds.first,
              let clientSecret = clientSecrets.first else {
            return nil
        }
        return (clientId, clientSecret)
    }

    private func extractMatches(using pattern: String, from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(content.startIndex..., in: content)
        return regex.matches(in: content, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: content) else {
                return nil
            }
            return String(content[matchRange])
        }
    }

    // MARK: - API

    private struct SubscriptionInfo {
        let tierId: String?
        let tierName: String?
        let projectId: String?
    }

    private struct ModelQuota {
        let id: String
        let label: String
        let remainingPercent: Double
        let resetAt: String?
        let providerLabel: String?
    }

    private func loadCodeAssist(accessToken: String) async -> SubscriptionInfo {
        guard let url = URL(string: Self.loadCodeAssistURL) else {
            return SubscriptionInfo(tierId: nil, tierName: nil, projectId: nil)
        }

        var request = URLRequest(url: url, timeoutInterval: min(timeoutSeconds, 8))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "ANTIGRAVITY"]
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SubscriptionInfo(tierId: nil, tierName: nil, projectId: nil)
        }

        let tier = (json["paidTier"] as? [String: Any]) ?? (json["currentTier"] as? [String: Any])
        return SubscriptionInfo(
            tierId: tier?["id"] as? String,
            tierName: tier?["name"] as? String,
            projectId: normalizeProjectId(json["cloudaicompanionProject"])
        )
    }

    private func fetchAvailableModels(accessToken: String, projectId: String?) async throws -> [String: Any] {
        guard let url = URL(string: Self.quotaURL) else {
            throw ProviderError("invalid_url", "Antigravity quota URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]
        if let projectId, !projectId.isEmpty {
            body["project"] = projectId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError("invalid_response", "Antigravity quota API returned an invalid response.")
        }
        if http.statusCode == 401 {
            throw ProviderError("unauthorized", "Antigravity OAuth token is invalid or expired.")
        }
        if http.statusCode == 403 {
            throw ProviderError("forbidden", "Antigravity quota API returned HTTP 403.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError("api_error", "Antigravity quota API returned HTTP \(http.statusCode).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Antigravity quota API returned invalid JSON.")
        }
        return json
    }

    // MARK: - Build Usage

    private func buildUsage(authContext: AuthContext,
                            authFile: AntigravityAuthFile,
                            subscription: SubscriptionInfo,
                            quotaResponse: [String: Any]) -> ProviderUsage {
        let models = parseModels(quotaResponse)
        let lowestPercent = models.map(\.remainingPercent).min()
        let sortedModels = models.sorted {
            if $0.remainingPercent == $1.remainingPercent {
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            return $0.remainingPercent < $1.remainingPercent
        }

        var usage = ProviderUsage(provider: "antigravity", label: "Antigravity")
        usage.accountEmail = authFile.email
        usage.accountPlan = subscription.tierName ?? parsePlanName(tierId: subscription.tierId)
        usage.primary = sortedModels.indices.contains(0) ? modelWindow(from: sortedModels[0]) : nil
        usage.secondary = sortedModels.indices.contains(1) ? modelWindow(from: sortedModels[1]) : nil
        usage.tertiary = sortedModels.indices.contains(2) ? modelWindow(from: sortedModels[2]) : nil

        var source = SourceInfo(mode: "oauth", type: "cli-proxy-auth-file")
        source.profile = authContext.url.lastPathComponent
        source.roots = [authContext.sourceDirectory]
        usage.source = source

        usage.extra["projectId"] = AnyCodable(subscription.projectId ?? authFile.projectId ?? "")
        usage.extra["lowestPercentLeft"] = AnyCodable(lowestPercent ?? -1)
        usage.extra["modelCount"] = AnyCodable(models.count)
        usage.extra["authFileCount"] = AnyCodable(authContext.fileCount)
        usage.extra["selectedAuthFile"] = AnyCodable(authContext.url.lastPathComponent)
        usage.extra["trackedModels"] = AnyCodable(sortedModels.map { model in
            AnyCodable([
                "id": AnyCodable(model.id),
                "label": AnyCodable(model.label),
                "remainingPercent": AnyCodable(model.remainingPercent),
                "resetAt": AnyCodable(model.resetAt ?? ""),
                "providerLabel": AnyCodable(model.providerLabel ?? "")
            ] as [String: AnyCodable])
        })

        return usage
    }

    private func parseModels(_ response: [String: Any]) -> [ModelQuota] {
        let rawModels = response["models"] as? [String: Any] ?? [:]
        var models: [ModelQuota] = []

        for (name, rawInfo) in rawModels {
            guard let info = rawInfo as? [String: Any],
                  let quotaInfo = info["quotaInfo"] as? [String: Any],
                  let remainingFraction = doubleValue(quotaInfo["remainingFraction"]) else { continue }

            let isInternal = info["isInternal"] as? Bool ?? false
            let apiProvider = info["apiProvider"] as? String
            guard !isInternal, apiProvider != "API_PROVIDER_INTERNAL" else { continue }

            let displayName = (info["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label = displayName, !label.isEmpty else { continue }

            let remainingPercent = min(100, max(0, remainingFraction * 100))
            models.append(ModelQuota(
                id: name,
                label: label,
                remainingPercent: remainingPercent,
                resetAt: quotaInfo["resetTime"] as? String,
                providerLabel: providerLabel(apiProvider: apiProvider, modelProvider: info["modelProvider"] as? String)
            ))
        }

        return models
    }

    private func modelWindow(from model: ModelQuota) -> RawQuotaWindow {
        var window = RawQuotaWindow()
        window.label = model.label
        window.remainingPercent = model.remainingPercent
        window.usedPercent = max(0, 100 - model.remainingPercent)
        window.resetAt = model.resetAt
        window.resetDescription = formatResetDescription(
            model.resetAt.flatMap(Self.parseISO8601),
            prefix: model.providerLabel ?? "Model"
        )
        return window
    }

    private func providerLabel(apiProvider: String?, modelProvider: String?) -> String? {
        let value = (modelProvider ?? apiProvider ?? "").uppercased()
        if value.contains("ANTHROPIC") { return "Anthropic" }
        if value.contains("OPENAI") { return "OpenAI" }
        if value.contains("GOOGLE") || value.contains("GEMINI") { return "Google" }
        return nil
    }

    // MARK: - Helpers

    private func parsePlanName(tierId: String?) -> String? {
        guard let tierId, !tierId.isEmpty else { return nil }
        switch tierId.lowercased() {
        case "free": return "Free"
        case "standard": return "Standard"
        case "pro": return "Pro"
        case "ultra": return "Ultra"
        case "enterprise": return "Enterprise"
        default: return tierId.capitalized
        }
    }

    private func normalizeProjectId(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let dict = value as? [String: Any] {
            return dict["id"] as? String ?? dict["projectId"] as? String
        }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }

    private func iso8601String(_ date: Date) -> String {
        SharedFormatters.iso8601String(from: date)
    }

    private func formatResetDescription(_ date: Date?, prefix: String) -> String {
        guard let date else { return "\(prefix) • Reset unavailable" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "\(prefix) • Resets soon" }

        let totalMinutes = Int(diff / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(prefix) • Resets in \(days)d \(hours)h" }
        if hours > 0 { return "\(prefix) • Resets in \(hours)h \(minutes)m" }
        return "\(prefix) • Resets in \(max(1, minutes))m"
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let n as Int: return Double(n)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
