import Foundation
import SQLite3
import os.log

// MARK: - OpenCode Node Stats Fetcher
// 受管节点（providerID 以 aiusage 开头）的用量统计与最近请求明细，供管理页展示。
// 数据来源: opencode.db message 表（临时快照 + READONLY，复用 OpenCodeCostProvider 机制）。
// 工作方式: SQL LIKE 预过滤受管 providerID 行 → JSON 防御解析 → 按 providerID 聚合 +
//          截取最近 N 条明细。费用为 OpenCode 预计算冻结值，与用量统计页同一口径，
//          不与代理日志混账（代理日志仅观测成功率/时延）。

private let openCodeNodeStatsLog = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeNodeStats")

public enum OpenCodeNodeStatsFetcher {

    // MARK: - Output Types

    /// 单个受管节点（providerID）的全量聚合。
    public struct NodeStats: Sendable {
        public var requestCount = 0
        public var inputTokens = 0
        public var outputTokens = 0
        public var cacheReadTokens = 0
        public var cacheCreateTokens = 0
        public var totalTokens = 0
        public var costUsd: Double = 0
        public var lastUsedAt: Date?
    }

    /// 一条 assistant 消息的展示明细（新→旧）。
    public struct RecentMessage: Sendable, Identifiable {
        public let id: String
        public let date: Date
        public let providerID: String
        public let modelID: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheCreateTokens: Int
        public let costUsd: Double
        /// data.time.completed - created；任一缺失为 nil。
        public let durationMs: Int?

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens
        }
    }

    public struct Snapshot: Sendable {
        public var statsByProviderID: [String: NodeStats] = [:]
        /// 全部受管节点合并的最近明细（新→旧，封顶 recentLimit）。
        public var recentMessages: [RecentMessage] = []
        public var generatedAt = Date()
    }

    // MARK: - Change Detection

    /// 轻量变更指纹：opencode.db / -wal 的 mtime+size 拼接。
    /// 管理页轮询比对，仅在库真正变化时才触发整库快照扫描。
    public static func databaseFingerprint(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let provider = OpenCodeCostProvider(homeDirectory: homeDirectory, environment: environment)
        guard let dataDirectory = provider.resolveDataDirectory() else { return nil }
        let dbPath = (dataDirectory as NSString).appendingPathComponent(OpenCodeCostProvider.databaseFilename)

        var parts: [String] = []
        for path in [dbPath, dbPath + "-wal"] {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? Int) ?? 0
            parts.append("\(mtime):\(size)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    // MARK: - Fetch

    /// 同步阻塞读取（调用方负责放后台任务）。opencode.db 不存在时返回 nil。
    public static func fetch(
        providerIDPrefix: String = "aiusage",
        recentLimit: Int = 200,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Snapshot? {
        let provider = OpenCodeCostProvider(homeDirectory: homeDirectory, environment: environment)
        guard let dataDirectory = provider.resolveDataDirectory() else { return nil }

        let snapshotPath = try provider.makeDatabaseSnapshot(dataDirectory: dataDirectory)
        defer { provider.cleanupDatabaseSnapshot(snapshotPath) }

        let rows = try fetchManagedRows(databasePath: snapshotPath, likePattern: "%\(providerIDPrefix)%")

        var snapshot = Snapshot()
        let decoder = JSONDecoder()
        for row in rows {
            guard let message = try? decoder.decode(OpenCodeCostProvider.MessageData.self, from: row.data),
                  message.role == "assistant",
                  let providerID = message.providerID,
                  providerID.hasPrefix(providerIDPrefix) else {
                continue
            }

            let input = message.tokens?.input ?? 0
            let output = message.tokens?.output ?? 0
            let cacheRead = message.tokens?.cache?.read ?? 0
            let cacheCreate = message.tokens?.cache?.write ?? 0
            let cost = message.cost ?? 0
            let total = input + output + cacheRead + cacheCreate
            guard total > 0 || cost > 0 else { continue }

            let date = Date(timeIntervalSince1970: Double(row.timeCreatedMillis) / 1000)

            var stats = snapshot.statsByProviderID[providerID] ?? NodeStats()
            stats.requestCount += 1
            stats.inputTokens += input
            stats.outputTokens += output
            stats.cacheReadTokens += cacheRead
            stats.cacheCreateTokens += cacheCreate
            stats.totalTokens += total
            stats.costUsd += cost
            if stats.lastUsedAt.map({ date > $0 }) ?? true {
                stats.lastUsedAt = date
            }
            snapshot.statsByProviderID[providerID] = stats

            if snapshot.recentMessages.count < recentLimit {
                var durationMs: Int?
                if let created = message.time?.created, let completed = message.time?.completed, completed >= created {
                    durationMs = Int(completed - created)
                }
                snapshot.recentMessages.append(RecentMessage(
                    id: row.messageId,
                    date: date,
                    providerID: providerID,
                    modelID: message.modelID ?? "unknown",
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheCreateTokens: cacheCreate,
                    costUsd: cost,
                    durationMs: durationMs
                ))
            }
        }

        openCodeNodeStatsLog.debug("OpenCode node stats: \(snapshot.statsByProviderID.count, privacy: .public) providers, \(snapshot.recentMessages.count, privacy: .public) recent rows")
        return snapshot
    }

    // MARK: - SQL

    private struct ManagedRow {
        let messageId: String
        let timeCreatedMillis: Int64
        let data: Data
    }

    /// LIKE 预过滤受管行，按时间新→旧返回。模式只是粗筛（避免全表 JSON 解析），
    /// providerID 前缀精确匹配在解析后进行。
    private static func fetchManagedRows(databasePath: String, likePattern: String) throws -> [ManagedRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw ProviderError("db_open_failed", SensitiveDataRedactor.redactPaths(in: message))
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, time_created, data FROM message WHERE data LIKE ? ORDER BY time_created DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ProviderError("db_query_failed", SensitiveDataRedactor.redactPaths(in: message))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, likePattern, -1, transient)

        var rows: [ManagedRow] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                let message = String(cString: sqlite3_errmsg(db))
                throw ProviderError("db_step_failed", SensitiveDataRedactor.redactPaths(in: message))
            }

            guard let idCString = sqlite3_column_text(statement, 0),
                  let dataCString = sqlite3_column_text(statement, 2) else {
                continue
            }
            rows.append(ManagedRow(
                messageId: String(cString: idCString),
                timeCreatedMillis: sqlite3_column_int64(statement, 1),
                data: Data(String(cString: dataCString).utf8)
            ))
        }
        return rows
    }
}
