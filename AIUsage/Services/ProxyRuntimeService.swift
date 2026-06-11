import Foundation
import QuotaBackend
import os.log

private actor ProxyProcessInspector {
    static let shared = ProxyProcessInspector()

    func killStaleProcesses(port: Int, currentProcessIdentifier: Int32) throws {
        let processLog = Logger(
            subsystem: "com.aiusage.desktop",
            category: "ProxyRuntime"
        )
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        lsof.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for pidStr in output.components(separatedBy: .whitespacesAndNewlines) where !pidStr.isEmpty {
            guard let pid = Int32(pidStr), pid != currentProcessIdentifier else { continue }
            processLog.info("Killing stale proxy process on port \(port, privacy: .public): pid=\(pid, privacy: .public)")
            kill(pid, SIGTERM)
            usleep(200_000)
        }
    }
}

private actor QuotaServerBuilder {
    static let shared = QuotaServerBuilder()

    func buildQuotaServer(packageRoot: String, configuration: String) async throws -> String? {
        let buildLog = Logger(
            subsystem: "com.aiusage.desktop",
            category: "QuotaServerBuild"
        )
        let executablePath = (packageRoot as NSString).appendingPathComponent(".build/\(configuration)/QuotaServer")
        if FileManager.default.fileExists(atPath: executablePath) {
            return executablePath
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swift",
            "build",
            "--package-path", packageRoot,
            "--product", "QuotaServer",
            "-c", configuration
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            buildLog.error("QuotaServer build failed with exit code \(process.terminationStatus, privacy: .public): \(output, privacy: .public)")
            return nil
        }

        return FileManager.default.fileExists(atPath: executablePath) ? executablePath : nil
    }
}

@MainActor
protocol ProxyRuntimeServiceDelegate: AnyObject {
    func proxyRuntimeService(_ service: ProxyRuntimeService, didReceiveProxyLog json: String, configId: String)
    func proxyRuntimeService(_ service: ProxyRuntimeService, processDidTerminateFor configId: String)
}

@MainActor
final class ProxyRuntimeService {
    private static let sourceFileDir: String = {
        let filePath = #filePath
        return (filePath as NSString).deletingLastPathComponent
    }()
    private static let proxyStartupTimeout: TimeInterval = 5
    private static let proxyStartupProbeIntervalNanos: UInt64 = 100_000_000

    weak var delegate: ProxyRuntimeServiceDelegate?

    private let settingsManager: ClaudeSettingsManager
    private var runningProcesses: [String: Process] = [:]
    private let fileManager = FileManager.default

    init(settingsManager: ClaudeSettingsManager? = nil) {
        self.settingsManager = settingsManager ?? ClaudeSettingsManager.shared
    }

    /// Activate using full settings.json replacement (new profile-based flow).
    func activateRuntime(
        for config: ProxyConfiguration,
        settings: [String: Any]
    ) async throws {
        if config.needsProxyProcess {
            try await startProxy(config)
        }

        do {
            try settingsManager.writeFullSettings(settings)
        } catch {
            if config.needsProxyProcess {
                stopProxy(config)
            }
            do {
                try settingsManager.restoreFromBackup()
            } catch {
                proxyRuntimeLog.error("Failed to restore settings while rolling back node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// Deactivate using backup restoration (new profile-based flow).
    func deactivateRuntime(
        for config: ProxyConfiguration,
        settings: [String: Any]
    ) async throws {
        if config.needsProxyProcess {
            stopProxy(config)
        }

        do {
            try settingsManager.restoreFromBackup()
        } catch {
            do {
                try await activateRuntime(for: config, settings: settings)
            } catch {
                proxyRuntimeLog.error("Failed to restore runtime for node \(config.name, privacy: .public) after deactivation rollback: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// Legacy activation using partial env write (kept for backward compat).
    func activateRuntime(
        for config: ProxyConfiguration,
        envConfig: ClaudeSettingsManager.EnvConfig
    ) async throws {
        if config.needsProxyProcess {
            try await startProxy(config)
        }

        do {
            try settingsManager.writeEnv(envConfig)
        } catch {
            if config.needsProxyProcess {
                stopProxy(config)
            }
            do {
                try settingsManager.clearEnv()
            } catch {
                proxyRuntimeLog.error("Failed to clear Claude runtime env while rolling back node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// Legacy deactivation using env clear (kept for backward compat).
    func deactivateRuntime(
        for config: ProxyConfiguration,
        envConfig: ClaudeSettingsManager.EnvConfig
    ) async throws {
        if config.needsProxyProcess {
            stopProxy(config)
        }

        do {
            try settingsManager.clearEnv()
        } catch {
            do {
                try await activateRuntime(for: config, envConfig: envConfig)
            } catch {
                proxyRuntimeLog.error("Failed to restore runtime for node \(config.name, privacy: .public) after deactivation rollback: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    func clearRuntime() throws {
        try settingsManager.restoreFromBackup()
    }

    // MARK: - Codex Runtime
    // Codex 节点与 Claude 节点写不同文件（~/.codex/config.toml vs ~/.claude/settings.json），
    // 因此可与 Claude 节点并存。代理成本由 App 端按节点重算，故不写共享的 proxy-pricing.json。

    private let codexConfigManager = CodexConfigManager.shared

    /// Codex 节点是否已注入受管理的 config.toml。
    func isCodexConfigManaged() -> Bool {
        codexConfigManager.isManaged
    }

    /// 激活 Codex 节点：启动本地 QuotaServer(PROXY_TARGET=codex)，再外科式注入 config.toml。
    /// - Parameters:
    ///   - globalTOML: 全局通用配置基底（启用时由 ViewModel 传入）。
    ///   - nodeTOML: 该节点的额外 TOML（覆盖全局同名顶层键 / 表）。
    func activateCodexRuntime(
        for config: ProxyConfiguration,
        globalTOML: String? = nil,
        nodeTOML: String? = nil
    ) async throws {
        try await startProxy(config)

        do {
            try codexConfigManager.activate(
                baseURL: codexProxyBaseURL(for: config),
                bearerToken: config.effectiveClientKey,
                model: config.codexModel,
                globalTOML: globalTOML,
                nodeTOML: nodeTOML
            )
        } catch {
            stopProxy(config)
            do {
                try codexConfigManager.restore()
            } catch {
                proxyRuntimeLog.error("Failed to restore config.toml while rolling back Codex node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            throw error
        }

        // 系统代理会拦截 codex 发往本地回环的请求并回 502。检测到系统代理时，自动往
        // ~/.codex/.env 写入 no_proxy（仅对 codex 生效），让 codex 跳过本地代理。
        // 写入失败不阻断激活（UI 横幅仍提供手动复制兜底）。
        if SystemProxyDetector.current().isAnyEnabled {
            do {
                try CodexNoProxyFixer.apply()
            } catch {
                proxyRuntimeLog.error("Failed to write no_proxy to ~/.codex/.env for node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 停用 Codex 节点：停止进程并从备份还原 config.toml。
    func deactivateCodexRuntime(for config: ProxyConfiguration) async throws {
        stopProxy(config)

        // 移除激活时写入的 no_proxy 受管理块（仅清理我们自己的块，不动用户内容）。
        try? CodexNoProxyFixer.remove()

        do {
            try codexConfigManager.restore()
        } catch {
            do {
                try await activateCodexRuntime(for: config)
            } catch {
                proxyRuntimeLog.error("Failed to re-activate Codex runtime for node \(config.name, privacy: .public) after deactivation rollback: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    /// 还原 Codex config.toml（启动时清理残留激活态用）。
    func clearCodexRuntime() throws {
        try? CodexNoProxyFixer.remove()
        try codexConfigManager.restore()
    }

    /// Codex 的 base_url 需包含 /v1，Codex 会在其后拼接 /responses。
    private func codexProxyBaseURL(for config: ProxyConfiguration) -> String {
        let scheme: String
        let portValue: Int
        if config.enableHTTPS {
            scheme = "https"
            portValue = config.effectiveHTTPSPort
        } else {
            scheme = "http"
            portValue = config.port
        }
        return "\(scheme)://\(config.host):\(portValue)/v1"
    }

    // MARK: - Proxy-Only Mode

    /// Start the proxy process without writing to settings.json.
    /// Used for "proxy only" mode where the node serves other tools via its port.
    func startProxyOnly(for config: ProxyConfiguration) async throws {
        try await startProxy(config)
    }

    /// Starts a proxy for a one-off connectivity test. Returns true when this call started it.
    func startProxyForConnectivityTest(for config: ProxyConfiguration) async throws -> Bool {
        if isProxyRunning(config.id) { return false }
        try await startProxy(config)
        return true
    }

    func stopProxyForConnectivityTest(for config: ProxyConfiguration, startedByTest: Bool) {
        guard startedByTest else { return }
        stopProxy(config)
    }

    /// Stop a proxy-only process without touching settings.json or backup.
    func stopProxyOnly(for config: ProxyConfiguration) {
        stopProxy(config)
    }

    /// Returns the set of ports currently occupied by running proxy processes.
    func runningPorts(from configurations: [ProxyConfiguration]) -> [String: Int] {
        var result: [String: Int] = [:]
        for config in configurations where isProxyRunning(config.id) {
            result[config.id] = config.port
        }
        return result
    }

    func isProxyRunning(_ configId: String) -> Bool {
        guard let process = runningProcesses[configId] else { return false }
        if !process.isRunning {
            runningProcesses.removeValue(forKey: configId)
            return false
        }
        return true
    }

    func processDebugDescription(for configId: String) -> String? {
        guard let process = runningProcesses[configId] else { return nil }
        return "Proxy process isRunning=\(process.isRunning) pid=\(process.processIdentifier)"
    }

    private func startProxy(_ config: ProxyConfiguration) async throws {
        let runtimeLog = Logger(
            subsystem: "com.aiusage.desktop",
            category: "ProxyRuntime"
        )
        guard config.needsProxyProcess else { return }
        if runningProcesses[config.id]?.isRunning == true {
            runtimeLog.info("Proxy already running for node \(config.name, privacy: .public)")
            return
        }

        do {
            try await ProxyProcessInspector.shared.killStaleProcesses(
                port: config.port,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        } catch {
            proxyRuntimeLog.error("Failed to inspect stale proxy process on port \(config.port, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        var environment = ProcessInfo.processInfo.environment

        if config.nodeType == .codexProxy {
            // Codex 节点: QuotaServer 以 PROXY_TARGET=codex 启动 Responses 入站，转换到 OpenAI 兼容上游。
            environment["PROXY_TARGET"] = "codex"
            environment["OPENAI_API_KEY"] = config.upstreamAPIKey
            environment["OPENAI_BASE_URL"] = config.normalizedUpstreamBaseURL
            // Codex 的 wire_api 恒为 responses：强制 Responses 忠实透传，避免误用 Chat Completions 造成有损转换。
            environment["OPENAI_API_MODE"] = OpenAIUpstreamAPI.responses.rawValue
            let codexModel = config.codexModel
            if !codexModel.isEmpty {
                environment["CODEX_UPSTREAM_MODEL"] = codexModel
            }
            if config.maxOutputTokens > 0 {
                environment["MAX_OUTPUT_TOKENS"] = "\(config.maxOutputTokens)"
            }
            environment["CODEX_CLIENT_KEY"] = config.effectiveClientKey
        } else if config.nodeType == .anthropicDirect && config.usePassthroughProxy {
            environment["PROXY_MODE"] = "passthrough"
            environment["ANTHROPIC_UPSTREAM_URL"] = config.anthropicBaseURL
            environment["ANTHROPIC_UPSTREAM_KEY"] = config.anthropicAPIKey
            if !config.expectedClientKey.isEmpty {
                environment["ANTHROPIC_API_KEY"] = config.expectedClientKey
            }
            let upstreamLower = config.anthropicBaseURL.lowercased()
            if upstreamLower.contains("anyrouter.top")
                || upstreamLower.contains("a-ocnfniawgw.cn-shanghai.fcapp.run") {
                environment["ENABLE_THINKING_REWRITE"] = "1"
            }
            if config.enableModelAliasMapping {
                environment["ENABLE_MODEL_ALIAS_MAPPING"] = "1"
                environment["BIG_MODEL"] = config.modelMapping.bigModel.name
                environment["MIDDLE_MODEL"] = config.modelMapping.middleModel.name
                environment["SMALL_MODEL"] = config.modelMapping.smallModel.name
            }
        } else {
            environment["OPENAI_API_KEY"] = config.upstreamAPIKey
            environment["OPENAI_BASE_URL"] = config.normalizedUpstreamBaseURL
            environment["OPENAI_API_MODE"] = config.openAIUpstreamAPI.rawValue
            environment["BIG_MODEL"] = config.modelMapping.bigModel.name
            environment["MIDDLE_MODEL"] = config.modelMapping.middleModel.name
            environment["SMALL_MODEL"] = config.modelMapping.smallModel.name

            if config.maxOutputTokens > 0 {
                environment["MAX_OUTPUT_TOKENS"] = "\(config.maxOutputTokens)"
            }

            if !config.expectedClientKey.isEmpty {
                environment["ANTHROPIC_API_KEY"] = config.expectedClientKey
            }
        }

        if config.enableHTTPS {
            do {
                try await TLSCertificateManager.shared.ensureCertificate()
                environment["ENABLE_HTTPS"] = "1"
                environment["TLS_IDENTITY_PATH"] = TLSCertificateManager.shared.identityFilePath
                environment["HTTPS_PORT"] = "\(config.effectiveHTTPSPort)"
            } catch {
                proxyRuntimeLog.error("TLS certificate setup failed: \(String(describing: error), privacy: .public)")
                throw ProxyRuntimeError.proxyStartFailed("TLS certificate setup failed: \(error.localizedDescription)")
            }
        }

        guard let executablePath = await findQuotaServerExecutable() else {
            runtimeLog.error("QuotaServer executable not found while starting node \(config.name, privacy: .public)")
            throw ProxyRuntimeError.quotaServerNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--host", config.bindAddress,
            "--port", "\(config.port)"
        ]
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let configId = config.id
        let configName = config.name
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            runtimeLog.debug("Proxy runtime output for \(configName, privacy: .public): \(output, privacy: .private)")

            // 高频 stdout 输出只在确认含 PROXY_LOG 标记时才做行拆分与解析，
            // 避免代理流量高峰期对每块输出做无谓的全量字符串处理。
            guard output.contains("PROXY_LOG:") else { return }

            for line in output.split(separator: "\n") {
                guard line.hasPrefix("PROXY_LOG:"),
                      let jsonStart = line.firstIndex(of: Character("{")) else {
                    continue
                }

                let jsonStr = String(line[jsonStart...])
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.proxyRuntimeService(self, didReceiveProxyLog: jsonStr, configId: configId)
                }
            }
        }

        do {
            try process.run()
            try await waitForProxyHealth(process: process, config: config)
            runningProcesses[config.id] = process
            runtimeLog.info(
                "Proxy started for node \(config.name, privacy: .public) on \(config.displayURL, privacy: .public) pid=\(process.processIdentifier, privacy: .public)"
            )

            process.terminationHandler = { [weak self] proc in
                runtimeLog.notice(
                    "Proxy process exited for node \(config.name, privacy: .public) code=\(proc.terminationStatus, privacy: .public)"
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.runningProcesses.removeValue(forKey: config.id)
                    self.delegate?.proxyRuntimeService(self, processDidTerminateFor: config.id)
                }
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            runtimeLog.error("Failed to start proxy for node \(config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error is ProxyRuntimeError
                ? error
                : ProxyRuntimeError.proxyStartFailed(error.localizedDescription)
        }
    }

    private func stopProxy(_ config: ProxyConfiguration) {
        guard let process = runningProcesses[config.id] else { return }
        process.terminate()
        runningProcesses.removeValue(forKey: config.id)
        proxyRuntimeLog.info("Proxy stopped for node \(config.name, privacy: .public)")
    }

    private func findQuotaServerExecutable() async -> String? {
        if let bundledExecutable = bundledQuotaServerExecutable() {
            proxyRuntimeLog.info("Found bundled QuotaServer at \(bundledExecutable, privacy: .public)")
            return bundledExecutable
        }

        let sourceProjectRoot = (Self.sourceFileDir as NSString).deletingLastPathComponent
        let projectRootFromSource = (sourceProjectRoot as NSString).deletingLastPathComponent

        if let sourceTreeExecutable = sourceTreeQuotaServerExecutable(from: projectRootFromSource) {
            proxyRuntimeLog.info("Found QuotaServer in source tree at \(sourceTreeExecutable, privacy: .public)")
            return sourceTreeExecutable
        }

        let packageRoot = (projectRootFromSource as NSString).appendingPathComponent("QuotaBackend")
        if fileManager.fileExists(atPath: packageRoot),
           let builtExecutable = await buildQuotaServerIfNeeded(packageRoot: packageRoot) {
            proxyRuntimeLog.info("Built QuotaServer on demand at \(builtExecutable, privacy: .public)")
            return builtExecutable
        }

        let bundlePath = Bundle.main.bundlePath
        proxyRuntimeLog.error(
            """
            QuotaServer executable not found in bundle or expected build outputs.
            sourceFileDir=\(Self.sourceFileDir, privacy: .public)
            bundlePath=\(bundlePath, privacy: .public)
            """
        )
        return nil
    }

    private func bundledQuotaServerExecutable() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let bundledPath = resourceURL
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("QuotaServer")
            .path
        return fileManager.fileExists(atPath: bundledPath) ? bundledPath : nil
    }

    private func sourceTreeQuotaServerExecutable(from projectRoot: String) -> String? {
        let relativePaths = [
            "QuotaBackend/.build/debug/QuotaServer",
            "QuotaBackend/.build/release/QuotaServer",
        ]

        let candidateRoots = [
            projectRoot,
            Bundle.main.bundlePath,
        ]

        for root in candidateRoots {
            for relPath in relativePaths {
                let fullPath = (root as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
        }

        var searchDir = projectRoot
        for _ in 0..<5 {
            for relPath in relativePaths {
                let fullPath = (searchDir as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
            searchDir = (searchDir as NSString).deletingLastPathComponent
        }

        return nil
    }

    private func waitForProxyHealth(process: Process, config: ProxyConfiguration) async throws {
        let deadline = Date().addingTimeInterval(Self.proxyStartupTimeout)
        var lastErrorDescription: String?

        repeat {
            if !process.isRunning {
                throw ProxyRuntimeError.proxyStartFailed("process exited with code \(process.terminationStatus)")
            }

            do {
                if try await probeProxyHealth(config: config) {
                    return
                }
                lastErrorDescription = "health endpoint returned a non-2xx status"
            } catch {
                lastErrorDescription = error.localizedDescription
            }

            try await Task.sleep(nanoseconds: Self.proxyStartupProbeIntervalNanos)
        } while Date() < deadline

        if !process.isRunning {
            throw ProxyRuntimeError.proxyStartFailed("process exited with code \(process.terminationStatus)")
        }

        if let lastErrorDescription {
            throw ProxyRuntimeError.proxyStartFailed("health check timed out: \(lastErrorDescription)")
        }
        throw ProxyRuntimeError.proxyStartFailed("health check timed out")
    }

    private func probeProxyHealth(config: ProxyConfiguration) async throws -> Bool {
        let host = healthCheckHost(for: config.host)
        let hostComponent = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(hostComponent):\(config.port)/health") else {
            return false
        }

        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    private func healthCheckHost(for configuredHost: String) -> String {
        let trimmed = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0.0.0.0" || trimmed == "::" {
            return "127.0.0.1"
        }
        return trimmed
    }

    private func buildQuotaServerIfNeeded(packageRoot: String) async -> String? {
        let buildConfiguration: String
#if DEBUG
        buildConfiguration = "debug"
#else
        buildConfiguration = "release"
#endif

        do {
            return try await QuotaServerBuilder.shared.buildQuotaServer(
                packageRoot: packageRoot,
                configuration: buildConfiguration
            )
        } catch {
            proxyRuntimeLog.error("Failed to build QuotaServer on demand: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
