import Foundation
import Security
import os.log
import QuotaBackend

private let vaultLog = Logger(subsystem: "com.aiusage.desktop", category: "SecureAccountVault")

/// Stores the provider account registry. To keep the whole app down to a single
/// keychain item (and at most one "Always Allow" prompt), the registry is folded
/// into the credential vault item owned by `AccountCredentialStore` as an
/// auxiliary blob. The old standalone keychain item is migrated once on first
/// access and then deleted.
final class SecureAccountVault: @unchecked Sendable {
    nonisolated static let shared = SecureAccountVault()

    /// Key under which the registry blob lives inside the unified vault item.
    private static let auxiliaryKey = "providerAccounts.registry"

    // Old standalone item coordinates, kept only for one-time migration.
    private static let legacyService = "com.aiusage.desktop.providerAccounts"
    private static let legacyAccount = "registry"

    private init() {}

    // MARK: - Public API

    nonisolated func loadAccounts() -> [StoredProviderAccount] {
        if let data = AccountCredentialStore.shared.loadAuxiliaryData(forKey: Self.auxiliaryKey) {
            return decodeAccounts(data)
        }

        // Not yet folded in: migrate the old standalone item if present.
        guard let legacyData = readOldRegistryItem() else { return [] }
        do {
            try AccountCredentialStore.shared.saveAuxiliaryData(legacyData, forKey: Self.auxiliaryKey)
            deleteOldRegistryItems()
            vaultLog.info("Migrated account registry into the unified credential vault item")
        } catch {
            // Leave the old item in place so a later launch can retry the migration.
            vaultLog.warning("Account registry migration deferred: \(error.localizedDescription, privacy: .public)")
        }
        return decodeAccounts(legacyData)
    }

    nonisolated func saveAccounts(_ accounts: [StoredProviderAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        try AccountCredentialStore.shared.saveAuxiliaryData(data, forKey: Self.auxiliaryKey)
    }

    // MARK: - Legacy standalone item (migration source)

    /// Read the old `providerAccounts/registry` item (Data Protection first,
    /// then legacy file-based keychain). Returns nil when neither exists.
    private func readOldRegistryItem() -> Data? {
        if let data = readOldItem(dataProtection: true) { return data }
        return readOldItem(dataProtection: false)
    }

    private func readOldItem(dataProtection: Bool) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyService,
            kSecAttrAccount as String: Self.legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func deleteOldRegistryItems() {
        for dataProtection in [true, false] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.legacyService,
                kSecAttrAccount as String: Self.legacyAccount
            ]
            if dataProtection {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Helpers

    private func decodeAccounts(_ data: Data) -> [StoredProviderAccount] {
        do {
            return try JSONDecoder().decode([StoredProviderAccount].self, from: data)
        } catch {
            vaultLog.error("Account registry decode failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
