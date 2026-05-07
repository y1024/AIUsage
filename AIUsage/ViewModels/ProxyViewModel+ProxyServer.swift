import Foundation
import QuotaBackend
import os.log

extension ProxyViewModel {

    func restoreActivatedNode() {
        Task {
            await restoreActivatedNodeAsync()
            await restoreProxyOnlyNodes()
        }
    }

    private func restoreActivatedNodeAsync() async {
        let shouldAutoRestore = AppSettings.shared.proxyAutoRestoreOnLaunch

        activatedConfigId = shouldAutoRestore
            ? UserDefaults.standard.string(forKey: DefaultsKey.proxyActivatedConfigId)
            : nil

        if activatedConfigId == nil {
            var migrated = false
            for i in configurations.indices where configurations[i].isEnabled {
                configurations[i].isEnabled = false
                migrated = true
            }
            if migrated { saveConfigurations() }
        }

        guard let id = activatedConfigId else {
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime while restoring empty activation state: \(String(describing: error), privacy: .public)")
            }
            return
        }

        guard let config = configurations.first(where: { $0.id == id }) else {
            var migrated = false
            for i in configurations.indices where configurations[i].isEnabled {
                configurations[i].isEnabled = false
                migrated = true
            }
            activatedConfigId = nil
            if migrated { saveConfigurations() }
            saveActivatedId()
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime for missing restored node: \(String(describing: error), privacy: .public)")
            }
            return
        }

        proxyRuntimeLog.info(
            "Restoring node \(config.name, privacy: .public) type=\(config.nodeType.rawValue, privacy: .public)"
        )

        do {
            try await activateRuntime(for: config)
            try persistActivationSelection(config.id, touchLastUsedAt: false)
        } catch {
            proxyRuntimeLog.error("Failed to restore proxy node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            activatedConfigId = nil
            for index in configurations.indices {
                configurations[index].isEnabled = false
            }
            saveConfigurations()
            saveActivatedId()
            do {
                try runtimeService.clearRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear proxy runtime after restore failure: \(String(describing: error), privacy: .public)")
            }
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self = self else { return }
            if let description = self.runtimeService.processDebugDescription(for: id) {
                proxyRuntimeLog.info("Restored node process state: \(description, privacy: .public)")
            } else {
                proxyRuntimeLog.notice("No proxy process found for restored node \(config.name, privacy: .public)")
            }
        }
    }

    func activateRuntime(for config: ProxyConfiguration) async throws {
        if let profile = profileStore.profile(for: config.id) {
            let finalSettings: [String: Any]
            if profileStore.globalConfig.enabled {
                finalSettings = GlobalConfig.deepMerge(
                    base: profileStore.globalConfig.settings,
                    override: profile.settings
                )
            } else {
                finalSettings = profile.settings
            }

            var settingsToWrite = finalSettings
            if config.enableHTTPS {
                var env = settingsToWrite["env"] as? [String: Any] ?? [:]
                env["NODE_EXTRA_CA_CERTS"] = TLSCertificateManager.shared.certFilePath
                let httpsURL = "https://\(config.host):\(config.effectiveHTTPSPort)"
                env["ANTHROPIC_BASE_URL"] = httpsURL
                settingsToWrite["env"] = env
            }

            try await runtimeService.activateRuntime(
                for: config,
                settings: settingsToWrite
            )
        } else {
            try await runtimeService.activateRuntime(
                for: config,
                envConfig: envConfig(for: config)
            )
        }
    }

    func deactivateRuntime(for config: ProxyConfiguration) async throws {
        if let profile = profileStore.profile(for: config.id) {
            try await runtimeService.deactivateRuntime(
                for: config,
                settings: profile.settings
            )
        } else {
            try await runtimeService.deactivateRuntime(
                for: config,
                envConfig: envConfig(for: config)
            )
        }
    }

    func isProxyRunning(_ configId: String) -> Bool {
        runtimeService.isProxyRunning(configId)
    }
}

extension ProxyViewModel: ProxyRuntimeServiceDelegate {
    func proxyRuntimeService(_ service: ProxyRuntimeService, didReceiveProxyLog json: String, configId: String) {
        parseProxyLog(json, configId: configId)
    }

    func proxyRuntimeService(_ service: ProxyRuntimeService, processDidTerminateFor configId: String) {
        if proxyOnlyRunningIds.remove(configId) != nil {
            saveProxyOnlyIds()
            proxyRuntimeLog.notice("Proxy-only process terminated unexpectedly for node \(configId, privacy: .public), removed from running set")
        }
    }
}

extension ProxyViewModel {
    func parseProxyLog(_ jsonStr: String, configId: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "proxy_request_log" else {
            return
        }

        let upstreamModel = json["upstream_model"] as? String ?? "unknown"
        let tokensInput = json["input_tokens"] as? Int ?? 0
        let tokensOutput = json["output_tokens"] as? Int ?? 0

        // Prefer split cache fields; fall back to legacy combined `cache_tokens` (attribute to cache-read).
        let splitRead = json["cache_read_tokens"] as? Int
        let splitCreate = json["cache_creation_tokens"] as? Int
        let legacyCache = json["cache_tokens"] as? Int
        let tokensCacheRead: Int
        let tokensCacheCreation: Int
        if splitRead != nil || splitCreate != nil {
            tokensCacheRead = splitRead ?? 0
            tokensCacheCreation = splitCreate ?? 0
        } else {
            tokensCacheRead = legacyCache ?? 0
            tokensCacheCreation = 0
        }

        let config = configurations.first { $0.id == configId }
        let pricing = config?.pricingForModel(upstreamModel)
        let estimatedCost = pricing?.costForTokens(
            input: tokensInput,
            output: tokensOutput,
            cacheRead: tokensCacheRead,
            cacheCreate: tokensCacheCreation
        ) ?? 0

        let log = ProxyRequestLog(
            configId: configId,
            method: "POST",
            path: "/v1/messages",
            claudeModel: json["claude_model"] as? String ?? "unknown",
            upstreamModel: upstreamModel,
            success: json["success"] as? Bool ?? false,
            responseTimeMs: Double(json["response_time_ms"] as? Int ?? 0),
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            tokensCacheRead: tokensCacheRead,
            tokensCacheCreation: tokensCacheCreation,
            estimatedCostUSD: estimatedCost,
            errorMessage: json["error"] as? String,
            errorType: json["error_type"] as? String,
            statusCode: json["status_code"] as? Int
        )

        DispatchQueue.main.async { [weak self] in
            self?.recordRequest(log)
        }
    }
}
