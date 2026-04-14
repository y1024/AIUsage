import Foundation
import Security

public struct AccountCredentialReference: Hashable, Sendable {
    public let providerId: String
    public let credentialId: String

    public init(providerId: String, credentialId: String) {
        self.providerId = providerId
        self.credentialId = credentialId
    }
}

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

    private init() {}

    private struct CredentialIndex: Codable {
        let storageKeys: [String]
    }

    private struct CredentialVault: Codable {
        let credentials: [AccountCredential]
    }

    // MARK: - CRUD

    public func saveCredential(_ credential: AccountCredential) throws {
        lock.lock()
        defer { lock.unlock() }

        let key = storageKey(credential)
        var vault = loadCredentialVaultOrMigrateUnsafe()
        vault[key] = credential
        try saveCredentialVaultUnsafe(vault)
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
        try? saveCredentialVaultUnsafe(vault)
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
            try? saveCredentialVaultUnsafe(vault)
            cachedCredentialsByStorageKey = vault
        }
    }

    public func updateLastUsed(_ credential: AccountCredential) {
        var updated = credential
        updated.lastUsedAt = SharedFormatters.iso8601String(from: Date())
        try? saveCredential(updated)
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
            try? saveCredentialVaultUnsafe(vault)
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

        if let storedVault = loadCredentialVaultUnsafe() {
            cachedCredentialsByStorageKey = storedVault
            return storedVault
        }

        let legacyCredentials = loadCredentialsByLegacySearchUnsafe()
        let migratedVault = Dictionary(
            uniqueKeysWithValues: legacyCredentials.map { (storageKey($0), $0) }
        )
        cachedCredentialsByStorageKey = migratedVault

        guard !migratedVault.isEmpty else { return migratedVault }

        try? saveCredentialVaultUnsafe(migratedVault)
        for key in migratedVault.keys {
            deleteCredentialStorageKeyUnsafe(key)
        }
        deleteLegacyCredentialIndexUnsafe()
        return migratedVault
    }

    private func loadCredentialVaultUnsafe() -> [String: AccountCredential]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.credentialVaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let vault = try? JSONDecoder().decode(CredentialVault.self, from: data) else {
            return nil
        }

        return Dictionary(
            uniqueKeysWithValues: vault.credentials.map { (storageKey($0), $0) }
        )
    }

    private func saveCredentialVaultUnsafe(_ credentialsByStorageKey: [String: AccountCredential]) throws {
        let orderedCredentials = credentialsByStorageKey.values.sorted(by: credentialSort)
        let data = try JSONEncoder().encode(CredentialVault(credentials: orderedCredentials))

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

    private func credentialIdentityKey(_ credential: AccountCredential) -> String {
        let provider = credential.providerId.lowercased()

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
            let path = NSString(string: credential.credential).expandingTildeInPath
            return "\(provider):authfile:\(path.lowercased())"
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
