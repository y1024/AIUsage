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
        let managementKey = secrets.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientKey = secrets.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !managementKey.isEmpty, !clientKey.isEmpty, managementKey != clientKey else {
            throw CLIProxyGatewayError.configuration("CPA management and client keys must be non-empty and distinct")
        }
        do {
            try paths.prepare(fileManager: fileManager)
            let existing = try existingRuntimeConfig()
            var document = RuntimeYAMLDocument(existing)
            let configuredPluginDirectory = try document.nestedStringScalar(
                section: "plugins",
                key: "dir"
            )
            document.setTopLevelScalar("host", value: yamlQuoted(value.bindHost))
            document.setTopLevelScalar("port", value: "\(value.port)")
            document.setTopLevelScalar("auth-dir", value: yamlQuoted(paths.authDirectory.path))
            try document.upsertTopLevelStringSequence(
                "api-keys",
                value: clientKey,
                quotedValue: yamlQuoted(clientKey),
                replacingValuesWithPrefix: "cpa-client-"
            )
            // CPA's /v1/ws route bypasses the normal AuthMiddleware when this is false.
            // Keep it authenticated for loopback and LAN operation alike.
            document.setTopLevelScalar("ws-auth", value: "true")
            try document.setNestedScalar(section: "remote-management", key: "allow-remote", value: "false")
            try document.setNestedScalar(
                section: "remote-management",
                key: "secret-key",
                value: yamlQuoted(managementKey)
            )
            try document.setNestedScalar(
                section: "remote-management",
                key: "disable-control-panel",
                value: "true"
            )
            try document.setNestedScalar(
                section: "routing",
                key: "strategy",
                value: yamlQuoted(value.routingStrategy.rawValue)
            )
            document.setTopLevelScalar("request-retry", value: "\(value.requestRetry)")
            try document.setNestedScalar(
                section: "plugins",
                key: "enabled",
                value: value.enablePlugins ? "true" : "false"
            )
            // Perform filesystem migration only after the existing YAML has passed
            // every structural validation above.
            let runtimePluginDirectory = try paths.runtimePluginsDirectory(
                configuredPath: configuredPluginDirectory,
                fileManager: fileManager
            )
            try document.setNestedScalar(
                section: "plugins",
                key: "dir",
                value: yamlQuoted(runtimePluginDirectory.path)
            )
            document.setTopLevelScalar("debug", value: "false")
            document.setTopLevelScalar("logging-to-file", value: "false")
            document.setTopLevelScalar("usage-statistics-enabled", value: "true")
            if value.proxyURL.isEmpty {
                document.removeTopLevel("proxy-url")
            } else {
                document.setTopLevelScalar("proxy-url", value: yamlQuoted(value.proxyURL))
            }
            let config = document.rendered
            try config.write(to: paths.configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configURL.path)
        } catch {
            if let error = error as? CLIProxyGatewayError { throw error }
            throw CLIProxyGatewayError.configuration(error.localizedDescription)
        }
    }

    private func existingRuntimeConfig() throws -> String? {
        guard fileManager.fileExists(atPath: paths.configURL.path) else { return nil }
        do {
            return try String(contentsOf: paths.configURL, encoding: .utf8)
        } catch {
            throw CLIProxyGatewayError.configuration(
                "existing CPA config could not be read safely: \(error.localizedDescription)"
            )
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

/// A deliberately small, lossless editor for the scalar paths AIUsage owns.
/// Unknown top-level fields and nested CPA/plugin configuration remain byte-for-byte
/// intact. Inline mappings are rejected instead of being rewritten destructively.
nonisolated private struct RuntimeYAMLDocument {
    private var lines: [String]

    init(_ source: String?) {
        guard let source, !source.isEmpty else {
            lines = []
            return
        }
        lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    var rendered: String {
        lines.joined(separator: "\n") + "\n"
    }

    mutating func setTopLevelScalar(_ key: String, value: String) {
        guard let range = topLevelRange(key) else {
            appendBlock(["\(key): \(value)"])
            return
        }
        if hasInlineValue(at: range.lowerBound) || range.count == 1 {
            lines[range.lowerBound] = "\(key): \(value)"
        } else {
            lines.replaceSubrange(contentRange(range), with: ["\(key): \(value)"])
        }
    }

    mutating func upsertTopLevelStringSequence(
        _ key: String,
        value: String,
        quotedValue: String,
        replacingValuesWithPrefix managedPrefix: String? = nil
    ) throws {
        guard let range = topLevelRange(key) else {
            appendBlock(["\(key):", "  - \(quotedValue)"])
            return
        }
        guard !hasInlineValue(at: range.lowerBound) else {
            throw CLIProxyGatewayError.configuration(
                "CPA config uses an unsupported inline sequence for '\(key)'; it was left unchanged"
            )
        }

        var currentValueFound = false
        var obsoleteManagedIndices: [Int] = []
        for index in lines.indices where range.contains(index) && index > range.lowerBound {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard leadingSpaces(in: lines[index]) == 2,
                  trimmed.first == "-",
                  trimmed.dropFirst().first?.isWhitespace == true else {
                throw CLIProxyGatewayError.configuration(
                    "CPA config uses an unsupported complex sequence for '\(key)'; it was left unchanged"
                )
            }
            let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let existingValue = try parseSimpleStringScalar(item, context: key)
            if existingValue == value {
                if currentValueFound {
                    obsoleteManagedIndices.append(index)
                } else {
                    currentValueFound = true
                }
            } else if let managedPrefix, existingValue.hasPrefix(managedPrefix) {
                obsoleteManagedIndices.append(index)
            }
        }

        // Old AIUsage client keys must be revoked on Keychain loss/rotation while
        // unrelated user-managed CPA keys remain byte-for-byte intact.
        for index in obsoleteManagedIndices.reversed() {
            lines.remove(at: index)
        }
        guard !currentValueFound else { return }
        guard let updatedRange = topLevelRange(key) else {
            throw CLIProxyGatewayError.configuration(
                "CPA config changed unexpectedly while updating '\(key)'"
            )
        }
        lines.insert("  - \(quotedValue)", at: contentRange(updatedRange).upperBound)
    }

    func nestedStringScalar(section: String, key: String) throws -> String? {
        guard let sectionRange = topLevelRange(section) else { return nil }
        guard !hasInlineValue(at: sectionRange.lowerBound) else {
            throw CLIProxyGatewayError.configuration(
                "CPA config uses an unsupported inline mapping for '\(section)'; it was left unchanged"
            )
        }
        guard let valueRange = nestedRange(sectionRange: sectionRange, key: key) else { return nil }
        guard hasInlineValue(at: valueRange.lowerBound),
              let colon = lines[valueRange.lowerBound].firstIndex(of: ":") else {
            throw CLIProxyGatewayError.configuration(
                "CPA config uses an unsupported complex value for '\(section).\(key)'; it was left unchanged"
            )
        }
        for index in valueRange.dropFirst() {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#") else {
                throw CLIProxyGatewayError.configuration(
                    "CPA config uses an unsupported complex value for '\(section).\(key)'; it was left unchanged"
                )
            }
        }
        let scalar = String(lines[valueRange.lowerBound][lines[valueRange.lowerBound].index(after: colon)...])
        return try parseSimpleStringScalar(scalar, context: "\(section).\(key)")
    }

    mutating func removeTopLevel(_ key: String) {
        guard let range = topLevelRange(key) else { return }
        lines.removeSubrange(contentRange(range))
        trimRepeatedBlankLines()
    }

    mutating func setNestedScalar(section: String, key: String, value: String) throws {
        guard let sectionRange = topLevelRange(section) else {
            appendBlock(["\(section):", "  \(key): \(value)"])
            return
        }
        guard !hasInlineValue(at: sectionRange.lowerBound) else {
            throw CLIProxyGatewayError.configuration(
                "CPA config uses an unsupported inline mapping for '\(section)'; it was left unchanged"
            )
        }
        if let nestedRange = nestedRange(sectionRange: sectionRange, key: key) {
            if hasInlineValue(at: nestedRange.lowerBound) || nestedRange.count == 1 {
                lines[nestedRange.lowerBound] = "  \(key): \(value)"
            } else {
                lines.replaceSubrange(contentRange(nestedRange), with: ["  \(key): \(value)"])
            }
        } else {
            lines.insert("  \(key): \(value)", at: sectionRange.upperBound)
        }
    }

    private func topLevelRange(_ key: String) -> Range<Int>? {
        guard let start = lines.indices.first(where: { mappingKey(in: lines[$0], indent: 0) == key }) else {
            return nil
        }
        let end = lines.indices.dropFirst(start + 1).first(where: {
            mappingKey(in: lines[$0], indent: 0) != nil
        }) ?? lines.endIndex
        return start..<end
    }

    private func nestedRange(sectionRange: Range<Int>, key: String) -> Range<Int>? {
        let body = lines.indices.filter { sectionRange.contains($0) && $0 > sectionRange.lowerBound }
        guard let start = body.first(where: { mappingKey(in: lines[$0], indent: 2) == key }) else {
            return nil
        }
        let end = body.drop(while: { $0 <= start }).first(where: {
            leadingSpaces(in: lines[$0]) <= 2 && mappingKey(in: lines[$0], indent: 2) != nil
        }) ?? sectionRange.upperBound
        return start..<end
    }

    private func contentRange(_ range: Range<Int>) -> Range<Int> {
        var upper = range.upperBound
        while upper > range.lowerBound + 1 {
            let value = lines[upper - 1].trimmingCharacters(in: .whitespaces)
            guard value.isEmpty || value.hasPrefix("#") else { break }
            upper -= 1
        }
        return range.lowerBound..<upper
    }

    private func mappingKey(in line: String, indent: Int) -> String? {
        guard leadingSpaces(in: line) == indent else { return nil }
        let trimmed = line.dropFirst(indent)
        guard !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon])
        guard !key.isEmpty,
              key.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else { return nil }
        return key
    }

    private func leadingSpaces(in line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private func hasInlineValue(at index: Int) -> Bool {
        guard let colon = lines[index].firstIndex(of: ":") else { return false }
        return !lines[index][lines[index].index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    private func parseSimpleStringScalar(_ source: String, context: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw unsupportedScalar(context)
        }
        if value.first == "\"" {
            return try parseDoubleQuotedScalar(value, context: context)
        }
        if value.first == "'" {
            return try parseSingleQuotedScalar(value, context: context)
        }

        var characters = Array(value)
        if let comment = characters.indices.first(where: {
            characters[$0] == "#" && $0 > characters.startIndex && characters[$0 - 1].isWhitespace
        }) {
            characters.removeSubrange(comment...)
        }
        let plain = String(characters).trimmingCharacters(in: .whitespaces)
        guard let first = plain.first,
              !"[{&*!|>@`".contains(first),
              !plain.enumerated().contains(where: { offset, character in
                  guard character == ":" else { return false }
                  let next = plain.index(plain.startIndex, offsetBy: offset + 1)
                  return next < plain.endIndex && plain[next].isWhitespace
              }) else {
            throw unsupportedScalar(context)
        }
        return plain
    }

    private func parseSingleQuotedScalar(_ source: String, context: String) throws -> String {
        let characters = Array(source)
        var result = ""
        var index = 1
        while index < characters.count {
            if characters[index] == "'" {
                if index + 1 < characters.count, characters[index + 1] == "'" {
                    result.append("'")
                    index += 2
                    continue
                }
                try validateScalarRemainder(characters[(index + 1)...], context: context)
                return result
            }
            result.append(characters[index])
            index += 1
        }
        throw unsupportedScalar(context)
    }

    private func parseDoubleQuotedScalar(_ source: String, context: String) throws -> String {
        let characters = Array(source)
        var result = ""
        var index = 1
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                try validateScalarRemainder(characters[(index + 1)...], context: context)
                return result
            }
            guard character == "\\" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { throw unsupportedScalar(context) }
            switch characters[index] {
            case "0": result.append("\0")
            case "a": result.append("\u{7}")
            case "b": result.append("\u{8}")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "v": result.append("\u{B}")
            case "f": result.append("\u{C}")
            case "r": result.append("\r")
            case "e": result.append("\u{1B}")
            case " ": result.append(" ")
            case "\"": result.append("\"")
            case "/": result.append("/")
            case "\\": result.append("\\")
            case "N": result.append("\u{85}")
            case "_": result.append("\u{A0}")
            case "L": result.append("\u{2028}")
            case "P": result.append("\u{2029}")
            case "x", "u", "U":
                let count = characters[index] == "x" ? 2 : (characters[index] == "u" ? 4 : 8)
                let start = index + 1
                let end = start + count
                guard end <= characters.count,
                      let codePoint = UInt32(String(characters[start..<end]), radix: 16),
                      let scalar = UnicodeScalar(codePoint) else {
                    throw unsupportedScalar(context)
                }
                result.unicodeScalars.append(scalar)
                index = end - 1
            default:
                throw unsupportedScalar(context)
            }
            index += 1
        }
        throw unsupportedScalar(context)
    }

    private func validateScalarRemainder(
        _ remainder: ArraySlice<Character>,
        context: String
    ) throws {
        let trailing = String(remainder).trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else {
            throw unsupportedScalar(context)
        }
    }

    private func unsupportedScalar(_ context: String) -> CLIProxyGatewayError {
        CLIProxyGatewayError.configuration(
            "CPA config uses an unsupported YAML scalar for '\(context)'; it was left unchanged"
        )
    }

    private mutating func appendBlock(_ block: [String]) {
        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(contentsOf: block)
    }

    private mutating func trimRepeatedBlankLines() {
        var index = lines.count - 1
        while index > 0 {
            if lines[index].isEmpty, lines[index - 1].isEmpty { lines.remove(at: index) }
            index -= 1
        }
    }
}

nonisolated private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
