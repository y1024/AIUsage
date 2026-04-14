import AppKit
import Foundation
import QuotaBackend

enum ProviderAuthManager {
    static func plan(for providerId: String) -> ProviderAuthPlan {
        switch providerId {
        case "cursor":
            return ProviderAuthPlan(
                titleEn: "Connect a Cursor account",
                titleZh: "连接 Cursor 账号",
                summaryEn: "Sign in inside the embedded browser and AIUsage will start monitoring that Cursor account immediately.",
                summaryZh: "直接在内置浏览器里登录，AIUsage 会立刻开始监控这个 Cursor 账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: true
            )
        case "amp":
            return ProviderAuthPlan(
                titleEn: "Connect an Amp account",
                titleZh: "连接 Amp 账号",
                summaryEn: "Use the embedded web login and AIUsage will connect that Amp account as its own monitored account.",
                summaryZh: "使用内置网页登录后，AIUsage 会把这个 Amp 账号接成独立的监控账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: true
            )
        case "codex":
            return ProviderAuthPlan(
                titleEn: "Connect a Codex account",
                titleZh: "连接 Codex 账号",
                summaryEn: "AIUsage can start an isolated ChatGPT sign-in just for this Codex account, show the official OpenAI page inside the app, and save the finished login as a separate monitored account automatically.",
                summaryZh: "AIUsage 会为这个 Codex 账号启动一条隔离的 ChatGPT 登录流程，在应用内展示 OpenAI 官方登录页，并在完成后自动保存成独立的监控账号。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "codex-login",
                        titleEn: "Continue with ChatGPT",
                        titleZh: "使用 ChatGPT 继续",
                        subtitleEn: "AIUsage opens the official OpenAI sign-in page in a secure window and connects the account automatically after login.",
                        subtitleZh: "AIUsage 会在安全窗口中打开 OpenAI 官方登录页，并在登录完成后自动接入这个账号。",
                        kind: .runTerminal(command: "codex login")
                    ),
                    ProviderAuthLaunchAction(
                        id: "codex-docs",
                        titleEn: "Open Official Login Guide",
                        titleZh: "打开官方登录说明",
                        subtitleEn: "Read the Codex CLI quickstart if you want the official ChatGPT login notes.",
                        subtitleZh: "如果想看 OpenAI 官方的 ChatGPT 登录说明，可以打开 Codex CLI quickstart。",
                        kind: .openURL(URL(string: "https://github.com/openai/codex#using-codex-with-your-chatgpt-plan")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "copilot":
            return ProviderAuthPlan(
                titleEn: "Connect a GitHub Copilot account",
                titleZh: "连接 GitHub Copilot 账号",
                summaryEn: "Run GitHub's official web login once. AIUsage will detect the resulting GitHub CLI session below and connect it as its own monitored account.",
                summaryZh: "先走一次 GitHub 官方网页登录。AIUsage 会在下方发现这个 GitHub CLI 会话，并把它接成独立监控账号。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "copilot-gh-login",
                        titleEn: "Run GitHub Web Login",
                        titleZh: "运行 GitHub 网页登录",
                        subtitleEn: "Open Terminal and run gh auth login in browser mode.",
                        subtitleZh: "打开终端并以网页模式执行 gh auth login。",
                        kind: .runTerminal(command: "gh auth login -h github.com -p https -w")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "antigravity":
            return ProviderAuthPlan(
                titleEn: "Connect an Antigravity account",
                titleZh: "连接 Antigravity 账号",
                summaryEn: "Open Antigravity and sign in. AIUsage will detect each account session below so you can connect it with one click.",
                summaryZh: "打开 Antigravity 并完成登录。AIUsage 会在下方检测到每个账号会话，你可以一键连接。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "antigravity-app",
                        titleEn: "Open Antigravity",
                        titleZh: "打开 Antigravity",
                        subtitleEn: "Launch the Antigravity app to sign in with another account.",
                        subtitleZh: "打开 Antigravity 应用，用另一个账号完成登录。",
                        kind: .openApp(bundleIdentifier: "com.google.antigravity")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "kiro":
            return ProviderAuthPlan(
                titleEn: "Connect a Kiro account",
                titleZh: "连接 Kiro 账号",
                summaryEn: "Open Kiro and complete sign-in. AIUsage will detect the new Kiro session below and keep it monitoring even after you switch accounts later.",
                summaryZh: "打开 Kiro 并完成登录。AIUsage 会在下方发现新的 Kiro 会话，并在你之后切换账号时继续监控它。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "kiro-app",
                        titleEn: "Open Kiro",
                        titleZh: "打开 Kiro",
                        subtitleEn: "Launch the Kiro desktop app to complete sign-in.",
                        subtitleZh: "打开 Kiro 桌面应用完成登录。",
                        kind: .openApp(bundleIdentifier: "dev.kiro.desktop")
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "gemini":
            return ProviderAuthPlan(
                titleEn: "Connect a Gemini CLI account",
                titleZh: "连接 Gemini CLI 账号",
                summaryEn: "AIUsage opens Gemini's official Google sign-in in your browser, receives the OAuth callback itself, and saves that account as a monitored Gemini CLI login automatically.",
                summaryZh: "AIUsage 会直接在浏览器中打开 Gemini 官方 Google 登录页，自己接收 OAuth 回调，并把这个账号自动保存成可监控的 Gemini CLI 登录。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "gemini-login",
                        titleEn: "Continue with Google",
                        titleZh: "使用 Google 继续",
                        subtitleEn: "AIUsage opens the official Google sign-in in your browser and connects the Gemini CLI account automatically after authorization.",
                        subtitleZh: "AIUsage 会在浏览器中打开 Google 官方登录页，并在授权完成后自动接入这个 Gemini CLI 账号。",
                        kind: .runTerminal(command: "gemini")
                    ),
                    ProviderAuthLaunchAction(
                        id: "gemini-docs",
                        titleEn: "Open Official Auth Guide",
                        titleZh: "打开官方认证说明",
                        subtitleEn: "Check Gemini CLI's official authentication guide if you need project or account guidance.",
                        subtitleZh: "如果需要确认项目或账号要求，可以查看 Gemini CLI 官方认证说明。",
                        kind: .openURL(URL(string: "https://geminicli.com/docs/get-started/authentication/")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        case "droid":
            return ProviderAuthPlan(
                titleEn: "Connect a Droid account",
                titleZh: "连接 Droid 账号",
                summaryEn: "Open Factory if you need to switch accounts first. AIUsage reads Factory's current local login, imports it as its own managed Droid account, and keeps it refreshable after restart.",
                summaryZh: "如果需要切换账号，先打开 Factory 完成登录。AIUsage 会读取当前本地登录态，把它导入成自己管理的 Droid 账号，并在重启后继续正常刷新。",
                launchActions: [
                    ProviderAuthLaunchAction(
                        id: "droid-site",
                        titleEn: "Open Factory",
                        titleZh: "打开 Factory",
                        subtitleEn: "Open the official Droid website to switch or complete the browser login first.",
                        subtitleZh: "打开 Droid 官方网站，先在浏览器里切换或完成登录。",
                        kind: .openURL(URL(string: "https://app.factory.ai")!)
                    )
                ],
                supportsEmbeddedWebLogin: false
            )
        default:
            return ProviderAuthPlan(
                titleEn: "Connect account",
                titleZh: "连接账号",
                summaryEn: "Finish the provider's normal sign-in flow first, then AIUsage can connect and monitor that account.",
                summaryZh: "先完成服务商自己的正常登录流程，之后 AIUsage 才能连接并监控这个账号。",
                launchActions: [],
                supportsEmbeddedWebLogin: false
            )
        }
    }

    static func makeCodexCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let json = loadJSONObject(at: path)
        let tokens = json?["tokens"] as? [String: Any]
        let email = jwtEmail(from: stringValue(tokens?["id_token"]))
            ?? jwtEmail(from: stringValue(json?["id_token"]))
            ?? stringValue(json?["email"])
        let fingerprint: String?
        if let json {
            fingerprint = sessionFingerprint(from: json, preferredKeys: ["account_id", "email"])
        } else {
            fingerprint = nil
        }

        return ProviderAuthCandidate(
            id: "codex-oauth:\(path)",
            providerId: "codex",
            sourceIdentifier: "codex-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Codex ChatGPT Login",
            subtitle: "Fresh login",
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func discoverCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let rawCandidates: [ProviderAuthCandidate]

        switch providerId {
        case "codex":
            rawCandidates = codexCandidates()
        case "cursor":
            rawCandidates = cursorCandidates()
        case "amp":
            rawCandidates = ampCandidates()
        case "copilot":
            rawCandidates = copilotCandidates()
        case "antigravity":
            rawCandidates = antigravityCandidates()
        case "kiro":
            rawCandidates = kiroCandidates()
        case "gemini":
            rawCandidates = geminiCandidates()
        case "droid":
            rawCandidates = droidCandidates()
        default:
            rawCandidates = []
        }

        return rawCandidates.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func unmanagedCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let monitored = monitoredSessions(for: providerId)
        return discoverCandidates(for: providerId).filter { !isCandidateManaged($0, monitored: monitored) }
    }

    static func preferredQuickConnectCandidate(for providerId: String) -> ProviderAuthCandidate? {
        let monitored = monitoredSessions(for: providerId)
        let prioritized: [ProviderAuthCandidate]

        switch providerId {
        case "droid":
            prioritized = droidCandidates()
        default:
            prioritized = discoverCandidates(for: providerId)
        }

        return prioritized.first { !isCandidateManaged($0, monitored: monitored) }
    }

    static func monitoredSessions(for providerId: String) -> ProviderMonitoredSessionIndex {
        let credentials = AccountCredentialStore.shared.loadCredentials(for: providerId)
        return ProviderMonitoredSessionIndex(
            sourceIdentifiers: Set(credentials.compactMap { credential in
                guard sourceIdentifierIsStableIdentity(for: credential) else { return nil }
                return credential.metadata["sourceIdentifier"]
                    ?? credential.metadata["sourcePath"]
                    ?? authFileSourceIdentifier(for: credential.credential, authMethod: credential.authMethod)
            }),
            sessionFingerprints: Set(credentials.compactMap { credential in
                normalizedHandle(credential.metadata["sessionFingerprint"])
            }),
            accountHandles: Set(credentials.compactMap { credential in
                normalizedHandle(
                    credential.metadata["accountHandle"]
                        ?? credential.metadata["accountEmail"]
                        ?? credential.accountLabel
                )
            })
        )
    }

    static func launch(_ action: ProviderAuthLaunchAction) throws {
        switch action.kind {
        case .openApp(let bundleIdentifier):
            try runOpen(arguments: ["-b", bundleIdentifier])
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .revealPath(let path):
            let expanded = expand(path)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
        case .runTerminal(let command):
            try launchTerminal(command: command)
        }
    }

    static func authenticateCandidate(_ candidate: ProviderAuthCandidate) async throws -> (AccountCredential, ProviderUsage) {
        var copiedPath: String?
        do {
            let credentialValue: String
            if candidate.authMethod == .authFile, candidate.shouldCopyFile, let sourcePath = candidate.sourcePath {
                copiedPath = try copyImportedAuthFile(
                    providerId: candidate.providerId,
                    sourcePath: sourcePath,
                    suggestedName: candidate.title
                )
                credentialValue = copiedPath ?? sourcePath
            } else {
                credentialValue = candidate.credentialValue
            }

            let storedSourcePath: String
            if (candidate.providerId == "codex" || candidate.providerId == "gemini" || candidate.providerId == "kiro"), let copiedPath {
                // Codex, Gemini, and Kiro imports may originate from singleton session
                // files (for example ~/.codex/auth.json, ~/.gemini/oauth_creds.json, or
                // Kiro's IDE cache). Once imported, the managed copy must remain the
                // source of truth so later logins do not overwrite this saved account.
                storedSourcePath = copiedPath
            } else {
                storedSourcePath = candidate.sourcePath ?? ""
            }

            let credential = AccountCredential(
                providerId: candidate.providerId,
                accountLabel: candidate.title.nilIfBlank,
                authMethod: candidate.authMethod,
                credential: credentialValue,
                metadata: [
                    "sourceIdentifier": candidate.sourceIdentifier,
                    "sourcePath": storedSourcePath,
                    "importedAt": SharedFormatters.iso8601String(from: Date()),
                    "sessionFingerprint": candidate.sessionFingerprint ?? "",
                    "identityScope": candidate.identityScope.rawValue
                ]
            )

            let usage = try await validate(credential: credential)
            return (credential, usage)
        } catch {
            if let copiedPath {
                try? FileManager.default.removeItem(atPath: copiedPath)
            }
            throw error
        }
    }

    static func authenticateManualCredential(
        providerId: String,
        authMethod: AuthMethod,
        value: String,
        suggestedLabel: String? = nil
    ) async throws -> (AccountCredential, ProviderUsage) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError("missing_credential", "Credential value is empty.")
        }

        let credential = AccountCredential(
            providerId: providerId,
            accountLabel: suggestedLabel?.nilIfBlank,
            authMethod: authMethod,
            credential: trimmed,
            metadata: [
                "sourceIdentifier": "manual:\(authMethod.rawValue):\(UUID().uuidString)",
                "importedAt": SharedFormatters.iso8601String(from: Date()),
                "identityScope": ProviderAuthCandidate.IdentityScope.sharedSource.rawValue
            ]
        )
        let usage = try await validate(credential: credential)
        return (credential, usage)
    }

    // MARK: - Validation

    private static func validate(credential: AccountCredential) async throws -> ProviderUsage {
        guard let provider = ProviderRegistry.provider(for: credential.providerId) as? any CredentialAcceptingProvider else {
            throw ProviderError("unsupported_provider", "\(credential.providerId) does not accept imported credentials.")
        }
        return try await provider.fetchUsage(with: credential)
    }

    // MARK: - Import Persistence

    private static func copyImportedAuthFile(
        providerId: String,
        sourcePath: String,
        suggestedName: String
    ) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let directory = try managedImportDirectory(for: providerId)
        let stem = sanitizedFilenameStem(suggestedName)
        let filename = "\(stem)-\(DateFormat.string(from: Date(), format: "yyyyMMdd-HHmmss")).json"
        let destinationURL = directory.appendingPathComponent(filename)

        let data: Data
        if providerId == "droid",
           let normalizedData = DroidProvider.managedSessionData(from: sourcePath) {
            data = normalizedData
        } else {
            data = try Data(contentsOf: sourceURL)
        }
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL.path
    }

    private static func managedImportDirectory(for providerId: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("AuthImports", isDirectory: true)
            .appendingPathComponent(providerId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Launch Helpers

    private static func runOpen(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderError("launch_failed", "Could not launch the requested sign-in flow.")
        }
    }

    private static func launchTerminal(command: String) throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let scriptURL = tempDirectory.appendingPathComponent("aiusage-auth-\(UUID().uuidString).command")
        let script = """
        #!/bin/zsh
        \(command)
        printf "\\n\\nPress any key to close..."
        read -k 1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        try runOpen(arguments: ["-a", "Terminal", scriptURL.path])
    }
}
