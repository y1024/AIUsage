import Foundation

nonisolated enum CLIProxyCredentialAdapter {
    static let supportedProviderIDs: Set<String> = ["codex", "antigravity"]

    static func convert(
        providerId: String,
        credentialId: String,
        accountLabel: String?,
        metadata: [String: String],
        sourceData: Data
    ) throws -> Data {
        guard supportedProviderIDs.contains(providerId) else {
            throw CLIProxyGatewayError.unsupportedAccount("no verified adapter for \(providerId)")
        }
        guard var object = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
            throw CLIProxyGatewayError.invalidResponse("credential file is not a JSON object")
        }
        switch providerId {
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
        object["note"] = "Synced from AIUsage"
        object["aiusage_credential_id"] = credentialId
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
