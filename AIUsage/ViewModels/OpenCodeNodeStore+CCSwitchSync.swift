import Foundation
import SQLite3
import CryptoKit

// MARK: - OpenCodeNodeStore cc-switch Sync
// 与 cc-switch 的 OpenCode 供应商「镜像同步」（与 Claude/Codex 的 cc-switch 导入同语义）。
// cc-switch 把 OpenCode 供应商存在 ~/.cc-switch/cc-switch.db 的 providers 表
// （app_type='opencode'），settings_config 即 opencode.json 的 provider 片段：
//   { "npm": "@ai-sdk/openai-compatible", "options": { "baseURL", "apiKey", ... },
//     "models": { "<id>": { "name", "limit": {context,output}, "cost": {input,output,...} } } }
// npm 包名映射到本地协议类型；models 的 cost 块（USD/百万 token）映射为每模型定价。
// cc-switch 对 OpenCode 没有通用配置（其源码对 OpenCode 的 common config 显式不适用），
// 故只同步供应商节点。节点 id 由 cc-switch 行 id 派生为确定性 UUID，重复同步执行
// upsert（保留本地代理设置、归因 slug、排序、创建时间），不产生重复节点。
// SQLite 读取放后台线程，仅把 Sendable 的原始文本行带回主线程解析。

extension OpenCodeNodeStore {

    struct CCSwitchSyncResult {
        var imported = 0
        var updated = 0
        var failed = 0
        var errors: [String] = []
    }

    /// 后台读取的原始行：只含 Sendable 标量/字符串。
    private struct RawRow: Sendable {
        let id: String
        let name: String
        let settingsText: String
    }

    private struct ReadOutput: Sendable {
        var rawRows: [RawRow] = []
        var dbMissing = false
        var openFailed = false
    }

    // MARK: - Entry Point

    func importCCSwitchOpenCodeNodes(dbPath: String? = nil) async -> CCSwitchSyncResult {
        let path = dbPath ?? CCSwitchLocator.databasePath()
        let output = await Task.detached(priority: .userInitiated) {
            Self.readCCSwitchOpenCodeData(dbPath: path)
        }.value

        var result = CCSwitchSyncResult()
        if output.dbMissing {
            result.failed = 1
            result.errors.append("cc-switch database not found: \(path)")
            return result
        }
        if output.openFailed {
            result.failed = 1
            result.errors.append("failed to open cc-switch database")
            return result
        }
        if output.rawRows.isEmpty {
            result.errors.append("no cc-switch OpenCode providers found")
            return result
        }

        var nextOrder = (nodes.map(\.sortOrder).max() ?? -1) + 1
        for raw in output.rawRows {
            guard let node = makeNode(from: raw, appendOrder: nextOrder) else {
                result.failed += 1
                result.errors.append("\(raw.name.nilIfBlank ?? raw.id): invalid OpenCode provider config")
                continue
            }
            let isNew = !nodes.contains { $0.id == node.id }
            if isNew { nextOrder += 1 }
            // upsert 统一处理 slug 生成、排序、落盘，以及激活中/仅代理运行中节点的滚动重载。
            upsert(node)
            if isNew { result.imported += 1 } else { result.updated += 1 }
        }
        return result
    }

    // MARK: - Row → Node Mapping

    /// 把 cc-switch 行映射为节点。已存在同 id 节点时保留本地专属字段
    /// （代理模式/端口、合并策略、归因 slug、创建时间、排序、默认模型选择）。
    private func makeNode(from raw: RawRow, appendOrder: Int) -> OpenCodeNode? {
        guard let data = raw.settingsText.data(using: .utf8),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let options = settings["options"] as? [String: Any] ?? [:]
        guard let baseURL = (options["baseURL"] as? String)?.nilIfBlank else { return nil }
        let apiKey = (options["apiKey"] as? String) ?? ""
        let npm = (settings["npm"] as? String) ?? "@ai-sdk/openai-compatible"

        var entries: [OpenCodeModelEntry] = []
        var contextLimit = 0
        var outputLimit = 0
        let models = settings["models"] as? [String: Any] ?? [:]
        for modelId in models.keys.sorted() {
            guard modelId.nilIfBlank != nil else { continue }
            let model = models[modelId] as? [String: Any] ?? [:]
            let cost = model["cost"] as? [String: Any] ?? [:]
            entries.append(OpenCodeModelEntry(
                id: modelId,
                priceInputPerMillion: Self.doubleValue(cost["input"]),
                priceOutputPerMillion: Self.doubleValue(cost["output"]),
                priceCacheReadPerMillion: Self.doubleValue(cost["cache_read"]),
                priceCacheWritePerMillion: Self.doubleValue(cost["cache_write"])
            ))
            if let limit = model["limit"] as? [String: Any] {
                contextLimit = max(contextLimit, Int(Self.doubleValue(limit["context"])))
                outputLimit = max(outputLimit, Int(Self.doubleValue(limit["output"])))
            }
        }
        guard !entries.isEmpty else { return nil }

        let stableId = Self.stableNodeId(forCCSwitchRowId: raw.id)
        let existing = nodes.first { $0.id == stableId }
        let name = raw.name.nilIfBlank
            ?? (settings["name"] as? String)?.nilIfBlank
            ?? raw.id

        var node = existing ?? OpenCodeNode(id: stableId, sortOrder: appendOrder)
        node.name = name
        node.baseURL = baseURL
        node.apiKey = apiKey
        node.protocolType = Self.protocolType(forNPMPackage: npm)
        node.modelEntries = entries
        node.contextLimit = contextLimit
        node.outputLimit = outputLimit
        // cc-switch 的 cost 块固定为 USD/百万 token；无任何定价时不计价。
        node.pricingCurrency = entries.contains(where: \.hasPricing) ? .usd : .none
        if !node.models.contains(node.defaultModel) {
            node.defaultModel = node.models.first ?? ""
        }
        return node
    }

    /// npm 包名 → 协议类型。未知包按 OpenAI 兼容处理（cc-switch 预设以该包为主）。
    private static func protocolType(forNPMPackage npm: String) -> OpenCodeProtocol {
        if npm.contains("openai-compatible") { return .openAICompatible }
        if npm.contains("anthropic") { return .anthropic }
        if npm.contains("openai") { return .openAIResponses }
        return .openAICompatible
    }

    /// 由 cc-switch 行 id + OpenCode 专用盐派生确定性节点 id（与 Claude/Codex 导入同构），
    /// 保证多次同步命中同一节点。
    private static func stableNodeId(forCCSwitchRowId rowId: String) -> String {
        let digest = SHA256.hash(data: Data("aiusage.ccswitch.opencode.\(rowId)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02X", Int($0)) }.joined()
        func seg(_ lo: Int, _ hi: Int) -> Substring {
            hex[hex.index(hex.startIndex, offsetBy: lo)..<hex.index(hex.startIndex, offsetBy: hi)]
        }
        return "\(seg(0, 8))-\(seg(8, 12))-\(seg(12, 16))-\(seg(16, 20))-\(seg(20, 32))"
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) ?? 0 }
        return 0
    }

    // MARK: - SQLite Read (background)

    nonisolated private static func readCCSwitchOpenCodeData(dbPath: String) -> ReadOutput {
        var output = ReadOutput()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            output.dbMissing = true
            return output
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            output.openFailed = true
            return output
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, name, settings_config
        FROM providers
        WHERE app_type = 'opencode'
        ORDER BY sort_index, name
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return output }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            output.rawRows.append(RawRow(
                id: columnText(stmt, 0) ?? UUID().uuidString,
                name: columnText(stmt, 1) ?? "",
                settingsText: columnText(stmt, 2) ?? "{}"
            ))
        }
        return output
    }

    nonisolated private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}
