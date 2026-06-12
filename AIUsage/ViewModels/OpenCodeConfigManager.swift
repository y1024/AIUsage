import Foundation
import os.log

// MARK: - OpenCode Config Manager
// 管理 ~/.config/opencode/opencode.json：注入受管的 provider["aiusage-<节点>"] 块
// （npm 按节点协议选择 @ai-sdk/openai-compatible|anthropic|openai + baseURL/apiKey/models），
// 并把顶层 model 指向 "aiusage-<节点>/<模型>"；停用时从备份完整还原原文。
// 直连模式 OpenCode 原生直连上游；代理模式经 baseURLOverride 指向本地透传代理（路线 B）。
// provider id 按节点区分（node.managedProviderId）——opencode.db 的消息会携带它作为
// providerID，Phase 1 统计据此把用量/费用归因到具体节点。
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

    /// 受管 provider id 前缀。OpenCode 内置 provider 无此前缀，不冲突。
    /// 实际键为 `aiusage-<节点 slug>`（兼容剥离早期固定的 `aiusage`）。
    static let providerIdPrefix = "aiusage"

    /// 是否为本应用注入的受管 provider 键。
    static func isManagedProviderKey(_ key: String) -> Bool {
        key == providerIdPrefix || key.hasPrefix(providerIdPrefix + "-")
    }

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
        guard let provider = root["provider"] as? [String: Any] else { return false }
        return provider.keys.contains(where: Self.isManagedProviderKey)
    }

    /// 是否存在我们的备份（代表接管态/未正常还原）。
    var hasBackup: Bool {
        fileManager.fileExists(atPath: backupPath)
    }

    // MARK: - Activation

    /// 注入节点配置：provider["aiusage-<节点>"]（baseURL/apiKey/models）+ 顶层 model 指向受管 provider。
    /// - Parameter baseURLOverride: 代理模式下指向本地透传代理（如 http://127.0.0.1:4321/v1），
    ///   上游真实 baseURL/Key 由代理进程持有，不再出现在 opencode.json。
    func activate(node: OpenCodeNode, baseURLOverride: String? = nil) throws {
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

        // 防御性再剥离：备份理应是干净原文，但异常残留时也不会叠加多个受管块。
        let root = injectManagedEntries(
            into: stripManagedEntries(from: pristine),
            node: node,
            defaultModel: defaultModel,
            baseURLOverride: baseURLOverride
        )

        try writeObject(root, toPath: configPath, restrictPermissions: true)
        openCodeConfigLog.info("opencode.json managed provider injected (provider=\(node.managedProviderId, privacy: .public), models=\(node.models.count))")
    }

    // MARK: - Managed Block Building

    /// 受管 provider 条目（写进 provider[managedProviderId] 的值）。激活与编辑器 JSON 预览共用。
    func managedProviderEntry(node: OpenCodeNode, baseURLOverride: String? = nil) -> [String: Any] {
        // 定价（USD/百万 token）写入每个模型的 cost 块，OpenCode 据此把费用算进
        // opencode.db——金额单一来源，统计页直接呈现，不在本地重复计费。
        var costBlock: [String: Any] = [:]
        if node.hasPricing {
            costBlock["input"] = node.priceInputPerMillion
            costBlock["output"] = node.priceOutputPerMillion
            if node.priceCacheReadPerMillion > 0 { costBlock["cache_read"] = node.priceCacheReadPerMillion }
            if node.priceCacheWritePerMillion > 0 { costBlock["cache_write"] = node.priceCacheWritePerMillion }
        }

        var modelsBlock: [String: Any] = [:]
        for modelId in node.models where !modelId.isEmpty {
            var entry: [String: Any] = ["name": modelId]
            var limit: [String: Any] = [:]
            if node.contextLimit > 0 { limit["context"] = node.contextLimit }
            if node.outputLimit > 0 { limit["output"] = node.outputLimit }
            if !limit.isEmpty { entry["limit"] = limit }
            if !costBlock.isEmpty { entry["cost"] = costBlock }
            modelsBlock[modelId] = entry
        }

        var options: [String: Any] = ["baseURL": baseURLOverride ?? node.baseURL]
        if baseURLOverride != nil {
            // 代理模式：真实 Key 留在代理进程环境里，配置里只放占位符
            // （AI SDK 各包都需要非空 apiKey 才不会去找环境变量）。
            options["apiKey"] = "aiusage-proxy"
        } else if let apiKey = node.apiKey.nilIfBlank {
            options["apiKey"] = apiKey
        }

        return [
            "npm": node.protocolType.npmPackage,
            "name": node.displayName,
            "options": options,
            "models": modelsBlock,
        ]
    }

    /// 把受管块注入干净原文：provider[managedId] + 顶层 model 指向（含 $schema 补齐）。
    private func injectManagedEntries(
        into cleanRoot: [String: Any],
        node: OpenCodeNode,
        defaultModel: String,
        baseURLOverride: String?
    ) -> [String: Any] {
        var root = cleanRoot
        if root["$schema"] == nil {
            root["$schema"] = "https://opencode.ai/config.json"
        }
        let managedId = node.managedProviderId
        var provider = root["provider"] as? [String: Any] ?? [:]
        provider[managedId] = managedProviderEntry(node: node, baseURLOverride: baseURLOverride)
        root["provider"] = provider
        root["model"] = "\(managedId)/\(defaultModel)"
        return root
    }

    /// 编辑器 JSON 预览：激活该节点后 opencode.json 的完整内容（基于备份/当前原文合成，不落盘）。
    /// 节点缺默认模型时顶层 model 留空字符串占位，仅供预览。
    func previewMergedConfig(node: OpenCodeNode, baseURLOverride: String? = nil) -> [String: Any] {
        let pristine: [String: Any]
        if hasBackup {
            pristine = (try? readObject(atPath: backupPath)) ?? [:]
        } else {
            pristine = (try? readConfigObjectIfExists()) ?? [:]
        }
        return injectManagedEntries(
            into: stripManagedEntries(from: pristine),
            node: node,
            defaultModel: node.effectiveDefaultModel ?? "",
            baseURLOverride: baseURLOverride
        )
    }

    // MARK: - Launch Command Export

    /// 「复制启动命令」：导出与激活完全同口径的合并配置（不碰全局 opencode.json），
    /// 写到 ~/.config/aiusage/opencode-configs/<slug>.json（0600），返回
    /// `OPENCODE_CONFIG="<path>" opencode`。代理模式节点指向本地代理（需代理在运行）。
    func makeLaunchCommand(node: OpenCodeNode) throws -> String {
        guard node.isComplete else { throw OpenCodeConfigError.nodeIncomplete }
        let merged = previewMergedConfig(
            node: node,
            baseURLOverride: node.proxyEnabled ? node.proxyLocalBaseURL : nil
        )
        let home = fileManager.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent(".config/aiusage/opencode-configs")
        let slug = node.providerSlug?.nilIfBlank ?? node.preferredSlug()
        let path = (dir as NSString).appendingPathComponent("\(slug).json")
        try writeObject(merged, toPath: path, restrictPermissions: true)
        return "OPENCODE_CONFIG=\"\(path)\" opencode"
    }

    /// 预览用的稳定序列化（与落盘格式一致：pretty + sortedKeys + 不转义斜杠）。
    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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

    /// 剥离全部受管条目：`aiusage*` provider 键（空了则连 provider 键一起删）与指向它们的顶层 model。
    func stripManagedEntries(from root: [String: Any]) -> [String: Any] {
        var result = root
        if var provider = result["provider"] as? [String: Any] {
            for key in provider.keys where Self.isManagedProviderKey(key) {
                provider.removeValue(forKey: key)
            }
            if provider.isEmpty {
                result.removeValue(forKey: "provider")
            } else {
                result["provider"] = provider
            }
        }
        if let model = result["model"] as? String,
           let modelProvider = model.split(separator: "/", maxSplits: 1).first,
           Self.isManagedProviderKey(String(modelProvider)) {
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
