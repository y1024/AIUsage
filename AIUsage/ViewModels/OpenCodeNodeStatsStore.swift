import Foundation
import Combine
import os.log
import QuotaBackend

// MARK: - OpenCode Node Stats Store
// 管理页的节点用量数据源：包装 OpenCodeNodeStatsFetcher（opencode.db 按 providerID 聚合
// + 最近明细），主线程发布。费用口径与用量统计页一致（OpenCode 预计算冻结值）；
// 成功率/失败明细不在此处——那是代理日志（OpenCodeProxyRuntime）的职责。
// 刷新时机: 管理页出现、激活/停用后、手动刷新；页面可见期间轮询 db 指纹
// （mtime+size，3s 一次），库有变化才整库扫描——对话产生新消息后秒级反映到统计。

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
    /// 页面可见期间的 db 指纹轮询间隔。
    private static let pollInterval: TimeInterval = 3

    private var pollTimer: Timer?
    private var lastFingerprint: String?

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
                // 指纹先于扫库采样：扫库期间的新写入会让下一次轮询的指纹不一致，
                // 从而再触发一次刷新（反过来采样则可能漏掉一轮更新）。
                let result = try await Task.detached(priority: .utility) {
                    (fingerprint: OpenCodeNodeStatsFetcher.databaseFingerprint(),
                     snapshot: try OpenCodeNodeStatsFetcher.fetch())
                }.value
                statsByProviderID = result.snapshot?.statsByProviderID ?? [:]
                recentMessages = result.snapshot?.recentMessages ?? []
                lastFingerprint = result.fingerprint
                lastRefreshedAt = Date()
            } catch {
                openCodeStatsLog.error("Failed to load OpenCode node stats: \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)")
            }
        }
    }

    // MARK: - Visible-Page Polling

    /// 管理页可见期间启动：轮询 db 指纹，变化才整库扫描（无变化零开销）。
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollOnce()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        guard !isLoading else { return }
        Task {
            let fingerprint = await Task.detached(priority: .utility) {
                OpenCodeNodeStatsFetcher.databaseFingerprint()
            }.value
            guard fingerprint != lastFingerprint else { return }
            refresh()
        }
    }
}
