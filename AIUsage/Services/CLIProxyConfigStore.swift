import Foundation

nonisolated struct CLIProxyConfigStore {
    private struct StateFile: Codable {
        let version: Int
        var settings: CLIProxyGatewaySettings
    }

    private let paths: CLIProxyPaths
    private let fileManager: FileManager

    init(paths: CLIProxyPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadSettings() -> CLIProxyGatewaySettings {
        guard let data = fileManager.contents(atPath: paths.stateURL.path),
              let state = try? JSONDecoder().decode(StateFile.self, from: data),
              state.version == 1 else { return .default }
        return state.settings.normalized
    }

    func saveSettings(_ settings: CLIProxyGatewaySettings) throws {
        do {
            try paths.prepare(fileManager: fileManager)
            let data = try JSONEncoder.pretty.encode(StateFile(version: 1, settings: settings.normalized))
            try data.write(to: paths.stateURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateURL.path)
        } catch {
            throw CLIProxyGatewayError.configuration(error.localizedDescription)
        }
    }

    func writeRuntimeConfig(settings: CLIProxyGatewaySettings, secrets: CLIProxySecrets) throws {
        let value = settings.normalized
        guard (1_024...65_535).contains(value.port) else {
            throw CLIProxyGatewayError.invalidPort(value.port)
        }
        let proxyLine = value.proxyURL.isEmpty ? "" : "\nproxy-url: \(yamlQuoted(value.proxyURL))"
        let config = """
        host: "127.0.0.1"
        port: \(value.port)
        auth-dir: \(yamlQuoted(paths.authDirectory.path))
        api-keys:
          - \(yamlQuoted(secrets.clientAPIKey))
        remote-management:
          allow-remote: false
          secret-key: \(yamlQuoted(secrets.managementKey))
          disable-control-panel: true
        routing:
          strategy: \(yamlQuoted(value.routingStrategy.rawValue))
        request-retry: \(value.requestRetry)
        plugins:
          enabled: \(value.enablePlugins ? "true" : "false")
        debug: false
        logging-to-file: false
        usage-statistics-enabled: true\(proxyLine)
        """
        do {
            try paths.prepare(fileManager: fileManager)
            try config.write(to: paths.configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configURL.path)
        } catch {
            throw CLIProxyGatewayError.configuration(error.localizedDescription)
        }
    }

    private func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

nonisolated private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
