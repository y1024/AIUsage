import Foundation
import SwiftUI
import Combine
import os.log

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
        var errors: [String] = []
    }

    private static let globalConfigFileName = "global-config.json"

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
            if fileURL.lastPathComponent == Self.globalConfigFileName {
                if let data = try? Data(contentsOf: fileURL),
                   let imported = try? GlobalConfig.fromFileData(data) {
                    globalConfig = imported
                    saveGlobalConfig()
                    result.importedGlobalConfig = true
                }
                continue
            }

            guard let data = try? Data(contentsOf: fileURL) else {
                result.failed += 1
                result.errors.append("\(fileURL.lastPathComponent): unreadable")
                continue
            }

            do {
                var profile = try NodeProfile.fromFileData(data)
                if profiles.contains(where: { $0.id == profile.id }) {
                    profile.metadata.id = UUID().uuidString
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

    // MARK: - Batch Export

    @discardableResult
    func exportProfiles(ids: [String], to directory: URL) throws -> Int {
        var exported = 0
        for id in ids {
            guard let profile = profile(for: id) else { continue }
            let data = try profile.toFileData()
            let sanitizedName = profile.metadata.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileName = "\(sanitizedName)_\(profile.id.prefix(8)).json"
            let fileURL = directory.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)
            exported += 1
        }

        if !globalConfig.settings.isEmpty {
            let gcData = try globalConfig.toFileData()
            let gcURL = directory.appendingPathComponent(Self.globalConfigFileName)
            try gcData.write(to: gcURL, options: .atomic)
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

    // MARK: - CodeX Global Config

    func loadCodexGlobalConfig() {
        let path = Self.codexGlobalConfigPath
        guard let data = fileManager.contents(atPath: path) else {
            codexGlobalConfig = .empty
            return
        }
        do {
            codexGlobalConfig = try CodexGlobalConfig.fromFileData(data)
        } catch {
            storeLog.error("Failed to load CodeX global config: \(String(describing: error), privacy: .public)")
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
            storeLog.error("Failed to save CodeX global config: \(String(describing: error), privacy: .public)")
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

    // MARK: - Helpers

    private func filePath(for id: String) -> String {
        (Self.profilesDirectory as NSString).appendingPathComponent("\(id).json")
    }

    private func nextAvailablePort() -> Int {
        let usedPorts = Set(profiles.map(\.metadata.proxy.port))
        var port = 8080
        while usedPorts.contains(port) { port += 1 }
        return port
    }
}
