import Foundation
import Combine
import os.log
import QuotaBackend

// MARK: - OpenCode Proxy Runtime
// OpenCode 节点「代理模式」（路线 B）的本地透传进程管理。
// 按节点协议复用 QuotaServer 的对应透传轨道（环境变量选轨）：
//   openai-compatible → PROXY_TARGET=opencode（/v1/chat/completions）
//   openai-responses  → PROXY_TARGET=codex（/v1/responses，需 API Key）
//   anthropic         → PROXY_MODE=passthrough（/v1/messages，Anthropic 透传）
// 三条轨道都向 stdout 发同构的 PROXY_LOG 行，统一解析为请求级日志
// （仅观测展示，不参与计费——用量成本仍以 opencode.db 为准，避免双重计账）。
// 多进程模型（与 Claude/Codex 的 ProxyRuntimeService 同语义）: 每个节点一个独立子进程、
// 各占一个端口，可同时运行多个「仅代理」节点 + 一个激活节点；同端口启动会得到可读错误。

private let openCodeProxyLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeProxyRuntime")

@MainActor
final class OpenCodeProxyRuntime: ObservableObject {
    static let shared = OpenCodeProxyRuntime()

    /// 进程正在运行的节点 id 集合。
    @Published private(set) var runningNodeIds: Set<String> = []
    /// 最近请求日志（全部节点共享环形缓冲，按 configId=节点 id 区分），新→旧，
    /// 最多保留 500 条；落盘持久化（成本恒 0，仅观测不计费）。
    @Published private(set) var requestLogs: [ProxyRequestLog] = []
    @Published private(set) var lastError: String?

    private static let maxLogEntries = 500
    private static let startupTimeout: TimeInterval = 5
    private static let startupProbeIntervalNanos: UInt64 = 100_000_000
    private static let maxRestartAttempts = 3
    private static let restartBaseDelayNanos: UInt64 = 1_000_000_000
    private static let logsSaveDebounceNanos: UInt64 = 2_000_000_000

    /// 单个节点的进程实例（期望保持运行；手动 stop 移除，崩溃重启据此判断）。
    private final class Instance {
        var node: OpenCodeNode
        var process: Process?
        var restartAttempts = 0
        init(node: OpenCodeNode) { self.node = node }
    }

    private var instances: [String: Instance] = [:]
    private var pendingLogsSave: Task<Void, Never>?

    private static var logsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-proxy-logs.json")
    }

    private init() {
        loadPersistedLogs()
    }

    // MARK: - Lifecycle

    func isRunning(nodeId: String) -> Bool {
        runningNodeIds.contains(nodeId)
    }

    func start(node: OpenCodeNode) async throws {
        // 幂等：同节点且代理相关参数（协议/上游/Key/端口）未变时复用现有进程。
        // 否则编辑无关字段（通用配置、定价、模型）触发的重新激活会让代理闪断一拍。
        if let instance = instances[node.id], instance.process?.isRunning == true,
           Self.proxyParametersEqual(instance.node, node) {
            instance.node = node
            return
        }
        // 端口被其它运行中节点占用：直接报可读错误（否则 killStaleProcesses 会误杀它）。
        if let conflict = instances.values.first(where: {
            $0.node.id != node.id && $0.process?.isRunning == true && $0.node.proxyPort == node.proxyPort
        }) {
            throw ProxyRuntimeError.proxyStartFailed(AppSettings.shared.t(
                "Port \(node.proxyPort) is already in use by node \"\(conflict.node.displayName)\". Change the port in node settings first.",
                "端口 \(node.proxyPort) 已被节点「\(conflict.node.displayName)」占用，请先在节点设置中修改端口。"
            ))
        }

        stopProcess(nodeId: node.id)
        let instance = Instance(node: node)
        instances[node.id] = instance
        lastError = nil

        do {
            try await launch(instance: instance)
            instance.restartAttempts = 0
        } catch {
            instances.removeValue(forKey: node.id)
            throw error
        }
    }

    func stop(nodeId: String) {
        guard let instance = instances.removeValue(forKey: nodeId) else { return }
        terminate(instance)
        runningNodeIds.remove(nodeId)
        if instances.isEmpty { lastError = nil }
    }

    /// 用户在错误横幅上手动重启：拉起所有「期望运行但进程不在」的实例。
    func restartStopped() async {
        lastError = nil
        for instance in instances.values where instance.process?.isRunning != true {
            do {
                instance.restartAttempts = 0
                try await launch(instance: instance)
            } catch {
                lastError = SensitiveDataRedactor.redactedMessage(for: error)
            }
        }
    }

    func clearLogs() {
        requestLogs = []
        persistLogsSoon()
    }

    /// 单个节点的日志切片（节点详情统计用）。
    func logs(forNodeId nodeId: String) -> [ProxyRequestLog] {
        requestLogs.filter { $0.configId == nodeId }
    }

    /// 代理进程的环境是否等价（决定 start 是否可以跳过重启）。
    private static func proxyParametersEqual(_ a: OpenCodeNode, _ b: OpenCodeNode) -> Bool {
        a.protocolType == b.protocolType
            && a.baseURL == b.baseURL
            && a.apiKey == b.apiKey
            && a.proxyPort == b.proxyPort
    }

    private func stopProcess(nodeId: String) {
        guard let instance = instances[nodeId] else { return }
        terminate(instance)
        runningNodeIds.remove(nodeId)
    }

    private func terminate(_ instance: Instance) {
        guard let process = instance.process else { return }
        instance.process = nil
        if process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
    }

    // MARK: - Launch

    private func launch(instance: Instance) async throws {
        let node = instance.node
        killStaleProcesses(port: node.proxyPort)

        guard let executablePath = await QuotaServerLocator.find() else {
            throw ProxyRuntimeError.quotaServerNotFound
        }

        var environment = ProcessInfo.processInfo.environment
        // 清掉继承环境里可能残留的选轨/认证变量，避免误启别的轨道或被
        // passthrough 当作客户端校验 Key（ANTHROPIC_API_KEY）拒掉 OpenCode 请求。
        for key in ["PROXY_TARGET", "PROXY_MODE", "OPENAI_API_MODE", "ANTHROPIC_API_KEY",
                    "CODEX_CLIENT_KEY", "OPENCODE_CLIENT_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL"] {
            environment.removeValue(forKey: key)
        }
        switch node.protocolType {
        case .openAICompatible:
            environment["PROXY_TARGET"] = "opencode"
            environment["OPENAI_BASE_URL"] = node.baseURL
            environment["OPENAI_API_KEY"] = node.apiKey
        case .openAIResponses:
            // Codex 轨道要求非空 Key（responses 上游均需认证）。
            environment["PROXY_TARGET"] = "codex"
            environment["OPENAI_API_MODE"] = "responses"
            environment["OPENAI_BASE_URL"] = node.baseURL
            environment["OPENAI_API_KEY"] = node.apiKey
        case .anthropic:
            // passthrough 轨道按「上游根 + /v1/messages」拼 URL，传入不含 /v1 的根地址。
            environment["PROXY_MODE"] = "passthrough"
            environment["ANTHROPIC_UPSTREAM_URL"] = node.baseURLWithoutV1Suffix
            environment["ANTHROPIC_UPSTREAM_KEY"] = node.apiKey
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--host", "127.0.0.1", "--port", "\(node.proxyPort)"]
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let nodeId = node.id
        let inboundPath = "/v1" + node.protocolType.requestPath
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            guard output.contains("PROXY_LOG:") else { return }

            for line in output.split(separator: "\n") {
                guard line.hasPrefix("PROXY_LOG:"),
                      let jsonStart = line.firstIndex(of: Character("{")) else {
                    continue
                }
                let jsonStr = String(line[jsonStart...])
                Task { @MainActor [weak self] in
                    self?.recordProxyLog(jsonStr, nodeId: nodeId, path: inboundPath)
                }
            }
        }

        do {
            try process.run()
            try await waitForHealth(process: process, port: node.proxyPort)
        } catch {
            if process.isRunning {
                process.terminate()
            }
            openCodeProxyLog.error("Failed to start OpenCode proxy for node \(node.displayName, privacy: .public): \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)")
            throw error is ProxyRuntimeError
                ? error
                : ProxyRuntimeError.proxyStartFailed(error.localizedDescription)
        }

        instance.process = process
        runningNodeIds.insert(node.id)
        openCodeProxyLog.info("OpenCode proxy started for node \(node.displayName, privacy: .public) on 127.0.0.1:\(node.proxyPort, privacy: .public) pid=\(process.processIdentifier, privacy: .public)")

        process.terminationHandler = { [weak self] proc in
            openCodeProxyLog.notice("OpenCode proxy process exited code=\(proc.terminationStatus, privacy: .public)")
            Task { @MainActor [weak self] in
                self?.handleUnexpectedTermination(of: proc, nodeId: nodeId)
            }
        }
    }

    // MARK: - Crash Recovery

    private func handleUnexpectedTermination(of proc: Process, nodeId: String) {
        guard let instance = instances[nodeId], instance.process === proc else { return }
        instance.process = nil
        runningNodeIds.remove(nodeId)
        scheduleRestart(nodeId: nodeId)
    }

    private func scheduleRestart(nodeId: String) {
        guard let instance = instances[nodeId] else { return }

        instance.restartAttempts += 1
        guard instance.restartAttempts <= Self.maxRestartAttempts else {
            lastError = AppSettings.shared.t(
                "The local proxy for node \"\(instance.node.displayName)\" keeps exiting. Requests through it will fail until it is restarted.",
                "节点「\(instance.node.displayName)」的本地代理持续退出，经由它的请求将失败，请手动重启代理。"
            )
            openCodeProxyLog.error("OpenCode proxy restart attempts exhausted for node \(instance.node.displayName, privacy: .public)")
            return
        }

        let attempt = instance.restartAttempts
        openCodeProxyLog.notice("Scheduling OpenCode proxy restart attempt \(attempt, privacy: .public)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.restartBaseDelayNanos * UInt64(attempt))
            guard let self, let current = self.instances[nodeId],
                  current.process?.isRunning != true else { return }
            do {
                try await self.launch(instance: current)
                current.restartAttempts = 0
            } catch {
                self.scheduleRestart(nodeId: nodeId)
            }
        }
    }

    // MARK: - Log Ingestion

    private func recordProxyLog(_ jsonStr: String, nodeId: String, path: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "proxy_request_log" else {
            return
        }

        // 缓存字段拆分逻辑与 ProxyViewModel.parseProxyLog 对齐（优先分项，回退合并值）。
        let splitRead = json["cache_read_tokens"] as? Int
        let splitCreate = json["cache_creation_tokens"] as? Int
        let legacyCache = json["cache_tokens"] as? Int
        let tokensCacheRead = splitRead ?? legacyCache ?? 0
        let tokensCacheCreation = splitCreate ?? 0

        // 路线 B 约束: 请求日志仅观测，不估算费用（计费以 opencode.db 为准），故成本恒为 0。
        let log = ProxyRequestLog(
            configId: nodeId,
            method: "POST",
            path: path,
            claudeModel: json["claude_model"] as? String ?? "unknown",
            upstreamModel: json["upstream_model"] as? String ?? "unknown",
            success: json["success"] as? Bool ?? false,
            responseTimeMs: Double(json["response_time_ms"] as? Int ?? 0),
            tokensInput: json["input_tokens"] as? Int ?? 0,
            tokensOutput: json["output_tokens"] as? Int ?? 0,
            tokensCacheRead: tokensCacheRead,
            tokensCacheCreation: tokensCacheCreation,
            estimatedCostUSD: 0,
            pricingResolved: false,
            errorMessage: json["error"] as? String,
            errorType: json["error_type"] as? String,
            statusCode: json["status_code"] as? Int
        )

        requestLogs.insert(log, at: 0)
        if requestLogs.count > Self.maxLogEntries {
            requestLogs.removeLast(requestLogs.count - Self.maxLogEntries)
        }
        persistLogsSoon()
    }

    // MARK: - Log Persistence

    private func loadPersistedLogs() {
        guard let data = FileManager.default.contents(atPath: Self.logsFilePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let logs = try? decoder.decode([ProxyRequestLog].self, from: data) {
            requestLogs = Array(logs.prefix(Self.maxLogEntries))
        }
    }

    /// 防抖落盘：日志多为突发（流式回合结束），合并 2 秒窗口内的写入。
    private func persistLogsSoon() {
        pendingLogsSave?.cancel()
        pendingLogsSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.logsSaveDebounceNanos)
            guard !Task.isCancelled else { return }
            self?.persistLogsNow()
        }
    }

    private func persistLogsNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(requestLogs) else { return }
        let path = Self.logsFilePath
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            openCodeProxyLog.warning("Failed to persist OpenCode proxy logs: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// 清掉残留占用端口的旧代理进程（上次未正常退出时）。
    /// 调用前已确认没有别的受管实例占用该端口，不会误杀自己的子进程。
    private func killStaleProcesses(port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        do {
            try lsof.run()
            lsof.waitUntilExit()
        } catch {
            openCodeProxyLog.error("Failed to inspect stale processes on port \(port, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let currentPid = ProcessInfo.processInfo.processIdentifier
        for pidStr in output.components(separatedBy: .whitespacesAndNewlines) where !pidStr.isEmpty {
            guard let pid = Int32(pidStr), pid != currentPid else { continue }
            openCodeProxyLog.info("Killing stale process on port \(port, privacy: .public): pid=\(pid, privacy: .public)")
            kill(pid, SIGTERM)
            usleep(200_000)
        }
    }

    private func waitForHealth(process: Process, port: Int) async throws {
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        var lastErrorDescription: String?

        repeat {
            if !process.isRunning {
                throw ProxyRuntimeError.proxyStartFailed("process exited with code \(process.terminationStatus)")
            }

            do {
                if try await probeHealth(port: port) {
                    return
                }
                lastErrorDescription = "health endpoint returned a non-2xx status"
            } catch {
                lastErrorDescription = error.localizedDescription
            }

            try await Task.sleep(nanoseconds: Self.startupProbeIntervalNanos)
        } while Date() < deadline

        throw ProxyRuntimeError.proxyStartFailed("health check timed out: \(lastErrorDescription ?? "unknown")")
    }

    private func probeHealth(port: Int) async throws -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
