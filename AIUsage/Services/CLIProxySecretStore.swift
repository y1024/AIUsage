import Foundation
import QuotaBackend
import Security

nonisolated struct CLIProxySecretStore: Sendable {
    private enum Key {
        static let management = "cliproxy.gateway.management-key.v1"
        static let client = "cliproxy.gateway.client-api-key.v1"
    }

    func loadOrCreate() throws -> CLIProxySecrets {
        CLIProxySecrets(
            managementKey: try loadOrCreate(Key.management, prefix: "cpa-mgmt"),
            clientAPIKey: try loadOrCreate(Key.client, prefix: "cpa-client")
        )
    }

    func load() -> CLIProxySecrets? {
        guard let management = string(for: Key.management),
              let client = string(for: Key.client) else { return nil }
        return CLIProxySecrets(managementKey: management, clientAPIKey: client)
    }

    func delete() throws {
        do {
            try AccountCredentialStore.shared.saveAuxiliaryData(nil, forKey: Key.management)
            try AccountCredentialStore.shared.saveAuxiliaryData(nil, forKey: Key.client)
        } catch {
            throw CLIProxyGatewayError.secretStorage(error.localizedDescription)
        }
    }

    private func loadOrCreate(_ key: String, prefix: String) throws -> String {
        if let existing = string(for: key) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CLIProxyGatewayError.secretStorage("secure random generation failed")
        }
        let value = "\(prefix)-" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        do {
            try AccountCredentialStore.shared.saveAuxiliaryData(Data(value.utf8), forKey: key)
        } catch {
            throw CLIProxyGatewayError.secretStorage(error.localizedDescription)
        }
        return value
    }

    private func string(for key: String) -> String? {
        guard let data = AccountCredentialStore.shared.loadAuxiliaryData(forKey: key),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }
}
