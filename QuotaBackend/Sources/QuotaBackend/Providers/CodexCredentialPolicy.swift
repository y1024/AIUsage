import Foundation

enum CodexCredentialPolicy {
    static func belongsToSameWorkspace(
        lhsAccountID: String?,
        lhsUserID: String?,
        rhsAccountID: String?,
        rhsUserID: String?
    ) -> Bool {
        guard let lhsAccountID = normalized(lhsAccountID),
              let rhsAccountID = normalized(rhsAccountID),
              lhsAccountID == rhsAccountID else {
            return false
        }

        guard let lhsUserID = normalized(lhsUserID),
              let rhsUserID = normalized(rhsUserID) else {
            return false
        }
        return lhsUserID == rhsUserID
    }

    static func refreshFailure(statusCode: Int, data: Data) -> ProviderError {
        let details = oauthErrorDetails(from: data)
        let code = normalized(details.code)?.replacingOccurrences(of: "-", with: "_")
        let description = normalized(details.description) ?? ""
        let combined = [code, description].compactMap { $0 }.joined(separator: " ")

        if combined.contains("reused")
            || combined.contains("already used")
            || combined.contains("rotat") {
            return ProviderError(
                "refresh_token_reused",
                "The Codex refresh token was already rotated by another session. Sign in again to replace this credential."
            )
        }

        if combined.contains("expired") || combined.contains("revoked") {
            return ProviderError(
                "refresh_token_expired",
                "The Codex refresh token expired or was revoked. Sign in again to reconnect this account."
            )
        }

        if code == "invalid_grant"
            || code == "invalid_token"
            || statusCode == 400
            || statusCode == 401 {
            return ProviderError(
                "refresh_token_invalid",
                "The Codex refresh token was rejected. Sign in again if the account does not recover automatically."
            )
        }

        if statusCode == 429 {
            return ProviderError(
                "oauth_rate_limited",
                "Codex OAuth is temporarily rate limited. Wait a moment and try again."
            )
        }

        if (500..<600).contains(statusCode) {
            return ProviderError(
                "oauth_server_error",
                "Codex OAuth is temporarily unavailable (HTTP \(statusCode))."
            )
        }

        return ProviderError(
            "oauth_refresh_failed",
            "Codex OAuth refresh failed (HTTP \(statusCode))."
        )
    }

    static func refreshTransportFailure(_ error: Error) -> ProviderError {
        guard let urlError = error as? URLError else {
            return ProviderError(
                "oauth_network_error",
                "Codex OAuth refresh could not complete because of a network error."
            )
        }

        switch urlError.code {
        case .timedOut:
            return ProviderError(
                "oauth_network_timeout",
                "Codex OAuth refresh timed out. Check the network or proxy and try again."
            )
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return ProviderError(
                "oauth_network_unavailable",
                "Codex OAuth could not reach the authentication service. Check the network or proxy."
            )
        default:
            return ProviderError(
                "oauth_network_error",
                "Codex OAuth refresh failed because of a network error."
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func oauthErrorDetails(from data: Data) -> (code: String?, description: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        if let code = object["error"] as? String {
            return (code, object["error_description"] as? String ?? object["message"] as? String)
        }
        if let nested = object["error"] as? [String: Any] {
            return (
                nested["code"] as? String ?? nested["type"] as? String,
                nested["message"] as? String ?? object["error_description"] as? String
            )
        }
        return (nil, object["error_description"] as? String ?? object["message"] as? String)
    }
}
