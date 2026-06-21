import Foundation
import Security
import os

public struct AccountCredentialReference: Hashable, Sendable {
    public let providerId: String
    public let credentialId: String

    public init(providerId: String, credentialId: String) {
        self.providerId = providerId
        self.credentialId = credentialId
    }
}

private let credentialLog = Logger(subsystem: "com.aiusage.desktop", category: "CredentialStore")

/// Secure credential store backed by macOS Keychain.
/// Stores AccountCredential objects (cookies, tokens, auth file paths, API keys)
/// per provider+account, enabling multi-account and manual auth flows.
public final class AccountCredentialStore: @unchecked Sendable {
    public static let shared = AccountCredentialStore()

    private static let service = "com.aiusage.desktop.providerCredentials"
    private static let credentialVaultAccount = "__credential_vault_v2__"
    private static let credentialIndexAccount = "__credential_index_v1__"
    private static let managedAuthImportsPathComponent = "/Library/Application Support/AIUsage/AuthImports/"
    private static let keychainAccessibility = kSecAttrAccessibleAfterFirstUnlock
    private let lock = NSLock()
    private var cachedCredentialsByStorageKey: [String: AccountCredential]?
    /// Opaque blobs from other stores folded into the same single keychain item
    /// (e.g. the account registry from SecureAccountVault), so the whole app keeps
    /// exactly one keychain item and at most one "Always Allow" prompt.
    private var cachedAuxiliary: [String: Data] = [:]

    // Ad-hoc signed builds can't satisfy the Data Protection Keychain's
    // entitlement requirement, so DP writes always fail with -34018. Cache that
    // state to avoid repeat warnings. All access goes through `lock` (except the
    // one-time probe in `init`, which runs before the singleton is observable).
    private var dpKeychainUnavailable = false
    private func markDPKeychainUnavailableUnsafe(status: OSStatus) {
        guard !dpKeychainUnavailable else { return }
        dpKeychainUnavailable = true
        credentialLog.info("Data Protection Keychain unavailable (OSStatus \(status)); using legacy keychain. Expected for ad-hoc signed builds.")
    }

    private init() {
        // Decide up front whether this build can use the Data Protection Keychain.
        // DP access from a non-sandboxed macOS app requires a real
        // `keychain-access-groups` entitlement embedded in the signature; ad-hoc /
        // self-signed builds don't have it, so DP writes fail with -34018. Probing
        // the live signature (instead of persisting a flag) keeps this in lockstep
        // with the actual build: a future signed build that embeds the entitlement
        // re-enables DP on its next launch with no stale state to clear.
        if !Self.hasDataProtectionKeychainEntitlement() {
            dpKeychainUnavailable = true
        }
    }

    /// True when the running binary's signature embeds a non-empty
    /// `keychain-access-groups` entitlement — the prerequisite for using the Data
    /// Protection Keychain from a non-sandboxed macOS app.
    private static func hasDataProtectionKeychainEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else {
            return false
        }
        return (value as? [String])?.isEmpty == false
    }

    private struct CredentialIndex: Codable {
        let storageKeys: [String]
    }

    private struct CredentialVault: Codable {
        let credentials: [AccountCredential]
        /// Auxiliary blobs co-located in the same keychain item (key → opaque Data).
        /// Optional so older vault JSON (credentials only) still decodes unchanged.
        var auxiliary: [String: Data]?
    }

    // MARK: - CRUD

    public func saveCredential(_ credential: AccountCredential) throws {
        lock.lock()
        defer { lock.unlock() }

        let key = storageKey(credential)
        var vault = loadCredentialVaultOrMigrateUnsafe()
        vault[key] = credential
        do {
            try saveCredentialVaultUnsafe(vault)
        } catch {
            credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        cachedCredentialsByStorageKey = vault

        // Best-effort cleanup of legacy per-credential storage so startup does not
        // trigger repeated keychain prompts for every historical item.
        deleteCredentialStorageKeyUnsafe(key)
    }

    public func loadCredentials(for providerId: String) -> [AccountCredential] {
        lock.lock()
        defer { lock.unlock() }

        let allCreds = Array(loadCredentialVaultOrMigrateUnsafe().values)
        let providerCreds = allCreds.filter { $0.providerId == providerId }
        return canonicalizedCredentials(providerCreds)
    }

    public func loadAllCredentials() -> [AccountCredential] {
        lock.lock()
        defer { lock.unlock() }
        return canonicalizedCredentials(Array(loadCredentialVaultOrMigrateUnsafe().values))
    }

    public func loadCredential(providerId: String, credentialId: String) -> AccountCredential? {
        lock.lock()
        defer { lock.unlock() }
        return loadCredentialVaultOrMigrateUnsafe()[storageKey(providerId: providerId, credentialId: credentialId)]
    }

    public func deleteCredential(_ credential: AccountCredential) {
        lock.lock()
        defer { lock.unlock() }

        let key = storageKey(credential)
        var vault = loadCredentialVaultOrMigrateUnsafe()
        vault.removeValue(forKey: key)
        do {
            try saveCredentialVaultUnsafe(vault)
        } catch {
            credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
        }
        cachedCredentialsByStorageKey = vault
        deleteCredentialStorageKeyUnsafe(key)
    }

    public func deleteCredentials(for providerId: String) {
        lock.lock()
        defer { lock.unlock() }

        var vault = loadCredentialVaultOrMigrateUnsafe()
        let keysToRemove = vault.keys.filter { $0.hasPrefix(providerId.lowercased() + ":") }
        if !keysToRemove.isEmpty {
            for key in keysToRemove {
                vault.removeValue(forKey: key)
                deleteCredentialStorageKeyUnsafe(key)
            }
            do {
                try saveCredentialVaultUnsafe(vault)
            } catch {
                credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
            }
            cachedCredentialsByStorageKey = vault
        }
    }

    public func updateLastUsed(_ credential: AccountCredential) {
        var updated = credential
        updated.lastUsedAt = SharedFormatters.iso8601String(from: Date())
        do {
            try saveCredential(updated)
        } catch {
            credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func bootstrapCredentialIndex(references: [AccountCredentialReference]) {
        lock.lock()
        defer { lock.unlock() }

        // Legacy no-op. We no longer rely on a per-credential keychain index at startup,
        // because it caused repeated access prompts for every stored credential.
        if cachedCredentialsByStorageKey == nil {
            _ = loadCredentialVaultOrMigrateUnsafe()
        }
    }

    @discardableResult
    public func deduplicateCredentials(for providerId: String? = nil) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        let allCredentials = loadAllCredentialsUnsafe()
        let targetCredentials = providerId.map { id in
            allCredentials.filter { $0.providerId == id }
        } ?? allCredentials

        let (canonical, remappedIDs) = canonicalizationResult(for: targetCredentials)
        guard !remappedIDs.isEmpty else { return [:] }

        let keptIDs = Set(canonical.map(\.id))
        var vault = loadCredentialVaultOrMigrateUnsafe()
        var didMutateVault = false
        for credential in targetCredentials where !keptIDs.contains(credential.id) {
            let key = storageKey(credential)
            if vault.removeValue(forKey: key) != nil {
                didMutateVault = true
            }
            deleteCredentialStorageKeyUnsafe(key)
        }

        if didMutateVault {
            do {
                try saveCredentialVaultUnsafe(vault)
            } catch {
                credentialLog.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
            }
            cachedCredentialsByStorageKey = vault
        }

        return remappedIDs
    }

    // MARK: - Internal

    private func storageKey(_ credential: AccountCredential) -> String {
        storageKey(providerId: credential.providerId, credentialId: credential.id)
    }

    private func storageKey(providerId: String, credentialId: String) -> String {
        "\(providerId):\(credentialId)"
    }

    private func loadAllCredentialsUnsafe() -> [AccountCredential] {
        Array(loadCredentialVaultOrMigrateUnsafe().values)
    }

    private func loadCredentialVaultOrMigrateUnsafe() -> [String: AccountCredential] {
        if let cachedCredentialsByStorageKey {
            return cachedCredentialsByStorageKey
        }

        if !dpKeychainUnavailable, let dpVault = loadVaultFromDataProtectionKeychainUnsafe() {
            return applyLoadedVaultUnsafe(dpVault)
        }

        if let legacyVault = loadVaultFromLegacyKeychainUnsafe() {
            let dict = applyLoadedVaultUnsafe(legacyVault)
            if !dpKeychainUnavailable {
                migrateVaultToDataProtectionKeychainUnsafe()
            }
            return dict
        }

        let legacyCredentials = loadCredentialsByLegacySearchUnsafe()
        let migratedVault = Dictionary(
            uniqueKeysWithValues: legacyCredentials.map { (storageKey($0), $0) }
        )
        cachedCredentialsByStorageKey = migratedVault
        cachedAuxiliary = [:]

        guard !migratedVault.isEmpty else { return migratedVault }

        // Persist the consolidated vault BEFORE removing any source item. The write
        // targets the Data Protection Keychain when its entitlement is present and
        // otherwise falls back to the legacy keychain, so a missing entitlement can
        // never strand the only persisted copy (the previous code attempted a
        // DP-only write and then deleted the per-credential items unconditionally —
        // on ad-hoc/self-signed builds that meant losing every credential after the
        // next launch). Deletes run strictly as post-success cleanup; if the write
        // fails we keep the source items so a later launch can retry the migration.
        do {
            try saveCredentialVaultUnsafe(migratedVault)
            for key in migratedVault.keys {
                deleteCredentialStorageKeyUnsafe(key)
            }
            deleteLegacyCredentialIndexUnsafe()
        } catch {
            credentialLog.error("Credential migration deferred (vault write failed): \(error.localizedDescription, privacy: .public)")
        }
        return migratedVault
    }

    /// Cache the decoded vault (credentials + auxiliary blobs) and return the
    /// credential dictionary keyed by storage key.
    @discardableResult
    private func applyLoadedVaultUnsafe(_ vault: CredentialVault) -> [String: AccountCredential] {
        let dict = Dictionary(
            uniqueKeysWithValues: vault.credentials.map { (storageKey($0), $0) }
        )
        cachedCredentialsByStorageKey = dict
        cachedAuxiliary = vault.auxiliary ?? [:]
        return dict
    }

    private func encodeCurrentVaultUnsafe() throws -> Data {
        let orderedCredentials = (cachedCredentialsByStorageKey ?? [:]).values.sorted(by: credentialSort)
        return try JSONEncoder().encode(
            CredentialVault(credentials: orderedCredentials, auxiliary: cachedAuxiliary.isEmpty ? nil : cachedAuxiliary)
        )
    }

    // MARK: - Auxiliary blob storage (folded into the single vault item)

    /// Read an opaque blob co-located in the credential vault item.
    /// Used by app-side stores (e.g. SecureAccountVault) so the whole app keeps
    /// a single keychain item and at most one access prompt.
    public func loadAuxiliaryData(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        _ = loadCredentialVaultOrMigrateUnsafe()
        return cachedAuxiliary[key]
    }

    /// Write (or clear, when `data` is nil) an opaque blob into the credential
    /// vault item, preserving the stored credentials.
    public func saveAuxiliaryData(_ data: Data?, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let vault = loadCredentialVaultOrMigrateUnsafe()
        if let data {
            cachedAuxiliary[key] = data
        } else {
            cachedAuxiliary.removeValue(forKey: key)
        }
        try saveCredentialVaultUnsafe(vault)
    }

    private func dpVaultQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialVaultAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func loadVaultFromDataProtectionKeychainUnsafe() -> CredentialVault? {
        var query = dpVaultQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CredentialVault.self, from: data)
    }

    private func loadVaultFromLegacyKeychainUnsafe() -> CredentialVault? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialVaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CredentialVault.self, from: data)
    }

    private func migrateVaultToDataProtectionKeychainUnsafe() {
        do {
            try writeToDPKeychainUnsafe(try encodeCurrentVaultUnsafe())
            deleteLegacyVaultItemUnsafe()
            credentialLog.info("Migrated credential vault to Data Protection Keychain")
        } catch CredentialStoreError.keychainWriteFailed(let status) where status == errSecMissingEntitlement {
            markDPKeychainUnavailableUnsafe(status: status)
        } catch {
            credentialLog.warning("DP migration skipped (entitlement missing?), using legacy keychain")
        }
    }

    private func deleteLegacyVaultItemUnsafe() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialVaultAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func saveCredentialVaultUnsafe(_ credentialsByStorageKey: [String: AccountCredential]) throws {
        let orderedCredentials = credentialsByStorageKey.values.sorted(by: credentialSort)
        let data = try JSONEncoder().encode(
            CredentialVault(credentials: orderedCredentials, auxiliary: cachedAuxiliary.isEmpty ? nil : cachedAuxiliary)
        )

        if !dpKeychainUnavailable {
            do {
                try writeToDPKeychainUnsafe(data)
                return
            } catch CredentialStoreError.keychainWriteFailed(let status) where status == errSecMissingEntitlement {
                markDPKeychainUnavailableUnsafe(status: status)
            } catch {
                credentialLog.warning("DP Keychain write failed, falling back to legacy: \(error.localizedDescription, privacy: .public)")
            }
        }
        try writeToLegacyKeychainUnsafe(data)
    }

    private func writeToDPKeychainUnsafe(_ data: Data) throws {
        let base = dpVaultQuery()
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.keychainAccessibility
        ]

        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = base
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = Self.keychainAccessibility
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainWriteFailed(addStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychainWriteFailed(status)
        }
    }

    private func writeToLegacyKeychainUnsafe(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialVaultAccount
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.keychainAccessibility
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = baseQuery
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = Self.keychainAccessibility
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainWriteFailed(addStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychainWriteFailed(status)
        }
    }

    private func loadCredentialsByLegacySearchUnsafe() -> [AccountCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(AccountCredential.self, from: data)
        }
    }

    private func loadCredentialUnsafe(storageKey: String) -> AccountCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: storageKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AccountCredential.self, from: data)
    }

    private func deleteCredentialStorageKeyUnsafe(_ storageKey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: storageKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func deleteLegacyCredentialIndexUnsafe() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialIndexAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func canonicalizedCredentials(_ credentials: [AccountCredential]) -> [AccountCredential] {
        canonicalizationResult(for: credentials).canonical.sorted(by: credentialSort)
    }

    private func canonicalizationResult(for credentials: [AccountCredential]) -> (canonical: [AccountCredential], remappedIDs: [String: String]) {
        guard !credentials.isEmpty else { return ([], [:]) }

        var canonicalByIdentity: [String: AccountCredential] = [:]
        var remappedIDs: [String: String] = [:]

        for credential in credentials {
            let key = credentialIdentityKey(credential)
            if let existing = canonicalByIdentity[key] {
                if shouldPreferCredential(credential, over: existing) {
                    canonicalByIdentity[key] = credential
                    remappedIDs[existing.id] = credential.id
                } else {
                    remappedIDs[credential.id] = existing.id
                }
            } else {
                canonicalByIdentity[key] = credential
            }
        }

        let canonical = credentials.filter { credential in
            canonicalByIdentity[credentialIdentityKey(credential)]?.id == credential.id
        }
        return (canonical, remappedIDs)
    }

    /// Single source of truth for providers whose accounts cannot be deduped by
    /// email or accountId alone (same email may span multiple workspaces, and
    /// the same user-xxx may represent both Plus and Team). All identity layers
    /// — credential store, provider engine, app-side AccountIdentityPolicy —
    /// must consult this set rather than keeping their own copies.
    public static let multiWorkspaceProviders: Set<String> = ["codex"]

    public static func isMultiWorkspace(_ providerId: String) -> Bool {
        multiWorkspaceProviders.contains(providerId.lowercased())
    }

    /// 规则#9：`resolvingSymlinksInPath()` 每次都做 lstat/realpath（文件系统往返）。
    /// 该归一化在账号匹配的 O(n²) 循环里被反复调用，是数据刷新期间主线程的头号文件系统热点
    /// （见 issue #28 Instruments profile）。auth 路径在一次会话内稳定、同路径恒等结果，故缓存复用。
    /// NSCache 线程安全，可跨 actor/线程共享；缓存条目数受唯一路径数约束（极小）。
    private static let normalizedAuthPathCache = NSCache<NSString, NSString>()

    /// Normalize an auth-file path for identity comparison.
    /// - Expands `~`, removes `//` / `.` / `..`, resolves symlinks so two credentials
    ///   pointing at the same underlying file dedupe.
    /// - Lowercased because macOS default FS (APFS) is case-insensitive; case-sensitive
    ///   volumes accept a false positive here but that is preferable to a missed merge.
    public static func normalizedAuthFilePath(_ rawPath: String) -> String {
        let key = rawPath as NSString
        if let cached = normalizedAuthPathCache.object(forKey: key) {
            return cached as String
        }
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let normalized = url.path.precomposedStringWithCanonicalMapping.lowercased()
        normalizedAuthPathCache.setObject(normalized as NSString, forKey: key)
        return normalized
    }

    private func credentialIdentityKey(_ credential: AccountCredential) -> String {
        let provider = credential.providerId.lowercased()

        if Self.multiWorkspaceProviders.contains(provider) {
            if credential.authMethod == .authFile {
                return "\(provider):authfile:\(Self.normalizedAuthFilePath(credential.credential))"
            }
            return "\(provider):raw:\(credential.id.lowercased())"
        }

        if let accountId = normalizedLookup(credential.metadata["accountId"]) {
            return "\(provider):account:\(accountId)"
        }

        if let handle = normalizedLookup(
            credential.metadata["accountEmail"]
                ?? credential.metadata["accountHandle"]
                ?? credential.accountLabel
        ) {
            return "\(provider):handle:\(handle)"
        }

        if credential.authMethod == .authFile {
            return "\(provider):authfile:\(Self.normalizedAuthFilePath(credential.credential))"
        }

        return "\(provider):raw:\(credential.id.lowercased())"
    }

    private func shouldPreferCredential(_ candidate: AccountCredential, over existing: AccountCredential) -> Bool {
        let candidateScore = credentialScore(candidate)
        let existingScore = credentialScore(existing)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }

        let candidateImported = recencyTimestamp(for: candidate)
        let existingImported = recencyTimestamp(for: existing)
        if candidateImported != existingImported {
            return candidateImported > existingImported
        }

        let candidateLastUsed = timestamp(for: candidate.lastUsedAt)
        let existingLastUsed = timestamp(for: existing.lastUsedAt)
        if candidateLastUsed != existingLastUsed {
            return candidateLastUsed > existingLastUsed
        }

        let candidateCreated = timestamp(for: candidate.createdAt)
        let existingCreated = timestamp(for: existing.createdAt)
        if candidateCreated != existingCreated {
            return candidateCreated > existingCreated
        }

        return candidate.id < existing.id
    }

    private func credentialScore(_ credential: AccountCredential) -> Int {
        var score = 0

        if normalizedLookup(credential.metadata["accountId"]) != nil {
            score += 80
        }
        if normalizedLookup(credential.metadata["accountEmail"] ?? credential.metadata["accountHandle"] ?? credential.accountLabel) != nil {
            score += 40
        }

        switch credential.authMethod {
        case .authFile:
            let path = NSString(string: credential.credential).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                score += 35
            } else {
                score -= 120
            }
            if path.contains(Self.managedAuthImportsPathComponent) {
                score += 25
            }
            if normalizedLookup(credential.metadata["sourcePath"]) == normalizedLookup(path) {
                score += 10
            }
        case .cookie, .webSession, .token, .apiKey, .oauth:
            score += 15
        case .auto:
            break
        }

        if normalizedLookup(credential.metadata["sourceIdentifier"]) != nil {
            score += 5
        }

        return score
    }

    private func recencyTimestamp(for credential: AccountCredential) -> Date {
        if let validated = timestampOrNil(for: credential.metadata["lastValidatedAt"]) {
            return validated
        }
        if let imported = timestampOrNil(for: credential.metadata["importedAt"]) {
            return imported
        }
        return timestamp(for: credential.createdAt)
    }

    private func timestampOrNil(for value: String?) -> Date? {
        guard let value,
              let date = SharedFormatters.parseISO8601(value) else {
            return nil
        }
        return date
    }

    private func timestamp(for value: String?) -> Date {
        guard let value,
              let date = SharedFormatters.parseISO8601(value) else {
            return .distantPast
        }
        return date
    }

    private func normalizedLookup(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func credentialSort(_ lhs: AccountCredential, _ rhs: AccountCredential) -> Bool {
        if lhs.providerId != rhs.providerId {
            return lhs.providerId < rhs.providerId
        }

        let lhsLabel = normalizedLookup(lhs.metadata["accountEmail"] ?? lhs.metadata["accountHandle"] ?? lhs.accountLabel) ?? lhs.id.lowercased()
        let rhsLabel = normalizedLookup(rhs.metadata["accountEmail"] ?? rhs.metadata["accountHandle"] ?? rhs.accountLabel) ?? rhs.id.lowercased()
        if lhsLabel != rhsLabel {
            return lhsLabel < rhsLabel
        }

        return shouldPreferCredential(lhs, over: rhs)
    }
}

// MARK: - Errors

public enum CredentialStoreError: LocalizedError {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychainWriteFailed(let status):
            return "Keychain write failed (OSStatus: \(status))"
        case .keychainReadFailed(let status):
            return "Keychain read failed (OSStatus: \(status))"
        }
    }
}
