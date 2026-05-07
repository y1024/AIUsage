import Foundation
import os.log

private let claudeSettingsLog = Logger(subsystem: "com.aiusage.desktop", category: "ClaudeSettings")

enum ClaudeSettingsError: LocalizedError {
    case invalidRootObject
    case unreadableSettings
    case failedToSerialize
    case failedToCreateDirectory
    case failedToWriteFile

    var errorDescription: String? {
        switch self {
        case .invalidRootObject:
            return AppSettings.shared.t("Claude settings.json must contain a top-level object.", "Claude settings.json 必须是顶层对象。")
        case .unreadableSettings:
            return AppSettings.shared.t("Claude settings.json is unreadable or contains invalid JSON.", "Claude settings.json 无法读取或 JSON 已损坏。")
        case .failedToSerialize:
            return AppSettings.shared.t("Failed to serialize Claude settings.", "序列化 Claude 设置失败。")
        case .failedToCreateDirectory:
            return AppSettings.shared.t("Failed to create the Claude settings directory.", "创建 Claude 设置目录失败。")
        case .failedToWriteFile:
            return AppSettings.shared.t("Failed to write Claude settings.json.", "写入 Claude settings.json 失败。")
        }
    }
}

// MARK: - Claude Settings Manager

class ClaudeSettingsManager {
    static let shared = ClaudeSettingsManager()

    private var settingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".claude/settings.json")
    }

    private var backupPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".claude/settings.backup.json")
    }

    func readSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            return [:]
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let json = object as? [String: Any] else {
                claudeSettingsLog.error("Failed to read Claude settings: root object is not a dictionary")
                throw ClaudeSettingsError.invalidRootObject
            }
            return json
        } catch let error as ClaudeSettingsError {
            throw error
        } catch {
            claudeSettingsLog.error("Failed to read Claude settings from \(self.settingsPath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.unreadableSettings
        }
    }

    private let managedEnvKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "NODE_EXTRA_CA_CERTS",
    ]

    struct EnvConfig {
        var baseURL: String?
        var authToken: String?
        var defaultModel: String?
        var opusModel: String?
        var sonnetModel: String?
        var haikuModel: String?
        var nodeExtraCACerts: String?
    }

    /// Legacy partial write: only updates managed env keys + model (kept for backward compat).
    func writeEnv(_ config: EnvConfig) throws {
        var settings = try readSettings()
        var env = settings["env"] as? [String: Any] ?? [:]

        let pairs: [(String, String?)] = [
            ("ANTHROPIC_BASE_URL", config.baseURL),
            ("ANTHROPIC_AUTH_TOKEN", config.authToken),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", config.opusModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", config.sonnetModel),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", config.haikuModel),
            ("NODE_EXTRA_CA_CERTS", config.nodeExtraCACerts),
        ]
        for (key, value) in pairs {
            if let value = value {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }

        settings["env"] = env

        if let model = config.defaultModel, !model.isEmpty {
            settings["model"] = model
        } else {
            settings.removeValue(forKey: "model")
        }

        try writeSettings(settings)
    }

    /// Full replacement write: backs up current file, then writes the entire settings dict.
    func writeFullSettings(_ settings: [String: Any]) throws {
        backupCurrentSettings()
        try writeSettings(settings)
        claudeSettingsLog.info("Full settings.json replacement written successfully")
    }

    func clearEnv() throws {
        var settings = try readSettings()
        var env = settings["env"] as? [String: Any] ?? [:]
        for key in managedEnvKeys {
            env.removeValue(forKey: key)
        }
        settings["env"] = env
        settings.removeValue(forKey: "model")
        try writeSettings(settings)
    }

    /// Restore settings.json from the backup created before the last full write.
    func restoreFromBackup() throws {
        guard let data = FileManager.default.contents(atPath: backupPath) else {
            claudeSettingsLog.info("No backup file to restore from, clearing managed keys instead")
            try clearEnv()
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            claudeSettingsLog.info("Restored settings.json from backup")
        } catch {
            claudeSettingsLog.error("Failed to restore settings.json from backup: \(String(describing: error), privacy: .public)")
            try clearEnv()
        }
    }

    // MARK: - Internal

    private func backupCurrentSettings() {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return }
        do {
            if FileManager.default.fileExists(atPath: backupPath) {
                try FileManager.default.removeItem(atPath: backupPath)
            }
            try FileManager.default.copyItem(atPath: settingsPath, toPath: backupPath)
        } catch {
            claudeSettingsLog.error("Failed to backup settings.json: \(String(describing: error), privacy: .public)")
        }
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            claudeSettingsLog.error("Failed to serialize Claude settings: \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.failedToSerialize
        }

        let dir = (settingsPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            claudeSettingsLog.error("Failed to create Claude settings directory \(dir, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.failedToCreateDirectory
        }

        do {
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        } catch {
            claudeSettingsLog.error("Failed to write Claude settings at \(self.settingsPath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)")
            throw ClaudeSettingsError.failedToWriteFile
        }
    }
}
