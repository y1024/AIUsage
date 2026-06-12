import Foundation
import Combine
import os.log
import QuotaBackend

// MARK: - OpenCode Proxy Runtime
// OpenCode 节点「代理模式」（路线 B）的本地透传进程管理：
// 启动 QuotaServer(PROXY_TARGET=opencode) 把 /v1/chat/completions 忠实透传到节点上游，
// 解析其 stdout 的 PROXY_LOG 行得到请求级日志（仅观测展示，不参与计费——
// 用量成本仍以 opencode.db 为准，避免双重计账）。
// 单进程模型: 同一时刻最多一个 OpenCode 节点生效，因此只维护一个子进程。

private let openCodeProxyLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeProxyRuntime")

@MainActor
final class OpenCodeProxyRuntime: ObservableObject {
    static let shared = OpenCodeProxyRuntime()

    @Published private(set) var isRunning = false
    @Published private(set) var runningNodeId: String?
    /// 最近请求日志，新→旧，最多保留 200 条（仅内存，不落盘）。
    @Published private(set) var requestLogs: [ProxyRequestLog] = []
    @Published private(set) var lastError: String?

    private static let maxLogEntries = 200
    private static let startupTimeout: TimeInterval = 5
    private static let startupProbeIntervalNanos: UInt64 = 100_000_000
    private static let maxRestartAttempts = 3
    private static let restartBaseDelayNanos: UInt64 = 1_000_000_000

    private var process: Process?
    /// 期望保持运行的节点（手动 stop 时清空；崩溃重启据此判断）。
    private var expectedNode: OpenCodeNode?
    private var restartAttempts = 0

    // MARK: - Lifecycle

    func start(node: OpenCodeNode) async throws {
        // 切换节点/重复激活：先停掉旧进程。
        stopProcessOnly()
        expectedNode = node
        lastError = nil

        do {
            try await launch(node: node)
            restartAttempts = 0
        } catch {
            expectedNode = nil
            throw error
        }
    }

    func stop() {
        expectedNode = nil
        stopProcessOnly()
        lastError = nil
    }

    /// 用户在错误横幅上手动重启。
    func restart() async {
        guard let node = expectedNode else { return }
        do {
            try await start(node: node)
        } catch {
            lastError = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    func clearLogs() {
        requestLogs = []
    }

    private func stopProcessOnly() {
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        isRunning = false
        runningNodeId = nil
    }

    // MARK: - Launch

    private func launch(node: OpenCodeNode) async throws {
        killStaleProcesses(port: node.proxyPort)

        guard let executablePath = await QuotaServerLocator.find() else {
            throw ProxyRuntimeError.quotaServerNotFound
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PROXY_TARGET"] = "opencode"
        environment["OPENAI_BASE_URL"] = node.baseURL
        environment["OPENAI_API_KEY"] = node.apiKey

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--host", "127.0.0.1", "--port", "\(node.proxyPort)"]
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let nodeId = node.id
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
                    self?.recordProxyLog(jsonStr, nodeId: nodeId)
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

        self.process = process
        isRunning = true
        runningNodeId = node.id
        openCodeProxyLog.info("OpenCode proxy started for node \(node.displayName, privacy: .public) on 127.0.0.1:\(node.proxyPort, privacy: .public) pid=\(process.processIdentifier, privacy: .public)")

        process.terminationHandler = { [weak self] proc in
            openCodeProxyLog.notice("OpenCode proxy process exited code=\(proc.terminationStatus, privacy: .public)")
            Task { @MainActor [weak self] in
                self?.handleUnexpectedTermination(of: proc)
            }
        }
    }

    // MARK: - Crash Recovery

    private func handleUnexpectedTermination(of proc: Process) {
        guard process === proc else { return }
        process = nil
        isRunning = false
        runningNodeId = nil
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard let node = expectedNode else { return }

        restartAttempts += 1
        guard restartAttempts <= Self.maxRestartAttempts else {
            lastError = AppSettings.shared.t(
                "The local proxy keeps exiting. OpenCode requests will fail until it is restarted.",
                "本地代理持续退出，OpenCode 请求将失败，请手动重启代理。"
            )
            openCodeProxyLog.error("OpenCode proxy restart attempts exhausted for node \(node.displayName, privacy: .public)")
            return
        }

        let attempt = restartAttempts
        openCodeProxyLog.notice("Scheduling OpenCode proxy restart attempt \(attempt, privacy: .public)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.restartBaseDelayNanos * UInt64(attempt))
            guard let self, let current = self.expectedNode, current.id == node.id, !self.isRunning else { return }
            do {
                try await self.launch(node: current)
                self.restartAttempts = 0
            } catch {
                self.scheduleRestart()
            }
        }
    }

    // MARK: - Log Ingestion

    private func recordProxyLog(_ jsonStr: String, nodeId: String) {
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
            path: "/v1/chat/completions",
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
    }

    // MARK: - Helpers

    /// 清掉残留占用端口的旧代理进程（上次未正常退出时）。
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
