import Foundation

/// Converts Gemini CLI credentials between AIUsage's native `oauth_creds.json`
/// shape and the account file consumed by CPA's official `gemini-cli` plugin.
///
/// The plugin persists one physical account file and expands `project_ids` into
/// virtual project rows. Callers must only migrate the physical parent file.
nonisolated enum CLIProxyGeminiCredentialBridge {
    struct OAuthClientCredentials: Equatable, Sendable {
        let clientID: String
        let clientSecret: String
    }

    private struct CredentialMaterial {
        var accessToken: String?
        var refreshToken: String
        var idToken: String?
        var expiry: Date?
        let tokenType: String
        let email: String?
        let clientID: String?
        let clientSecret: String?
        let scope: String?
    }

    private struct ProjectInventory: Equatable, Sendable {
        let primaryProjectID: String
        let projectIDs: [String]
    }

    private enum DiscoveryFailure: Error {
        case unauthorized
        case unavailable
    }

    private static let defaultScope = [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cloud-platform"
    ].joined(separator: " ")

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let loadCodeAssistURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!
    private static let projectsURL = URL(
        string: "https://cloudresourcemanager.googleapis.com/v1/projects"
    )!
    private static let bundledOAuthClientCredentials: OAuthClientCredentials? = {
        guard let bundleDirectory = geminiBundleDirectory() else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: bundleDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "js" {
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  let clientID = extractConstant("OAUTH_CLIENT_ID", from: content),
                  let clientSecret = extractConstant("OAUTH_CLIENT_SECRET", from: content) else {
                continue
            }
            return OAuthClientCredentials(clientID: clientID, clientSecret: clientSecret)
        }
        return nil
    }()

    // MARK: Public conversion surface

    static func makeCPAPayload(
        sourceData: Data,
        credentialID: String,
        accountLabel: String?,
        metadata: [String: String]
    ) throws -> Data {
        let source = try jsonObject(from: sourceData)
        let material = try credentialMaterial(
            from: source,
            fallbackEmail: metadata["accountEmail"] ?? metadata["email"] ?? accountLabel
        )
        guard let accessToken = material.accessToken else {
            throw CLIProxyGatewayError.unsupportedAccount(
                "the Gemini auth file does not contain an access token"
            )
        }

        var result: [String: Any] = [:]
        copyCPAControlFields(from: source, to: &result)
        result["type"] = "gemini-cli"
        result["access_token"] = accessToken
        result["refresh_token"] = material.refreshToken
        result["token_type"] = material.tokenType
        result["disabled"] = bool(source["disabled"]) ?? false
        result["aiusage_credential_id"] = credentialID
        if let email = material.email { result["email"] = email }

        var token: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": material.refreshToken,
            "token_type": material.tokenType
        ]
        if let expiry = material.expiry {
            let encodedExpiry = iso8601String(from: expiry)
            result["expiry"] = encodedExpiry
            token["expiry"] = encodedExpiry
            token["expires_in"] = max(0, Int(expiry.timeIntervalSinceNow.rounded(.down)))
        }
        result["token"] = token

        let projects = normalizedProjectIDs(from: source)
        if !projects.isEmpty {
            result["project_ids"] = projects
            result["project_id"] = normalizedProjectID(source["project_id"]) ?? projects[0]
        }

        return try encodedJSONObject(result)
    }

    static func makeNativePayload(from sourceData: Data) throws -> Data {
        let source = try jsonObject(from: sourceData)
        let material = try credentialMaterial(from: source, fallbackEmail: nil)
        let installedOAuth = material.clientID != nil && material.clientSecret != nil
            ? nil
            : oauthClientCredentials()

        var result: [String: Any] = [
            "refresh_token": material.refreshToken,
            "token_type": material.tokenType,
            "scope": material.scope ?? defaultScope
        ]
        if let accessToken = material.accessToken { result["access_token"] = accessToken }
        if let idToken = material.idToken { result["id_token"] = idToken }
        if let email = material.email { result["email"] = email }
        if let expiry = material.expiry {
            result["expiry_date"] = Int64(expiry.timeIntervalSince1970 * 1_000)
        }
        if let clientID = material.clientID ?? installedOAuth?.clientID {
            result["client_id"] = clientID
        }
        if let clientSecret = material.clientSecret ?? installedOAuth?.clientSecret {
            result["client_secret"] = clientSecret
        }

        // Preserve the plugin's project inventory as harmless extension data.
        // Gemini CLI ignores unknown fields, while a later CPA round trip can
        // avoid another network discovery when the file has not been rewritten.
        let projects = normalizedProjectIDs(from: source)
        if !projects.isEmpty { result["project_ids"] = projects }
        if let project = normalizedProjectID(source["project_id"]) {
            result["project_id"] = project
        }

        return try encodedJSONObject(result)
    }

    static func accountEmail(from data: Data) -> String? {
        guard let source = try? jsonObject(from: data),
              let material = try? credentialMaterial(from: source, fallbackEmail: nil) else {
            return nil
        }
        return material.email
    }

    /// Ensures a newly copied Gemini credential contains the project inventory
    /// required by the official CPA plugin. Existing same-account CPA projects
    /// are reused so routine status refreshes never make Google network calls.
    static func prepareCPAPayloadForUpload(
        _ payload: Data,
        existingCPAData: Data?,
        allowNetworkDiscovery: Bool
    ) async throws -> Data {
        var source = try jsonObject(from: payload)
        var preservedCPAControls = false
        if let existingCPAData,
           let existing = try? jsonObject(from: existingCPAData),
           sameAccount(source, existing) {
            copyCPAControlFields(from: existing, to: &source)
            preservedCPAControls = true
            if normalizedProjectIDs(from: source).isEmpty,
               let inventory = projectInventory(from: existing) {
                apply(inventory, to: &source)
            }
        }

        if !normalizedProjectIDs(from: source).isEmpty {
            return preservedCPAControls ? try encodedJSONObject(source) : payload
        }

        guard allowNetworkDiscovery else { return payload }

        var material = try credentialMaterial(from: source, fallbackEmail: nil)
        let inventory: ProjectInventory
        do {
            guard let accessToken = material.accessToken else {
                throw DiscoveryFailure.unauthorized
            }
            inventory = try await discoverProjectInventory(accessToken: accessToken)
        } catch DiscoveryFailure.unauthorized {
            do {
                material = try await refresh(material)
                guard let accessToken = material.accessToken else {
                    throw DiscoveryFailure.unavailable
                }
                inventory = try await discoverProjectInventory(accessToken: accessToken)
                apply(material, to: &source)
            } catch let error as CLIProxyGatewayError {
                throw error
            } catch {
                throw projectDiscoveryError()
            }
        } catch {
            throw projectDiscoveryError()
        }

        apply(inventory, to: &source)
        return try encodedJSONObject(source)
    }

    // MARK: OAuth configuration shared with Gemini login and refresh

    static func oauthClientCredentials() -> OAuthClientCredentials? {
        let environment = ProcessInfo.processInfo.environment
        if let clientID = normalizedString(environment["AIUSAGE_GEMINI_OAUTH_CLIENT_ID"]),
           let clientSecret = normalizedString(environment["AIUSAGE_GEMINI_OAUTH_CLIENT_SECRET"]) {
            return OAuthClientCredentials(clientID: clientID, clientSecret: clientSecret)
        }

        return bundledOAuthClientCredentials
    }

    // MARK: Project discovery

    private static func discoverProjectInventory(accessToken: String) async throws -> ProjectInventory {
        var primary: String?
        var listed: [String] = []
        var sawUnauthorized = false
        do {
            primary = try await loadPrimaryProject(accessToken: accessToken)
        } catch DiscoveryFailure.unauthorized {
            sawUnauthorized = true
        } catch {}
        do {
            listed = try await listProjects(accessToken: accessToken)
        } catch DiscoveryFailure.unauthorized {
            sawUnauthorized = true
        } catch {}

        var projects = listed
        if let primary, !projects.contains(primary) { projects.append(primary) }
        let selected = primary
            ?? projects.first(where: { $0.hasPrefix("gen-lang-client") })
            ?? projects.first
        projects = stableProjectOrder(projects, primary: selected)

        guard let selected else {
            if sawUnauthorized { throw DiscoveryFailure.unauthorized }
            throw DiscoveryFailure.unavailable
        }
        return ProjectInventory(primaryProjectID: selected, projectIDs: projects)
    }

    private static func loadPrimaryProject(accessToken: String) async throws -> String? {
        var request = URLRequest(url: loadCodeAssistURL, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodedJSONObject([
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateDiscoveryResponse(response)
        guard let object = try? jsonObject(from: data) else { return nil }
        return normalizeProjectContainer(object["cloudaicompanionProject"])
    }

    private static func listProjects(accessToken: String) async throws -> [String] {
        var projects: [String] = []
        var nextPageToken: String?
        var pageCount = 0

        repeat {
            var components = URLComponents(url: projectsURL, resolvingAgainstBaseURL: false)
            var query = [URLQueryItem(name: "pageSize", value: "200")]
            if let nextPageToken { query.append(URLQueryItem(name: "pageToken", value: nextPageToken)) }
            components?.queryItems = query
            guard let url = components?.url else { throw DiscoveryFailure.unavailable }

            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateDiscoveryResponse(response)
            guard let object = try? jsonObject(from: data) else { throw DiscoveryFailure.unavailable }

            let rows = object["projects"] as? [[String: Any]] ?? []
            for row in rows {
                let lifecycle = normalizedString(row["lifecycleState"] as? String)?.uppercased()
                guard lifecycle == nil || lifecycle == "ACTIVE",
                      let project = normalizedProjectID(row["projectId"]) else { continue }
                if !projects.contains(project) { projects.append(project) }
            }
            nextPageToken = normalizedString(object["nextPageToken"] as? String)
            pageCount += 1
        } while nextPageToken != nil && pageCount < 10 && projects.count < 500

        return projects
    }

    private static func validateDiscoveryResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DiscoveryFailure.unavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw DiscoveryFailure.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw DiscoveryFailure.unavailable }
    }

    private static func refresh(_ material: CredentialMaterial) async throws -> CredentialMaterial {
        let installed = material.clientID != nil && material.clientSecret != nil
            ? nil
            : oauthClientCredentials()
        guard let clientID = material.clientID ?? installed?.clientID,
              let clientSecret = material.clientSecret ?? installed?.clientSecret else {
            throw CLIProxyGatewayError.unsupportedAccount(
                localizedMessage(
                    "Gemini OAuth configuration is unavailable. Reinstall Gemini CLI and try again.",
                    "找不到 Gemini OAuth 配置。请重新安装 Gemini CLI 后重试。"
                )
            )
        }

        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: material.refreshToken)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let object = try? jsonObject(from: data),
              let accessToken = normalizedString(object["access_token"] as? String) else {
            throw CLIProxyGatewayError.unsupportedAccount(
                localizedMessage(
                    "The Gemini session has expired and could not be refreshed. Sign in again, then retry.",
                    "Gemini 登录已过期且无法刷新，请重新登录后再试。"
                )
            )
        }

        var refreshed = material
        refreshed.accessToken = accessToken
        refreshed.refreshToken = normalizedString(object["refresh_token"] as? String)
            ?? material.refreshToken
        refreshed.idToken = normalizedString(object["id_token"] as? String) ?? material.idToken
        if let expiresIn = number(object["expires_in"]) {
            refreshed.expiry = Date().addingTimeInterval(expiresIn)
        }
        return refreshed
    }

    // MARK: Material and schema helpers

    private static func credentialMaterial(
        from source: [String: Any],
        fallbackEmail: String?
    ) throws -> CredentialMaterial {
        let token = (source["token"] as? [String: Any]) ?? (source["tokens"] as? [String: Any])
        guard let refreshToken = firstString([source["refresh_token"], token?["refresh_token"]]) else {
            throw CLIProxyGatewayError.unsupportedAccount(
                "the Gemini auth file does not contain a reusable refresh token"
            )
        }

        let idToken = firstString([source["id_token"], token?["id_token"]])
        let directEmail = firstEmail([source["email"], token?["email"], fallbackEmail])
        let email = directEmail ?? jwtEmail(from: idToken)
        let expiry = firstDate([
            source["expiry_date"], token?["expiry_date"],
            source["expiry"], token?["expiry"],
            source["expires_at"], token?["expires_at"]
        ])
        return CredentialMaterial(
            accessToken: firstString([source["access_token"], token?["access_token"]]),
            refreshToken: refreshToken,
            idToken: idToken,
            expiry: expiry,
            tokenType: firstString([source["token_type"], token?["token_type"]]) ?? "Bearer",
            email: email?.lowercased(),
            clientID: firstString([source["client_id"], token?["client_id"]]),
            clientSecret: firstString([source["client_secret"], token?["client_secret"]]),
            scope: firstString([source["scope"], token?["scope"]])
        )
    }

    private static func apply(_ material: CredentialMaterial, to source: inout [String: Any]) {
        source["refresh_token"] = material.refreshToken
        source["token_type"] = material.tokenType
        var token = source["token"] as? [String: Any] ?? [:]
        if let accessToken = material.accessToken {
            source["access_token"] = accessToken
            token["access_token"] = accessToken
        }
        token["refresh_token"] = material.refreshToken
        token["token_type"] = material.tokenType
        if let expiry = material.expiry {
            let encoded = iso8601String(from: expiry)
            source["expiry"] = encoded
            token["expiry"] = encoded
            token["expires_in"] = max(0, Int(expiry.timeIntervalSinceNow.rounded(.down)))
        }
        source["token"] = token
    }

    private static func apply(_ inventory: ProjectInventory, to source: inout [String: Any]) {
        source["project_id"] = inventory.primaryProjectID
        source["project_ids"] = inventory.projectIDs
    }

    private static func projectInventory(from source: [String: Any]) -> ProjectInventory? {
        let projects = normalizedProjectIDs(from: source)
        guard !projects.isEmpty else { return nil }
        let primary = normalizedProjectID(source["project_id"]) ?? projects[0]
        return ProjectInventory(
            primaryProjectID: primary,
            projectIDs: projects
        )
    }

    private static func sameAccount(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let leftMaterial = try? credentialMaterial(from: lhs, fallbackEmail: nil),
              let rightMaterial = try? credentialMaterial(from: rhs, fallbackEmail: nil),
              let left = leftMaterial.email,
              let right = rightMaterial.email else { return false }
        return left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func projectDiscoveryError() -> CLIProxyGatewayError {
        .unsupportedAccount(
            localizedMessage(
                "Gemini projects could not be discovered. Refresh this subscription account or sign in with Gemini CLI once, then try again.",
                "无法发现 Gemini 项目。请先刷新该订阅账号，或用 Gemini CLI 完成一次登录后重试。"
            )
        )
    }

    private static func normalizedProjectIDs(from source: [String: Any]) -> [String] {
        var result: [String] = []
        if let values = source["project_ids"] as? [Any] {
            for value in values {
                guard let project = normalizedProjectID(value), !result.contains(project) else { continue }
                result.append(project)
            }
        }
        if let project = normalizedProjectID(source["project_id"]), !result.contains(project) {
            result.insert(project, at: 0)
        }
        return result
    }

    private static func normalizeProjectContainer(_ value: Any?) -> String? {
        if let project = normalizedProjectID(value) { return project }
        guard let object = value as? [String: Any] else { return nil }
        return normalizedProjectID(object["id"]) ?? normalizedProjectID(object["projectId"])
    }

    private static func normalizedProjectID(_ value: Any?) -> String? {
        guard let project = normalizedString(value as? String),
              project.count <= 256,
              project.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:.")).contains($0)
              }) else { return nil }
        return project
    }

    private static func stableProjectOrder(_ projects: [String], primary: String?) -> [String] {
        let unique = projects.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        let remainder = unique.filter { $0 != primary }.sorted()
        return primary.map { [$0] + remainder } ?? remainder
    }

    private static func copyCPAControlFields(
        from source: [String: Any],
        to result: inout [String: Any]
    ) {
        for key in [
            "disabled", "proxy_url", "prefix", "priority", "note",
            "excluded_models", "model_aliases", "headers"
        ] where source[key] != nil {
            result[key] = source[key]
        }
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIProxyGatewayError.invalidResponse("credential file is not a JSON object")
        }
        return object
    }

    private static func encodedJSONObject(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIProxyGatewayError.invalidResponse("credential file contains invalid JSON values")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func firstString(_ values: [Any?]) -> String? {
        for value in values {
            if let string = normalizedString(value as? String) { return string }
        }
        return nil
    }

    private static func firstEmail(_ values: [Any?]) -> String? {
        for value in values {
            guard let email = normalizedString(value as? String),
                  email.contains("@"), !email.contains(where: \.isWhitespace) else { continue }
            return email
        }
        return nil
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func localizedMessage(_ english: String, _ chinese: String) -> String {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
            ? chinese
            : english
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func firstDate(_ values: [Any?]) -> Date? {
        for value in values {
            if let date = date(from: value) { return date }
        }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = normalizedString(value as? String) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func jwtEmail(from token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return firstEmail([object["email"]])
    }

    private static func geminiBundleDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let executableCandidates = [
            "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "/usr/bin/gemini", "/bin/gemini",
            "\(home)/.local/bin/gemini", "\(home)/bin/gemini"
        ]
        if let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            let parent = URL(fileURLWithPath: executable)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let direct = parent.appendingPathComponent(
                "lib/node_modules/@google/gemini-cli/bundle",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }

        return [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle",
            "/usr/local/lib/node_modules/@google/gemini-cli/bundle"
        ]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private static func extractConstant(_ name: String, from content: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        for pattern in [
            "(?:var|const)\\s+\(escaped)\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
            "\(escaped)\\s*:\\s*[\\\"']([^\\\"']+)[\\\"']"
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: content,
                    range: NSRange(content.startIndex..., in: content)
                  ),
                  let range = Range(match.range(at: 1), in: content) else { continue }
            return String(content[range])
        }
        return nil
    }
}
