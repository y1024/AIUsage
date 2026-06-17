import Foundation
import AppKit
import os.log

// MARK: - Proxy-Only Mode
// Allows starting a proxy process without writing to ~/.claude/settings.json.
// Multiple nodes can run in proxy-only mode simultaneously, each on its own port.
// Useful for letting other tools connect to the proxy without affecting Claude Code config.

extension ProxyViewModel {

    // MARK: - Proxy-Only Start / Stop

    func startProxyOnly(_ id: String) async {
        guard !operationInProgressConfigIds.contains(id) else { return }
        guard let config = configurations.first(where: { $0.id == id }) else { return }
        guard config.needsProxyProcess else { return }

        if let conflict = portConflictDescription(for: config) {
            operationErrorMessage = conflict
            return
        }

        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        operationErrorMessage = nil

        do {
            try await runtimeService.startProxyOnly(for: config)
            proxyOnlyRunningIds.insert(id)
            saveProxyOnlyIds()
            proxyRuntimeLog.info("Proxy-only started for node \(config.name, privacy: .public) on \(config.displayURL, privacy: .public)")
        } catch {
            reportOperationError(error)
        }
    }

    func stopProxyOnly(_ id: String) async {
        guard !operationInProgressConfigIds.contains(id) else { return }
        guard let config = configurations.first(where: { $0.id == id }) else { return }

        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }

        runtimeService.stopProxyOnly(for: config)
        proxyOnlyRunningIds.remove(id)
        saveProxyOnlyIds()
        proxyRuntimeLog.info("Proxy-only stopped for node \(config.name, privacy: .public)")
    }

    func toggleProxyOnly(_ id: String) async {
        if proxyOnlyRunningIds.contains(id) {
            await stopProxyOnly(id)
        } else {
            await startProxyOnly(id)
        }
    }

    // MARK: - Proxy-Only Persistence & Restore

    func saveProxyOnlyIds() {
        let ids = Array(proxyOnlyRunningIds)
        UserDefaults.standard.set(ids, forKey: DefaultsKey.proxyOnlyRunningIds)
    }

    /// Restores proxy-only nodes that were running before the app was last quit.
    /// Called from `restoreActivatedNode` when auto-restore is enabled.
    func restoreProxyOnlyNodes() async {
        guard AppSettings.shared.proxyAutoRestoreOnLaunch else {
            return
        }

        let savedIds = UserDefaults.standard.stringArray(forKey: DefaultsKey.proxyOnlyRunningIds) ?? []
        guard !savedIds.isEmpty else { return }

        for id in savedIds {
            guard let config = configurations.first(where: { $0.id == id }),
                  config.needsProxyProcess,
                  activatedConfigId != id else {
                continue
            }

            if portConflictDescription(for: config) != nil {
                proxyRuntimeLog.notice("Skipping proxy-only restore for \(config.name, privacy: .public): port conflict")
                continue
            }

            do {
                try await runtimeService.startProxyOnly(for: config)
                proxyOnlyRunningIds.insert(id)
                proxyRuntimeLog.info("Restored proxy-only node \(config.name, privacy: .public) on \(config.displayURL, privacy: .public)")
            } catch {
                proxyRuntimeLog.error("Failed to restore proxy-only node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        saveProxyOnlyIds()
    }

    // MARK: - Port Conflict Detection

    /// Claude/Codex 轨道当前正在监听的代理：供跨轨端口仲裁聚合。
    /// 仅统计进程确实在运行的节点（激活但代理已崩溃的不占端口）。
    func runningProxyPortOwners() -> [ProxyPortArbiter.Owner] {
        configurations.compactMap { config in
            guard config.needsProxyProcess, runtimeService.isProxyRunning(config.id) else { return nil }
            let track = config.nodeType.isCodex ? "Codex" : "Claude Code"
            return ProxyPortArbiter.Owner(id: config.id, ports: config.listeningPorts, track: track, label: config.name)
        }
    }

    /// Returns a user-facing error message if the target port is already in use, nil otherwise.
    /// 跨 Claude/Codex/OpenCode 三轨判定：任一轨道有正在运行的代理占用本节点任一监听端口（含 HTTPS）即冲突。
    func portConflictDescription(for config: ProxyConfiguration) -> String? {
        guard let conflict = ProxyPortArbiter.conflict(forPorts: config.listeningPorts, excluding: config.id) else {
            return nil
        }
        return AppSettings.shared.t(
            "Port \(conflict.port) is already in use by node \"\(conflict.label)\" under the \(conflict.track) proxy. Please change the port in node settings before starting.",
            "端口 \(conflict.port) 已被「\(conflict.track) 代理」下的节点「\(conflict.label)」占用。请先在节点设置中修改端口再启动。"
        )
    }

    // MARK: - Copy Launch Command

    /// 复制「不改全局配置即可启动」的命令到剪贴板，按节点类型走不同口径：
    /// - Claude（anthropicDirect / openaiProxy）：导出干净 settings 文件 → `claude --settings <path>`。
    /// - Codex（codexProxy）：导出独立 CODEX_HOME 目录 → `CODEX_HOME="<dir>" codex`。
    func copyLaunchCommand(for id: String) {
        guard let profile = profileStore.profile(for: id) else {
            operationErrorMessage = AppSettings.shared.t(
                "Profile not found for this node.",
                "找不到该节点的配置文件。"
            )
            return
        }

        let command: String
        if let config = configurations.first(where: { $0.id == id }), config.nodeType.isCodex {
            guard let codexCommand = makeCodexLaunchCommand(config: config, profile: profile) else {
                operationErrorMessage = AppSettings.shared.t(
                    "Failed to export Codex config.",
                    "导出 Codex 配置失败。"
                )
                return
            }
            command = codexCommand
        } else {
            guard let claudeCommand = makeClaudeLaunchCommand(profile: profile) else {
                operationErrorMessage = AppSettings.shared.t(
                    "Failed to export settings file.",
                    "导出设置文件失败。"
                )
                return
            }
            command = claudeCommand
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        proxyRuntimeLog.info("Copied launch command for node \(profile.metadata.name, privacy: .public)")
    }

    /// Claude：导出干净 settings（剔除 `_metadata`），返回 `claude --settings <path>`。
    private func makeClaudeLaunchCommand(profile: NodeProfile) -> String? {
        let finalSettings: [String: Any]
        if profile.metadata.proxy.shouldMergeClaudeCommonConfig(globalEnabled: profileStore.globalConfig.enabled) {
            finalSettings = GlobalConfig.deepMerge(
                base: profileStore.globalConfig.settings,
                override: profile.settings
            )
        } else {
            finalSettings = profile.settings
        }

        guard let path = NodeProfileStore.exportCleanSettings(
            for: profile,
            settings: finalSettings
        ) else {
            return nil
        }

        let escapedPath = path.contains(" ") ? "\"\(path)\"" : path
        return "claude --settings \(escapedPath)"
    }

    /// Codex：导出独立 CODEX_HOME 目录（含指向本地代理的 config.toml），返回 `CODEX_HOME="<dir>" codex`。
    /// 与激活态采用同一份 baseURL / token / model / 全局+节点 TOML 派生口径，行为等价但不改用户真实 config.toml。
    private func makeCodexLaunchCommand(config: ProxyConfiguration, profile: NodeProfile) -> String? {
        let scheme = config.enableHTTPS ? "https" : "http"
        let port = config.enableHTTPS ? config.effectiveHTTPSPort : config.port
        let baseURL = "\(scheme)://\(config.host):\(port)/v1"

        let globalTOML = profileStore.codexGlobalConfig.hasContent
            ? profileStore.codexGlobalConfig.tomlText
            : nil
        let nodeTOML = profile.metadata.proxy.extraTOML?.nilIfBlank

        let toml = CodexConfigManager.shared.makeStandaloneConfig(
            baseURL: baseURL,
            bearerToken: config.effectiveClientKey,
            model: config.codexModel,
            globalTOML: globalTOML,
            nodeTOML: nodeTOML
        )

        guard let dir = NodeProfileStore.exportCodexHome(for: profile, configTOML: toml) else {
            return nil
        }
        return "CODEX_HOME=\"\(dir)\" codex"
    }
}
