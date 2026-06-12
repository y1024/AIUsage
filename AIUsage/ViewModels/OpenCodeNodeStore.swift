import Foundation
import SwiftUI
import Combine
import os.log
import QuotaBackend

// MARK: - OpenCode Node Store
// OpenCode 节点的持久化与激活状态。节点列表 + activeNodeId 存为单文件
// ~/.config/aiusage/opencode-nodes.json（含 API Key，0600 权限）。
// 激活/停用委托 OpenCodeConfigManager 写 opencode.json；启动时与配置文件实际状态对账
// （用户手动改回 opencode.json 后自动视为未激活）。
// 代理模式节点：激活前先经 OpenCodeProxyRuntime 拉起本地透传进程，opencode.json 指向
// 127.0.0.1；App 重启后对账时自动恢复代理进程（否则 OpenCode 请求会失败）。

private let openCodeStoreLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeNodeStore")

@MainActor
final class OpenCodeNodeStore: ObservableObject {
    static let shared = OpenCodeNodeStore()

    @Published private(set) var nodes: [OpenCodeNode] = []
    @Published private(set) var activeNodeId: String?

    private let configManager = OpenCodeConfigManager.shared
    private let proxyRuntime = OpenCodeProxyRuntime.shared
    private let fileManager = FileManager.default

    private struct StoreFile: Codable {
        var version: Int
        var nodes: [OpenCodeNode]
        var activeNodeId: String?
    }

    private static let storeVersion = 1

    static var storePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-nodes.json")
    }

    init() {
        load()
        reconcileWithConfigFile()
        restoreProxyIfNeeded()
    }

    // MARK: - Derived State

    var activeNode: OpenCodeNode? {
        guard let activeNodeId else { return nil }
        return nodes.first { $0.id == activeNodeId }
    }

    var usesJSONC: Bool { configManager.usesJSONC }

    var configPath: String { configManager.configPath }

    // MARK: - CRUD

    func upsert(_ node: OpenCodeNode) {
        var updated = node
        ensureProviderSlug(&updated)
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = updated
        } else {
            if updated.sortOrder == Int.max {
                let minOrder = nodes.map(\.sortOrder).min() ?? 0
                updated.sortOrder = minOrder - 1
            }
            nodes.insert(updated, at: 0)
            sortNodes()
        }
        save()

        // 编辑当前激活节点后立即重新激活（重写 opencode.json，代理模式下同步重启代理进程）。
        if updated.id == activeNodeId {
            Task { [weak self] in
                try? await self?.activate(updated)
            }
        }
    }

    func delete(_ node: OpenCodeNode) {
        if node.id == activeNodeId {
            try? deactivate()
        }
        nodes.removeAll { $0.id == node.id }
        save()
    }

    // MARK: - Activation

    func activate(_ node: OpenCodeNode) async throws {
        if node.proxyEnabled {
            // 代理模式：先拉起本地透传进程，再把 opencode.json 指向它；写配置失败则回收进程。
            try await proxyRuntime.start(node: node)
            do {
                try configManager.activate(node: node, baseURLOverride: node.proxyLocalBaseURL)
            } catch {
                proxyRuntime.stop()
                throw error
            }
        } else {
            proxyRuntime.stop()
            try configManager.activate(node: node)
        }
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index].lastUsedAt = Date()
        }
        activeNodeId = node.id
        save()
    }

    func deactivate() throws {
        proxyRuntime.stop()
        try configManager.restore()
        activeNodeId = nil
        save()
    }

    /// 启动对账：opencode.json 已不在受管状态（用户手动还原/删除）时清掉激活标记。
    func reconcileWithConfigFile() {
        if activeNodeId != nil, !configManager.isManaged {
            activeNodeId = nil
            save()
        }
    }

    /// App 重启后恢复代理：激活中的代理模式节点其子进程已随上次退出而消亡，
    /// 而 opencode.json 仍指向本地端口，必须重新拉起，否则 OpenCode 请求全部失败。
    private func restoreProxyIfNeeded() {
        guard let node = activeNode, node.proxyEnabled else { return }
        Task { [proxyRuntime] in
            do {
                try await proxyRuntime.start(node: node)
            } catch {
                openCodeStoreLog.error("Failed to restore OpenCode proxy after relaunch: \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)")
            }
        }
    }

    /// 拖拽重排：按展示顺序整表重写 sortOrder 并保存。
    func applyOrder(ids: [String]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        for index in nodes.indices {
            if let order = rank[nodes[index].id] {
                nodes[index].sortOrder = order
            }
        }
        sortNodes()
        save()
    }

    /// 首次保存时生成稳定的节点 slug（统计归因键，改名不再变动）；同名冲突追加序号。
    private func ensureProviderSlug(_ node: inout OpenCodeNode) {
        guard node.providerSlug?.nilIfBlank == nil else { return }
        let base = node.preferredSlug()
        var candidate = base
        var suffix = 2
        let taken = Set(nodes.filter { $0.id != node.id }.compactMap { $0.providerSlug?.nilIfBlank })
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        node.providerSlug = candidate
    }

    // MARK: - Persistence

    private func load() {
        guard let data = fileManager.contents(atPath: Self.storePath) else { return }
        do {
            let file = try JSONDecoder.profileDecoder.decode(StoreFile.self, from: data)
            nodes = file.nodes
            activeNodeId = file.activeNodeId
            sortNodes()
            backfillProviderSlugs()
        } catch {
            openCodeStoreLog.error("Failed to load OpenCode nodes: \(String(describing: error), privacy: .public)")
        }
    }

    /// 给早期版本（无 providerSlug 字段）落库的节点补齐稳定 slug。
    private func backfillProviderSlugs() {
        var changed = false
        for index in nodes.indices where nodes[index].providerSlug?.nilIfBlank == nil {
            var node = nodes[index]
            ensureProviderSlug(&node)
            nodes[index] = node
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        let file = StoreFile(version: Self.storeVersion, nodes: nodes, activeNodeId: activeNodeId)
        do {
            let dir = (Self.storePath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder.profileEncoder.encode(file)
            try data.write(to: URL(fileURLWithPath: Self.storePath), options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storePath)
        } catch {
            openCodeStoreLog.error("Failed to save OpenCode nodes: \(String(describing: error), privacy: .public)")
        }
    }

    private func sortNodes() {
        nodes.sort {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }
    }
}
