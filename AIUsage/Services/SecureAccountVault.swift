import Foundation
import os.log
import QuotaBackend

private let vaultLog = Logger(subsystem: "com.aiusage.desktop", category: "SecureAccountVault")

/// Stores the provider account registry as an auxiliary blob inside the single
/// credential vault item owned by `AccountCredentialStore` (so the whole app keeps
/// exactly one keychain item and at most one "Always Allow" prompt). Migration
/// from any older standalone keychain item is handled once by `LegacyKeychainCutover`;
/// this type only ever reads/writes the unified vault's auxiliary blob.
final class SecureAccountVault: @unchecked Sendable {
    nonisolated static let shared = SecureAccountVault()

    /// Key under which the registry blob lives inside the unified vault item.
    private static let auxiliaryKey = "providerAccounts.registry"

    private init() {}

    // MARK: - Public API

    nonisolated func loadAccounts() -> [StoredProviderAccount] {
        guard let data = AccountCredentialStore.shared.loadAuxiliaryData(forKey: Self.auxiliaryKey) else {
            return []
        }
        return decodeAccounts(data)
    }

    nonisolated func saveAccounts(_ accounts: [StoredProviderAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        try AccountCredentialStore.shared.saveAuxiliaryData(data, forKey: Self.auxiliaryKey)
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
