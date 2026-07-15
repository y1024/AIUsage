import Foundation
import QuotaBackend
import Security

/// 管理 CPA 推理用 client api-keys：默认钥来自 SecretStore，自定义钥存独立 Keychain 条目。
/// 不与 AccountCredentialStore 共用 Vault，避免密钥管理误写账号凭据。
nonisolated struct CLIProxyClientKeyStore: Sendable {
    private enum Key {
        /// 历史位置：曾折叠进账号 Vault auxiliary；首次读取时迁移到独立条目。
        static let legacyAuxiliary = "cliproxy.gateway.client-keys.custom.v1"
        static let keychainAccount = "cliproxy.gateway.client-keys.custom.v2"
    }

    private static let keychainService: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aiusage.desktop"
        if bundleID == "com.aiusage.desktop" {
            return "com.aiusage.desktop.cliproxyClientKeys"
        }
        return "\(bundleID).cliproxyClientKeys"
    }()

    private let secretStore: CLIProxySecretStore

    init(secretStore: CLIProxySecretStore = CLIProxySecretStore()) {
        self.secretStore = secretStore
    }

    static var managedKeyPrefixes: [String] { CLIProxyManagedAPIKeyNamespace.prefixes }

    func loadEntries() throws -> [CLIProxyClientKeyEntry] {
        let secrets = try secretStore.loadOrCreate()
        let defaults = CLIProxyClientKeyEntry(
            id: "default",
            label: L("Default key", "默认密钥"),
            key: secrets.clientAPIKey,
            enabled: true,
            isManagedDefault: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let custom = try loadCustomEntries()
        return [defaults] + custom.sorted { $0.createdAt > $1.createdAt }
    }

    func enabledKeysForRuntime() throws -> [String] {
        try loadEntries()
            .filter(\.enabled)
            .map(\.key)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func addKey(label: String, key: String?) throws -> CLIProxyClientKeyEntry {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey: String
        if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedKey = try Self.generateKey(prefix: "cpa-key")
        }
        guard !resolvedKey.isEmpty else { throw CLIProxyClientKeyStoreError.emptyKey }

        var custom = try loadCustomEntries()
        let existing = try loadEntries().map(\.key)
        guard !existing.contains(resolvedKey) else { throw CLIProxyClientKeyStoreError.duplicateKey }

        let entry = CLIProxyClientKeyEntry(
            id: UUID().uuidString,
            label: trimmedLabel,
            key: resolvedKey,
            enabled: true,
            isManagedDefault: false,
            createdAt: Date()
        )
        custom.append(entry)
        try saveCustomEntries(custom)
        return entry
    }

    func updateEntry(
        id: String,
        label: String? = nil,
        enabled: Bool? = nil
    ) throws {
        if id == "default" {
            // 默认钥只允许改备注（展示用）；启停始终保持启用。
            return
        }
        var custom = try loadCustomEntries()
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        if let label {
            custom[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let enabled {
            custom[index].enabled = enabled
        }
        try saveCustomEntries(custom)
    }

    func deleteEntry(id: String) throws {
        guard id != "default" else { throw CLIProxyClientKeyStoreError.cannotDeleteDefault }
        var custom = try loadCustomEntries()
        custom.removeAll { $0.id == id }
        try saveCustomEntries(custom)
    }

    // MARK: - Independent Keychain storage

    private func loadCustomEntries() throws -> [CLIProxyClientKeyEntry] {
        if let data = try readDedicatedKeychainData() {
            return try decodeCustomEntries(data)
        }
        // One-time migrate from the shared credential vault auxiliary blob.
        if let legacy = AccountCredentialStore.shared.loadAuxiliaryData(forKey: Key.legacyAuxiliary) {
            let entries = try decodeCustomEntries(legacy)
            try writeDedicatedKeychainData(legacy)
            try? AccountCredentialStore.shared.saveAuxiliaryData(nil, forKey: Key.legacyAuxiliary)
            return entries
        }
        return []
    }

    private func saveCustomEntries(_ entries: [CLIProxyClientKeyEntry]) throws {
        do {
            let data = try JSONEncoder().encode(entries)
            try writeDedicatedKeychainData(data)
            // Best-effort: drop legacy blob so future reads never touch the vault.
            try? AccountCredentialStore.shared.saveAuxiliaryData(nil, forKey: Key.legacyAuxiliary)
        } catch let error as CLIProxyClientKeyStoreError {
            throw error
        } catch {
            throw CLIProxyClientKeyStoreError.storage(error.localizedDescription)
        }
    }

    private func decodeCustomEntries(_ data: Data) throws -> [CLIProxyClientKeyEntry] {
        do {
            let decoded = try JSONDecoder().decode([CLIProxyClientKeyEntry].self, from: data)
            return decoded.filter { !$0.isManagedDefault && !$0.key.isEmpty }
        } catch {
            throw CLIProxyClientKeyStoreError.storage(
                "Custom client keys are corrupt and could not be decoded"
            )
        }
    }

    private func readDedicatedKeychainData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Key.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw CLIProxyClientKeyStoreError.storage("Keychain read returned empty data")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CLIProxyClientKeyStoreError.storage("Keychain read failed (OSStatus: \(status))")
        }
    }

    private func writeDedicatedKeychainData(_ data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Key.keychainAccount
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = baseQuery
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CLIProxyClientKeyStoreError.storage("Keychain write failed (OSStatus: \(addStatus))")
            }
        } else if status != errSecSuccess {
            throw CLIProxyClientKeyStoreError.storage("Keychain write failed (OSStatus: \(status))")
        }
    }

    private static func generateKey(prefix: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CLIProxyClientKeyStoreError.storage("secure random generation failed")
        }
        return "\(prefix)-" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
