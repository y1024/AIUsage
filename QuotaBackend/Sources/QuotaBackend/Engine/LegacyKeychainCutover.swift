import Foundation
import Security
import os

// MARK: - Legacy Keychain Cutover
// 一次性把所有历史 Keychain 布局迁移进 AccountCredentialStore 的唯一正式 vault。
//
// 重要约定：本文件是**唯一**允许引用旧 Keychain 服务名（旧 Bundle ID、独立账号
// 注册表）以及合并前的"逐条凭据 / 索引"布局的地方。AccountCredentialStore 与
// SecureAccountVault 的正常读写路径只认唯一正式 vault，不含任何旧逻辑。
//
// 生命周期：由写入 vault auxiliary 的 sentinel（`sentinelAuxiliaryKey`）门控，
// 每台机器至多执行一次。计划在 0.13.0 删除整个文件及其调用点，以彻底摆脱旧
// Keychain 兼容面（见 docs/RELEASE_PLAYBOOK.md）。

private let cutoverLog = Logger(subsystem: "com.aiusage.desktop", category: "LegacyKeychainCutover")

enum LegacyKeychainCutover {
    /// cutover 成功后写入 vault auxiliary 的完成标记。存在即跳过整个 cutover。
    static let sentinelAuxiliaryKey = "migration.legacyKeychainCutover.v1"

    /// 账号注册表 blob 在 vault auxiliary 中的 key。与 `SecureAccountVault` 保持一致；
    /// 在此重复声明，使旧兼容面自洽、正常路径不持有任何旧知识。
    static let registryAuxiliaryKey = "providerAccounts.registry"

    // 当前（正式）凭据条目坐标 —— 仅用于在清扫时跳过它。
    private static let currentCredentialService = "com.aiusage.desktop.providerCredentials"
    private static let vaultAccount = "__credential_vault_v2__"
    private static let indexAccount = "__credential_index_v1__"

    // 旧 Bundle ID（改名前）凭据服务名。
    private static let oldBundleCredentialService = "sylearn.AIUsage.providerCredentials"

    // 独立账号注册表条目（当前 + 旧 Bundle ID）。
    private static let registryServices = [
        "com.aiusage.desktop.providerAccounts",
        "sylearn.AIUsage.providerAccounts"
    ]
    private static let registryAccount = "registry"

    struct Collected {
        var credentials: [AccountCredential]
        var registryBlob: Data?
    }

    /// 旧合并版 vault 条目的最小解码形状，仅用于回收其中的凭据与折叠的注册表 blob。
    private struct LegacyVault: Decodable {
        let credentials: [AccountCredential]
        let auxiliary: [String: Data]?
    }

    // MARK: - Collect

    /// 读取全部旧来源，返回回收到的凭据与最佳可用的账号注册表 blob。纯读取，不删除。
    static func collect() -> Collected {
        var credentials: [AccountCredential] = []

        // 1. 当前服务名下的合并前逐条凭据条目（account 是 storage key，非 vault/index）。
        credentials += perCredentialItems(service: currentCredentialService)

        // 2. 旧 Bundle ID 服务名：合并版 vault 条目 + 逐条凭据条目。
        var registryBlob: Data?
        if let oldVault = consolidatedVault(service: oldBundleCredentialService) {
            credentials += oldVault.credentials
            registryBlob = oldVault.auxiliary?[registryAuxiliaryKey]
        }
        credentials += perCredentialItems(service: oldBundleCredentialService)

        // 3. 独立账号注册表条目（按顺序取第一个存在的：当前 Bundle ID 优先于旧 Bundle ID）。
        if registryBlob == nil {
            for service in registryServices {
                if let blob = rawItem(service: service, account: registryAccount) {
                    registryBlob = blob
                    break
                }
            }
        }

        return Collected(credentials: credentials, registryBlob: registryBlob)
    }

    // MARK: - Purge

    /// 尽力删除全部旧条目。失败无妨：sentinel 置位后正常路径永不再读这些条目，残留即惰性垃圾。
    static func purge() {
        // 当前服务名：删除索引条目与每个逐条凭据条目，但**绝不**删正式 vault 条目。
        deleteItem(service: currentCredentialService, account: indexAccount)
        for account in perCredentialAccounts(service: currentCredentialService) {
            deleteItem(service: currentCredentialService, account: account)
        }
        // 旧 Bundle ID 凭据服务名：整服务名一次性删尽。
        deleteAllItems(service: oldBundleCredentialService)
        // 独立账号注册表条目。
        for service in registryServices {
            deleteItem(service: service, account: registryAccount)
        }
        cutoverLog.info("Purged legacy keychain items after cutover")
    }

    // MARK: - Keychain helpers (legacy-only)

    private static func consolidatedVault(service: String) -> LegacyVault? {
        guard let data = rawItem(service: service, account: vaultAccount) else { return nil }
        return try? JSONDecoder().decode(LegacyVault.self, from: data)
    }

    private static func perCredentialItems(service: String) -> [AccountCredential] {
        attributedItems(service: service).compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != vaultAccount, account != indexAccount,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(AccountCredential.self, from: data)
        }
    }

    private static func perCredentialAccounts(service: String) -> [String] {
        attributedItems(service: service).compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != vaultAccount, account != indexAccount else { return nil }
            return account
        }
    }

    private static func attributedItems(service: String) -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items
    }

    private static func rawItem(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func deleteItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func deleteAllItems(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
