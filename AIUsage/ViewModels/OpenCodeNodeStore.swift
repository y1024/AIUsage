import Foundation
import SwiftUI
import Combine
import os.log

// MARK: - OpenCode Node Store
// OpenCode 节点的持久化与激活状态。节点列表 + activeNodeId 存为单文件
// ~/.config/aiusage/opencode-nodes.json（含 API Key，0600 权限）。
// 激活/停用委托 OpenCodeConfigManager 写 opencode.json；启动时与配置文件实际状态对账
// （用户手动改回 opencode.json 后自动视为未激活）。

private let openCodeStoreLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeNodeStore")

@MainActor
final class OpenCodeNodeStore: ObservableObject {
    static let shared = OpenCodeNodeStore()

    @Published private(set) var nodes: [OpenCodeNode] = []
    @Published private(set) var activeNodeId: String?

    private let configManager = OpenCodeConfigManager.shared
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

        // 编辑当前激活节点后立即重写 opencode.json，保持配置与节点一致。
        if updated.id == activeNodeId {
            try? configManager.activate(node: updated)
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

    func activate(_ node: OpenCodeNode) throws {
        try configManager.activate(node: node)
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index].lastUsedAt = Date()
        }
        activeNodeId = node.id
        save()
    }

    func deactivate() throws {
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

    // MARK: - Persistence

    private func load() {
        guard let data = fileManager.contents(atPath: Self.storePath) else { return }
        do {
            let file = try JSONDecoder.profileDecoder.decode(StoreFile.self, from: data)
            nodes = file.nodes
            activeNodeId = file.activeNodeId
            sortNodes()
        } catch {
            openCodeStoreLog.error("Failed to load OpenCode nodes: \(String(describing: error), privacy: .public)")
        }
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
