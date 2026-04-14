import Foundation
import Combine
import QuotaBackend

// MARK: - Provider Account Activation
// Manages CLI auth file switching for Codex and Gemini: detection from disk,
// activation from managed/proxy sources, format normalization, and UserDefaults persistence.

final class ProviderActivationManager: ObservableObject {
    static let shared = ProviderActivationManager()

    static let activatableProviders: Set<String> = ["codex", "gemini"]

    @Published var activeProviderAccountIds: [String: String] = {
        guard let data = UserDefaults.standard.data(forKey: "activeProviderAccountIds"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            if let legacyCodex = UserDefaults.standard.string(forKey: "activeCodexAccountId") {
                return ["codex": legacyCodex]
            }
            return [:]
        }
        return dict
    }()

    @Published var activationResult: ActivationResult?
    @Published var codexActivationResult: CodexActivationResult?

    let accountStore = AccountStore.shared
    let settings = AppSettings.shared

    var activeCodexAccountId: String? {
        get { activeProviderAccountIds["codex"] }
        set {
            activeProviderAccountIds["codex"] = newValue
            persistActiveIds()
        }
    }

    enum CodexActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    enum ActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    private init() {}

    private func persistActiveIds() {
        if let data = try? JSONEncoder().encode(activeProviderAccountIds) {
            UserDefaults.standard.set(data, forKey: "activeProviderAccountIds")
        }
    }

    func canActivateProvider(_ providerId: String) -> Bool {
        Self.activatableProviders.contains(providerId)
    }

    func activateAccount(entry: ProviderAccountEntry) throws {
        switch entry.providerId {
        case "codex":
            try activateCodexAccount(entry: entry)
        case "gemini":
            try activateGeminiAccount(entry: entry)
        default:
            break
        }
    }

    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool {
        guard let activeId = activeProviderAccountIds[entry.providerId]?.lowercased() else { return false }
        let candidates = [
            entry.storedAccount?.accountId,
            entry.storedAccount?.email,
            entry.liveProvider?.accountId,
            entry.liveProvider?.accountLabel,
            entry.accountEmail
        ].compactMap { $0?.lowercased().nilIfBlank }
        return candidates.contains(activeId)
    }

    func isActiveCodexAccount(_ entry: ProviderAccountEntry) -> Bool {
        isActiveAccount(entry)
    }

    // MARK: Codex activation

    func activateCodexAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let codexDir = NSString(string: "~/.codex").expandingTildeInPath
        let targetPath = "\(codexDir)/auth.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel
        let accountId = entry.storedAccount?.accountId
            ?? entry.liveProvider?.accountId

        let resolved = resolveCliProxyOrManagedSource(prefix: "codex", email: email, entry: entry)
        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            codexActivationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToCodexNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: nativeData, fm: fm)

        let newActiveId = email ?? accountId
        activeProviderAccountIds["codex"] = newActiveId
        persistActiveIds()

        let label = email ?? accountId ?? "Codex"
        let msg = settings.t("Switched to \(label)", "已切换到 \(label)")
        activationResult = .success(msg)
        codexActivationResult = .success(msg)
    }

    // MARK: Gemini / Antigravity activation

    func activateGeminiAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let geminiDir = NSString(string: "~/.gemini").expandingTildeInPath
        let oauthCredsPath = "\(geminiDir)/oauth_creds.json"
        let googleAccountsPath = "\(geminiDir)/google_accounts.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel

        let proxyPrefix = entry.providerId == "antigravity" ? "antigravity" : "gemini"
        let resolved = resolveCliProxyOrManagedSource(prefix: proxyPrefix, email: email, entry: entry)

        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToGeminiNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: geminiDir, targetPath: oauthCredsPath, data: nativeData, fm: fm)

        if let email {
            try updateGeminiActiveAccount(googleAccountsPath: googleAccountsPath, email: email, fm: fm)
        }

        activeProviderAccountIds["gemini"] = email
        persistActiveIds()

        let label = email ?? "Account"
        let msg = settings.t("Switched to \(label)", "已切换到 \(label)")
        activationResult = .success(msg)
    }

    private func convertToGeminiNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["refresh_token"] != nil, json["scope"] != nil {
            return data
        }

        if let tokenDict = json["token"] as? [String: Any], let refreshToken = tokenDict["refresh_token"] as? String {
            var native: [String: Any] = [
                "refresh_token": refreshToken,
                "token_type": "Bearer",
                "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform"
            ]
            if let accessToken = tokenDict["access_token"] as? String { native["access_token"] = accessToken }
            if let idToken = tokenDict["id_token"] as? String { native["id_token"] = idToken }
            if let expiryDate = tokenDict["expiry_date"] as? Int { native["expiry_date"] = expiryDate }
            if let clientId = tokenDict["client_id"] as? String { native["client_id"] = clientId }
            if let clientSecret = tokenDict["client_secret"] as? String { native["client_secret"] = clientSecret }
            if let email = json["email"] as? String { native["email"] = email }
            return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
        }

        if let refreshToken = json["refresh_token"] as? String {
            var native: [String: Any] = [
                "refresh_token": refreshToken,
                "token_type": "Bearer",
                "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloud-platform"
            ]
            if let accessToken = json["access_token"] as? String { native["access_token"] = accessToken }
            if let idToken = json["id_token"] as? String { native["id_token"] = idToken }
            if let expiryDate = json["expiry_date"] as? Int { native["expiry_date"] = expiryDate }
            if let clientId = json["client_id"] as? String { native["client_id"] = clientId }
            if let clientSecret = json["client_secret"] as? String { native["client_secret"] = clientSecret }
            if let email = json["email"] as? String { native["email"] = email }
            return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
        }

        return data
    }

    private func updateGeminiActiveAccount(googleAccountsPath: String, email: String, fm: FileManager) throws {
        var accounts: [String: Any]
        if let data = fm.contents(atPath: googleAccountsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accounts = json
        } else {
            accounts = [:]
        }

        let previousActive = accounts["active"] as? String
        var oldList = (accounts["old"] as? [String]) ?? []

        if let previousActive, previousActive != email, !oldList.contains(previousActive) {
            oldList.append(previousActive)
        }
        oldList.removeAll { $0 == email }

        accounts["active"] = email
        accounts["old"] = oldList

        let data = try JSONSerialization.data(withJSONObject: accounts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: googleAccountsPath), options: .atomic)
    }

    // MARK: Codex format conversion

    private func convertToCodexNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["tokens"] is [String: Any], json["auth_mode"] != nil {
            return data
        }

        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            return data
        }

        var native: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": json["account_id"] ?? "",
                "id_token": json["id_token"] ?? ""
            ] as [String: Any],
            "last_refresh": json["last_refresh"] ?? SharedFormatters.iso8601String(from: Date())
        ]
        if let email = json["email"] as? String, !email.isEmpty {
            native["email"] = email
        }
        native["OPENAI_API_KEY"] = NSNull()

        return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Shared helpers

    private func writeAuthFileWithBackup(targetDir: String, targetPath: String, data: Data, fm: FileManager) throws {
        if !fm.fileExists(atPath: targetDir) {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        let backupPath = "\(targetPath).bak"
        if fm.fileExists(atPath: targetPath) {
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: targetPath, toPath: backupPath)
        }

        do {
            try data.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
        } catch {
            if fm.fileExists(atPath: backupPath) {
                try? fm.removeItem(atPath: targetPath)
                try? fm.copyItem(atPath: backupPath, toPath: targetPath)
            }
            let redactedError = SensitiveDataRedactor.redactedMessage(for: error)
            let msg = settings.t("Switch failed: \(redactedError)", "切换失败：\(redactedError)")
            activationResult = .failure(msg)
            throw error
        }
    }

    private func resolveCliProxyOrManagedSource(prefix: String, email: String?, entry: ProviderAccountEntry) -> String? {
        let fm = FileManager.default
        let proxyDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath

        if let email {
            if let freshPath = freshestCliProxyFile(dir: proxyDir, prefix: prefix, email: email, fm: fm) {
                return freshPath
            }
        }

        let credentials = accountStore.matchingCredentials(for: entry)
        if let credential = credentials.first {
            let candidatePaths: [String?] = [
                credential.authMethod == .authFile ? credential.credential : nil,
                credential.metadata["sourcePath"]
            ]
            for p in candidatePaths.compactMap({ $0?.nilIfBlank }) {
                let expanded = NSString(string: p).expandingTildeInPath
                if fm.fileExists(atPath: expanded) { return expanded }
            }
        }

        return nil
    }

    private func freshestCliProxyFile(dir: String, prefix: String, email: String, fm: FileManager) -> String? {
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let emailLower = email.lowercased()
        let matching = files.filter {
            $0.hasPrefix("\(prefix)-") && $0.hasSuffix(".json") && $0.lowercased().contains(emailLower)
        }
        guard !matching.isEmpty else { return nil }

        var best: (path: String, date: Date)?
        for file in matching {
            let fullPath = "\(dir)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if let current = best, modDate > current.date {
                best = (fullPath, modDate)
            } else if best == nil {
                best = (fullPath, modDate)
            }
        }
        return best?.path
    }

    // MARK: Detection

    func detectActiveCodexAccount() {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var email = json["email"] as? String
        let tokens = json["tokens"] as? [String: Any]
        let accountId = (tokens?["account_id"] as? String)
            ?? (tokens?["accountId"] as? String)
            ?? (json["account_id"] as? String)
            ?? (json["accountId"] as? String)

        if email == nil, let uuid = accountId {
            email = resolveCodexEmailFromProxy(accountId: uuid)
        }

        let detectedId = email ?? accountId
        if let detectedId, detectedId != activeProviderAccountIds["codex"] {
            activeProviderAccountIds["codex"] = detectedId
            persistActiveIds()
        }
    }

    private func resolveCodexEmailFromProxy(accountId: String) -> String? {
        let proxyDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: proxyDir) else { return nil }
        for file in files where file.hasPrefix("codex-") && file.hasSuffix(".json") {
            let path = "\(proxyDir)/\(file)"
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fileAccountId = json["account_id"] as? String,
                  fileAccountId == accountId,
                  let email = json["email"] as? String else { continue }
            return email
        }
        return nil
    }

    func detectActiveGeminiAccount() {
        let googleAccountsPath = NSString(string: "~/.gemini/google_accounts.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: googleAccountsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["active"] as? String else {
            return
        }
        if active != activeProviderAccountIds["gemini"] {
            activeProviderAccountIds["gemini"] = active
            persistActiveIds()
        }
    }
}
