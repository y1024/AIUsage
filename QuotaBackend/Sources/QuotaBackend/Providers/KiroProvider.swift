import CryptoKit
import Foundation

// MARK: - Kiro Provider
// 读取 ~/.cli-proxy-api/kiro-*.json 或 Kiro IDE 本地 auth，
// 必要时刷新 token，再调用 Kiro/AWS usage endpoint 获取用量。

public struct KiroProvider: MultiAccountProviderFetcher, CredentialAcceptingProvider {
    public let id = "kiro"
    public let displayName = "Kiro"
    public let description = "Kiro app quota usage"

    let homeDirectory: String
    let timeoutSeconds: Double

    static let defaultRegion = "us-east-1"
    static let refreshBufferSeconds: TimeInterval = 5 * 60
    static let kiroVersion = "0.10.32"

    public var supportedAuthMethods: [AuthMethod] { [.authFile, .auto] }

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeoutSeconds: Double = 20) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    /// Default single-account fetch (picks latest auth file)
    public func fetchUsage() async throws -> ProviderUsage {
        let authContext = try resolveAuthContext()
        return try await fetchForAuthContext(authContext)
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard credential.authMethod == .authFile else {
            throw ProviderError("unsupported_auth_method", "Kiro currently supports auth file imports only.")
        }

        let authContext = try resolveCredentialAuthContext(credential)
        var usage = try await fetchForAuthContext(authContext)
        usage.usageAccountId = authContext.tokenData.email ?? authContext.url.lastPathComponent
        if usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            usage.accountEmail = credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return usage
    }

    /// Multi-account: fetch ALL auth files in parallel
    public func fetchAllAccounts() async -> [AccountFetchResult] {
        let allContexts: [AuthContext]
        do {
            allContexts = try resolveAllAuthContexts()
        } catch {
            return [AccountFetchResult(accountId: "default", accountLabel: nil, result: .failure(error))]
        }

        guard !allContexts.isEmpty else {
            return [AccountFetchResult(
                accountId: "default",
                accountLabel: nil,
                result: .failure(ProviderError("not_logged_in", "No Kiro auth files found."))
            )]
        }

        if allContexts.count == 1 {
            let ctx = allContexts[0]
            do {
                let usage = try await fetchForAuthContext(ctx)
                let accountId = ctx.tokenData.email ?? ctx.url.lastPathComponent
                return [AccountFetchResult(accountId: accountId, accountLabel: ctx.tokenData.email, result: .success(usage))]
            } catch {
                let accountId = ctx.tokenData.email ?? ctx.url.lastPathComponent
                return [AccountFetchResult(accountId: accountId, accountLabel: ctx.tokenData.email, result: .failure(error))]
            }
        }

        return await withTaskGroup(of: AccountFetchResult.self) { group in
            for ctx in allContexts {
                group.addTask {
                    let accountId = ctx.tokenData.email ?? ctx.url.lastPathComponent
                    do {
                        let usage = try await fetchForAuthContext(ctx)
                        return AccountFetchResult(accountId: accountId, accountLabel: ctx.tokenData.email, result: .success(usage))
                    } catch {
                        return AccountFetchResult(accountId: accountId, accountLabel: ctx.tokenData.email, result: .failure(error))
                    }
                }
            }
            var results: [AccountFetchResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    /// Core fetch logic for a single auth context
    private func fetchForAuthContext(_ authContext: AuthContext) async throws -> ProviderUsage {
        var auth = authContext.tokenData
        let originalData = authContext.rawData

        if needsRefresh(auth.expiresAt), let refreshed = try? await refreshToken(tokenData: auth, authContext: authContext, originalData: originalData) {
            auth.accessToken = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken {
                auth.refreshToken = refreshToken
            }
            auth.expiresAt = iso8601String(refreshed.expiryDate)
        }

        let response = try await fetchUsageResponse(tokenData: auth, authContext: authContext, allowRetry: true)
        return buildUsage(authContext: authContext, tokenData: auth, response: response)
    }

    // MARK: - Auth Context

    private struct AuthContext {
        let url: URL
        let tokenData: KiroTokenData
        let rawData: Data
        let fileCount: Int
        let sourceDirectory: String
        let sourceType: String
    }

    private struct KiroTokenData {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: String?
        var clientId: String?
        var clientSecret: String?
        var authMethod: String
        var region: String
        var profileArn: String?
        var authProvider: String?
        var email: String?
    }

    private struct RefreshedToken {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Date
    }

    private struct KiroTokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let tokenType: String?
        let refreshToken: String?
    }

    private struct KiroUsageResponse: Decodable {
        let usageBreakdownList: [KiroUsageBreakdown]?
        let subscriptionInfo: KiroSubscriptionInfo?
        let userInfo: KiroUserInfo?
        let nextDateReset: Double?

        struct KiroUsageBreakdown: Decodable {
            let displayName: String?
            let resourceType: String?
            let currentUsage: Double?
            let currentUsageWithPrecision: Double?
            let usageLimit: Double?
            let usageLimitWithPrecision: Double?
            let nextDateReset: Double?
            let freeTrialInfo: KiroFreeTrialInfo?
        }

        struct KiroFreeTrialInfo: Decodable {
            let currentUsage: Double?
            let currentUsageWithPrecision: Double?
            let usageLimit: Double?
            let usageLimitWithPrecision: Double?
            let freeTrialStatus: String?
            let freeTrialExpiry: Double?
        }

        struct KiroSubscriptionInfo: Decodable {
            let subscriptionTitle: String?
            let type: String?
        }

        struct KiroUserInfo: Decodable {
            let email: String?
            let userId: String?
        }
    }

    private struct UsageEntry {
        let label: String
        let remainingPercent: Double
        let resetAt: Date?
    }

    /// Resolve ALL auth contexts for multi-account fetching
    private func resolveAllAuthContexts() throws -> [AuthContext] {
        let env = ProcessInfo.processInfo.environment

        if let explicitFile = env["KIRO_AUTH_FILE"], !explicitFile.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: explicitFile).expandingTildeInPath)
            return [try loadAuthContext(url: url, fileCount: 1, sourceDirectory: url.deletingLastPathComponent().path, sourceType: sourceType(for: url))]
        }

        let authDirectory = env["KIRO_AUTH_DIR"].map { NSString(string: $0).expandingTildeInPath }
            ?? "\(homeDirectory)/.cli-proxy-api"
        let directoryURL = URL(fileURLWithPath: authDirectory, isDirectory: true)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let matches = files.filter {
            $0.lastPathComponent.hasPrefix("kiro-") && $0.pathExtension == "json"
        }

        let ideAuthURL = URL(fileURLWithPath: "\(homeDirectory)/.aws/sso/cache/kiro-auth-token.json")

        var candidates: [URL] = matches
        if FileManager.default.fileExists(atPath: ideAuthURL.path) {
            candidates.append(ideAuthURL)
        }

        guard !candidates.isEmpty else {
            throw ProviderError("not_logged_in", "No Kiro auth file found. Expected ~/.cli-proxy-api/kiro-*.json or ~/.aws/sso/cache/kiro-auth-token.json.")
        }

        let contexts = candidates
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
            .compactMap { url in
                try? loadAuthContext(
                    url: url,
                    fileCount: candidates.count,
                    sourceDirectory: url.deletingLastPathComponent().path,
                    sourceType: sourceType(for: url)
                )
            }
        return enrichEmailHints(in: contexts)
    }

    /// Legacy single-file resolution (picks latest modified)
    private func resolveAuthContext() throws -> AuthContext {
        let contexts = try resolveAllAuthContexts()
        guard let first = contexts.first else {
            throw ProviderError("not_logged_in", "No valid Kiro auth files found.")
        }
        return first
    }

    private func sourceType(for url: URL) -> String {
        url.lastPathComponent == "kiro-auth-token.json" ? "kiro-ide-auth-file" : "cli-proxy-auth-file"
    }

    private func loadAuthContext(url: URL, fileCount: Int, sourceDirectory: String, sourceType: String) throws -> AuthContext {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError("not_logged_in", "Kiro auth file not found at \(url.path).")
        }

        let data = try Data(contentsOf: url)
        var tokenData = try parseTokenData(from: data, url: url)

        if tokenData.authMethod == "idc", (tokenData.clientId == nil || tokenData.clientSecret == nil) {
            let registration = loadKiroDeviceRegistration()
            if tokenData.clientId == nil { tokenData.clientId = registration.clientId }
            if tokenData.clientSecret == nil { tokenData.clientSecret = registration.clientSecret }
        }

        if tokenData.accessToken.isEmpty {
            throw ProviderError("missing_tokens", "Kiro auth file exists but has no access token.")
        }

        return AuthContext(
            url: url,
            tokenData: tokenData,
            rawData: data,
            fileCount: fileCount,
            sourceDirectory: sourceDirectory,
            sourceType: sourceType
        )
    }

    private func resolveCredentialAuthContext(_ credential: AccountCredential) throws -> AuthContext {
        let path = NSString(string: credential.credential).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return try loadAuthContext(
            url: url,
            fileCount: 1,
            sourceDirectory: url.deletingLastPathComponent().path,
            sourceType: sourceType(for: url)
        )
    }

    private func parseTokenData(from data: Data, url: URL) throws -> KiroTokenData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Kiro auth file contained invalid JSON.")
        }

        let accessToken = stringValue(json["access_token"]) ?? stringValue(json["accessToken"]) ?? ""
        let refreshToken = stringValue(json["refresh_token"]) ?? stringValue(json["refreshToken"])
        let profileArn = stringValue(json["profile_arn"]) ?? stringValue(json["profileArn"])

        var expiresAt = stringValue(json["expires_at"]) ?? stringValue(json["expiresAt"]) ?? stringValue(json["expiry"])
        if expiresAt == nil, let numericExpiry = doubleValue(json["expires_at"] ?? json["expiresAt"] ?? json["expiry"]) {
            expiresAt = iso8601String(Date(timeIntervalSince1970: numericExpiry))
        }

        let authProvider = stringValue(json["provider"])
        let authMethod = (stringValue(json["auth_method"]) ?? stringValue(json["authMethod"]) ?? defaultAuthMethod(provider: authProvider)).lowercased()
        let region = stringValue(json["region"]) ?? extractRegionFromProfileArn(profileArn) ?? Self.defaultRegion
        let email = firstNonEmptyString(
            json["email"],
            json["accountEmail"],
            json["userEmail"],
            json["loginHint"]
        )

        return KiroTokenData(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            clientId: stringValue(json["client_id"]) ?? stringValue(json["clientId"]),
            clientSecret: stringValue(json["client_secret"]) ?? stringValue(json["clientSecret"]),
            authMethod: authMethod,
            region: region,
            profileArn: profileArn,
            authProvider: authProvider,
            email: email
        )
    }

    private func enrichEmailHints(in contexts: [AuthContext]) -> [AuthContext] {
        let hintedEmailsByProfile: [String: String] = Dictionary(
            uniqueKeysWithValues: contexts.compactMap { context -> (String, String)? in
                guard let profileArn = context.tokenData.profileArn,
                      let email = context.tokenData.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !email.isEmpty else {
                    return nil
                }
                return (profileArn, email)
            }
        )

        return contexts.map { context in
            let currentEmail = context.tokenData.email?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentEmail == nil || currentEmail?.isEmpty == true,
                  let profileArn = context.tokenData.profileArn,
                  let hintedEmail = hintedEmailsByProfile[profileArn] else {
                return context
            }

            var tokenData = context.tokenData
            tokenData.email = hintedEmail
            return AuthContext(
                url: context.url,
                tokenData: tokenData,
                rawData: context.rawData,
                fileCount: context.fileCount,
                sourceDirectory: context.sourceDirectory,
                sourceType: context.sourceType
            )
        }
    }

    private func defaultAuthMethod(provider: String?) -> String {
        provider?.lowercased() == "google" ? "social" : "idc"
    }

    private func fallbackAccountName(from filename: String, authProvider: String?) -> String? {
        if filename == "kiro-auth-token.json" {
            return authProvider.map { "Kiro (\($0))" } ?? "Kiro IDE"
        }

        guard filename.hasPrefix("kiro-"), filename.hasSuffix(".json") else {
            return authProvider.map { "Kiro (\($0))" }
        }

        let value = filename
            .replacingOccurrences(of: "kiro-", with: "")
            .replacingOccurrences(of: ".json", with: "")
        return value.isEmpty ? authProvider.map { "Kiro (\($0))" } : value
    }

    private func loadKiroDeviceRegistration() -> (clientId: String?, clientSecret: String?) {
        let cachePath = "\(homeDirectory)/.aws/sso/cache"
        let authTokenPath = "\(cachePath)/kiro-auth-token.json"

        var clientIdHash: String?
        if let data = FileManager.default.contents(atPath: authTokenPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            clientIdHash = json["clientIdHash"] as? String
        }

        if let hash = clientIdHash {
            let registrationPath = "\(cachePath)/\(hash).json"
            if let data = FileManager.default.contents(atPath: registrationPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let clientId = json["clientId"] as? String,
               let clientSecret = json["clientSecret"] as? String {
                return (clientId, clientSecret)
            }
        }

        if let files = try? FileManager.default.contentsOfDirectory(atPath: cachePath) {
            for file in files where file.hasSuffix(".json") && file != "kiro-auth-token.json" {
                let filePath = "\(cachePath)/\(file)"
                if let data = FileManager.default.contents(atPath: filePath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let clientId = json["clientId"] as? String,
                   let clientSecret = json["clientSecret"] as? String {
                    return (clientId, clientSecret)
                }
            }
        }

        return (nil, nil)
    }

    private func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Fetch Usage

    private func fetchUsageResponse(tokenData: KiroTokenData,
                                    authContext: AuthContext,
                                    allowRetry: Bool) async throws -> KiroUsageResponse {
        let result = try await fetchUsageOnce(tokenData: tokenData)
        if result.statusCode == 200, let response = result.response {
            return response
        }

        if allowRetry, (result.statusCode == 401 || result.statusCode == 403) {
            guard let refreshed = try? await refreshToken(tokenData: tokenData, authContext: authContext, originalData: authContext.rawData) else {
                throw ProviderError("unauthorized", "Kiro OAuth token is invalid or expired.")
            }
            var retryToken = tokenData
            retryToken.accessToken = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken {
                retryToken.refreshToken = refreshToken
            }
            retryToken.expiresAt = iso8601String(refreshed.expiryDate)

            let retryResult = try await fetchUsageOnce(tokenData: retryToken)
            if retryResult.statusCode == 200, let response = retryResult.response {
                return response
            }
        }

        switch result.statusCode {
        case 401, 403:
            throw ProviderError("unauthorized", "Kiro OAuth token is invalid or expired.")
        case 0:
            throw ProviderError("network_error", "Failed to reach the Kiro usage endpoint.")
        default:
            throw ProviderError("api_error", "Kiro usage API returned HTTP \(result.statusCode).")
        }
    }

    private struct UsageAPIResult {
        let statusCode: Int
        let response: KiroUsageResponse?
    }

    private func fetchUsageOnce(tokenData: KiroTokenData) async throws -> UsageAPIResult {
        guard var components = URLComponents(string: usageEndpoint(region: tokenData.region)) else {
            throw ProviderError("invalid_url", "Failed to build the Kiro usage URL.")
        }

        var queryItems = [
            URLQueryItem(name: "origin", value: "AI_EDITOR"),
            URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")
        ]
        if let profileArn = tokenData.profileArn, !profileArn.isEmpty {
            queryItems.append(URLQueryItem(name: "profileArn", value: profileArn))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ProviderError("invalid_url", "Failed to build the Kiro usage URL.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokenData.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("q.\(tokenData.region).amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue(kiroUserAgent(for: tokenData), forHTTPHeaderField: "User-Agent")
        request.setValue(kiroAmzUserAgent(for: tokenData), forHTTPHeaderField: "x-amz-user-agent")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "amz-sdk-invocation-id")
        request.setValue("attempt=1; max=1", forHTTPHeaderField: "amz-sdk-request")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return UsageAPIResult(statusCode: 0, response: nil)
        }
        guard http.statusCode == 200 else {
            return UsageAPIResult(statusCode: http.statusCode, response: nil)
        }

        guard let decoded = try? JSONDecoder().decode(KiroUsageResponse.self, from: data) else {
            throw ProviderError("parse_failed", "Kiro usage API returned invalid JSON.")
        }

        return UsageAPIResult(statusCode: 200, response: decoded)
    }

    // MARK: - Token Refresh

    private func refreshToken(tokenData: KiroTokenData,
                              authContext: AuthContext,
                              originalData: Data) async throws -> RefreshedToken {
        guard let refreshToken = tokenData.refreshToken, !refreshToken.isEmpty else {
            throw ProviderError("missing_refresh_token", "Kiro auth is missing a refresh token.")
        }

        let refreshed: RefreshedToken
        if tokenData.authMethod == "social" {
            refreshed = try await refreshSocialToken(refreshToken: refreshToken, region: tokenData.region)
        } else {
            refreshed = try await refreshIdCToken(tokenData: tokenData, refreshToken: refreshToken)
        }

        persistRefreshedToken(at: authContext.url, originalData: originalData, refreshed: refreshed, sourceType: authContext.sourceType)
        if authContext.sourceType != "kiro-ide-auth-file" {
            syncToKiroIDEAuthFile(refreshed: refreshed)
        }

        return refreshed
    }

    private func refreshSocialToken(refreshToken: String, region: String) async throws -> RefreshedToken {
        guard let url = URL(string: socialTokenEndpoint(region: region)) else {
            throw ProviderError("invalid_url", "Failed to build the Kiro social token endpoint.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError("refresh_failed", "Kiro social token refresh failed.")
        }

        let payload = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
        return RefreshedToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiryDate: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    private func refreshIdCToken(tokenData: KiroTokenData, refreshToken: String) async throws -> RefreshedToken {
        guard let clientId = tokenData.clientId, !clientId.isEmpty,
              let clientSecret = tokenData.clientSecret, !clientSecret.isEmpty,
              let url = URL(string: idcTokenEndpoint(region: tokenData.region)) else {
            throw ProviderError("missing_credentials", "Kiro IdC auth is missing client credentials.")
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oidc.\(tokenData.region).amazonaws.com", forHTTPHeaderField: "Host")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("aws-sdk-js/3.980.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.980.0 m/E KiroIDE", forHTTPHeaderField: "x-amz-user-agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("node", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError("refresh_failed", "Kiro IdC token refresh failed.")
        }

        let payload = try JSONDecoder().decode(KiroTokenResponse.self, from: data)
        return RefreshedToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiryDate: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    private func persistRefreshedToken(at url: URL, originalData: Data, refreshed: RefreshedToken, sourceType: String) {
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }
        let isCamelCase = sourceType == "kiro-ide-auth-file" || json["accessToken"] != nil

        if isCamelCase {
            json["accessToken"] = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken { json["refreshToken"] = refreshToken }
            json["expiresAt"] = iso8601String(refreshed.expiryDate)
        } else {
            json["access_token"] = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken { json["refresh_token"] = refreshToken }
            json["expires_at"] = iso8601String(refreshed.expiryDate)
            json["last_refresh"] = iso8601String(Date())
        }

        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? updated.write(to: url, options: .atomic)
    }

    private func syncToKiroIDEAuthFile(refreshed: RefreshedToken) {
        let ideAuthURL = URL(fileURLWithPath: "\(homeDirectory)/.aws/sso/cache/kiro-auth-token.json")
        guard FileManager.default.fileExists(atPath: ideAuthURL.path),
              let data = FileManager.default.contents(atPath: ideAuthURL.path),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        json["accessToken"] = refreshed.accessToken
        if let refreshToken = refreshed.refreshToken {
            json["refreshToken"] = refreshToken
        }
        json["expiresAt"] = iso8601String(refreshed.expiryDate)

        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? updated.write(to: ideAuthURL, options: .atomic)
    }

    // MARK: - Normalize Usage

    private func buildUsage(authContext: AuthContext,
                            tokenData: KiroTokenData,
                            response: KiroUsageResponse) -> ProviderUsage {
        let entries = buildEntries(from: response)
        let sortedEntries = entries.sorted { lhs, rhs in
            lhs.remainingPercent < rhs.remainingPercent
        }

        var usage = ProviderUsage(provider: "kiro", label: "Kiro")
        usage.accountEmail = response.userInfo?.email
            ?? emailLike(response.userInfo?.userId)
            ?? tokenData.email
        usage.accountName = response.userInfo?.userId ?? tokenData.authProvider.map { "Kiro (\($0))" }
        usage.accountPlan = response.subscriptionInfo?.subscriptionTitle ?? response.subscriptionInfo?.type ?? "Standard"

        let topEntries = Array(sortedEntries.prefix(3))
        if topEntries.indices.contains(0) { usage.primary = createWindow(from: topEntries[0]) }
        if topEntries.indices.contains(1) { usage.secondary = createWindow(from: topEntries[1]) }
        if topEntries.indices.contains(2) { usage.tertiary = createWindow(from: topEntries[2]) }

        var source = SourceInfo(mode: "oauth", type: authContext.sourceType)
        source.profile = authContext.url.lastPathComponent
        source.roots = [authContext.sourceDirectory]
        usage.source = source

        usage.extra["authMethod"] = AnyCodable(tokenData.authMethod)
        usage.extra["authProvider"] = AnyCodable(tokenData.authProvider ?? "")
        usage.extra["region"] = AnyCodable(tokenData.region)
        usage.extra["profileArn"] = AnyCodable(tokenData.profileArn ?? "")
        usage.extra["selectedAuthFile"] = AnyCodable(authContext.url.lastPathComponent)
        usage.extra["authFileCount"] = AnyCodable(authContext.fileCount)
        usage.extra["quotaEntryCount"] = AnyCodable(entries.count)
        usage.extra["hiddenQuotaCount"] = AnyCodable(max(0, entries.count - topEntries.count))
        usage.extra["tokenExpiresAt"] = AnyCodable(tokenData.expiresAt ?? "")
        usage.extra["userId"] = AnyCodable(response.userInfo?.userId ?? "")

        return usage
    }

    private func emailLike(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.contains("@") else {
            return nil
        }
        return value
    }

    private func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private func buildEntries(from response: KiroUsageResponse) -> [UsageEntry] {
        var entries: [UsageEntry] = []
        let defaultReset = response.nextDateReset.map { Date(timeIntervalSince1970: $0) }

        for breakdown in response.usageBreakdownList ?? [] {
            let displayName = breakdown.displayName ?? breakdown.resourceType ?? "Usage"
            let regularReset = breakdown.nextDateReset.map { Date(timeIntervalSince1970: $0) } ?? defaultReset

            if let freeTrial = breakdown.freeTrialInfo,
               freeTrial.freeTrialStatus?.uppercased() == "ACTIVE" {
                let used = freeTrial.currentUsageWithPrecision ?? freeTrial.currentUsage ?? 0
                let limit = freeTrial.usageLimitWithPrecision ?? freeTrial.usageLimit ?? 0
                if limit > 0 {
                    entries.append(UsageEntry(
                        label: "Bonus \(displayName)",
                        remainingPercent: remainingPercent(used: used, limit: limit),
                        resetAt: freeTrial.freeTrialExpiry.map { Date(timeIntervalSince1970: $0) } ?? regularReset
                    ))
                }
            }

            let used = breakdown.currentUsageWithPrecision ?? breakdown.currentUsage ?? 0
            let limit = breakdown.usageLimitWithPrecision ?? breakdown.usageLimit ?? 0
            if limit > 0 {
                let hasTrial = breakdown.freeTrialInfo?.freeTrialStatus?.uppercased() == "ACTIVE"
                entries.append(UsageEntry(
                    label: hasTrial ? "\(displayName) Base" : displayName,
                    remainingPercent: remainingPercent(used: used, limit: limit),
                    resetAt: regularReset
                ))
            }
        }

        if entries.isEmpty {
            entries.append(UsageEntry(label: "Agentic Requests", remainingPercent: 100, resetAt: defaultReset))
        }

        return entries
    }

    private func createWindow(from entry: UsageEntry) -> RawQuotaWindow {
        var window = RawQuotaWindow()
        window.label = entry.label
        window.remainingPercent = entry.remainingPercent
        window.usedPercent = max(0, 100 - entry.remainingPercent)
        window.resetAt = entry.resetAt.map(iso8601String)
        window.resetDescription = formatResetDescription(entry.resetAt)
        return window
    }

    // MARK: - Helpers

    private func extractRegionFromProfileArn(_ profileArn: String?) -> String? {
        guard let profileArn, !profileArn.isEmpty else { return nil }
        let parts = profileArn.split(separator: ":")
        guard parts.count >= 6,
              parts[0] == "arn",
              parts[2] == "codewhisperer",
              parts[3].contains("-") else { return nil }
        return String(parts[3])
    }

    private func usageEndpoint(region: String) -> String {
        "https://q.\(region).amazonaws.com/getUsageLimits"
    }

    private func socialTokenEndpoint(region: String) -> String {
        "https://prod.\(region).auth.desktop.kiro.dev/refreshToken"
    }

    private func idcTokenEndpoint(region: String) -> String {
        "https://oidc.\(region).amazonaws.com/token"
    }

    private func needsRefresh(_ expiresAt: String?) -> Bool {
        guard let expiry = parseISO8601(expiresAt) else { return false }
        return expiry.timeIntervalSinceNow <= Self.refreshBufferSeconds
    }

    private func remainingPercent(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return min(100, max(0, (limit - used) / limit * 100))
    }

    private func kiroUserAgent(for tokenData: KiroTokenData) -> String {
        let machineId = machineId(for: tokenData)
        return "aws-sdk-js/1.0.0 ua/2.1 os/darwin#\(darwinVersion()) lang/js md/nodejs#22.21.1 api/codewhispererruntime#1.0.0 m/N,E KiroIDE-\(Self.kiroVersion)-\(machineId)"
    }

    private func kiroAmzUserAgent(for tokenData: KiroTokenData) -> String {
        let machineId = machineId(for: tokenData)
        return "aws-sdk-js/1.0.0 KiroIDE-\(Self.kiroVersion)-\(machineId)"
    }

    private func machineId(for tokenData: KiroTokenData) -> String {
        let seed = tokenData.clientId ?? tokenData.refreshToken ?? tokenData.profileArn ?? tokenData.accessToken
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func darwinVersion() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return SharedFormatters.parseISO8601(value)
    }

    private func iso8601String(_ date: Date) -> String {
        SharedFormatters.iso8601FractionalUTC.string(from: date)
    }

    private func formatResetDescription(_ date: Date?) -> String {
        guard let date else { return "Reset unavailable" }
        let day = DateFormat.string(from: date, format: "MMM d")
        return "Resets \(day)"
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }
}
