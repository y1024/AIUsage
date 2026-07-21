import Foundation
import CryptoKit
import Darwin
#if canImport(QuotaBackend)
import QuotaBackend
#endif

// MARK: - Claude Desktop official 3P profile transaction

struct ClaudeDesktopCatalogEntry: Equatable, Identifiable {
    let id: String
    let upstreamModel: String
    let displayName: String
    let supports1M: Bool
}

struct ClaudeDesktopInstallation: Equatable {
    let appURL: URL?
    let version: String?

    var isInstalled: Bool { appURL != nil }

    static func inspect(workspace: FileManager = .default) -> ClaudeDesktopInstallation {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            workspace.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"),
        ]
        guard let url = candidates.first(where: { workspace.fileExists(atPath: $0.path) }) else {
            return ClaudeDesktopInstallation(appURL: nil, version: nil)
        }
        let bundle = Bundle(url: url)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return ClaudeDesktopInstallation(appURL: url, version: version)
    }
}

enum ClaudeDesktopProfileError: LocalizedError {
    case desktopNotInstalled
    case invalidJSONObject(String)
    case profileOwnedByAnotherTool
    case profileChangedExternally(String)
    case noRestoreJournal
    case lockUnavailable
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .desktopNotInstalled:
            return AppSettings.shared.t(
                "Claude Desktop is not installed in Applications.",
                "未在「应用程序」中找到 Claude Desktop。"
            )
        case .invalidJSONObject(let name):
            return AppSettings.shared.t(
                "Claude Desktop configuration \(name) is not a JSON object. Nothing was changed.",
                "Claude Desktop 配置 \(name) 不是 JSON 对象，未做任何修改。"
            )
        case .profileOwnedByAnotherTool:
            return AppSettings.shared.t(
                "Claude Desktop is now using a profile selected by another tool. AIUsage did not overwrite it.",
                "Claude Desktop 已被其它工具切换到另一份配置，AIUsage 没有覆盖它。"
            )
        case .profileChangedExternally(let name):
            return AppSettings.shared.t(
                "Claude Desktop configuration \(name) changed outside AIUsage. It was left untouched.",
                "Claude Desktop 配置 \(name) 已被外部修改，AIUsage 未覆盖它。"
            )
        case .noRestoreJournal:
            return AppSettings.shared.t("No AIUsage Desktop connection is recorded.", "没有可恢复的 AIUsage Desktop 连接记录。")
        case .lockUnavailable:
            return AppSettings.shared.t("Claude Desktop configuration is busy. Try again in a moment.", "Claude Desktop 配置正忙，请稍后重试。")
        case .verificationFailed(let reason):
            return AppSettings.shared.t(
                "Claude Desktop configuration verification failed: \(reason)",
                "Claude Desktop 配置校验失败：\(reason)"
            )
        }
    }

    var isExternalConflict: Bool {
        switch self {
        case .profileOwnedByAnotherTool, .profileChangedExternally:
            return true
        default:
            return false
        }
    }
}

final class ClaudeDesktopProfileStore {
    static let shared = ClaudeDesktopProfileStore()

    /// Stable forever after release.  A stable identity avoids duplicate
    /// entries when users alternate between AIUsage and another profile tool.
    static let profileID = "a1a5a9e0-7c1d-4e5f-9a0b-c1d2e3f4a5b6"
    static let profileName = "AIUsage Gateway"

    struct Paths {
        let normalConfig: URL
        let threePConfig: URL
        let meta: URL
        let profile: URL
        let journal: URL
        let lock: URL

        init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let normalRoot = appSupport.appendingPathComponent("Claude", isDirectory: true)
            let threePRoot = appSupport.appendingPathComponent("Claude-3p", isDirectory: true)
            let library = threePRoot.appendingPathComponent("configLibrary", isDirectory: true)
            let stateRoot = home.appendingPathComponent(".config/aiusage/claude-desktop", isDirectory: true)
            normalConfig = normalRoot.appendingPathComponent("claude_desktop_config.json")
            threePConfig = threePRoot.appendingPathComponent("claude_desktop_config.json")
            meta = library.appendingPathComponent("_meta.json")
            profile = library.appendingPathComponent("\(ClaudeDesktopProfileStore.profileID).json")
            journal = stateRoot.appendingPathComponent("restore-state.json")
            lock = stateRoot.appendingPathComponent("profile.lock")
        }

        var protectedFiles: [URL] { [normalConfig, threePConfig, meta, profile] }
    }

    enum Phase: String, Codable {
        case applying
        case active
        case externalConflict
    }

    struct FileSnapshot: Codable {
        let path: String
        let existed: Bool
        let data: Data?
        let permissions: UInt16?
        let sha256: String?
    }

    struct Journal: Codable {
        let version: Int
        var phase: Phase
        let createdAt: Date
        let snapshots: [FileSnapshot]
        var managedHashes: [String: String]
    }

    struct Status: Equatable {
        let isApplied: Bool
        let isOwnedByAIUsage: Bool
        let hasJournal: Bool
        let appliedProfileName: String?
    }

    private let fileManager: FileManager
    let paths: Paths

    init(fileManager: FileManager = .default, paths: Paths = Paths()) {
        self.fileManager = fileManager
        self.paths = paths
    }

    #if canImport(QuotaBackend)
    static func catalog(
        for node: ProxyConfiguration,
        supports1M: Set<String> = []
    ) -> [ClaudeDesktopCatalogEntry] {
        var upstreamModels = node.modelLibrary.map(\.name)
        if upstreamModels.isEmpty {
            upstreamModels = [
                node.defaultModel,
                node.modelMapping.bigModel.name,
                node.modelMapping.middleModel.name,
                node.modelMapping.smallModel.name,
            ]
        }
        let adapter = ScienceModelProtocolAdapter(
            upstreamModels: upstreamModels,
            requestedDefault: node.defaultModel,
            routeStyle: .desktop,
            supports1MUpstreamModels: supports1M
        )
        return adapter.models.map {
            ClaudeDesktopCatalogEntry(
                id: $0.id,
                upstreamModel: $0.upstreamModel,
                displayName: $0.displayName,
                supports1M: $0.supports1M
            )
        }
    }
    #endif

    func status() -> Status {
        let metaObject = (try? readJSONObject(paths.meta, missingAsEmpty: true)) ?? [:]
        let appliedID = metaObject["appliedId"] as? String
        let entries = metaObject["entries"] as? [[String: Any]] ?? []
        let appliedName = entries.first(where: { $0["id"] as? String == appliedID })?["name"] as? String
        let isOwn = appliedID == Self.profileID
        return Status(
            isApplied: appliedID != nil,
            isOwnedByAIUsage: isOwn,
            hasJournal: fileManager.fileExists(atPath: paths.journal.path),
            appliedProfileName: appliedName
        )
    }

    /// Recover only an interrupted apply.  An active journal is the exact
    /// snapshot needed for a future user-requested disconnect and must stay.
    func recoverInterruptedApplyIfNeeded() throws {
        try withLock {
            guard var journal = try loadJournal() else { return }
            guard journal.phase == .applying else { return }
            try restore(journal.snapshots)
            try removeJournal()
            journal.managedHashes.removeAll()
        }
    }

    func connect(
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry]
    ) throws {
        try withLock {
            if let journal = try loadJournal() {
                switch journal.phase {
                case .applying:
                    try restore(journal.snapshots)
                    try removeJournal()
                case .active:
                    guard status().isOwnedByAIUsage else {
                        throw ClaudeDesktopProfileError.profileOwnedByAnotherTool
                    }
                    var checkedJournal = journal
                    try ensureManagedFilesUnchanged(&checkedJournal)
                    try refreshLocked(baseURL: baseURL, clientKey: clientKey, catalog: catalog, journal: checkedJournal)
                    return
                case .externalConflict:
                    throw ClaudeDesktopProfileError.profileOwnedByAnotherTool
                }
            }

            let snapshots = try paths.protectedFiles.map(snapshot)
            var journal = Journal(
                version: 1,
                phase: .applying,
                createdAt: Date(),
                snapshots: snapshots,
                managedHashes: [:]
            )
            try writeJournal(journal)

            do {
                var normal = try readJSONObject(paths.normalConfig, missingAsEmpty: true)
                var threeP = try readJSONObject(paths.threePConfig, missingAsEmpty: true)
                var meta = try readJSONObject(paths.meta, missingAsEmpty: true)
                var profile = try readJSONObject(paths.profile, missingAsEmpty: true)

                normal["deploymentMode"] = "3p"
                threeP["deploymentMode"] = "3p"
                mergeMeta(&meta)
                mergeProfile(&profile, baseURL: baseURL, clientKey: clientKey, catalog: catalog)

                try writeJSONObject(normal, to: paths.normalConfig)
                try writeJSONObject(threeP, to: paths.threePConfig)
                try writeJSONObject(meta, to: paths.meta)
                try writeJSONObject(profile, to: paths.profile)
                try verify(baseURL: baseURL, clientKey: clientKey, expectedModelCount: catalog.count)

                journal.phase = .active
                journal.managedHashes = try managedHashes()
                try writeJournal(journal)
            } catch {
                try? restore(snapshots)
                try? removeJournal()
                throw error
            }
        }
    }

    func refresh(
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry]
    ) throws {
        try withLock {
            guard var journal = try loadJournal(), journal.phase == .active else {
                throw ClaudeDesktopProfileError.noRestoreJournal
            }
            guard status().isOwnedByAIUsage else {
                throw ClaudeDesktopProfileError.profileOwnedByAnotherTool
            }
            try ensureManagedFilesUnchanged(&journal)
            try refreshLocked(baseURL: baseURL, clientKey: clientKey, catalog: catalog, journal: journal)
        }
    }

    /// Returns true when the exact pre-connect bytes were restored.  If a
    /// third-party tool changed appliedId, fail closed and leave its selection
    /// untouched.
    @discardableResult
    func disconnect() throws -> Bool {
        try withLock {
            guard var journal = try loadJournal() else {
                throw ClaudeDesktopProfileError.noRestoreJournal
            }
            guard status().isOwnedByAIUsage else {
                journal.phase = .externalConflict
                try writeJournal(journal)
                throw ClaudeDesktopProfileError.profileOwnedByAnotherTool
            }
            try ensureManagedFilesUnchanged(&journal)
            try restore(journal.snapshots)
            try removeJournal()
            return true
        }
    }

    // MARK: - Merge / verification

    private func refreshLocked(
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry],
        journal original: Journal
    ) throws {
        var journal = original
        var profile = try readJSONObject(paths.profile, missingAsEmpty: true)
        mergeProfile(&profile, baseURL: baseURL, clientKey: clientKey, catalog: catalog)
        try writeJSONObject(profile, to: paths.profile)
        try verify(baseURL: baseURL, clientKey: clientKey, expectedModelCount: catalog.count)
        journal.managedHashes = try managedHashes()
        try writeJournal(journal)
    }

    private func mergeMeta(_ object: inout [String: Any]) {
        let rawEntries = object["entries"] as? [Any] ?? []
        var entries: [[String: Any]] = rawEntries.compactMap { $0 as? [String: Any] }
        var firstOwnIndex: Int?
        entries = entries.enumerated().compactMap { index, entry in
            guard entry["id"] as? String == Self.profileID else { return entry }
            if firstOwnIndex == nil {
                firstOwnIndex = index
                var updated = entry
                updated["name"] = Self.profileName
                return updated
            }
            return nil
        }
        if !entries.contains(where: { $0["id"] as? String == Self.profileID }) {
            entries.append(["id": Self.profileID, "name": Self.profileName])
        }
        object["entries"] = entries
        object["appliedId"] = Self.profileID
    }

    private func mergeProfile(
        _ object: inout [String: Any],
        baseURL: String,
        clientKey: String,
        catalog: [ClaudeDesktopCatalogEntry]
    ) {
        object["inferenceProvider"] = "gateway"
        object["inferenceGatewayBaseUrl"] = baseURL
        object["inferenceGatewayApiKey"] = clientKey
        object["disableDeploymentModeChooser"] = true
        // The profile and /v1/models both expose a presentation label. The
        // route remains Anthropic-shaped while the user sees the real upstream
        // model name in Claude Desktop's picker.
        object.removeValue(forKey: "inferenceGatewayAuthScheme")
        object["inferenceModels"] = catalog.map { entry -> [String: Any] in
            var model: [String: Any] = [
                "name": entry.id,
                "labelOverride": entry.displayName,
            ]
            if entry.supports1M { model["supports1m"] = true }
            return model
        }
    }

    private func verify(baseURL: String, clientKey: String, expectedModelCount: Int) throws {
        let normal = try readJSONObject(paths.normalConfig, missingAsEmpty: false)
        let threeP = try readJSONObject(paths.threePConfig, missingAsEmpty: false)
        let meta = try readJSONObject(paths.meta, missingAsEmpty: false)
        let profile = try readJSONObject(paths.profile, missingAsEmpty: false)
        guard normal["deploymentMode"] as? String == "3p",
              threeP["deploymentMode"] as? String == "3p",
              meta["appliedId"] as? String == Self.profileID,
              profile["inferenceGatewayBaseUrl"] as? String == baseURL,
              profile["inferenceGatewayApiKey"] as? String == clientKey,
              (profile["inferenceModels"] as? [[String: Any]])?.count == expectedModelCount else {
            throw ClaudeDesktopProfileError.verificationFailed("round-trip mismatch")
        }
    }

    // MARK: - Byte snapshots / durable journal

    private func snapshot(_ url: URL) throws -> FileSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return FileSnapshot(path: url.path, existed: false, data: nil, permissions: nil, sha256: nil)
        }
        let data = try Data(contentsOf: url)
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        return FileSnapshot(
            path: url.path,
            existed: true,
            data: data,
            permissions: permissions,
            sha256: Self.sha256(data)
        )
    }

    private func restore(_ snapshots: [FileSnapshot]) throws {
        for item in snapshots {
            let url = URL(fileURLWithPath: item.path)
            if item.existed, let data = item.data {
                try atomicWrite(data, to: url, permissions: item.permissions ?? 0o600)
                guard Self.sha256(try Data(contentsOf: url)) == item.sha256 else {
                    throw ClaudeDesktopProfileError.verificationFailed(url.lastPathComponent)
                }
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func managedHashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for url in paths.protectedFiles where fileManager.fileExists(atPath: url.path) {
            result[url.path] = Self.sha256(try Data(contentsOf: url))
        }
        return result
    }

    /// Restoring byte snapshots necessarily overwrites the four protected
    /// files. Refuse that restore when another process edited any of them after
    /// AIUsage connected, even if it left our `appliedId` selected.
    private func ensureManagedFilesUnchanged(_ journal: inout Journal) throws {
        for url in paths.protectedFiles {
            guard let expected = journal.managedHashes[url.path],
                  fileManager.fileExists(atPath: url.path),
                  Self.sha256(try Data(contentsOf: url)) == expected else {
                journal.phase = .externalConflict
                try writeJournal(journal)
                throw ClaudeDesktopProfileError.profileChangedExternally(url.lastPathComponent)
            }
        }
    }

    private func loadJournal() throws -> Journal? {
        guard fileManager.fileExists(atPath: paths.journal.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Journal.self, from: Data(contentsOf: paths.journal))
    }

    private func writeJournal(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try atomicWrite(try encoder.encode(journal), to: paths.journal, permissions: 0o600)
    }

    private func removeJournal() throws {
        if fileManager.fileExists(atPath: paths.journal.path) {
            try fileManager.removeItem(at: paths.journal)
        }
    }

    private func readJSONObject(_ url: URL, missingAsEmpty: Bool) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            if missingAsEmpty { return [:] }
            throw ClaudeDesktopProfileError.verificationFailed("missing \(url.lastPathComponent)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw ClaudeDesktopProfileError.invalidJSONObject(url.lastPathComponent)
        }
        return dictionary
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try atomicWrite(data + Data("\n".utf8), to: url, permissions: 0o600)
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: UInt16) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: paths.lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(paths.lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ClaudeDesktopProfileError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ClaudeDesktopProfileError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
