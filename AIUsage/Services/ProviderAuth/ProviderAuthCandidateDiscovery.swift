import Foundation
import QuotaBackend

extension ProviderAuthManager {
    // MARK: - Candidate Discovery

    internal static func codexCandidates() -> [ProviderAuthCandidate] {
        var candidates = authFileCandidates(
            providerId: "codex",
            directory: "~/.cli-proxy-api",
            prefix: "codex-"
        ) { url, json in
            let email = stringValue(json["email"])
                ?? jwtEmail(from: stringValue(json["id_token"]))
            return ProviderAuthCandidate(
                id: "codex:\(canonicalPath(url.path))",
                providerId: "codex",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["account_id", "email"]),
                title: email ?? readableFilename(url),
                subtitle: "CLI Proxy API",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .accountScoped
            )
        }

        let defaultURL = URL(fileURLWithPath: expand("~/.codex/auth.json"))
        if FileManager.default.fileExists(atPath: defaultURL.path),
           let json = loadJSONObject(at: defaultURL.path) {
            let email = jwtEmail(from: stringValue((json["tokens"] as? [String: Any])?["id_token"]))
                ?? stringValue(json["email"])
            candidates.append(
                ProviderAuthCandidate(
                    id: "codex:\(canonicalPath(defaultURL.path))",
                    providerId: "codex",
                    sourceIdentifier: "file:\(canonicalPath(defaultURL.path))",
                    sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["account_id", "email"]),
                    title: email ?? "Current ChatGPT login",
                    subtitle: "Current ChatGPT login",
                    detail: compactDetail(parts: [displayPath(defaultURL.path), formattedDate(modificationDate(for: defaultURL))]),
                    modifiedAt: modificationDate(for: defaultURL),
                    authMethod: .authFile,
                    credentialValue: defaultURL.path,
                    sourcePath: defaultURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource
                )
            )
        }

        return deduplicated(candidates)
    }

    internal static func copilotCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        if let session = currentGitHubCLISession() {
            candidates.append(
                ProviderAuthCandidate(
                    id: "copilot:\(session.sourceIdentifier)",
                    providerId: "copilot",
                    sourceIdentifier: session.sourceIdentifier,
                    sessionFingerprint: session.sessionFingerprint,
                    title: session.label,
                    subtitle: "GitHub CLI",
                    detail: session.detail,
                    modifiedAt: nil,
                    authMethod: .token,
                    credentialValue: session.token,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .accountScoped
                )
            )
        }

        candidates.append(contentsOf: authFileCandidates(
            providerId: "copilot",
            directory: "~/.cli-proxy-api",
            prefix: "github-copilot-"
        ) { url, json in
            guard let token = stringValue(json["access_token"]) else { return nil }
            let username = stringValue(json["username"]) ?? readableFilename(url)
            return ProviderAuthCandidate(
                id: "copilot:\(canonicalPath(url.path))",
                providerId: "copilot",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["username", "login"]),
                title: username,
                subtitle: "Saved token file",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .token,
                credentialValue: token,
                sourcePath: url.path,
                shouldCopyFile: false,
                identityScope: .accountScoped
            )
        })

        return deduplicated(candidates)
    }

    internal static func antigravityCandidates() -> [ProviderAuthCandidate] {
        authFileCandidates(providerId: "antigravity", directory: "~/.cli-proxy-api", prefix: "antigravity-") { url, json in
            let email = stringValue(json["email"]) ?? readableFilename(url)
            return ProviderAuthCandidate(
                id: "antigravity:\(canonicalPath(url.path))",
                providerId: "antigravity",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email", "account_id"]),
                title: email,
                subtitle: "CLI Proxy API",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .accountScoped
            )
        }
    }

    internal static func kiroCandidates() -> [ProviderAuthCandidate] {
        var candidates = authFileCandidates(providerId: "kiro", directory: "~/.cli-proxy-api", prefix: "kiro-") { url, json in
            let email = stringValue(json["email"])
            let provider = stringValue(json["provider"])
            let title = email ?? (provider.map { "Kiro (\($0))" }) ?? readableFilename(url)
            return ProviderAuthCandidate(
                id: "kiro:\(canonicalPath(url.path))",
                providerId: "kiro",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email", "userId", "accountEmail"]),
                title: title,
                subtitle: "CLI Proxy API",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .accountScoped
            )
        }

        let ideURL = URL(fileURLWithPath: expand("~/.aws/sso/cache/kiro-auth-token.json"))
        if FileManager.default.fileExists(atPath: ideURL.path),
           let json = loadJSONObject(at: ideURL.path) {
            let provider = stringValue(json["provider"]) ?? "IDE"
            candidates.append(
                ProviderAuthCandidate(
                    id: "kiro:\(canonicalPath(ideURL.path))",
                    providerId: "kiro",
                    sourceIdentifier: "file:\(canonicalPath(ideURL.path))",
                    sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email", "userId", "accountEmail"]),
                    title: "Kiro (\(provider))",
                    subtitle: "IDE session cache",
                    detail: compactDetail(parts: [displayPath(ideURL.path), formattedDate(modificationDate(for: ideURL))]),
                    modifiedAt: modificationDate(for: ideURL),
                    authMethod: .authFile,
                    credentialValue: ideURL.path,
                    sourcePath: ideURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource
                )
            )
        }

        return deduplicated(candidates)
    }

    internal static func geminiCandidates() -> [ProviderAuthCandidate] {
        let oauthURL = URL(fileURLWithPath: expand("~/.gemini/oauth_creds.json"))
        guard FileManager.default.fileExists(atPath: oauthURL.path),
              let json = loadJSONObject(at: oauthURL.path) else {
            return []
        }

        let email = stringValue(json["email"])
            ?? jwtEmail(from: stringValue(json["id_token"]))
            ?? "Current Gemini CLI session"
        return [
            ProviderAuthCandidate(
                id: "gemini:\(canonicalPath(oauthURL.path))",
                providerId: "gemini",
                sourceIdentifier: "file:\(canonicalPath(oauthURL.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email"]),
                title: email,
                subtitle: "Current Gemini CLI login",
                detail: compactDetail(parts: [displayPath(oauthURL.path), formattedDate(modificationDate(for: oauthURL))]),
                modifiedAt: modificationDate(for: oauthURL),
                authMethod: .authFile,
                credentialValue: oauthURL.path,
                sourcePath: oauthURL.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        ]
    }

    internal static func droidCandidates() -> [ProviderAuthCandidate] {
        let candidatePaths = [
            "~/.factory/auth.v2.file",
            "~/.factory/auth.v2.keyring",
            "~/.factory/auth.encrypted",
            "~/.config/factory/auth.json",
            "~/.factory/auth.json",
            "~/.config/droid/auth.json"
        ]

        var candidates = candidatePaths.compactMap { rawPath -> ProviderAuthCandidate? in
            let path = expand(rawPath)
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let snapshot = DroidProvider.loadStoredSessionSnapshot(at: url.path) else {
                return nil
            }

            let accessToken = snapshot.accessToken
            let email = jwtEmail(from: accessToken)
            let subject = jwtClaim("sub", from: accessToken)
            let title = email ?? subject ?? "Current Droid login"
            let fingerprint = normalizedHandle(email ?? subject)
                ?? sessionFingerprint(
                    from: [
                        "access_token": accessToken as Any,
                        "refresh_token": snapshot.refreshToken as Any
                    ],
                    preferredKeys: ["access_token", "refresh_token"]
                )

            return ProviderAuthCandidate(
                id: "droid:\(canonicalPath(url.path))",
                providerId: "droid",
                sourceIdentifier: "file:\(canonicalPath(url.path))",
                sessionFingerprint: fingerprint,
                title: title,
                subtitle: "Local Factory login",
                detail: compactDetail(parts: [displayPath(url.path), formattedDate(modificationDate(for: url))]),
                modifiedAt: modificationDate(for: url),
                authMethod: .authFile,
                credentialValue: url.path,
                sourcePath: url.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        }

        candidates.append(contentsOf: DroidProvider.discoverBrowserSessions().map { session in
            let profileLabel = "\(session.browserName) \(session.profileName)"
            let sourceIdentifier = "browser-profile:droid:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
            return ProviderAuthCandidate(
                id: "droid:\(sourceIdentifier)",
                providerId: "droid",
                sourceIdentifier: sourceIdentifier,
                sessionFingerprint: tokenFingerprint(session.cookieHeader),
                title: session.accountHint ?? profileLabel,
                subtitle: "Browser session",
                detail: compactDetail(parts: [profileLabel, "factory.ai"]),
                modifiedAt: nil,
                authMethod: .cookie,
                credentialValue: session.cookieHeader,
                sourcePath: nil,
                shouldCopyFile: false,
                identityScope: .sharedSource
            )
        })

        return deduplicated(candidates)
    }

    internal static func ampCandidates() -> [ProviderAuthCandidate] {
        deduplicated(
            AmpProvider.discoverBrowserSessions().map { session in
                let profileLabel = "\(session.browserName) \(session.profileName)"
                let sourceIdentifier = "browser-profile:amp:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
                return ProviderAuthCandidate(
                    id: "amp:\(sourceIdentifier)",
                    providerId: "amp",
                    sourceIdentifier: sourceIdentifier,
                    sessionFingerprint: tokenFingerprint(session.cookieHeader),
                    title: session.accountHint ?? profileLabel,
                    subtitle: "Browser session",
                    detail: compactDetail(parts: [profileLabel, "ampcode.com"]),
                    modifiedAt: nil,
                    authMethod: .cookie,
                    credentialValue: session.cookieHeader,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .sharedSource
                )
            }
        )
    }

    internal static func cursorCandidates() -> [ProviderAuthCandidate] {
        deduplicated(
            CursorProvider.discoverBrowserSessions().map { session in
                let profileLabel = "\(session.browserName) \(session.profileName)"
                let sourceIdentifier = "browser-profile:cursor:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
                return ProviderAuthCandidate(
                    id: "cursor:\(sourceIdentifier)",
                    providerId: "cursor",
                    sourceIdentifier: sourceIdentifier,
                    sessionFingerprint: tokenFingerprint(session.cookieHeader),
                    title: session.accountHint ?? profileLabel,
                    subtitle: "Browser session",
                    detail: compactDetail(parts: [profileLabel, "cursor.com"]),
                    modifiedAt: nil,
                    authMethod: .cookie,
                    credentialValue: session.cookieHeader,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .sharedSource
                )
            }
        )
    }

    private static func authFileCandidates(
        providerId: String,
        directory: String,
        prefix: String,
        builder: (URL, [String: Any]) -> ProviderAuthCandidate?
    ) -> [ProviderAuthCandidate] {
        let directoryURL = URL(fileURLWithPath: expand(directory), isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .compactMap { url in
                guard let json = loadJSONObject(at: url.path) else { return nil }
                return builder(url, json)
            }
    }
}
