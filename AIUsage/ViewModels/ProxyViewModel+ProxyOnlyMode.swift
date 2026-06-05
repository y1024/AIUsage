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

    /// Returns a user-facing error message if the target port is already in use, nil otherwise.
    func portConflictDescription(for config: ProxyConfiguration) -> String? {
        let targetPort = config.port
        let runningPorts = runtimeService.runningPorts(from: configurations)

        for (runningId, port) in runningPorts where port == targetPort && runningId != config.id {
            guard let conflicting = configurations.first(where: { $0.id == runningId }) else { continue }
            return AppSettings.shared.t(
                "Port \(targetPort) is already in use by node \"\(conflicting.name)\". Please change the port in node settings before starting.",
                "端口 \(targetPort) 已被节点「\(conflicting.name)」占用。请先在节点设置中修改端口再启动。"
            )
        }

        return nil
    }

    // MARK: - Copy Launch Command

    /// Exports a clean settings file and copies `claude --settings <path>` to the clipboard.
    func copyLaunchCommand(for id: String) {
        guard let profile = profileStore.profile(for: id) else {
            operationErrorMessage = AppSettings.shared.t(
                "Profile not found for this node.",
                "找不到该节点的配置文件。"
            )
            return
        }

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
            operationErrorMessage = AppSettings.shared.t(
                "Failed to export settings file.",
                "导出设置文件失败。"
            )
            return
        }

        let escapedPath = path.contains(" ") ? "\"\(path)\"" : path
        let command = "claude --settings \(escapedPath)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        proxyRuntimeLog.info("Copied launch command for node \(profile.metadata.name, privacy: .public)")
    }
}
