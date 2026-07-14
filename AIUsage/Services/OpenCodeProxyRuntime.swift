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

// MARK: - Global Proxy Per-Node Usage
// OpenCode「全局统一代理」模式下，单个真实节点的永久累计用量（成本按当时节点定价冻结）。
// 与 Codex/Claude 的 ProxyStatistics 同语义：原始日志可被环形/保留期裁剪，但本累计永久保留，
// 是节点卡片在全局模式下的用量/费用真相源（opencode.db 侧已排除全局 provider，互斥不双计）。
struct OpenCodeGlobalNodeUsage: Codable {
    var requestCount = 0
    var successCount = 0
    var failureCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreateTokens = 0
    var costUsd: Double = 0
    var lastRequestAt: Date?

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens }

    mutating func add(_ log: ProxyRequestLog) {
        requestCount += 1
        if log.success { successCount += 1 } else { failureCount += 1 }
        inputTokens += log.tokensInput
        outputTokens += log.tokensOutput
        cacheReadTokens += log.tokensCacheRead
        cacheCreateTokens += log.tokensCacheCreation
        costUsd += log.estimatedCostUSD
        lastRequestAt = log.timestamp
    }
}

@MainActor
final class OpenCodeProxyRuntime: ObservableObject {
    static let shared = OpenCodeProxyRuntime()

    /// 进程正在运行的节点 id 集合。
    @Published private(set) var runningNodeIds: Set<String> = []
    /// 正在启动/恢复/重启中的节点 id（进程尚未就绪）。用于抑制「本地代理未在运行」横幅在
    /// 启动窗口内的闪现——这些节点既不算运行中、也不该报故障。
    @Published private(set) var startingNodeIds: Set<String> = []
    /// 运行时本会话正在「负责保活」的节点 id（建立了 Instance；崩溃后 Instance 仍在、process=nil）。
    /// 横幅据此判断「该跑却没跑」：未启动恢复（设置关闭）时为空 → 不误报；只反映本会话真实接管的节点。
    @Published private(set) var managedNodeIds: Set<String> = []
    /// 最近请求日志（全部节点共享环形缓冲，按 configId=节点 id 区分），新→旧，
    /// 最多保留 500 条；落盘持久化（成本恒 0，仅观测不计费）。
    @Published private(set) var requestLogs: [ProxyRequestLog] = []
    /// 全局统一代理模式下每个真实节点的永久累计用量（按 node id 归因，独立于 opencode.db）。
    @Published private(set) var globalNodeStats: [String: OpenCodeGlobalNodeUsage] = [:]
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
    private var pendingGlobalStatsSave: Task<Void, Never>?

    private static var logsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-proxy-logs.json")
    }

    private static var globalStatsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/opencode-global-usage.json")
    }

    private init() {
        loadPersistedLogs()
        loadGlobalStats()
    }

    // MARK: - Lifecycle

    func isRunning(nodeId: String) -> Bool {
        runningNodeIds.contains(nodeId)
    }

    /// OpenCode 轨道当前正在监听的代理：供跨轨端口仲裁聚合。
    /// 读自运行实例的真实进程状态，避免与 store 标记漂移。
    func runningPortOwners() -> [ProxyPortArbiter.Owner] {
        instances.values.compactMap { instance in
            guard instance.process?.isRunning == true else { return nil }
            return ProxyPortArbiter.Owner(
                id: instance.node.id,
                ports: [instance.node.proxyPort],
                track: "OpenCode",
                label: instance.node.displayName
            )
        }
    }

    /// 启动恢复开始时，把待恢复节点预标记为「启动中」，覆盖 reap→launch 的整段窗口，
    /// 避免横幅在进程就绪前闪现（`launch` 完成/失败时会逐个清除自己的标记）。
    func beginRestoring(nodeIds: [String]) {
        startingNodeIds.formUnion(nodeIds)
    }

    /// 启动恢复结束时清除残留标记（个别节点在到达 `launch` 前就抛错时的兜底清理）。
    func endRestoring(nodeIds: [String]) {
        startingNodeIds.subtract(nodeIds)
    }

    func start(node: OpenCodeNode) async throws {
        // 幂等：同节点且代理相关参数（协议/上游/Key/端口）未变时复用现有进程。
        // 否则编辑无关字段（通用配置、定价、模型）触发的重新激活会让代理闪断一拍。
        if let instance = instances[node.id], instance.process?.isRunning == true,
           Self.proxyParametersEqual(instance.node, node) {
            instance.node = node
            return
        }
        // 跨轨端口仲裁：端口被任一条正在运行的代理（OpenCode/Claude/Codex）占用时直接报可读错误
        // （否则 killStaleProcesses 会把那条活代理误杀）。
        if let conflict = ProxyPortArbiter.conflict(forPorts: [node.proxyPort], excluding: node.id) {
            throw ProxyRuntimeError.proxyPortInUseByNode(conflict.port, conflict.track, conflict.label)
        }

        stopProcess(nodeId: node.id)
        let instance = Instance(node: node)
        instances[node.id] = instance
        managedNodeIds.insert(node.id)
        lastError = nil

        do {
            try await launch(instance: instance)
            instance.restartAttempts = 0
        } catch {
            if instances[node.id] === instance {
                instances.removeValue(forKey: node.id)
                managedNodeIds.remove(node.id)
            }
            throw error
        }
    }

    func stop(nodeId: String) {
        guard let instance = instances.removeValue(forKey: nodeId) else { return }
        terminate(instance)
        runningNodeIds.remove(nodeId)
        managedNodeIds.remove(nodeId)
        startingNodeIds.remove(nodeId)
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

    /// 单个节点在全局统一代理模式下的永久累计用量（无则 nil）。
    func globalStats(forNodeId nodeId: String) -> OpenCodeGlobalNodeUsage? {
        globalNodeStats[nodeId]
    }

    /// 删除节点时清理其在内存/磁盘上的代理残留：全局永久累计 + 该节点的请求日志切片，
    /// 避免已删除节点的归因数据在 JSON 里长期堆积（热力图归档为按天聚合，不含节点维度，保留不受影响）。
    func purgeNode(_ nodeId: String) {
        var didChange = false
        if globalNodeStats.removeValue(forKey: nodeId) != nil {
            persistGlobalStatsSoon()
            didChange = true
        }
        let before = requestLogs.count
        requestLogs.removeAll { $0.configId == nodeId }
        if requestLogs.count != before {
            persistLogsSoon()
            didChange = true
        }
        if didChange {
            openCodeProxyLog.info("Purged proxy residue for deleted OpenCode node \(nodeId, privacy: .public)")
        }
    }

    /// 代理进程的环境是否等价（决定 start 是否可以跳过重启）。
    private static func proxyParametersEqual(_ a: OpenCodeNode, _ b: OpenCodeNode) -> Bool {
        a.protocolType == b.protocolType
            && a.baseURL == b.baseURL
            && a.apiKey == b.apiKey
            && a.proxyPort == b.proxyPort
            && a.expectedClientKey == b.expectedClientKey
    }

    private func stopProcess(nodeId: String) {
        guard let instance = instances[nodeId] else { return }
        terminate(instance)
        runningNodeIds.remove(nodeId)
    }

    private func terminate(_ instance: Instance) {
        guard let process = instance.process else { return }
        instance.process = nil
        // 先解绑日志读取回调（进程结束后管道 EOF 会反复触发），再终止进程。
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
    }

    // MARK: - Launch

    private func launch(instance: Instance) async throws {
        let node = instance.node
        // 启动期间标记「启动中」，结束（成功/失败/抛错）即清除，抑制横幅闪现。
        startingNodeIds.insert(node.id)
        defer { startingNodeIds.remove(node.id) }
        // 清掉残留占用端口的旧代理进程（上次未正常退出时）。复用 Claude/Codex 的独立
        // actor，避免在 @MainActor 上同步 lsof.waitUntilExit()+usleep 阻塞 UI。
        // 调用前已确认没有别的受管实例占用该端口，不会误杀自己的子进程。
        do {
            try await ProxyProcessInspector.shared.killStaleProcesses(
                port: node.proxyPort,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        } catch {
            openCodeProxyLog.error("Failed to inspect stale processes on port \(node.proxyPort, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        if await ProxyProcessInspector.shared.isPortOccupied(node.proxyPort) {
            throw ProxyRuntimeError.proxyPortInUse(node.proxyPort)
        }

        var environment = ProcessInfo.processInfo.environment
        // 清掉继承环境里可能残留的选轨/认证变量，避免误启别的轨道或被
        // passthrough 当作客户端校验 Key（ANTHROPIC_API_KEY）拒掉 OpenCode 请求。
        for key in ["PROXY_TARGET", "PROXY_MODE", "OPENAI_API_MODE", "ANTHROPIC_API_KEY",
                    "CODEX_CLIENT_KEY", "OPENCODE_CLIENT_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL"] {
            environment.removeValue(forKey: key)
        }
        // 客户端访问本地代理时校验的 Key（留空 = 环回放行）。按协议落到各轨道对应的环境变量：
        // opencode→OPENCODE_CLIENT_KEY，codex→CODEX_CLIENT_KEY，passthrough→ANTHROPIC_API_KEY。
        let clientKey = node.expectedClientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch node.protocolType {
        case .openAICompatible:
            environment["PROXY_TARGET"] = "opencode"
            environment["OPENAI_BASE_URL"] = node.baseURL
            environment["OPENAI_API_KEY"] = node.apiKey
            if !clientKey.isEmpty { environment["OPENCODE_CLIENT_KEY"] = clientKey }
        case .openAIResponses:
            // Codex 轨道要求非空 Key（responses 上游均需认证）。
            environment["PROXY_TARGET"] = "codex"
            environment["OPENAI_API_MODE"] = "responses"
            environment["OPENAI_BASE_URL"] = node.baseURL
            environment["OPENAI_API_KEY"] = node.apiKey
            if !clientKey.isEmpty { environment["CODEX_CLIENT_KEY"] = clientKey }
        case .anthropic:
            // passthrough 轨道按「上游根 + /v1/messages」拼 URL，传入不含 /v1 的根地址。
            environment["PROXY_MODE"] = "passthrough"
            environment["ANTHROPIC_UPSTREAM_URL"] = node.baseURLWithoutV1Suffix
            environment["ANTHROPIC_UPSTREAM_KEY"] = node.apiKey
            if !clientKey.isEmpty { environment["ANTHROPIC_API_KEY"] = clientKey }
        }

        let nodeId = node.id
        let inboundPath = "/v1" + node.protocolType.requestPath
        guard let healthURL = URL(string: "http://127.0.0.1:\(node.proxyPort)/health") else {
            throw ProxyRuntimeError.proxyStartFailed("invalid health URL")
        }

        let launchResult: QuotaServerLaunchResult
        do {
            launchResult = try await QuotaServerLauncher.launch(
                arguments: ["--host", "127.0.0.1", "--port", "\(node.proxyPort)"],
                environment: environment,
                healthURL: healthURL,
                startupTimeout: Self.startupTimeout,
                probeIntervalNanos: Self.startupProbeIntervalNanos
            ) { [weak self] line in
                guard line.hasPrefix("PROXY_LOG:"),
                      let jsonStart = line.firstIndex(of: Character("{")) else { return }
                let jsonStr = String(line[jsonStart...])
                Task { @MainActor [weak self] in
                    self?.recordProxyLog(jsonStr, nodeId: nodeId, path: inboundPath)
                }
            }
        } catch QuotaServerStartupError.executableNotFound {
            throw ProxyRuntimeError.quotaServerNotFound
        } catch QuotaServerStartupError.portInUse(let occupiedPort, _) {
            throw ProxyRuntimeError.proxyPortInUse(occupiedPort)
        } catch {
            openCodeProxyLog.error("Failed to start OpenCode proxy for node \(node.displayName, privacy: .public): \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)")
            throw ProxyRuntimeError.proxyStartFailed(error.localizedDescription)
        }

        let process = launchResult.process
        guard instances[node.id] === instance else {
            await QuotaServerLauncher.terminateOwnedProcess(process)
            throw CancellationError()
        }
        instance.process = process
        runningNodeIds.insert(node.id)
        openCodeProxyLog.info("OpenCode proxy started for node \(node.displayName, privacy: .public) on 127.0.0.1:\(node.proxyPort, privacy: .public) pid=\(process.processIdentifier, privacy: .public)")

        process.terminationHandler = { [weak self] proc in
            Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeProxyRuntime")
                .notice("OpenCode proxy process exited code=\(proc.terminationStatus, privacy: .public)")
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
            // 自动重启耗尽：撤掉「启动中」标记，让横幅显式报错（不再抑制）。
            startingNodeIds.remove(nodeId)
            lastError = AppSettings.shared.t(
                "The local proxy for node \"\(instance.node.displayName)\" keeps exiting. Requests through it will fail until it is restarted.",
                "节点「\(instance.node.displayName)」的本地代理持续退出，经由它的请求将失败，请手动重启代理。"
            )
            openCodeProxyLog.error("OpenCode proxy restart attempts exhausted for node \(instance.node.displayName, privacy: .public)")
            return
        }

        let attempt = instance.restartAttempts
        // 整个重启周期（含退避等待）都视为「启动中」，抑制 backoff 间隙的横幅闪现。
        startingNodeIds.insert(nodeId)
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

    // MARK: - Global Unified Proxy Log Ingestion
    // 全局统一代理（常驻进程随激活节点轮转）的 PROXY_LOG 入口：与每节点路线 B 不同，
    // 这里 db 不参与计费（opencode.db 记在虚拟 provider `aiusage` 下、已被排除），
    // 故按激活节点定价就地算成本，并归因到日志携带的真实 node_id + 真实上游模型，
    // 与 Codex/Claude 全局代理同口径——日志、用量、价格、模型全部落到真实节点上。

    /// 摄入一条全局统一代理日志：按 node_id 归因到真实节点，按节点定价算成本，
    /// 写入请求日志（节点卡片成功率/最近请求）+ 永久每节点累计 + 永久按天×模型归档（热力图）。
    func ingestGlobalProxyLog(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "proxy_request_log",
              let nodeId = (json["node_id"] as? String)?.nilIfBlank else {
            return
        }

        let upstreamModel = json["upstream_model"] as? String ?? "unknown"
        let tokensInput = json["input_tokens"] as? Int ?? 0
        let tokensOutput = json["output_tokens"] as? Int ?? 0
        let splitRead = json["cache_read_tokens"] as? Int
        let splitCreate = json["cache_creation_tokens"] as? Int
        let legacyCache = json["cache_tokens"] as? Int
        let tokensCacheRead = splitRead ?? legacyCache ?? 0
        let tokensCacheCreation = splitCreate ?? 0

        let pricingInfo = openCodeNodePricing(nodeId: nodeId, model: upstreamModel)
        let pricing = pricingInfo?.pricing
        // 归档模型键与 opencode.db 直连/路线B 完全一致（`aiusage-<slug>/<model>`），让同节点同模型
        // 跨「全局代理」与「直连」两条路径在热力图/用量统计合并为一行；节点未知时退化为裸模型名。
        let archiveModel = pricingInfo.map { "\($0.managedProviderId)/\(upstreamModel)" } ?? upstreamModel
        let cost = pricing?.costForTokens(
            input: tokensInput,
            output: tokensOutput,
            cacheRead: tokensCacheRead,
            cacheCreate: tokensCacheCreation
        ) ?? 0

        let log = ProxyRequestLog(
            configId: nodeId,
            method: "POST",
            path: pricingInfo?.path ?? "/v1/chat/completions",
            claudeModel: json["claude_model"] as? String ?? "unknown",
            upstreamModel: upstreamModel,
            success: json["success"] as? Bool ?? false,
            responseTimeMs: Double(json["response_time_ms"] as? Int ?? 0),
            firstTokenMs: (json["first_token_ms"] as? Int).map(Double.init),
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            tokensCacheRead: tokensCacheRead,
            tokensCacheCreation: tokensCacheCreation,
            estimatedCostUSD: cost,
            pricingResolved: pricing != nil,
            errorMessage: json["error"] as? String,
            errorType: json["error_type"] as? String,
            statusCode: json["status_code"] as? Int,
            isGlobalProxy: true
        )

        requestLogs.insert(log, at: 0)
        if requestLogs.count > Self.maxLogEntries {
            requestLogs.removeLast(requestLogs.count - Self.maxLogEntries)
        }
        persistLogsSoon()

        var agg = globalNodeStats[nodeId] ?? OpenCodeGlobalNodeUsage()
        agg.add(log)
        globalNodeStats[nodeId] = agg
        persistGlobalStatsSoon()

        // 永久按天×真实模型归档（喂热力图/用量统计）。原始日志会被环形封顶裁剪，
        // 故按发生即增量累加（不可整日重算），跨重启不重复折叠。
        ProxyUsageArchiveStore.shared.accumulate(
            .opencode,
            dayKey: ProxyPersistence.dayKey(for: log.timestamp),
            model: archiveModel,
            log: log
        )
    }

    /// 按 node_id 找 OpenCodeNode，取匹配 upstreamModel 的模型条目单价构造 ModelPricing
    /// （与 Claude/Codex 同口径），并给出展示用请求路径与该节点的受管 provider 键（用于归档模型键对齐 db）。
    /// 节点不存在返回 nil；无定价返回 (nil, path, managedProviderId)。
    private func openCodeNodePricing(nodeId: String, model: String) -> (pricing: ProxyConfiguration.ModelPricing?, path: String, managedProviderId: String)? {
        guard let node = OpenCodeNodeStore.shared.nodes.first(where: { $0.id == nodeId }) else { return nil }
        let path = "/v1" + node.protocolType.requestPath
        guard node.pricingCurrency != .none,
              let entry = node.modelEntries.first(where: { $0.id == model }) ?? node.modelEntries.first,
              entry.hasPricing else {
            return (nil, path, node.managedProviderId)
        }
        let currency: ProxyConfiguration.PricingCurrency = node.pricingCurrency == .cny ? .cny : .usd
        let pricing = ProxyConfiguration.ModelPricing(
            inputPerMillion: entry.priceInputPerMillion,
            outputPerMillion: entry.priceOutputPerMillion,
            cacheCreatePerMillion: entry.priceCacheWritePerMillion,
            cacheReadPerMillion: entry.priceCacheReadPerMillion,
            currency: currency
        )
        return (pricing, path, node.managedProviderId)
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

    // MARK: - Global Per-Node Usage Persistence

    private func loadGlobalStats() {
        guard let data = FileManager.default.contents(atPath: Self.globalStatsFilePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let stats = try? decoder.decode([String: OpenCodeGlobalNodeUsage].self, from: data) {
            globalNodeStats = stats
        }
    }

    /// 防抖落盘（与日志同窗口）。永久累计，永不裁剪。
    private func persistGlobalStatsSoon() {
        pendingGlobalStatsSave?.cancel()
        pendingGlobalStatsSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.logsSaveDebounceNanos)
            guard !Task.isCancelled else { return }
            self?.persistGlobalStatsNow()
        }
    }

    private func persistGlobalStatsNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(globalNodeStats) else { return }
        let path = Self.globalStatsFilePath
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            openCodeProxyLog.warning("Failed to persist OpenCode global usage: \(String(describing: error), privacy: .public)")
        }
    }

}
