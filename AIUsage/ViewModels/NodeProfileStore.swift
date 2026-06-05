import Foundation
import SwiftUI
import Combine
import os.log
import SQLite3
import QuotaBackend

// MARK: - Node Profile Store
// File-based persistence for NodeProfile objects. Each profile is a standalone JSON file
// at ~/.config/aiusage/profiles/<id>.json. Supports CRUD, batch import/export, and
// migration from the legacy UserDefaults-based ProxyConfiguration storage.

private let storeLog = Logger(subsystem: "com.aiusage.desktop", category: "NodeProfileStore")

@MainActor
class NodeProfileStore: ObservableObject {
    static let shared = NodeProfileStore()

    @Published var profiles: [NodeProfile] = []
    @Published var activatedProfileId: String?
    @Published var globalConfig: GlobalConfig = .empty
    @Published var codexGlobalConfig: CodexGlobalConfig = .empty

    private let fileManager = FileManager.default

    static var profilesDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/profiles")
    }

    static var globalConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/global-config.json")
    }

    static var codexGlobalConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/codex-global-config.json")
    }

    // MARK: - Lifecycle

    init() {
        ensureDirectoryExists()
        migrateFromUserDefaultsIfNeeded()
        loadAll()
        loadGlobalConfig()
        loadCodexGlobalConfig()
        restoreActivatedId()
    }

    // MARK: - Directory

    private func ensureDirectoryExists() {
        let dir = Self.profilesDirectory
        if !fileManager.fileExists(atPath: dir) {
            do {
                try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                storeLog.error("Failed to create profiles directory: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Load

    func loadAll() {
        let dir = Self.profilesDirectory
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else {
            storeLog.info("No profiles directory or empty")
            return
        }

        var loaded: [NodeProfile] = []
        for entry in entries where entry.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(entry)
            guard let data = fileManager.contents(atPath: path) else { continue }
            do {
                let profile = try NodeProfile.fromFileData(data)
                loaded.append(profile)
            } catch {
                storeLog.error("Failed to load profile \(entry, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        loaded.sort {
            if $0.metadata.sortOrder != $1.metadata.sortOrder {
                return $0.metadata.sortOrder < $1.metadata.sortOrder
            }
            return $0.metadata.createdAt < $1.metadata.createdAt
        }
        profiles = loaded
    }

    // MARK: - CRUD

    @discardableResult
    func save(_ profile: NodeProfile) -> Bool {
        ensureDirectoryExists()
        var p = profile
        let isNew = !profiles.contains(where: { $0.id == p.id })
        if isNew && p.metadata.sortOrder == Int.max {
            // 新建/复制节点默认排到列表最前（取最小 sortOrder - 1）。
            let minOrder = profiles.map { $0.metadata.sortOrder }.min() ?? 0
            p.metadata.sortOrder = minOrder - 1
        }
        let path = filePath(for: p.id)
        do {
            let data = try p.toFileData()
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if let index = profiles.firstIndex(where: { $0.id == p.id }) {
                profiles[index] = p
            } else {
                profiles.insert(p, at: 0)
            }
            return true
        } catch {
            storeLog.error("Failed to save profile \(profile.metadata.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func delete(_ id: String) {
        let path = filePath(for: id)
        try? fileManager.removeItem(atPath: path)
        profiles.removeAll { $0.id == id }
        if activatedProfileId == id {
            activatedProfileId = nil
            saveActivatedId()
        }
    }

    func profile(for id: String) -> NodeProfile? {
        profiles.first { $0.id == id }
    }

    func duplicate(_ id: String) -> NodeProfile? {
        guard let source = profile(for: id) else { return nil }
        var copy = source
        copy.metadata.id = UUID().uuidString
        copy.metadata.name = source.metadata.name + " (Copy)"
        copy.metadata.createdAt = Date()
        copy.metadata.lastUsedAt = nil
        copy.metadata.sortOrder = Int.max

        if copy.metadata.proxy.needsProxyProcess(nodeType: copy.metadata.nodeType) {
            copy.metadata.proxy.port = nextAvailablePort()
            copy.syncEnvFromProxy()
        }

        if save(copy) { return copy }
        return nil
    }

    func move(fromId: String, toIndex: Int) {
        guard let fromIndex = profiles.firstIndex(where: { $0.id == fromId }) else { return }
        let clamped = min(max(toIndex, 0), profiles.count)
        guard fromIndex != clamped, fromIndex != clamped - 1 else { return }
        let item = profiles.remove(at: fromIndex)
        let insertAt = clamped > fromIndex ? clamped - 1 : clamped
        profiles.insert(item, at: insertAt)
        persistSortOrder()
    }

    /// 增量持久化排序：仅把 `sortOrder` 与新下标不一致的节点落盘，避免每次拖拽全量重写。
    private func persistSortOrder() {
        for index in profiles.indices where profiles[index].metadata.sortOrder != index {
            profiles[index].metadata.sortOrder = index
            save(profiles[index])
        }
    }

    // MARK: - Activation State

    private static let activatedIdKey = "proxyActivatedConfigId"

    func saveActivatedId() {
        UserDefaults.standard.set(activatedProfileId, forKey: Self.activatedIdKey)
    }

    private func restoreActivatedId() {
        let shouldRestore = AppSettings.shared.proxyAutoRestoreOnLaunch
        activatedProfileId = shouldRestore
            ? UserDefaults.standard.string(forKey: Self.activatedIdKey)
            : nil
    }

    // MARK: - Batch Import

    struct ImportResult {
        var succeeded: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        var importedGlobalConfig = false
        var importedCodexGlobalConfig = false
        var skippedGlobalConfig = false
        var errors: [String] = []
    }

    // 导出/导入用的「通用配置」文件名（家族区分、语义直白）。
    // 与磁盘内部存储路径（global-config.json / codex-global-config.json）解耦——
    // 导出包里只用这两个名字，导入也只认这两个名字。
    static let claudeCommonConfigExportName = "claude-common-config.json"
    static let codexCommonConfigExportName = "codex-common-config.json"

    func importProfiles(from urls: [URL]) -> ImportResult {
        var result = ImportResult()
        var filesToImport: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let contents = try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                ) {
                    filesToImport.append(contentsOf: contents.filter { $0.pathExtension == "json" })
                }
            } else if url.pathExtension == "json" {
                filesToImport.append(url)
            }
        }

        for fileURL in filesToImport {
            if fileURL.lastPathComponent == Self.claudeCommonConfigExportName {
                if let data = try? Data(contentsOf: fileURL),
                   let imported = try? GlobalConfig.fromFileData(data) {
                    globalConfig = imported
                    saveGlobalConfig()
                    result.importedGlobalConfig = true
                }
                continue
            }

            if fileURL.lastPathComponent == Self.codexCommonConfigExportName {
                if let data = try? Data(contentsOf: fileURL),
                   let imported = try? CodexGlobalConfig.fromFileData(data) {
                    codexGlobalConfig = imported
                    saveCodexGlobalConfig()
                    result.importedCodexGlobalConfig = true
                }
                continue
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                result.failed += 1
                result.errors.append("\(fileURL.lastPathComponent): unreadable")
                continue
            }

            do {
                let profile = try NodeProfile.fromFileData(data)
                // 去重：同 id 视为同一节点（导出文件内嵌的 id 稳定，跨设备保持一致），
                // 已存在则跳过，避免重复导入同一份导出文件生成多份重复节点。
                if profiles.contains(where: { $0.id == profile.id }) {
                    result.skipped += 1
                    continue
                }
                if save(profile) {
                    result.succeeded += 1
                } else {
                    result.failed += 1
                    result.errors.append("\(fileURL.lastPathComponent): save failed")
                }
            } catch {
                result.failed += 1
                result.errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return result
    }

    // MARK: - cc-switch Import

    func importCCSwitchClaudeProfiles(dbPath: String? = nil) -> ImportResult {
        let path = dbPath ?? Self.defaultCCSwitchDBPath
        var result = ImportResult()

        guard fileManager.fileExists(atPath: path) else {
            result.failed = 1
            result.errors.append("cc-switch database not found: \(path)")
            return result
        }

        guard let db = Self.openReadonlySQLiteDB(at: path) else {
            result.failed = 1
            result.errors.append("failed to open cc-switch database")
            return result
        }
        defer { sqlite3_close(db) }

        let rows = Self.loadCCSwitchClaudeRows(db: db)
        if rows.isEmpty {
            result.skipped = 0
            result.errors.append("no cc-switch Claude providers found")
            return result
        }

        var reservedPorts = Set<Int>()
        let importDate = Date()
        for row in rows {
            do {
                let port = nextAvailablePort(startingAt: 4320, reserving: reservedPorts)
                reservedPorts.insert(port)
                let profile = try Self.makeProfile(from: row, port: port, importDate: importDate)
                if save(profile) {
                    result.succeeded += 1
                } else {
                    result.failed += 1
                    result.errors.append("\(row.name): save failed")
                }
            } catch {
                result.failed += 1
                result.errors.append("\(row.name): \(error.localizedDescription)")
            }
        }

        if let commonSettings = Self.loadCCSwitchClaudeCommonConfig(db: db), !commonSettings.isEmpty {
            if globalConfig.settings.isEmpty {
                globalConfig = GlobalConfig(enabled: true, settings: commonSettings)
                if saveGlobalConfig() {
                    result.importedGlobalConfig = true
                } else {
                    result.errors.append("failed to save cc-switch common config")
                }
            } else {
                result.skippedGlobalConfig = true
            }
        }

        return result
    }

    // MARK: - Batch Export

    @discardableResult
    func exportProfiles(ids: [String], to directory: URL) throws -> Int {
        var exported = 0
        var hasClaudeNode = false
        var hasCodexNode = false

        for id in ids {
            guard let profile = profile(for: id) else { continue }
            let isCodex = profile.metadata.nodeType.isCodex
            if isCodex { hasCodexNode = true } else { hasClaudeNode = true }

            let data = try profile.toFileData()
            let sanitizedName = profile.metadata.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            // 家族前缀让文件夹里一眼区分 Claude / Codex 节点。
            let familyPrefix = isCodex ? "codex" : "claude"
            let fileName = "\(familyPrefix)_\(sanitizedName)_\(profile.id.prefix(8)).json"
            let fileURL = directory.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)
            exported += 1
        }

        // 按家族携带对应「通用配置」：导出集合含 Claude 节点才带 Claude 通用配置，
        // 含 Codex 节点才带 Codex 通用配置（不再无条件混入 Claude 配置）。
        if hasClaudeNode, !globalConfig.settings.isEmpty {
            let data = try globalConfig.toFileData()
            let url = directory.appendingPathComponent(Self.claudeCommonConfigExportName)
            try data.write(to: url, options: .atomic)
        }
        if hasCodexNode,
           !codexGlobalConfig.tomlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = try codexGlobalConfig.toFileData()
            let url = directory.appendingPathComponent(Self.codexCommonConfigExportName)
            try data.write(to: url, options: .atomic)
        }

        return exported
    }

    // MARK: - Migration from UserDefaults

    private static let migrationKey = "proxyProfileMigrationCompleted"

    private func migrateFromUserDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else { return }
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyConfigurations) else {
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            return
        }

        storeLog.info("Starting migration from UserDefaults to profile files")
        do {
            let configs = try JSONDecoder().decode([ProxyConfiguration].self, from: data)
            for config in configs {
                let profile = NodeProfile.fromLegacyConfiguration(config)
                save(profile)
            }
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            storeLog.info("Migration completed: \(configs.count, privacy: .public) profiles migrated")
        } catch {
            storeLog.error("Migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Global Config

    func loadGlobalConfig() {
        let path = Self.globalConfigPath
        guard let data = fileManager.contents(atPath: path) else {
            globalConfig = .empty
            return
        }
        do {
            globalConfig = try GlobalConfig.fromFileData(data)
        } catch {
            storeLog.error("Failed to load global config: \(String(describing: error), privacy: .public)")
            globalConfig = .empty
        }
    }

    @discardableResult
    func saveGlobalConfig(_ config: GlobalConfig? = nil) -> Bool {
        if let config { globalConfig = config }
        let path = Self.globalConfigPath
        do {
            let data = try globalConfig.toFileData()
            let dir = (path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            storeLog.error("Failed to save global config: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Codex Global Config

    func loadCodexGlobalConfig() {
        let path = Self.codexGlobalConfigPath
        guard let data = fileManager.contents(atPath: path) else {
            codexGlobalConfig = .empty
            return
        }
        do {
            codexGlobalConfig = try CodexGlobalConfig.fromFileData(data)
        } catch {
            storeLog.error("Failed to load Codex global config: \(String(describing: error), privacy: .public)")
            codexGlobalConfig = .empty
        }
    }

    @discardableResult
    func saveCodexGlobalConfig(_ config: CodexGlobalConfig? = nil) -> Bool {
        if let config { codexGlobalConfig = config }
        let path = Self.codexGlobalConfigPath
        do {
            let data = try codexGlobalConfig.toFileData()
            let dir = (path as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            storeLog.error("Failed to save Codex global config: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Clean Settings Export

    private static var cleanSettingsDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/claude-settings")
    }

    /// Writes a clean settings file (without `_metadata`) for use with `claude --settings <path>`.
    /// Returns the file path on success, nil on failure.
    @discardableResult
    static func exportCleanSettings(for profile: NodeProfile, settings: [String: Any]) -> String? {
        let dir = cleanSettingsDirectory
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            storeLog.error("Failed to create claude-settings directory: \(String(describing: error), privacy: .public)")
            return nil
        }

        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitizedName = profile.metadata.name.unicodeScalars
            .map { allowedChars.contains($0) ? String($0) : "_" }
            .joined()
        let fileName = "\(sanitizedName).json"
        let filePath = (dir as NSString).appendingPathComponent(fileName)

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            return filePath
        } catch {
            storeLog.error("Failed to export clean settings for \(profile.metadata.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private struct CCSwitchClaudeRow {
        var id: String
        var name: String
        var settingsConfig: [String: Any]
        var isCurrent: Bool
        var createdAtMs: Int64?
        var meta: [String: Any]
    }

    private enum CCSwitchImportError: LocalizedError {
        case invalidSettings

        var errorDescription: String? {
            switch self {
            case .invalidSettings:
                return "invalid cc-switch settings JSON"
            }
        }
    }

    private static var defaultCCSwitchDBPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".cc-switch/cc-switch.db")
    }

    private static func openReadonlySQLiteDB(at path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private static func loadCCSwitchClaudeRows(db: OpaquePointer) -> [CCSwitchClaudeRow] {
        let sql = """
        SELECT id, name, settings_config, is_current, created_at, meta
        FROM providers
        WHERE app_type = 'claude'
        ORDER BY sort_index, name
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [CCSwitchClaudeRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqliteText(stmt, 0) ?? UUID().uuidString
            let name = sqliteText(stmt, 1)?.nilIfBlank ?? "cc-switch Claude"
            let settingsText = sqliteText(stmt, 2) ?? "{}"
            let metaText = sqliteText(stmt, 5) ?? "{}"
            let settings = jsonObject(from: settingsText) ?? [:]
            let meta = jsonObject(from: metaText) ?? [:]
            let createdAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
            rows.append(CCSwitchClaudeRow(
                id: id,
                name: name,
                settingsConfig: settings,
                isCurrent: sqlite3_column_int(stmt, 3) == 1,
                createdAtMs: createdAt,
                meta: meta
            ))
        }
        return rows
    }

    private static func loadCCSwitchClaudeCommonConfig(db: OpaquePointer) -> [String: Any]? {
        let sql = "SELECT value FROM settings WHERE key = 'common_config_claude' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqliteText(stmt, 0) else {
            return nil
        }
        return jsonObject(from: text)
    }

    private static func makeProfile(
        from row: CCSwitchClaudeRow,
        port: Int,
        importDate: Date
    ) throws -> NodeProfile {
        var settings = row.settingsConfig
        var env = settings["env"] as? [String: Any] ?? [:]

        let upstreamBaseURL = stringValue(env["ANTHROPIC_BASE_URL"]) ?? "https://api.anthropic.com"
        let upstreamKey = stringValue(env["ANTHROPIC_AUTH_TOKEN"]) ?? stringValue(env["ANTHROPIC_API_KEY"]) ?? ""
        let defaultModel = stringValue(env["ANTHROPIC_MODEL"])
            ?? stringValue(settings["model"])
            ?? stringValue(env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
            ?? ""
        let opus = stringValue(env["ANTHROPIC_DEFAULT_OPUS_MODEL"]) ?? defaultModel
        let sonnet = stringValue(env["ANTHROPIC_DEFAULT_SONNET_MODEL"]) ?? defaultModel
        let haiku = stringValue(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]) ?? defaultModel

        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
        env["ANTHROPIC_AUTH_TOKEN"] = upstreamKey
        if !opus.isEmpty { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opus }
        if !sonnet.isEmpty { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet }
        if !haiku.isEmpty { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku }
        settings["env"] = env
        settings["$schema"] = settings["$schema"] ?? "https://json.schemastore.org/claude-code-settings.json"
        if !defaultModel.isEmpty { settings["model"] = defaultModel }

        let commonMode: CommonConfigMode?
        if let enabled = boolValue(row.meta["commonConfigEnabled"]) ?? boolValue(row.meta["common_config_enabled"]) {
            commonMode = enabled ? .alwaysMerge : .neverMerge
        } else {
            commonMode = .followGlobal
        }

        let proxy = ProxySettings(
            host: "127.0.0.1",
            port: port,
            allowLAN: false,
            upstreamBaseURL: "https://api.openai.com",
            openAIUpstreamAPI: .chatCompletions,
            upstreamAPIKey: "",
            expectedClientKey: "",
            maxOutputTokens: 0,
            defaultModel: defaultModel,
            modelMapping: ProxyConfiguration.ModelMapping(
                bigModel: .init(name: opus),
                middleModel: .init(name: sonnet),
                smallModel: .init(name: haiku)
            ),
            anthropicBaseURL: upstreamBaseURL,
            anthropicAPIKey: upstreamKey,
            usePassthroughProxy: true,
            enableModelAliasMapping: false,
            enableHTTPS: false,
            httpsPort: nil,
            commonConfigMode: commonMode
        )

        let createdAt = row.createdAtMs.flatMap { dateFromCCSwitchTimestamp($0) } ?? importDate
        let metadata = NodeProfile.Metadata(
            id: UUID().uuidString,
            name: "\(row.name) (cc-switch)",
            nodeType: .anthropicDirect,
            createdAt: createdAt,
            lastUsedAt: row.isCurrent ? importDate : nil,
            sortOrder: Int.max,
            proxy: proxy
        )
        return NodeProfile(metadata: metadata, settings: settings)
    }

    private static func sqliteText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func dateFromCCSwitchTimestamp(_ timestamp: Int64) -> Date? {
        guard timestamp > 0 else { return nil }
        if timestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        }
        return Date(timeIntervalSince1970: Double(timestamp))
    }

    // MARK: - Helpers

    private func filePath(for id: String) -> String {
        (Self.profilesDirectory as NSString).appendingPathComponent("\(id).json")
    }

    func nextAvailablePort(startingAt startPort: Int = 8080, reserving reservedPorts: Set<Int> = []) -> Int {
        let usedPorts = Set(profiles.map(\.metadata.proxy.port)).union(reservedPorts)
        var port = startPort
        while usedPorts.contains(port) { port += 1 }
        return port
    }
}
