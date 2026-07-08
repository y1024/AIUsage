import Foundation
import Combine
import os.log

// MARK: - Global Proxy Manager (track-generic)
// 编排某条轨的「全局统一代理」：把激活节点投影为上游、驱动 GlobalProxyRuntime 启停/热切换、
// 一次性接管/还原 CLI 配置（config.toml / settings.json / opencode.json）、持久化 GlobalProxyConfig。
// 只做调度，轨道差异（节点筛选、env/payload 投影、CLI 写入）全部下沉到 GlobalProxyTrackAdapter。
//
// 与每节点激活互斥：启用时停掉本轨当前激活节点并接管 CLI 配置；启用期间每节点激活被
// performActivationTransaction 兜底拦截。切换激活节点走 admin 热替换，不重写 CLI 配置、不重启进程。

private let globalProxyManagerLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxyManager")

@MainActor
final class GlobalProxyManager: ObservableObject {
    // 每条轨一个实例（独立持久化、独立常驻进程，可同时启用）。
    static let codex = GlobalProxyManager(track: .codex, adapter: CodexGlobalProxyAdapter())
    static let claude = GlobalProxyManager(track: .claude, adapter: ClaudeGlobalProxyAdapter())
    static let opencode = GlobalProxyManager(track: .opencode, adapter: OpenCodeGlobalProxyAdapter())

    /// 兼容别名：既有 Codex 调用点（菜单栏 / 激活闸门 / 启动恢复）继续用 `.shared`。
    static var shared: GlobalProxyManager { codex }

    let track: GlobalProxyTrack
    private let adapter: GlobalProxyTrackAdapter
    private var runtime: GlobalProxyRuntime { adapter.runtime }

    @Published private(set) var config: GlobalProxyConfig
    @Published var operationError: String?
    @Published private(set) var isBusy = false

    private init(track: GlobalProxyTrack, adapter: GlobalProxyTrackAdapter) {
        self.track = track
        self.adapter = adapter
        self.config = GlobalProxyStore.load(track: track)
    }

    var isEnabled: Bool { config.isEnabled }
    var activeNodeId: String? { config.activeNodeId }

    /// 可参与全局代理的节点（由适配器按轨/接口筛选）。
    func availableNodes() -> [GlobalProxyNodeRef] { adapter.availableNodes(config: config) }

    func node(for id: String?) -> GlobalProxyNodeRef? {
        guard let id else { return nil }
        return adapter.availableNodes(config: config).first { $0.id == id }
    }

    /// 切换 OpenCode 接口协议（仅 OpenCode 轨；切换会清空已选激活节点，因为节点集合随之变化）。仅停用态可改。
    func updateOpenCodeInterface(_ interface: OpenCodeProtocol) {
        guard !config.isEnabled, track == .opencode else { return }
        guard config.openCodeInterface != interface else { return }
        config.openCodeInterface = interface
        config.activeNodeId = nil
        persist()
    }

    // MARK: - Settings (editable only while disabled)

    /// 更新端口 / 主虚拟模型 / client key。仅在停用态可改（运行态改端口会让 CLI 失联）。
    /// Codex/OpenCode 用此单模型入口；Claude 见 `updateClaudeModels`。
    func updateSettings(port: Int, virtualModel: String, clientKey: String) {
        guard !config.isEnabled else { return }
        config.port = max(1, min(65_535, port))
        config.virtualModel = virtualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        config.clientKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// 更新是否允许局域网访问。仅停用态可改（运行态改绑定地址需重启进程）。
    func updateAllowLAN(_ allowLAN: Bool) {
        guard !config.isEnabled else { return }
        config.allowLAN = allowLAN
        persist()
    }

    /// 更新 Claude 三层虚拟模型（写入 settings.json 的 opus/sonnet/haiku）。仅停用态可改。
    func updateClaudeModels(port: Int, opus: String, sonnet: String, haiku: String) {
        guard !config.isEnabled else { return }
        config.port = max(1, min(65_535, port))
        config.virtualModel = opus.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sonnetModel = sonnet.trimmingCharacters(in: .whitespacesAndNewlines)
        config.haikuModel = haiku.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    // MARK: - Enable / Disable / Switch

    func enable(activeNodeId nodeId: String) async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId), let env = adapter.startEnv(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }

        // 与每节点激活互斥：接管 CLI 配置前先停掉本轨当前激活的节点（干净交接）。
        if let activePerNode = adapter.currentPerNodeActiveId() {
            await adapter.deactivatePerNode(activePerNode)
        }

        do {
            try await runtime.start(
                port: config.port,
                bindHost: config.bindAddress,
                env: env,
                nodeId: node.id,
                nodeName: node.name
            )
            try adapter.activateCLIConfig(config)
            config.isEnabled = true
            config.activeNodeId = nodeId
            persist()
            globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) enabled with node \(nodeId, privacy: .public)")
        } catch {
            runtime.stop()
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to enable global proxy (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    func switchActiveNode(to nodeId: String) async {
        guard !isBusy else { return }
        guard config.isEnabled, runtime.isProcessRunning else {
            await enable(activeNodeId: nodeId)
            return
        }
        guard nodeId != config.activeNodeId else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId), let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }

        do {
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: node.id,
                nodeName: node.name
            )
            config.activeNodeId = nodeId
            persist()
        } catch {
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to switch global proxy node (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    func disable() async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        runtime.stop()
        do {
            try adapter.restoreCLIConfig()
        } catch {
            globalProxyManagerLog.error("Failed to restore CLI config on global proxy disable (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
        config.isEnabled = false
        persist()
        globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) disabled")
    }

    // MARK: - Launch Restore

    /// 启动时恢复：持久化为启用且激活节点仍存在 → 重新拉起进程；否则优雅停用并清理 CLI 配置。
    func restoreOnLaunch() async {
        guard config.isEnabled else { return }
        guard AppSettings.shared.proxyAutoRestoreOnLaunch else { return }

        guard let node = node(for: config.activeNodeId),
              let env = adapter.startEnv(config: config, nodeId: node.id) else {
            globalProxyManagerLog.notice("Global proxy (\(self.track.rawValue, privacy: .public)) active node missing on launch; disabling")
            await disable()
            return
        }

        do {
            try await runtime.start(
                port: config.port,
                bindHost: config.bindAddress,
                env: env,
                nodeId: node.id,
                nodeName: node.name
            )
            // CLI 配置在上次会话已写入并指向同端口；幂等重注入确保仍然有效。
            try adapter.activateCLIConfig(config)
            globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) restored on launch with node \(node.id, privacy: .public)")
        } catch {
            globalProxyManagerLog.error("Failed to restore global proxy (\(self.track.rawValue, privacy: .public)) on launch: \(String(describing: error), privacy: .public)")
            operationError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func persist() {
        GlobalProxyStore.save(config, track: track)
    }
}
