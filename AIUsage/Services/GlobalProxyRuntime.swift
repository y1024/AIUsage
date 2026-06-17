import Foundation
import Combine
import os.log

// MARK: - Global Proxy Runtime (Codex track)
// 管理「全局统一代理」的常驻 QuotaServer 进程（PROXY_TARGET=codex）。与每节点独立进程不同：
// 本进程在固定端口长期存活，切换激活节点时通过受 token 保护的本地 admin 端点热替换上游，
// 进程不重启、端口不变。日志经 stdout PROXY_LOG（已带 node_id）回流到 ProxyViewModel 按节点归因。
//
// 数据流: ProxyViewModel(GlobalProxy 扩展) 解析节点 → CodexUpstream → 本类启动/热切换。

private let globalProxyRuntimeLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxyRuntime")

enum GlobalProxyRuntimeError: LocalizedError {
    case quotaServerNotFound
    case startFailed(String)
    case portInUseByNode(Int, String, String)
    case adminUnreachable(String)
    case adminRejected(Int)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .quotaServerNotFound:
            return AppSettings.shared.t("QuotaServer executable not found.", "未找到 QuotaServer 可执行文件。")
        case .startFailed(let reason):
            return AppSettings.shared.t("Failed to start the global proxy: \(reason)", "启动全局代理失败：\(reason)")
        case .portInUseByNode(let port, let track, let name):
            return AppSettings.shared.t(
                "Port \(port) is already in use by node \"\(name)\" under the \(track) proxy. Change the global proxy port, or stop that node first.",
                "端口 \(port) 已被「\(track) 代理」下的节点「\(name)」占用。请修改全局代理端口，或先停用那个节点。"
            )
        case .adminUnreachable(let reason):
            return AppSettings.shared.t("Global proxy admin endpoint is unreachable: \(reason)", "全局代理 admin 端点不可达：\(reason)")
        case .adminRejected(let status):
            return AppSettings.shared.t("Global proxy rejected the upstream switch (HTTP \(status)).", "全局代理拒绝了上游切换（HTTP \(status)）。")
        case .notRunning:
            return AppSettings.shared.t("Global proxy is not running.", "全局代理未在运行。")
        }
    }
}

@MainActor
final class GlobalProxyRuntime: ObservableObject {
    static let shared = GlobalProxyRuntime()

    /// 全局代理在跨轨端口仲裁中的所有者 id（固定标识，排除自身用）。
    static let ownerId = "__aiusage_global_codex__"
    static let trackLabel = "Codex 全局代理"

    /// 当前激活节点的上游快照：宿主层把 codexProxy 节点投影成本结构再交给运行时。
    struct CodexUpstream {
        let nodeId: String
        let nodeName: String
        let baseURL: String
        let apiKey: String
        let model: String?
        let maxOutputTokens: Int?
    }

    @Published private(set) var isRunning = false
    @Published private(set) var activeNodeId: String?
    @Published private(set) var activeNodeName: String?

    private var process: Process?
    private var adminKey: String?
    private var listenPort = GlobalProxyConfig.defaultPort

    private static let startupTimeout: TimeInterval = 6
    private static let probeIntervalNanos: UInt64 = 250_000_000

    var isProcessRunning: Bool { process?.isRunning == true }

    /// 跨轨仲裁聚合用：全局代理运行时占用的端口所有者（仅在确实运行时上报）。
    func runningPortOwners() -> [ProxyPortArbiter.Owner] {
        guard isProcessRunning else { return [] }
        return [ProxyPortArbiter.Owner(id: Self.ownerId, ports: [listenPort], track: Self.trackLabel, label: activeNodeName ?? "")]
    }

    // MARK: - Lifecycle

    /// 启动常驻全局代理进程。端口冲突走跨轨仲裁 fail-loud；启动后等待 /health 就绪。
    func start(port: Int, clientKey: String, initial: CodexUpstream) async throws {
        if isProcessRunning { stop() }

        if let conflict = ProxyPortArbiter.conflict(forPorts: [port], excluding: Self.ownerId) {
            throw GlobalProxyRuntimeError.portInUseByNode(conflict.port, conflict.track, conflict.label)
        }

        guard let executablePath = await QuotaServerLocator.find() else {
            throw GlobalProxyRuntimeError.quotaServerNotFound
        }

        let admin = UUID().uuidString
        var environment = ProcessInfo.processInfo.environment
        environment["PROXY_TARGET"] = "codex"
        environment["OPENAI_API_MODE"] = "responses"
        environment["GLOBAL_PROXY_ADMIN_KEY"] = admin
        environment["GLOBAL_PROXY_NODE_ID"] = initial.nodeId
        environment["CODEX_CLIENT_KEY"] = clientKey
        applyUpstreamEnv(&environment, upstream: initial)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["--host", "127.0.0.1", "--port", "\(port)"]
        proc.environment = environment

        let outputPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8), !output.isEmpty,
                  output.contains("PROXY_LOG:") else { return }
            for line in output.split(separator: "\n") {
                guard line.hasPrefix("PROXY_LOG:"),
                      let jsonStart = line.firstIndex(of: Character("{")) else { continue }
                let jsonStr = String(line[jsonStart...])
                Task { @MainActor in
                    let fallbackId = GlobalProxyRuntime.shared.activeNodeId ?? ""
                    ProxyViewModel.shared.parseProxyLog(jsonStr, configId: fallbackId)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            throw GlobalProxyRuntimeError.startFailed(error.localizedDescription)
        }

        proc.terminationHandler = { p in
            globalProxyRuntimeLog.notice("Global proxy process exited code=\(p.terminationStatus, privacy: .public)")
            Task { @MainActor in
                let runtime = GlobalProxyRuntime.shared
                if runtime.process === p {
                    runtime.process = nil
                    runtime.isRunning = false
                }
            }
        }

        self.process = proc
        self.adminKey = admin
        self.listenPort = port
        self.activeNodeId = initial.nodeId
        self.activeNodeName = initial.nodeName

        do {
            try await waitForHealth(port: port, process: proc)
        } catch {
            stop()
            throw error
        }

        self.isRunning = true
        globalProxyRuntimeLog.info("Global proxy started on 127.0.0.1:\(port, privacy: .public) pid=\(proc.processIdentifier, privacy: .public) node=\(initial.nodeId, privacy: .public)")
    }

    func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        adminKey = nil
        isRunning = false
        globalProxyRuntimeLog.info("Global proxy stopped")
    }

    // MARK: - Hot Switch

    /// 热切换激活节点：POST admin 端点替换上游，进程不重启。成功后更新 activeNode 状态。
    func switchUpstream(_ upstream: CodexUpstream) async throws {
        guard isProcessRunning, let adminKey else {
            throw GlobalProxyRuntimeError.notRunning
        }
        guard let url = URL(string: "http://127.0.0.1:\(listenPort)/__aiusage/admin/codex-upstream") else {
            throw GlobalProxyRuntimeError.adminUnreachable("invalid url")
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "nodeId": upstream.nodeId,
            "baseURL": upstream.baseURL,
            "apiKey": upstream.apiKey,
            "model": upstream.model ?? "",
            "maxOutputTokens": upstream.maxOutputTokens ?? 0
        ])

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GlobalProxyRuntimeError.adminUnreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GlobalProxyRuntimeError.adminUnreachable("no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GlobalProxyRuntimeError.adminRejected(http.statusCode)
        }

        self.activeNodeId = upstream.nodeId
        self.activeNodeName = upstream.nodeName
        globalProxyRuntimeLog.info("Global proxy hot-switched to node \(upstream.nodeId, privacy: .public)")
    }

    // MARK: - Helpers

    private func applyUpstreamEnv(_ environment: inout [String: String], upstream: CodexUpstream) {
        environment["OPENAI_API_KEY"] = upstream.apiKey
        environment["OPENAI_BASE_URL"] = upstream.baseURL
        if let model = upstream.model, !model.isEmpty {
            environment["CODEX_UPSTREAM_MODEL"] = model
        }
        if let maxTokens = upstream.maxOutputTokens, maxTokens > 0 {
            environment["MAX_OUTPUT_TOKENS"] = "\(maxTokens)"
        }
    }

    private func waitForHealth(port: Int, process: Process) async throws {
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            throw GlobalProxyRuntimeError.startFailed("invalid health url")
        }
        var lastError = "health check timed out"
        repeat {
            if !process.isRunning {
                throw GlobalProxyRuntimeError.startFailed("process exited with code \(process.terminationStatus)")
            }
            do {
                var request = URLRequest(url: url, timeoutInterval: 1)
                request.httpMethod = "GET"
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
                lastError = "health endpoint returned a non-2xx status"
            } catch {
                lastError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: Self.probeIntervalNanos)
        } while Date() < deadline
        throw GlobalProxyRuntimeError.startFailed(lastError)
    }
}
