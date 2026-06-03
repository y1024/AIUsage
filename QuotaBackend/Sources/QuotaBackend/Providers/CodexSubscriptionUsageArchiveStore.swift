import Foundation
import os.log

private let codexSubArchiveLog = Logger(subsystem: "com.aiusage.quotabackend", category: "CodexSubscriptionUsageArchive")

// MARK: - Codex Subscription Usage Archive Store
// 订阅轨的「永久每日用量归档」：JSONL 非代理(订阅)行按订阅定价表逐日折算、逐日冻结。
// 账号无关、每个 home 一张（订阅本质同源，不区分账号；按 homeDirectory 区分以隔离测试 / 多配置）。
//
// 冻结规则（与用户确认一致）：
// - 「今天之前」的日期：首次写入后即冻结，之后改价 / 重扫都不再变动 → 历史不可篡改。
// - 「今天」：仍在累加，每次扫描用当前订阅表重算并覆盖；跨天后自然冻结。
//
// 持久化（永久、放 ~/.config/aiusage 避免被系统清理）:
//   <home>/.config/aiusage/usage-archive/codex-subscription-usage-v<version>.json
// 复用 CodexUsageArchive 结构（订阅历史不重算，按 fullHistoryImportedAt 标记一次性全量冻结）。

actor CodexSubscriptionUsageArchiveStore {
    static let artifactVersion = 1

    private var archives: [String: CodexUsageArchive] = [:]
    private var loaded: Set<String> = []

    /// 是否需要全量历史导入（首次：该 home 的归档从未完成全量扫描）。
    func needsFullHistoryImport(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    /// 首次返回 true（触发一次全量扫描以冻结所有历史订阅日），完成后恒 false。
    /// 刻意不因定价签名变化触发重算——订阅历史成本不可篡改。
    func consumeFullHistoryImportRequest(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    /// 冻结合并：past(<today) 仅在缺失时首次写入；today 每次覆盖重算；已冻结的 past 保持不动。
    /// 返回合并后的全部归档日，供 costSummary 聚合。
    func freeze(
        homeDirectory: String,
        computed: [String: CodexAggregateBucket],
        todayKey: String,
        completedFullHistory: Bool
    ) -> [String: CodexAggregateBucket] {
        var archive = load(homeDirectory)
        var changed = false

        for (day, bucket) in computed where !bucket.models.isEmpty {
            if day == todayKey {
                archive.days[day] = bucket
                changed = true
            } else if archive.days[day] == nil {
                archive.days[day] = bucket
                changed = true
            }
        }

        if completedFullHistory, archive.fullHistoryImportedAt == nil {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
            changed = true
        }

        if changed {
            archive.updatedAt = SharedFormatters.iso8601String(from: Date())
            archives[homeDirectory] = archive
            save(homeDirectory, archive)
        } else {
            archives[homeDirectory] = archive
        }
        return archive.days
    }

    // MARK: Disk

    private func load(_ homeDirectory: String) -> CodexUsageArchive {
        if let archive = archives[homeDirectory], loaded.contains(homeDirectory) { return archive }
        loaded.insert(homeDirectory)

        let url = Self.fileURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexUsageArchive.self, from: data),
              decoded.version == Self.artifactVersion else {
            let fresh = CodexUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
            archives[homeDirectory] = fresh
            return fresh
        }
        archives[homeDirectory] = decoded
        return decoded
    }

    private func save(_ homeDirectory: String, _ archive: CodexUsageArchive) {
        let url = Self.fileURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(archive)
            try data.write(to: url, options: .atomic)
        } catch {
            codexSubArchiveLog.warning("Failed to save Codex subscription usage archive: \(String(describing: error), privacy: .public)")
        }
    }

    static func fileURL(homeDirectory: String) -> URL {
        let dir = (homeDirectory as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("codex-subscription-usage-v\(artifactVersion).json")
    }
}
