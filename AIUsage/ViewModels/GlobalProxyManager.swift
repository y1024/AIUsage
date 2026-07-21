import Foundation
import Combine
import os.log
import QuotaBackend

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

    /// For the Claude page this remains the Claude Code consumer state; the
    /// shared runtime may continue running for Desktop after Code disconnects.
    var isEnabled: Bool {
        track == .claude ? config.effectiveClaudeCodeEnabled : config.isEnabled
    }
    /// Runtime ownership is broader than the visible Code connection state.
    /// Claude Desktop can be the only active consumer while `isEnabled` is
    /// intentionally false on the Code tab.
    var isRuntimeEnabled: Bool {
        track == .claude ? config.hasClaudeConsumers : config.isEnabled
    }
    var claudeConsumers: Set<ClaudeGatewayConsumer> {
        track == .claude ? config.claudeConsumers : []
    }
    func isClaudeConsumerAttached(_ consumer: ClaudeGatewayConsumer) -> Bool {
        claudeConsumers.contains(consumer)
    }
    var activeNodeId: String? { config.activeNodeId }
    var isProxyRunning: Bool { runtime.isProcessRunning }

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

    /// Stores the single localhost HTTPS endpoint used by Claude Desktop.
    /// It is intentionally independent from every upstream node: switching
    /// nodes changes only the gateway's upstream projection, never Desktop's
    /// endpoint. Active Desktop sessions must disconnect before this changes.
    @discardableResult
    func updateClaudeDesktopHTTPSPort(_ port: Int) -> Bool {
        guard track == .claude,
              !isBusy,
              !config.effectiveClaudeDesktopEnabled,
              (1_024...65_535).contains(port),
              port != config.port else { return false }
        config.claudeDesktopHTTPSPort = port
        persist()
        return true
    }

    /// Updates one Desktop picker capability without changing the public route
    /// identity. The active gateway and selected profile are refreshed through
    /// the same hot-switch notification used for node changes.
    func updateClaudeDesktopSupports1M(
        nodeID: String,
        modelID: String,
        enabled: Bool
    ) async {
        guard track == .claude else { return }
        var byNode = config.claudeDesktopSupports1MByNode ?? [:]
        var models = byNode[nodeID] ?? [:]
        if enabled {
            models[modelID] = true
        } else {
            models.removeValue(forKey: modelID)
        }
        if models.isEmpty {
            byNode.removeValue(forKey: nodeID)
        } else {
            byNode[nodeID] = models
        }
        config.claudeDesktopSupports1MByNode = byNode
        persist()

        guard config.effectiveClaudeDesktopEnabled,
              config.activeNodeId == nodeID,
              runtime.isProcessRunning else { return }
        await reapplyActiveUpstream()
    }

    /// Changes the public model surface exposed to Claude Desktop while
    /// preserving the shared Gateway endpoint and active node. The subsequent
    /// upstream reapply drives the same profile refresh path as a node switch:
    /// smart routes normally remain live, while a changed full catalog reloads
    /// a running Desktop so its picker cannot become stale.
    func updateClaudeDesktopCatalogMode(_ mode: ClaudeDesktopCatalogMode) async {
        guard track == .claude,
              !isBusy,
              config.effectiveClaudeDesktopCatalogMode != mode else { return }
        let previousMode = config.claudeDesktopCatalogMode
        config.claudeDesktopCatalogMode = mode
        guard persist() else {
            config.claudeDesktopCatalogMode = previousMode
            operationError = AppSettings.shared.t(
                "Could not save the Desktop model mode.",
                "无法保存 Desktop 模型模式。"
            )
            return
        }

        guard config.effectiveClaudeDesktopEnabled,
              config.activeNodeId != nil,
              runtime.isProcessRunning else { return }
        await reapplyActiveUpstream()
        if let failure = operationError {
            config.claudeDesktopCatalogMode = previousMode
            _ = persist()
            await reapplyActiveUpstream()
            operationError = failure
        }
    }

    // MARK: - Enable / Disable / Switch

    func enable(activeNodeId nodeId: String) async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId),
              let env = runtimeEnvironment(nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }
        if track == .claude,
           config.effectiveClaudeDesktopEnabled,
           !config.effectiveClaudeCodeEnabled,
           let sharedNodeId = config.activeNodeId,
           sharedNodeId != nodeId {
            operationError = AppSettings.shared.t(
                "Desktop already owns another Gateway route. Switch that shared route explicitly before attaching Code.",
                "Desktop 已在使用另一条 Gateway 路由；请先明确切换共享路由，再接入 Code。"
            )
            return
        }
        let previousConfig = config

        // 与每节点激活互斥：接管 CLI 配置前先停掉本轨当前激活的节点（干净交接）。
        let activePerNode = adapter.currentPerNodeActiveId()
        if let activePerNode {
            await adapter.deactivatePerNode(activePerNode)
            guard adapter.currentPerNodeActiveId() != activePerNode else {
                operationError = AppSettings.shared.t(
                    "Could not disconnect the current direct route. Try again before attaching the Gateway.",
                    "无法断开当前直连路由，请重试后再接入 Gateway。"
                )
                return
            }
        }

        let canReuseClaudeRuntime = track == .claude && runtime.isProcessRunning
        let previousNodeId = config.activeNodeId
        var changedSharedRoute = false
        do {
            if canReuseClaudeRuntime {
                // Desktop may already own the process and HTTPS listener. Code
                // joining the same route is a config-only operation: keep the
                // process and every live Desktop session intact.
                if previousNodeId != nodeId {
                    guard let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
                        throw GlobalProxyRuntimeError.startFailed("selected node has no gateway route")
                    }
                    try await runtime.switchUpstream(
                        payload: payload,
                        adminPath: adapter.adminPath(config: config),
                        nodeId: node.id,
                        nodeName: node.name
                    )
                    changedSharedRoute = true
                }
            } else {
                try await runtime.start(
                    port: config.port,
                    bindHost: runtimeBindAddress,
                    env: env,
                    nodeId: node.id,
                    nodeName: node.name,
                    httpsPort: track == .claude && config.effectiveClaudeDesktopEnabled
                        ? config.effectiveClaudeDesktopHTTPSPort : nil,
                    tlsIdentityPath: track == .claude && config.effectiveClaudeDesktopEnabled
                        ? TLSCertificateManager.shared.identityFilePath : nil
                )
            }
            try adapter.activateCLIConfig(config)
            if track == .claude { config.claudeCodeEnabled = true }
            config.isEnabled = track == .claude ? config.hasClaudeConsumers : true
            config.activeNodeId = nodeId
            guard persist() else {
                throw GlobalProxyRuntimeError.startFailed("failed to save Gateway state")
            }
            if track == .claude, config.effectiveClaudeDesktopEnabled {
                NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
            }
            globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) enabled with node \(nodeId, privacy: .public)")
        } catch is CancellationError {
            // Superseded by a newer lifecycle operation on this runtime; the
            // newer owner controls the process, so exit without a raw error.
            return
        } catch {
            config = previousConfig
            // A failed Code attach must not strand Desktop on a route that was
            // only selected for the failed transaction.
            if changedSharedRoute,
               let previousNodeId,
               let previousNode = self.node(for: previousNodeId),
               let rollback = adapter.switchPayload(config: config, nodeId: previousNodeId) {
                try? await runtime.switchUpstream(
                    payload: rollback,
                    adminPath: adapter.adminPath(config: config),
                    nodeId: previousNode.id,
                    nodeName: previousNode.name
                )
            }
            if !canReuseClaudeRuntime && (track != .claude || !config.effectiveClaudeDesktopEnabled) {
                runtime.stop()
            }
            try? adapter.restoreCLIConfig()
            if let activePerNode {
                await adapter.activatePerNode(activePerNode)
            }
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to enable global proxy (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    func switchActiveNode(to nodeId: String) async {
        guard !isBusy else { return }
        guard isRuntimeEnabled, runtime.isProcessRunning else {
            if track == .claude, config.effectiveClaudeDesktopEnabled {
                do {
                    try await attachClaudeDesktop(
                        activeNodeId: nodeId,
                        httpsPort: config.effectiveClaudeDesktopHTTPSPort,
                        clientKey: config.effectiveClaudeDesktopClientKey,
                        tlsIdentityPath: TLSCertificateManager.shared.identityFilePath
                    )
                    NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
                } catch {
                    operationError = error.localizedDescription
                }
                return
            }
            await enable(activeNodeId: nodeId)
            return
        }
        guard nodeId != config.activeNodeId else { return }
        let previousNodeId = config.activeNodeId
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let selectedNode = node(for: nodeId), let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }

        do {
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: selectedNode.id,
                nodeName: selectedNode.name
            )
            config.activeNodeId = nodeId
            guard persist() else {
                config.activeNodeId = previousNodeId
                if let previousNodeId,
                   let previousNode = node(for: previousNodeId),
                   let rollback = adapter.switchPayload(config: config, nodeId: previousNodeId) {
                    try? await runtime.switchUpstream(
                        payload: rollback,
                        adminPath: adapter.adminPath(config: config),
                        nodeId: previousNode.id,
                        nodeName: previousNode.name
                    )
                }
                throw GlobalProxyRuntimeError.startFailed("failed to save Gateway route")
            }
            if track == .claude, config.effectiveClaudeDesktopEnabled {
                NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
            }
        } catch {
            operationError = error.localizedDescription
            globalProxyManagerLog.error("Failed to switch global proxy node (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    /// 节点配置已变（例如 CPA 从 convert 切到 Anthropic 透传）时，对当前激活节点强制再推上游。
    func reapplyActiveUpstream() async {
        guard !isBusy else { return }
        guard isRuntimeEnabled, runtime.isProcessRunning,
              let nodeId = config.activeNodeId else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId),
              let payload = adapter.switchPayload(config: config, nodeId: nodeId) else { return }
        do {
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: node.id,
                nodeName: node.name
            )
            if track == .claude, config.effectiveClaudeDesktopEnabled {
                NotificationCenter.default.post(name: .claudeGatewayActiveNodeDidChange, object: nodeId)
            }
        } catch {
            operationError = error.localizedDescription
            globalProxyManagerLog.error(
                "Failed to reapply global proxy upstream (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
        }
    }

    func disable() async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        let previousConfig = config
        do {
            try adapter.restoreCLIConfig()
        } catch {
            globalProxyManagerLog.error("Failed to restore CLI config on global proxy disable (\(self.track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            operationError = error.localizedDescription
            return
        }
        var stoppedRuntime = false
        if track == .claude {
            config.claudeCodeEnabled = false
            config.isEnabled = config.hasClaudeConsumers
            if !config.effectiveClaudeDesktopEnabled {
                runtime.stop()
                stoppedRuntime = true
            }
        } else {
            runtime.stop()
            stoppedRuntime = true
            config.isEnabled = false
        }
        guard persist() else {
            config = previousConfig
            if stoppedRuntime { await restoreRuntimeBestEffort() }
            try? adapter.activateCLIConfig(config)
            operationError = AppSettings.shared.t(
                "Could not save the disconnected state; the previous route was restored.",
                "无法保存断开状态，已恢复之前的路由。"
            )
            return
        }
        globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) disabled")
    }

    // MARK: - Launch Restore

    /// 启动时恢复：持久化为启用且激活节点仍存在 → 重新拉起进程；否则优雅停用并清理 CLI 配置。
    func restoreOnLaunch() async {
        let shouldRestore = track == .claude ? config.hasClaudeConsumers : config.isEnabled
        guard shouldRestore else { return }
        // An attached Desktop profile permanently points at this localhost
        // endpoint. Leaving that profile selected while skipping its listener
        // produces a broken provider after every app restart, so Desktop is a
        // required restore independent of the optional CLI auto-restore switch.
        let desktopRequiresRuntime = track == .claude && config.effectiveClaudeDesktopEnabled
        guard desktopRequiresRuntime || AppSettings.shared.proxyAutoRestoreOnLaunch else { return }

        guard let node = node(for: config.activeNodeId),
              let env = runtimeEnvironment(nodeId: node.id) else {
            let message = AppSettings.shared.t(
                "The previously selected node no longer exists. Choose another node to reconnect.",
                "之前选择的节点已不存在，请选择其它节点重新连接。"
            )
            globalProxyManagerLog.notice("Global proxy (\(self.track.rawValue, privacy: .public)) active node missing on launch")
            // Keep an attached Desktop profile recoverable. Calling the normal
            // Claude `disable()` path here would only turn off Code while still
            // leaving Desktop enabled, which hides the real restore failure.
            if track == .claude, config.effectiveClaudeDesktopEnabled {
                runtime.stop()
                if config.effectiveClaudeCodeEnabled {
                    try? adapter.restoreCLIConfig()
                    config.claudeCodeEnabled = false
                }
                config.isEnabled = config.hasClaudeConsumers
                _ = persist()
                operationError = message
                return
            }
            await disable()
            return
        }

        do {
            try await runtime.start(
                port: config.port,
                bindHost: runtimeBindAddress,
                env: env,
                nodeId: node.id,
                nodeName: node.name,
                httpsPort: track == .claude && config.effectiveClaudeDesktopEnabled
                    ? config.effectiveClaudeDesktopHTTPSPort : nil,
                tlsIdentityPath: track == .claude && config.effectiveClaudeDesktopEnabled
                    ? TLSCertificateManager.shared.identityFilePath : nil
            )
            // Only the Code consumer owns ~/.claude/settings.json. Desktop-only
            // restore must never touch it.
            if track != .claude || config.effectiveClaudeCodeEnabled {
                try adapter.activateCLIConfig(config)
            }
            globalProxyManagerLog.info("Global proxy (\(self.track.rawValue, privacy: .public)) restored on launch with node \(node.id, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            globalProxyManagerLog.error("Failed to restore global proxy (\(self.track.rawValue, privacy: .public)) on launch: \(String(describing: error), privacy: .public)")
            operationError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Attach Claude Desktop as a second consumer of the Claude Gateway.  The
    /// process is restarted only to add the HTTPS listener; Claude Code keeps
    /// the same HTTP port/key throughout.
    func attachClaudeDesktop(
        activeNodeId nodeId: String,
        httpsPort: Int,
        clientKey: String,
        tlsIdentityPath: String
    ) async throws {
        guard track == .claude else { return }
        guard !isBusy else { throw GlobalProxyRuntimeError.startFailed("operation in progress") }
        guard (1_024...65_535).contains(httpsPort), httpsPort != config.port else {
            throw GlobalProxyRuntimeError.startFailed("invalid Claude Desktop HTTPS port")
        }
        let normalizedClientKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientKey.isEmpty else {
            throw GlobalProxyRuntimeError.startFailed("Claude Desktop client key is unavailable")
        }
        if config.effectiveClaudeCodeEnabled,
           let sharedNodeId = config.activeNodeId,
           sharedNodeId != nodeId {
            throw GlobalProxyRuntimeError.startFailed(AppSettings.shared.t(
                "Claude Code already owns another Gateway route. Switch the shared route explicitly before attaching Desktop.",
                "Claude Code 已在使用另一条 Gateway 路由；请先明确切换共享路由，再接入 Desktop。"
            ))
        }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        let previousConfig = config
        config.claudeDesktopEnabled = true
        config.claudeDesktopHTTPSPort = httpsPort
        config.claudeDesktopClientKey = normalizedClientKey
        guard let node = node(for: nodeId), let env = runtimeEnvironment(nodeId: nodeId) else {
            config = previousConfig
            throw GlobalProxyRuntimeError.startFailed(AppSettings.shared.t("Selected node not found.", "未找到所选节点。"))
        }

        do {
            if runtime.isClaudeDesktopListenerRunning {
                // Repairing/re-applying an existing Desktop profile does not
                // restart the Gateway. Only change the shared route when the
                // requested node is genuinely different.
                if previousConfig.activeNodeId != nodeId {
                    guard let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
                        throw GlobalProxyRuntimeError.startFailed("selected node has no gateway route")
                    }
                    try await runtime.switchUpstream(
                        payload: payload,
                        adminPath: adapter.adminPath(config: config),
                        nodeId: node.id,
                        nodeName: node.name
                    )
                }
            } else {
                // Adding the HTTPS listener changes the listener set, so this
                // is the one attachment transition that requires a restart.
                try await runtime.start(
                    port: config.port,
                    bindHost: "127.0.0.1",
                    env: env,
                    nodeId: node.id,
                    nodeName: node.name,
                    httpsPort: config.effectiveClaudeDesktopHTTPSPort,
                    tlsIdentityPath: tlsIdentityPath
                )
            }
            config.activeNodeId = nodeId
            config.isEnabled = config.hasClaudeConsumers
            guard persist() else {
                throw GlobalProxyRuntimeError.startFailed("failed to save Claude Desktop runtime state")
            }
        } catch {
            config = previousConfig
            await restoreRuntimeBestEffort()
            throw error
        }
    }

    func detachClaudeDesktop() async throws {
        guard track == .claude else { return }
        guard !isBusy else { throw GlobalProxyRuntimeError.startFailed("operation in progress") }
        isBusy = true
        defer { isBusy = false }

        let previousConfig = config
        config.claudeDesktopEnabled = false
        config.isEnabled = config.hasClaudeConsumers
        do {
            if config.effectiveClaudeCodeEnabled,
               let nodeId = config.activeNodeId,
               let node = node(for: nodeId),
               let env = runtimeEnvironment(nodeId: nodeId) {
                try await runtime.start(
                    port: config.port,
                    bindHost: config.bindAddress,
                    env: env,
                    nodeId: node.id,
                    nodeName: node.name
                )
            } else {
                runtime.stop()
            }
            guard persist() else {
                throw GlobalProxyRuntimeError.startFailed("failed to save Claude Desktop runtime state")
            }
        } catch {
            config = previousConfig
            await restoreRuntimeBestEffort()
            throw error
        }
    }

    /// Restore the exact consumer shape that existed before a failed attach or
    /// detach transaction. This keeps Code available and never leaves the
    /// persisted Desktop profile pointing at a listener with different keys.
    private func restoreRuntimeBestEffort() async {
        guard isRuntimeEnabled,
              let nodeId = config.activeNodeId,
              let node = node(for: nodeId),
              let env = runtimeEnvironment(nodeId: nodeId) else {
            runtime.stop()
            return
        }
        try? await runtime.start(
            port: config.port,
            bindHost: runtimeBindAddress,
            env: env,
            nodeId: node.id,
            nodeName: node.name,
            httpsPort: config.effectiveClaudeDesktopEnabled ? config.effectiveClaudeDesktopHTTPSPort : nil,
            tlsIdentityPath: config.effectiveClaudeDesktopEnabled
                ? TLSCertificateManager.shared.identityFilePath : nil
        )
    }

    private func runtimeEnvironment(nodeId: String) -> [String: String]? {
        guard var env = adapter.startEnv(config: config, nodeId: nodeId) else { return nil }
        guard track == .claude, config.effectiveClaudeDesktopEnabled else { return env }
        env["ANTHROPIC_DESKTOP_API_KEY"] = config.effectiveClaudeDesktopClientKey

        guard let node = ProxyViewModel.shared.configurations.first(where: {
            $0.id == nodeId && ProxyNodeFamily.claude.contains($0.nodeType)
        }) else { return env }
        let projection = ClaudeDesktopProfileStore.gatewayProjection(
            for: node,
            mode: config.effectiveClaudeDesktopCatalogMode,
            supports1M: config.claudeDesktopSupports1MModels(for: node.id)
        )
        if let data = try? JSONEncoder().encode(projection.availableModels),
           let json = String(data: data, encoding: .utf8) {
            env["AIUSAGE_CLAUDE_MODELS_JSON"] = json
        }
        if let defaultModel = projection.defaultModel {
            env["AIUSAGE_CLAUDE_DEFAULT_MODEL"] = defaultModel
        }
        if let data = try? JSONEncoder().encode(projection.supports1MModels),
           let json = String(data: data, encoding: .utf8) {
            env["AIUSAGE_CLAUDE_SUPPORTS_1M_JSON"] = json
        }
        env["AIUSAGE_CLAUDE_ROUTE_STYLE"] = "desktop"
        env["AIUSAGE_CLAUDE_MODEL_CATALOG"] = "1"
        env["AIUSAGE_CLAUDE_EXACT_MODELS"] = "1"
        return env
    }

    /// Desktop's official 3P endpoint is intentionally local-only. Because
    /// Code and Desktop share one process, attaching Desktop narrows the shared
    /// listener to loopback even if Code previously allowed LAN access.
    private var runtimeBindAddress: String {
        track == .claude && config.effectiveClaudeDesktopEnabled ? "127.0.0.1" : config.bindAddress
    }

    @discardableResult
    private func persist() -> Bool {
        if track == .claude { config.ensureClaudeDesktopDefaults() }
        return GlobalProxyStore.save(config, track: track)
    }
}

extension Notification.Name {
    static let claudeGatewayActiveNodeDidChange = Notification.Name("AIUsage.ClaudeGatewayActiveNodeDidChange")
}
