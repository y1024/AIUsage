import Foundation
import os.log

// MARK: - OpenCode Config Manager
// 管理 ~/.config/opencode/opencode.json：注入受管的 provider["aiusage"] 块
// （npm: @ai-sdk/openai-compatible + baseURL/apiKey/models），并把顶层 model 指向
// "aiusage/<模型>"；停用时从备份完整还原原文。OpenCode 原生直连上游，无本地代理进程。
//
// 数据来源/写入目标: $XDG_CONFIG_HOME/opencode/opencode.json（默认 ~/.config/opencode/）
// 工作方式: 结构化 JSON 读写。激活前把「干净原文」备份到 opencode.json.aiusage.bak
//          （备份即真相源，重复激活幂等），还原即覆盖回原文。
// 边界: 检测到 opencode.jsonc（含注释，无法保真重写）或 JSON 解析失败时拒绝接管。
// 安全: 写入的配置含 API Key，落盘后恢复 0600 权限。

private let openCodeConfigLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeConfig")

enum OpenCodeConfigError: LocalizedError {
    case jsoncUnsupported
    case invalidJSON
    case nodeIncomplete
    case failedToWriteFile
    case failedToRestore

    var errorDescription: String? {
        switch self {
        case .jsoncUnsupported:
            return AppSettings.shared.t(
                "opencode.jsonc (with comments) is in use. AIUsage cannot rewrite it safely — please migrate it to opencode.json first.",
                "检测到 opencode.jsonc（含注释），AIUsage 无法安全改写——请先将其迁移为 opencode.json。"
            )
        case .invalidJSON:
            return AppSettings.shared.t(
                "opencode.json could not be parsed as JSON, refusing to take over.",
                "opencode.json 无法解析为 JSON，已拒绝接管。"
            )
        case .nodeIncomplete:
            return AppSettings.shared.t(
                "The node is missing a base URL or model list.",
                "节点缺少 Base URL 或模型列表。"
            )
        case .failedToWriteFile:
            return AppSettings.shared.t("Failed to write opencode.json.", "写入 opencode.json 失败。")
        case .failedToRestore:
            return AppSettings.shared.t(
                "Failed to restore opencode.json from backup.",
                "从备份还原 opencode.json 失败。"
            )
        }
    }
}

final class OpenCodeConfigManager {
    static let shared = OpenCodeConfigManager()

    /// 受管 provider id。OpenCode 内置 provider 无此名，不冲突。
    static let providerId = "aiusage"

    private let fileManager = FileManager.default

    // MARK: - Paths

    var configDirectory: String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?.nilIfBlank {
            return (xdg as NSString).appendingPathComponent("opencode")
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/opencode")
    }

    var configPath: String {
        (configDirectory as NSString).appendingPathComponent("opencode.json")
    }

    private var jsoncPath: String {
        (configDirectory as NSString).appendingPathComponent("opencode.jsonc")
    }

    private var backupPath: String {
        configPath + ".aiusage.bak"
    }

    // MARK: - State

    /// 用户使用 jsonc 配置时无法接管（无法保真重写注释）。
    var usesJSONC: Bool {
        fileManager.fileExists(atPath: jsoncPath)
    }

    /// 当前 opencode.json 是否处于受管理（已注入节点）状态。
    var isManaged: Bool {
        guard let root = try? readConfigObjectIfExists() else { return false }
        let provider = root["provider"] as? [String: Any]
        return provider?[Self.providerId] != nil
    }

    /// 是否存在我们的备份（代表接管态/未正常还原）。
    var hasBackup: Bool {
        fileManager.fileExists(atPath: backupPath)
    }

    // MARK: - Activation

    /// 注入节点配置：provider["aiusage"]（baseURL/apiKey/models）+ 顶层 model 指向受管 provider。
    func activate(node: OpenCodeNode) throws {
        guard !usesJSONC else { throw OpenCodeConfigError.jsoncUnsupported }
        guard let defaultModel = node.effectiveDefaultModel, node.isComplete else {
            throw OpenCodeConfigError.nodeIncomplete
        }

        // 备份即真相源：已有备份时原文以备份为准（重复激活/切换节点幂等，不把受管文件当原文）。
        let pristine: [String: Any]
        if hasBackup {
            pristine = try readObject(atPath: backupPath) ?? [:]
        } else if fileManager.fileExists(atPath: configPath) {
            let current = try readConfigObjectIfExists() ?? [:]
            // 防御：万一当前文件残留旧受管块，先剥离再作为原文备份。
            let clean = stripManagedEntries(from: current)
            try writeObject(clean, toPath: backupPath)
            pristine = clean
        } else {
            pristine = [:]
        }

        var root = pristine
        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }

        var modelsBlock: [String: Any] = [:]
        for modelId in node.models where !modelId.isEmpty {
            var entry: [String: Any] = ["name": modelId]
            var limit: [String: Any] = [:]
            if node.contextLimit > 0 { limit["context"] = node.contextLimit }
            if node.outputLimit > 0 { limit["output"] = node.outputLimit }
            if !limit.isEmpty { entry["limit"] = limit }
            modelsBlock[modelId] = entry
        }

        var options: [String: Any] = ["baseURL": node.baseURL]
        if let apiKey = node.apiKey.nilIfBlank {
            options["apiKey"] = apiKey
        }

        var provider = root["provider"] as? [String: Any] ?? [:]
        provider[Self.providerId] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": node.displayName,
            "options": options,
            "models": modelsBlock,
        ] as [String: Any]
        root["provider"] = provider
        root["model"] = "\(Self.providerId)/\(defaultModel)"

        try writeObject(root, toPath: configPath, restrictPermissions: true)
        openCodeConfigLog.info("opencode.json managed provider injected (node=\(node.id, privacy: .public), models=\(node.models.count))")
    }

    // MARK: - Deactivation

    /// 还原 opencode.json：有备份则整文覆盖回原文并删除备份；无备份则剥离受管块（必要时删文件）。
    func restore() throws {
        if hasBackup {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
                try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
                applyRestrictivePermissions(toPath: configPath)
                try? fileManager.removeItem(atPath: backupPath)
                openCodeConfigLog.info("opencode.json restored from backup")
            } catch {
                openCodeConfigLog.error("Failed to restore opencode.json: \(String(describing: error), privacy: .public)")
                throw OpenCodeConfigError.failedToRestore
            }
            return
        }

        // 无备份：可能是我们新建的文件（仅受管块），或本就未受管理。
        guard let root = try? readConfigObjectIfExists() else { return }
        let stripped = stripManagedEntries(from: root)
        let meaningfulKeys = stripped.keys.filter { $0 != "$schema" }
        if meaningfulKeys.isEmpty {
            try? fileManager.removeItem(atPath: configPath)
            openCodeConfigLog.info("opencode.json removed (was managed-only, no backup)")
        } else {
            try writeObject(stripped, toPath: configPath, restrictPermissions: true)
            openCodeConfigLog.info("opencode.json managed entries stripped (no backup)")
        }
    }

    // MARK: - Transform

    /// 剥离受管条目：provider["aiusage"]（空了则连 provider 键一起删）与指向它的顶层 model。
    func stripManagedEntries(from root: [String: Any]) -> [String: Any] {
        var result = root
        if var provider = result["provider"] as? [String: Any] {
            provider.removeValue(forKey: Self.providerId)
            if provider.isEmpty {
                result.removeValue(forKey: "provider")
            } else {
                result["provider"] = provider
            }
        }
        if let model = result["model"] as? String, model.hasPrefix("\(Self.providerId)/") {
            result.removeValue(forKey: "model")
        }
        return result
    }

    // MARK: - File IO

    /// 读取 opencode.json 为字典；文件不存在返回 nil，存在但非合法 JSON 对象时抛错。
    private func readConfigObjectIfExists() throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: configPath) else { return nil }
        return try readObject(atPath: configPath)
    }

    private func readObject(atPath path: String) throws -> [String: Any]? {
        guard let data = fileManager.contents(atPath: path) else {
            throw OpenCodeConfigError.invalidJSON
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OpenCodeConfigError.invalidJSON
        }
        return root
    }

    private func writeObject(_ object: [String: Any], toPath path: String, restrictPermissions: Bool = false) throws {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if restrictPermissions {
                applyRestrictivePermissions(toPath: path)
            }
        } catch {
            openCodeConfigLog.error("Failed to write \((path as NSString).lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            throw OpenCodeConfigError.failedToWriteFile
        }
    }

    /// 配置可能含 API Key，写入后恢复 0600 权限。
    private func applyRestrictivePermissions(toPath path: String) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
