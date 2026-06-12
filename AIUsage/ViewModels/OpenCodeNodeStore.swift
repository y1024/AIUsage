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

enum OpenCodeNodeStoreError: LocalizedError {
    case proxyRequiresAPIKey

    var errorDescription: String? {
        switch self {
        case .proxyRequiresAPIKey:
            return AppSettings.shared.t(
                "Proxy mode with the OpenAI Responses protocol requires an API key.",
                "OpenAI Responses 协议的代理模式需要填写 API Key。"
            )
        }
    }
}

@MainActor
final class OpenCodeNodeStore: ObservableObject {
    static let shared = OpenCodeNodeStore()

    @Published private(set) var nodes: [OpenCodeNode] = []
    @Published private(set) var activeNodeId: String?
    /// 通用配置片段（与 Claude 页同构）：激活时按节点合并策略深合并进 opencode.json，
    /// 受管块与用户原文之间的中间层。持久化于 ~/.config/aiusage/opencode-global-config.json。
    @Published var globalConfig: GlobalConfig = .empty

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

    static var globalConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-global-config.json")
    }

    init() {
        load()
        loadGlobalConfig()
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

    /// 复制节点：新 id/slug（归因独立），插在原节点之后；代理端口避让已占用端口。
    func duplicate(_ node: OpenCodeNode) {
        var copy = node
        copy.id = UUID().uuidString
        copy.name = node.displayName + " " + AppSettings.shared.t("(Copy)", "(副本)")
        copy.providerSlug = nil
        copy.createdAt = Date()
        copy.lastUsedAt = nil
        if copy.proxyEnabled {
            let usedPorts = Set(nodes.filter(\.proxyEnabled).map(\.proxyPort))
            while usedPorts.contains(copy.proxyPort) && copy.proxyPort < 65_535 {
                copy.proxyPort += 1
            }
        }
        ensureProviderSlug(&copy)
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes.insert(copy, at: index + 1)
        } else {
            nodes.append(copy)
        }
        for index in nodes.indices {
            nodes[index].sortOrder = index
        }
        save()
    }

    // MARK: - Common Config

    /// 按节点合并策略给出通用配置片段（不合并时为 nil），激活/预览/启动命令共用同一口径。
    func commonSettings(for node: OpenCodeNode) -> [String: Any]? {
        let mode = node.commonConfigMode ?? .followGlobal
        guard mode.shouldMerge(globalEnabled: globalConfig.enabled),
              !globalConfig.settings.isEmpty else { return nil }
        return globalConfig.settings
    }

    private func loadGlobalConfig() {
        guard let data = fileManager.contents(atPath: Self.globalConfigPath),
              let config = try? GlobalConfig.fromFileData(data) else { return }
        globalConfig = config
    }

    func saveGlobalConfig() {
        do {
            let data = try globalConfig.toFileData()
            let dir = (Self.globalConfigPath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: Self.globalConfigPath), options: .atomic)
        } catch {
            openCodeStoreLog.error("Failed to save OpenCode global config: \(String(describing: error), privacy: .public)")
        }
        // 通用配置变化即时反映到生效中的节点。
        if let node = activeNode {
            Task { try? await activate(node) }
        }
    }

    // MARK: - Activation

    func activate(_ node: OpenCodeNode) async throws {
        let common = commonSettings(for: node)
        if node.proxyEnabled {
            // Codex 轨道（responses 透传）启动时强制要求 Key，缺失会让 QuotaServer
            // 静默不挂载代理路由，请求全 404——提前拦截给出可读错误。
            if node.protocolType == .openAIResponses, node.apiKey.nilIfBlank == nil {
                throw OpenCodeNodeStoreError.proxyRequiresAPIKey
            }
            // 代理模式：先拉起本地透传进程，再把 opencode.json 指向它；写配置失败则回收进程。
            try await proxyRuntime.start(node: node)
            do {
                try configManager.activate(node: node, baseURLOverride: node.proxyLocalBaseURL, commonSettings: common)
            } catch {
                proxyRuntime.stop()
                throw error
            }
        } else {
            proxyRuntime.stop()
            try configManager.activate(node: node, commonSettings: common)
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

    // MARK: - Import / Export

    /// 导出文件结构（与 StoreFile 区分：不带激活状态，便于跨机分享）。
    private struct ExportFile: Codable {
        var version: Int
        var nodes: [OpenCodeNode]
    }

    /// 导出全部节点为 JSON（含 API Key，与 Claude/Codex 节点导出同语义）。
    func exportNodes() throws -> Data {
        let file = ExportFile(version: Self.storeVersion, nodes: nodes)
        return try JSONEncoder.profileEncoder.encode(file)
    }

    /// 从导出 JSON 导入节点。重复判定：同 baseURL + 协议 + API Key 视为已存在并跳过。
    /// 返回 (导入数, 跳过数)。
    func importNodes(from data: Data) throws -> (imported: Int, skipped: Int) {
        let decoded: [OpenCodeNode]
        if let file = try? JSONDecoder.profileDecoder.decode(ExportFile.self, from: data) {
            decoded = file.nodes
        } else {
            // 容忍裸数组格式。
            decoded = try JSONDecoder.profileDecoder.decode([OpenCodeNode].self, from: data)
        }

        var imported = 0
        var skipped = 0
        for var node in decoded {
            let exists = nodes.contains {
                $0.baseURL == node.baseURL && $0.protocolType == node.protocolType && $0.apiKey == node.apiKey
            }
            if exists {
                skipped += 1
                continue
            }
            // 新身份落库：避免跨机 id/slug 冲突，归因 slug 按本机已有节点重新生成。
            node.id = UUID().uuidString
            node.providerSlug = nil
            node.createdAt = Date()
            node.lastUsedAt = nil
            node.sortOrder = (nodes.map(\.sortOrder).max() ?? 0) + 1
            ensureProviderSlug(&node)
            nodes.append(node)
            imported += 1
        }
        if imported > 0 {
            sortNodes()
            save()
        }
        return (imported, skipped)
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
