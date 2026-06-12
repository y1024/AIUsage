import Foundation
import Combine
import os.log
import QuotaBackend

// MARK: - OpenCode Node Stats Store
// 管理页的节点用量数据源：包装 OpenCodeNodeStatsFetcher（opencode.db 按 providerID 聚合
// + 最近明细），主线程发布。费用口径与用量统计页一致（OpenCode 预计算冻结值）；
// 成功率/失败明细不在此处——那是代理日志（OpenCodeProxyRuntime）的职责。
// 刷新时机: 管理页出现、激活/停用后、手动刷新；防并发去重。

private let openCodeStatsLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeNodeStats")

@MainActor
final class OpenCodeNodeStatsStore: ObservableObject {
    static let shared = OpenCodeNodeStatsStore()

    @Published private(set) var statsByProviderID: [String: OpenCodeNodeStatsFetcher.NodeStats] = [:]
    @Published private(set) var recentMessages: [OpenCodeNodeStatsFetcher.RecentMessage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshedAt: Date?

    /// 自动刷新的最小间隔（视图反复出现时避免重复扫库）。
    private static let autoRefreshInterval: TimeInterval = 30

    func stats(for node: OpenCodeNode) -> OpenCodeNodeStatsFetcher.NodeStats? {
        statsByProviderID[node.managedProviderId]
    }

    func recentMessages(for node: OpenCodeNode) -> [OpenCodeNodeStatsFetcher.RecentMessage] {
        recentMessages.filter { $0.providerID == node.managedProviderId }
    }

    /// 视图出现时的节流刷新。
    func refreshIfStale() {
        if let last = lastRefreshedAt, Date().timeIntervalSince(last) < Self.autoRefreshInterval {
            return
        }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try OpenCodeNodeStatsFetcher.fetch()
                }.value
                statsByProviderID = snapshot?.statsByProviderID ?? [:]
                recentMessages = snapshot?.recentMessages ?? []
                lastRefreshedAt = Date()
            } catch {
                openCodeStatsLog.error("Failed to load OpenCode node stats: \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)")
            }
        }
    }
}
