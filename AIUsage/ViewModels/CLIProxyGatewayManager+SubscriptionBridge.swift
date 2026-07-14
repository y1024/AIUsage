import Foundation
import os
import QuotaBackend

// MARK: - CPA → 订阅账号桥接
// 把 CPA auth 池中的账号添加到「订阅账号」。已存在则跳过（按 accountId / 指纹去重）。
// 不反向删除 CPA 副本。

private let subscriptionBridgeLog = Logger(
    subsystem: "com.aiusage.desktop",
    category: "CLIProxySubscriptionBridge"
)

enum CLIProxySubscriptionAddOutcome: Equatable {
    case added(displayName: String)
    case alreadyPresent(displayName: String)
    case unsupported(providerID: String)
    case failed(String)
}

@MainActor
extension CLIProxyGatewayManager {
    /// 将单个 CPA auth 文件加入订阅账号；已存在则不去重写入。
    func addAuthFileToSubscriptionAccounts(_ file: CLIProxyAuthFile) async -> CLIProxySubscriptionAddOutcome {
        let providerID = file.gatewayProviderID.lowercased()
        guard Self.subscriptionImportableProviderIDs.contains(providerID) else {
            return .unsupported(providerID: file.gatewayProviderID)
        }

        guard let path = file.path, !path.isEmpty,
              FileManager.default.isReadableFile(atPath: path) else {
            return .failed(L("The CPA auth file is missing or unreadable.", "CPA 认证文件不存在或无法读取。"))
        }
        let authURL = URL(fileURLWithPath: path)

        let candidate: ProviderAuthCandidate
        switch providerID {
        case "codex":
            candidate = ProviderAuthManager.makeCodexCandidate(authFileURL: authURL)
        default:
            if let match = ProviderAuthManager.discoverCandidates(for: providerID)
                .first(where: { $0.sourcePath == authURL.path }) {
                candidate = match
            } else {
                return .unsupported(providerID: file.gatewayProviderID)
            }
        }

        let label = candidate.title
        if subscriptionAlreadyContains(candidate: candidate, providerID: providerID) {
            return .alreadyPresent(displayName: label)
        }

        do {
            let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
            try AppState.shared.registerAuthenticatedCredential(credential, usage: usage, note: nil)
            _ = await ProviderRefreshCoordinator.shared.fetchSingleProvider(providerID)
            subscriptionBridgeLog.notice(
                "Added CPA auth to subscription accounts provider=\(providerID, privacy: .public) label=\(label, privacy: .public)"
            )
            return .added(displayName: label)
        } catch {
            let message = SensitiveDataRedactor.redactedMessage(for: error)
            subscriptionBridgeLog.error("Add CPA auth to subscription failed: \(message, privacy: .public)")
            return .failed(message)
        }
    }

    /// 启动时：把 AuthImports/codex 中尚未出现在订阅列表的账号补回（跳过永久删除）。
    func backfillSubscriptionAccountsFromAuthImportsIfNeeded() async {
        let root: URL
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            root = base
                .appendingPathComponent("AIUsage", isDirectory: true)
                .appendingPathComponent("AuthImports", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
        } catch {
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var didAdd = false
        for url in files where url.pathExtension.lowercased() == "json" {
            let candidate = ProviderAuthManager.makeCodexCandidate(authFileURL: url)
            if subscriptionAlreadyContains(candidate: candidate, providerID: "codex") {
                continue
            }
            do {
                let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
                try AppState.shared.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                didAdd = true
                subscriptionBridgeLog.notice(
                    "Backfilled AuthImports Codex into subscription: \(candidate.title, privacy: .public)"
                )
            } catch {
                subscriptionBridgeLog.error(
                    "AuthImports backfill skipped: \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)"
                )
            }
        }
        if didAdd {
            _ = await ProviderRefreshCoordinator.shared.fetchSingleProvider("codex")
        }
    }

    private static let subscriptionImportableProviderIDs: Set<String> = ["codex"]

    private func subscriptionAlreadyContains(
        candidate: ProviderAuthCandidate,
        providerID: String
    ) -> Bool {
        let registry = AppState.shared.accountStore.accountRegistry
            .filter { $0.providerId.lowercased() == providerID }
        let path = candidate.sourcePath?.lowercased()
        if let path, registry.contains(where: {
            $0.isPermanentlyRemoved && ($0.sourceFilePath?.lowercased() == path)
        }) {
            return true
        }

        let credentials = AccountCredentialStore.shared.loadAllCredentials()
            .filter { $0.providerId.lowercased() == providerID }
        let credentialByID = Dictionary(uniqueKeysWithValues: credentials.map { ($0.id, $0) })

        let candidateEmail = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidateFingerprint = candidate.sessionFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fileAccountId: String? = {
            guard let sourcePath = candidate.sourcePath,
                  let json = ProviderAuthManager.loadJSONObject(at: sourcePath),
                  let accountId = (json["account_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  !accountId.isEmpty else { return nil }
            return accountId
        }()

        for account in registry where !account.isHidden && !account.isPermanentlyRemoved {
            if let fingerprint = candidateFingerprint,
               let credID = account.credentialId,
               let cred = credentialByID[credID],
               let existing = cred.metadata["sessionFingerprint"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               existing == fingerprint {
                return true
            }
            if let fileAccountId, let accountId = account.normalizedAccountId, fileAccountId == accountId {
                return true
            }
            if fileAccountId == nil,
               !candidateEmail.isEmpty,
               account.normalizedEmail == candidateEmail {
                return true
            }
        }

        if let path {
            let normalizedPath = AccountCredentialStore.normalizedAuthFilePath(path)
            for cred in credentials {
                if AccountCredentialStore.normalizedAuthFilePath(cred.credential) == normalizedPath {
                    return true
                }
            }
        }
        return false
    }
}
