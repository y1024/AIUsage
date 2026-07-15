import Foundation

nonisolated enum CLIProxyCredentialAdapter {
    static let supportedProviderIDs: Set<String> = ["codex", "antigravity", "gemini"]

    static func convert(
        providerId: String,
        credentialId: String,
        accountLabel: String?,
        metadata: [String: String],
        sourceData: Data
    ) throws -> Data {
        let normalizedProviderID = normalizedProviderID(providerId)
        guard supportedProviderIDs.contains(normalizedProviderID) else {
            throw CLIProxyGatewayError.unsupportedAccount("no verified adapter for \(providerId)")
        }
        if normalizedProviderID == "gemini" {
            return try CLIProxyGeminiCredentialBridge.makeCPAPayload(
                sourceData: sourceData,
                credentialID: credentialId,
                accountLabel: accountLabel,
                metadata: metadata
            )
        }
        guard var object = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
            throw CLIProxyGatewayError.invalidResponse("credential file is not a JSON object")
        }
        switch normalizedProviderID {
        case "codex":
            if let tokens = object["tokens"] as? [String: Any] {
                for key in ["id_token", "access_token", "refresh_token", "account_id"] {
                    if let value = tokens[key] { object[key] = value }
                }
            }
            object["type"] = "codex"
        case "antigravity":
            object["type"] = "antigravity"
        default:
            throw CLIProxyGatewayError.unsupportedAccount("no verified adapter for \(providerId)")
        }

        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = object["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw CLIProxyGatewayError.unsupportedAccount(
                "the auth file does not contain a reusable access/refresh token pair"
            )
        }
        object["email"] = object["email"] ?? metadata["accountEmail"] ?? accountLabel
        // 不写入系统备注；备注留给用户在账号详情里自行填写。
        if let note = object["note"] as? String {
            let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "synced from aiusage" || normalized == "来自 aiusage 的同步副本" {
                object.removeValue(forKey: "note")
            }
        }
        object["aiusage_credential_id"] = credentialId
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func normalizedProviderID(_ providerID: String) -> String {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gemini-cli": return "gemini"
        default: return providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
