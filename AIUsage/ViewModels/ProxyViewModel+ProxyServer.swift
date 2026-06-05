import Foundation
import QuotaBackend
import os.log

extension ProxyViewModel {

    func restoreActivatedNode() {
        Task {
            await restoreActivatedNodeAsync()
            await restoreActivatedCodexNodeAsync()
            await restoreProxyOnlyNodes()
        }
    }

    /// 启动时恢复 Codex 代理激活态（独立于 Claude 轨道）。
    private func restoreActivatedCodexNodeAsync() async {
        let shouldAutoRestore = AppSettings.shared.proxyAutoRestoreOnLaunch
        let savedId = shouldAutoRestore
            ? UserDefaults.standard.string(forKey: DefaultsKey.proxyActivatedCodexConfigId)
            : nil

        guard let id = savedId,
              let config = configurations.first(where: { $0.id == id }),
              config.nodeType.isCodex else {
            activatedCodexConfigId = nil
            saveActivatedCodexId()
            // 清理任何残留的受管理 config.toml（仅当确实由我们注入时才会动作）。
            if runtimeService.isCodexConfigManaged() {
                do {
                    try runtimeService.clearCodexRuntime()
                } catch {
                    proxyRuntimeLog.error("Failed to clear Codex runtime while restoring empty activation state: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }

        proxyRuntimeLog.info("Restoring Codex node \(config.name, privacy: .public)")
        do {
            try await activateRuntime(for: config)
            try persistActivationSelection(config.id, touchLastUsedAt: false, isCodex: true)
        } catch {
            proxyRuntimeLog.error("Failed to restore Codex node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            activatedCodexConfigId = nil
            saveActivatedCodexId()
            do {
                try runtimeService.clearCodexRuntime()
            } catch {
                proxyRuntimeLog.error("Failed to clear Codex runtime after restore failure: \(String(describing: error), privacy: .public)")
            }
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
            try persistActivationSelection(config.id, touchLastUsedAt: false, isCodex: false)
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
        if config.nodeType.isCodex {
            // 通用配置基底（启用时）+ 节点额外 TOML，交由 CodexConfigManager 按顶层键合并注入。
            let globalTOML = profileStore.codexGlobalConfig.hasContent
                ? profileStore.codexGlobalConfig.tomlText
                : nil
            let nodeTOML = profileStore.profile(for: config.id)?.metadata.proxy.extraTOML?.nilIfBlank
            try await runtimeService.activateCodexRuntime(
                for: config,
                globalTOML: globalTOML,
                nodeTOML: nodeTOML
            )
            return
        }

        if let profile = profileStore.profile(for: config.id) {
            let finalSettings: [String: Any]
            if profile.metadata.proxy.shouldMergeClaudeCommonConfig(globalEnabled: profileStore.globalConfig.enabled) {
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
        if config.nodeType.isCodex {
            try await runtimeService.deactivateCodexRuntime(for: config)
            return
        }

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

    func testConnectivity(_ id: String) async {
        guard let config = configurations.first(where: { $0.id == id }),
              !config.nodeType.isCodex else { return }
        guard !connectivityTestStates[id, default: .init()].isTesting else { return }

        connectivityTestStates[id] = ProxyConnectivityTestState(isTesting: true, lastSucceeded: nil, message: nil)
        defer {
            var state = connectivityTestStates[id, default: .init()]
            state.isTesting = false
            connectivityTestStates[id] = state
        }

        let startedByTest: Bool
        do {
            if config.needsProxyProcess {
                startedByTest = try await runtimeService.startProxyForConnectivityTest(for: config)
            } else {
                startedByTest = false
            }
        } catch {
            let message = sanitizedConnectivityMessage(error.localizedDescription)
            connectivityTestStates[id] = ProxyConnectivityTestState(isTesting: false, lastSucceeded: false, message: message)
            connectivityTestMessage = AppSettings.shared.t(
                "Connectivity test failed for \"\(config.name)\": \(message)",
                "节点「\(config.name)」连通性测试失败：\(message)"
            )
            return
        }

        defer {
            runtimeService.stopProxyForConnectivityTest(for: config, startedByTest: startedByTest)
        }

        do {
            let message = try await performClaudeConnectivityRequest(config)
            connectivityTestStates[id] = ProxyConnectivityTestState(isTesting: false, lastSucceeded: true, message: message)
            connectivityTestMessage = AppSettings.shared.t(
                "Connectivity test passed for \"\(config.name)\". \(message)",
                "节点「\(config.name)」连通性测试通过。\(message)"
            )
        } catch {
            let message = sanitizedConnectivityMessage(error.localizedDescription)
            connectivityTestStates[id] = ProxyConnectivityTestState(isTesting: false, lastSucceeded: false, message: message)
            connectivityTestMessage = AppSettings.shared.t(
                "Connectivity test failed for \"\(config.name)\": \(message)",
                "节点「\(config.name)」连通性测试失败：\(message)"
            )
        }
    }

    private func performClaudeConnectivityRequest(_ config: ProxyConfiguration) async throws -> String {
        let baseURL: String
        let apiKey: String
        if config.needsProxyProcess {
            baseURL = config.displayURL
            apiKey = config.effectiveClientKey
        } else {
            baseURL = config.anthropicBaseURL
            apiKey = config.anthropicAPIKey
        }

        guard let url = URL(string: claudeMessagesEndpoint(baseURL: baseURL)) else {
            throw URLError(.badURL)
        }

        let model = [
            config.defaultModel,
            config.modelMapping.middleModel.name,
            config.modelMapping.bigModel.name,
        ].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "claude-sonnet-4-6"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8,
            "stream": false,
            "messages": [
                ["role": "user", "content": "ping"]
            ],
        ]

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw NSError(
                domain: "AIUsage.ProxyConnectivity",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(sanitizedConnectivityMessage(text))"]
            )
        }

        return AppSettings.shared.t(
            "HTTP \(http.statusCode), \(elapsedMs) ms",
            "HTTP \(http.statusCode)，\(elapsedMs) ms"
        )
    }

    private func claudeMessagesEndpoint(baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/v1") {
            return "\(trimmed)/messages"
        }
        if trimmed.hasSuffix("/v1/messages") {
            return trimmed
        }
        return "\(trimmed)/v1/messages"
    }

    private func sanitizedConnectivityMessage(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(
            of: #"(?i)sk-[A-Za-z0-9_\-]{8,}"#,
            with: "sk-••••",
            options: .regularExpression
        )
        let patterns = [
            #"(?i)(Bearer\s+)[A-Za-z0-9._~+/=\-]{8,}"#,
            #"(?i)(ANTHROPIC_AUTH_TOKEN["':=\s]+)[^"',\s}]+"#,
            #"(?i)(x-api-key["':=\s]+)[^"',\s}]+"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: "$1••••",
                options: .regularExpression
            )
        }
        return String(text.prefix(500))
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
        let requestPath = config?.nodeType.isCodex == true ? "/v1/responses" : "/v1/messages"
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
            path: requestPath,
            claudeModel: json["claude_model"] as? String ?? "unknown",
            upstreamModel: upstreamModel,
            success: json["success"] as? Bool ?? false,
            responseTimeMs: Double(json["response_time_ms"] as? Int ?? 0),
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            tokensCacheRead: tokensCacheRead,
            tokensCacheCreation: tokensCacheCreation,
            estimatedCostUSD: estimatedCost,
            pricingResolved: pricing != nil,
            errorMessage: json["error"] as? String,
            errorType: json["error_type"] as? String,
            statusCode: json["status_code"] as? Int
        )

        DispatchQueue.main.async { [weak self] in
            self?.recordRequest(log)
        }
    }
}
