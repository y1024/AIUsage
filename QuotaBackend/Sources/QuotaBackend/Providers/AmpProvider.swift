import Foundation
import CommonCrypto

// MARK: - Amp Provider
// 从浏览器 Cookie 获取 session，抓取 ampcode.com/settings HTML，解析 freeTierUsage

public struct AmpProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "amp"
    public let displayName = "Amp"
    public let description = "Amp free tier quota usage"

    let timeoutSeconds: Double
    let homeDirectory: String

    static let settingsURL = "https://ampcode.com/settings"
    static let sessionCookieName = "session"
    static let cookieDomains = ["ampcode.com", ".ampcode.com"]
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    static func browserProfiles(home: String) -> [(name: String, cookiesPath: String, keychainService: String)] {
        [
            ("Chrome", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies",      "Chrome Safe Storage"),
            ("Chrome P1", "\(home)/Library/Application Support/Google/Chrome/Profile 1/Cookies", "Chrome Safe Storage"),
            ("Arc",    "\(home)/Library/Application Support/Arc/User Data/Default/Cookies",       "Arc Safe Storage"),
            ("Edge",   "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies",      "Microsoft Edge Safe Storage"),
            ("Brave",  "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies", "Brave Safe Storage"),
        ]
    }

    public var supportedAuthMethods: [AuthMethod] { [.cookie, .auto] }

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeoutSeconds: Double = 15) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage() async throws -> ProviderUsage {
        if let envCookie = ProcessInfo.processInfo.environment["AMP_COOKIE_HEADER"], !envCookie.isEmpty {
            return try await fetchWithCookie(envCookie, source: SourceInfo(mode: "manual", type: "env-var"))
        }

        var lastAutomaticError: Error?
        if let cookieHeader = try? importCookieFromBrowser() {
            let source = SourceInfo(mode: "auto", type: "browser-cookie")
            do {
                return try await fetchWithCookie(cookieHeader, source: source)
            } catch {
                // Browser state often lags behind a freshly imported account. Keep the
                // stored per-account session as the fallback source of truth.
                lastAutomaticError = error
            }
        }

        let storedCreds = AccountCredentialStore.shared.loadCredentials(for: "amp")
        for cred in storedCreds where cred.authMethod == .cookie {
            if let usage = try? await fetchWithCookie(cred.credential, source: SourceInfo(mode: "stored", type: "keychain-credential")) {
                AccountCredentialStore.shared.updateLastUsed(cred)
                return usage
            }
        }

        if let lastAutomaticError {
            throw lastAutomaticError
        }
        throw ProviderError("not_logged_in", "No Amp session cookie found. Log in to ampcode.com/settings, or save a valid cookie.")
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        let source = SourceInfo(mode: "manual", type: "pasted-cookie")
        return try await fetchWithCookie(credential.credential, source: source)
    }

    private func fetchWithCookie(_ cookieHeader: String, source: SourceInfo) async throws -> ProviderUsage {
        let normalizedCookieHeader = try normalizedCookieHeader(from: cookieHeader)
        guard let url = URL(string: Self.settingsURL) else {
            throw ProviderError("invalid_url", "Amp settings URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        applyAmpHeaders(to: &request, cookieHeader: normalizedCookieHeader)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds

        let session = URLSession(configuration: configuration)
        let redirectDelegate = AmpRedirectDelegate(cookieHeader: normalizedCookieHeader, userAgent: Self.userAgent)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        } catch let error as URLError where error.code == .httpTooManyRedirects {
            throw ProviderError("invalid_credentials", "Amp sign-in bounced through too many redirects. Please sign in again and let AIUsage capture the fresh session.")
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError("invalid_credentials", "Amp session cookie expired. Please log in again.")
        }
        if let http = response as? HTTPURLResponse, let url = http.url, isLoginRedirect(url.absoluteString) {
            throw ProviderError("invalid_credentials", "Amp redirected to sign-in. Please refresh your session cookie.")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError("parse_failed", "Could not decode Amp settings page.")
        }

        return try parseHTML(html, source: source)
    }

    private func normalizedCookieHeader(from rawHeader: String) throws -> String {
        let segments = rawHeader
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var sessionValue: String?
        var fallbackPairs: [String: String] = [:]

        for segment in segments {
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let name = String(segment[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(segment[segment.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }

            if name == Self.sessionCookieName {
                sessionValue = value
            } else {
                fallbackPairs[name] = value
            }
        }

        if let sessionValue, !sessionValue.isEmpty {
            return "\(Self.sessionCookieName)=\(sessionValue)"
        }

        if Self.isCookieSafeAscii(rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return "\(Self.sessionCookieName)=\(rawHeader.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        if !fallbackPairs.isEmpty {
            let header = fallbackPairs
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            return header
        }

        throw ProviderError("invalid_credentials", "Amp login did not return a usable session cookie. Please sign in again and let AIUsage capture the finished account.")
    }

    private func applyAmpHeaders(to request: inout URLRequest, cookieHeader: String) {
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("https://ampcode.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.settingsURL, forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func isLoginRedirect(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("/login") || lower.contains("/signin") || lower.contains("/sign-in")
    }

    private final class AmpRedirectDelegate: NSObject, URLSessionTaskDelegate {
        let cookieHeader: String
        let userAgent: String

        init(cookieHeader: String, userAgent: String) {
            self.cookieHeader = cookieHeader
            self.userAgent = userAgent
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            var redirectedRequest = request
            redirectedRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            redirectedRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            redirectedRequest.setValue("https://ampcode.com", forHTTPHeaderField: "Origin")
            redirectedRequest.setValue(response.url?.absoluteString ?? AmpProvider.settingsURL, forHTTPHeaderField: "Referer")
            completionHandler(redirectedRequest)
        }
    }

    // MARK: - HTML Parsing (mirrors parseAmpUsage.js)

    private func parseHTML(_ html: String, source: SourceInfo) throws -> ProviderUsage {
        guard let usage = extractFreeTierUsage(html) else {
            if html.lowercased().contains("sign in") || html.lowercased().contains("log in") {
                throw ProviderError("not_logged_in", "Not logged in to Amp. Please log in at https://ampcode.com/settings.")
            }
            throw ProviderError("parse_failed", "Could not parse Amp usage from settings page.")
        }

        let quota = max(0, usage.quota)
        let used = max(0, usage.used)
        let remaining = max(0, quota - used)
        let usedPercent = quota > 0 ? min(100.0, Double(used) / Double(quota) * 100.0) : 0
        let remainingPercent = quota > 0 ? max(0.0, 100.0 - usedPercent) : 0

        let estimatedFullResetAt: String?
        if used > 0, quota > 0, usage.hourlyReplenishment > 0 {
            let resetDate = Date(timeIntervalSinceNow: Double(used) / usage.hourlyReplenishment * 3600)
            estimatedFullResetAt = SharedFormatters.iso8601String(from: resetDate)
        } else {
            estimatedFullResetAt = nil
        }

        var window = RawQuotaWindow()
        window.usedPercent = usedPercent
        window.remainingPercent = remainingPercent
        window.resetAt = estimatedFullResetAt
        window.resetDescription = estimatedFullResetAt.flatMap { formatReset($0) }

        let accountEmail = extractEmail(html)

        var usageResult = ProviderUsage(provider: "amp", label: "Amp")
        usageResult.accountEmail = accountEmail
        usageResult.usageAccountId = accountEmail?.lowercased()
        usageResult.accountPlan = "Free"
        usageResult.primary = window
        usageResult.source = source

        usageResult.extra["quota"]               = AnyCodable(quota)
        usageResult.extra["used"]                = AnyCodable(used)
        usageResult.extra["remaining"]           = AnyCodable(remaining)
        usageResult.extra["usedPercent"]         = AnyCodable(usedPercent)
        usageResult.extra["remainingPercent"]    = AnyCodable(remainingPercent)
        usageResult.extra["hourlyReplenishment"] = AnyCodable(Int(usage.hourlyReplenishment))
        usageResult.extra["estimatedFullResetAt"] = AnyCodable(estimatedFullResetAt ?? "")

        return usageResult
    }

    private struct FreeTierUsage {
        let quota: Int
        let used: Int
        let hourlyReplenishment: Double
    }

    private func extractFreeTierUsage(_ html: String) -> FreeTierUsage? {
        let tokens = ["freeTierUsage", "getFreeTierUsage"]
        for token in tokens {
            guard let obj = extractObjectAfterToken(token, in: html) else { continue }
            if let quota = extractNumber("quota", from: obj),
               let used = extractNumber("used", from: obj),
               let hourly = extractDouble("hourlyReplenishment", from: obj) {
                return FreeTierUsage(quota: Int(quota), used: Int(used), hourlyReplenishment: hourly)
            }
        }
        return nil
    }

    private func extractObjectAfterToken(_ token: String, in text: String) -> String? {
        guard let tokenRange = text.range(of: token) else { return nil }
        let afterToken = text[tokenRange.upperBound...]
        guard let braceRange = afterToken.range(of: "{") else { return nil }
        let fromBrace = afterToken[braceRange.lowerBound...]

        var depth = 0
        var inString = false
        var escaped = false
        var endIndex = fromBrace.startIndex

        for (i, char) in fromBrace.enumerated() {
            endIndex = fromBrace.index(fromBrace.startIndex, offsetBy: i)
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                continue
            }
            if char == "\"" { inString = true; continue }
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(fromBrace[fromBrace.startIndex...endIndex])
                }
            }
        }
        return nil
    }

    private func extractNumber(_ key: String, from text: String) -> Double? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))\\b\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    private func extractDouble(_ key: String, from text: String) -> Double? {
        extractNumber(key, from: text)
    }

    private func extractEmail(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\buser\s*:\s*\{[^}]*?\bemail\s*:\s*"([^"]+)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let email = String(html[range])
        return email.contains("@") ? email : nil
    }

    private func formatReset(_ isoString: String) -> String? {
        guard let date = SharedFormatters.parseISO8601(isoString) else { return nil }
        let day = DateFormat.string(from: date, format: "MMM d")
        let time = DateFormat.string(from: date, format: "h:mma")
        return "Resets \(day) at \(time)"
    }

    // MARK: - Cookie Import (mirrors importAmpSessionCookieFromBrowser in browserCookies.js)

    private func importCookieFromBrowser() throws -> String {
        try Self.importCookieFromBrowser(homeDirectory: homeDirectory)
    }

    public static func discoverBrowserSessions(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [BrowserDiscovery.DiscoveredSession] {
        var seen = Set<String>()
        return browserProfiles(home: homeDirectory).compactMap { profile in
            guard FileManager.default.fileExists(atPath: profile.cookiesPath),
                  let cookie = extractAmpCookie(dbPath: profile.cookiesPath, keychainService: profile.keychainService) else {
                return nil
            }

            let header = "\(sessionCookieName)=\(cookie)"
            guard seen.insert(header).inserted else { return nil }
            return BrowserDiscovery.DiscoveredSession(
                browserName: profile.name,
                profileName: profile.name,
                cookieHeader: header,
                accountHint: nil
            )
        }
    }

    private static func importCookieFromBrowser(homeDirectory: String) throws -> String {
        if let session = discoverBrowserSessions(homeDirectory: homeDirectory).first {
            return session.cookieHeader
        }
        throw ProviderError(
            "not_logged_in",
            "No Amp session cookie found. Log in to https://ampcode.com/settings in Chrome/Arc/Edge/Brave, or set AMP_COOKIE_HEADER."
        )
    }

    private static func extractAmpCookie(dbPath: String, keychainService: String) -> String? {
        let tempPath = NSTemporaryDirectory() + "amp_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 10000...99999)).db"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        do { try FileManager.default.copyItem(atPath: dbPath, toPath: tempPath) } catch { return nil }

        // Query using hex() for binary safety
        let domainSQL = Self.cookieDomains.map { "'\($0)'" }.joined(separator: ",")
        let sql = "SELECT hex(encrypted_value), value FROM cookies WHERE name = '\(Self.sessionCookieName)' AND (host_key IN (\(domainSQL))) ORDER BY expires_utc DESC LIMIT 5;"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [tempPath, sql]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let rows = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }

        // Try plain text value first
        for row in rows {
            let parts = row.components(separatedBy: "|")
            if parts.count >= 2, !parts[1].isEmpty, isCookieSafeAscii(parts[1]) {
                return parts[1]
            }
        }

        // Need AES key for encrypted values
        guard let aesKey = chromiumAESKey(keychainService: keychainService) else { return nil }

        for row in rows {
            let hexBlob = row.components(separatedBy: "|").first ?? ""
            if let decrypted = CursorProvider.decryptChromiumCookie(blob: hexBlob, key: aesKey) {
                return decrypted
            }
        }
        return nil
    }

    private static func chromiumAESKey(keychainService: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() } catch { return nil }
        guard task.terminationStatus == 0 else { return nil }
        let password = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !password.isEmpty, let passData = password.data(using: .utf8) else { return nil }

        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: 16)
        let status = derivedKey.withUnsafeMutableBytes { dkPtr in
            passData.withUnsafeBytes { pPtr in
                salt.withUnsafeBytes { sPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pPtr.baseAddress, passData.count,
                                        sPtr.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                        1003, dkPtr.baseAddress, 16)
                }
            }
        }
        return status == kCCSuccess ? derivedKey : nil
    }

    private static func isCookieSafeAscii(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { c in
            let v = c.value
            return v == 0x21 || (v >= 0x23 && v <= 0x2b) || (v >= 0x2d && v <= 0x3a)
                || (v >= 0x3c && v <= 0x5b) || (v >= 0x5d && v <= 0x7e)
        }
    }
}
