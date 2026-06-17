import Foundation
import Combine
import os.log

// MARK: - Global Proxy Manager (Codex track)
// 编排全局统一代理：把 codexProxy 节点投影为上游、驱动 GlobalProxyRuntime 启停/热切换、
// 一次性写入/还原 config.toml、持久化 GlobalProxyConfig。是 UI 与运行时之间的协调者（只做调度）。
//
// 与每节点激活互斥：启用时接管 config.toml 并停掉当前激活的 Codex 节点；启用期间禁止每节点激活
// （由 performActivationTransaction 兜底拦截）。切换激活节点走热替换，不重写 config.toml。

private let globalProxyManagerLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxyManager")

@MainActor
final class GlobalProxyManager: ObservableObject {
    static let shared = GlobalProxyManager()

    @Published private(set) var config: GlobalProxyConfig
    @Published var operationError: String?
    @Published private(set) var isBusy = false

    private let runtime = GlobalProxyRuntime.shared
    private let codexConfig = CodexConfigManager.shared

    private init() {
        self.config = GlobalProxyStore.load()
    }

    var isEnabled: Bool { config.isEnabled }
    var activeNodeId: String? { config.activeNodeId }

    /// 可参与全局代理的节点：所有 codexProxy 节点。
    func availableNodes() -> [ProxyConfiguration] {
        ProxyViewModel.shared.configurations.filter { $0.nodeType == .codexProxy }
    }

    func node(for id: String?) -> ProxyConfiguration? {
        guard let id else { return nil }
        return ProxyViewModel.shared.configurations.first { $0.id == id && $0.nodeType == .codexProxy }
    }

    // MARK: - Settings (editable only while disabled)

    /// 更新端口 / 虚拟模型 / client key。仅在停用态可改（运行态改端口会让 CLI 失联）。
    func updateSettings(port: Int, virtualModel: String, clientKey: String) {
        guard !config.isEnabled else { return }
        config.port = max(1, min(65_535, port))
        config.virtualModel = virtualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        config.clientKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    // MARK: - Enable / Disable / Switch

    func enable(activeNodeId nodeId: String) async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }

        // 与每节点激活互斥：接管 config.toml 前先停掉当前激活的 Codex 节点（干净交接）。
        if let activeCodex = ProxyViewModel.shared.activatedId(isCodex: true) {
            await ProxyViewModel.shared.deactivateConfiguration(activeCodex)
        }

        do {
            try await runtime.start(port: config.port, clientKey: config.effectiveClientKey, initial: upstream(for: node))
            try codexConfig.activate(
                baseURL: config.cliBaseURL,
                bearerToken: config.effectiveClientKey,
                model: config.virtualModel
            )
            config.isEnabled = true
            config.activeNodeId = nodeId
            persist()
            globalProxyManagerLog.info("Global proxy enabled with node \(nodeId, privacy: .public)")
        } catch {
            runtime.stop()
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to enable global proxy: \(String(describing: error), privacy: .public)")
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

        guard let node = node(for: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }

        do {
            try await runtime.switchUpstream(upstream(for: node))
            config.activeNodeId = nodeId
            persist()
        } catch {
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to switch global proxy node: \(String(describing: error), privacy: .public)")
        }
    }

    func disable() async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        runtime.stop()
        do {
            try codexConfig.restore()
        } catch {
            globalProxyManagerLog.error("Failed to restore config.toml on global proxy disable: \(String(describing: error), privacy: .public)")
        }
        config.isEnabled = false
        persist()
        globalProxyManagerLog.info("Global proxy disabled")
    }

    // MARK: - Launch Restore

    /// 启动时恢复：持久化为启用且激活节点仍存在 → 重新拉起进程；否则优雅停用并清理 config.toml。
    func restoreOnLaunch() async {
        guard config.isEnabled else { return }
        guard AppSettings.shared.proxyAutoRestoreOnLaunch else { return }

        guard let node = node(for: config.activeNodeId) else {
            globalProxyManagerLog.notice("Global proxy active node missing on launch; disabling")
            await disable()
            return
        }

        do {
            try await runtime.start(port: config.port, clientKey: config.effectiveClientKey, initial: upstream(for: node))
            // config.toml 在上次会话已写入并指向同端口；幂等重注入确保仍然有效。
            try codexConfig.activate(
                baseURL: config.cliBaseURL,
                bearerToken: config.effectiveClientKey,
                model: config.virtualModel
            )
            globalProxyManagerLog.info("Global proxy restored on launch with node \(node.id, privacy: .public)")
        } catch {
            globalProxyManagerLog.error("Failed to restore global proxy on launch: \(String(describing: error), privacy: .public)")
            operationError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func upstream(for node: ProxyConfiguration) -> GlobalProxyRuntime.CodexUpstream {
        GlobalProxyRuntime.CodexUpstream(
            nodeId: node.id,
            nodeName: node.name,
            baseURL: node.normalizedUpstreamBaseURL,
            apiKey: node.upstreamAPIKey,
            model: node.codexModel.isEmpty ? nil : node.codexModel,
            maxOutputTokens: node.maxOutputTokens > 0 ? node.maxOutputTokens : nil
        )
    }

    private func persist() {
        GlobalProxyStore.save(config)
    }
}
