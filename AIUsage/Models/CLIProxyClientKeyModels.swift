import Foundation

// MARK: - CPA 客户端密钥
// 推理面 api-keys：默认托管钥 + 用户自定义钥。管理钥（management）永不出现在此列表。

nonisolated struct CLIProxyClientKeyEntry: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var label: String
    var key: String
    var enabled: Bool
    var isManagedDefault: Bool
    var createdAt: Date

    var fingerprint: String {
        guard key.count >= 4 else { return "????" }
        return String(key.suffix(4))
    }

    var displayTitle: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isManagedDefault
            ? L("Default key", "默认密钥")
            : L("Custom key", "自定义密钥")
    }
}

nonisolated enum CLIProxyClientKeyStoreError: LocalizedError, Sendable {
    case emptyKey
    case duplicateKey
    case cannotDeleteDefault
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return L("API key cannot be empty.", "API 密钥不能为空。")
        case .duplicateKey:
            return L("This API key already exists.", "该 API 密钥已存在。")
        case .cannotDeleteDefault:
            return L("The default key cannot be deleted.", "默认密钥不能删除。")
        case .storage(let message):
            return message
        }
    }
}
