import SwiftUI
import Combine
import QuotaBackend

// MARK: - Claude Settings Manager

class ClaudeSettingsManager {
    static let shared = ClaudeSettingsManager()

    private var settingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".claude/settings.json")
    }

    func readSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private let managedEnvKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    struct EnvConfig {
        var baseURL: String?
        var authToken: String?
        var defaultModel: String?
        var opusModel: String?
        var sonnetModel: String?
        var haikuModel: String?
    }

    func writeEnv(_ config: EnvConfig) {
        var settings = readSettings()
        var env = settings["env"] as? [String: Any] ?? [:]

        let pairs: [(String, String?)] = [
            ("ANTHROPIC_BASE_URL", config.baseURL),
            ("ANTHROPIC_AUTH_TOKEN", config.authToken),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", config.opusModel),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", config.sonnetModel),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", config.haikuModel),
        ]
        for (key, value) in pairs {
            if let value = value {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }

        settings["env"] = env

        if let model = config.defaultModel, !model.isEmpty {
            settings["model"] = model
        } else {
            settings.removeValue(forKey: "model")
        }

        writeSettings(settings)
    }

    func clearEnv() {
        var settings = readSettings()
        var env = settings["env"] as? [String: Any] ?? [:]
        for key in managedEnvKeys {
            env.removeValue(forKey: key)
        }
        settings["env"] = env
        settings.removeValue(forKey: "model")
        writeSettings(settings)
    }

    private func writeSettings(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }

        let dir = (settingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: settingsPath))
    }
}

// MARK: - Proxy ViewModel

class ProxyViewModel: ObservableObject {
    @Published var configurations: [ProxyConfiguration] = []
    @Published var activatedConfigId: String?
    @Published var statistics: [String: ProxyStatistics] = [:]
    @Published var recentLogs: [String: [ProxyRequestLog]] = [:]

    private var runningProcesses: [String: Process] = [:]
    private let settingsManager = ClaudeSettingsManager.shared

    private let configurationsKey = "proxyConfigurations"
    private let activatedKey = "proxyActivatedConfigId"
    private let statisticsKey = "proxyStatistics"
    private let logsKey = "proxyLogs"

    private var logRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "proxyLogRetentionDays")
        return days > 0 ? days : 30
    }

    private var logsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-logs.json")
    }

    init() {
        loadConfigurations()
        loadStatistics()
        loadLogs()
        restoreActivatedNode()
    }

    private func restoreActivatedNode() {
        activatedConfigId = UserDefaults.standard.string(forKey: activatedKey)

        if activatedConfigId == nil {
            var migrated = false
            for i in configurations.indices where configurations[i].isEnabled {
                configurations[i].isEnabled = false
                migrated = true
            }
            if migrated { saveConfigurations() }
        }

        guard let id = activatedConfigId,
              let config = configurations.first(where: { $0.id == id }) else {
            settingsManager.clearEnv()
            return
        }

        print("⟳ Restoring node: \(config.name) (type=\(config.nodeType.rawValue))")

        if config.needsProxyProcess {
            startProxy(config)
        }
        settingsManager.writeEnv(envConfig(for: config))
        writePricingOverrides(config)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if let proc = self.runningProcesses[id] {
                print("  Proxy process isRunning=\(proc.isRunning) pid=\(proc.processIdentifier)")
            } else {
                print("  ⚠ No process found for restored node \(config.name)")
            }
        }
    }

    // MARK: - Configuration Management

    func loadConfigurations() {
        if let data = UserDefaults.standard.data(forKey: configurationsKey),
           let configs = try? JSONDecoder().decode([ProxyConfiguration].self, from: data) {
            configurations = configs
        }
    }

    func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: configurationsKey)
        }
    }

    private func saveActivatedId() {
        UserDefaults.standard.set(activatedConfigId, forKey: activatedKey)
    }

    func addConfiguration(_ config: ProxyConfiguration) {
        configurations.append(config)
        if config.nodeType == .openaiProxy {
            statistics[config.id] = .empty
            recentLogs[config.id] = []
        }
        saveConfigurations()
        saveStatistics()
        saveLogs()
    }

    func updateConfiguration(_ config: ProxyConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            let wasActivated = activatedConfigId == config.id
            if wasActivated {
                deactivateConfiguration(config.id)
            }
            configurations[index] = config
            saveConfigurations()
            if wasActivated {
                activateConfiguration(config.id)
            }
        }
    }

    func deleteConfiguration(_ id: String) {
        if activatedConfigId == id {
            deactivateConfiguration(id)
        }

        configurations.removeAll { $0.id == id }
        statistics.removeValue(forKey: id)
        recentLogs.removeValue(forKey: id)
        saveConfigurations()
        saveStatistics()
        saveLogs()
    }

    // MARK: - Activate / Deactivate

    private func envConfig(for config: ProxyConfiguration) -> ClaudeSettingsManager.EnvConfig {
        let m = config.modelMapping
        let dm = config.defaultModel.isEmpty ? nil : config.defaultModel
        let opus   = m.bigModel.name.isEmpty    ? nil : m.bigModel.name
        let sonnet = m.middleModel.name.isEmpty ? nil : m.middleModel.name
        let haiku  = m.smallModel.name.isEmpty  ? nil : m.smallModel.name

        switch config.nodeType {
        case .anthropicDirect:
            if config.usePassthroughProxy {
                let proxyURL = "http://\(config.host):\(config.port)"
                return .init(baseURL: proxyURL, authToken: config.anthropicAPIKey,
                             defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
            }
            return .init(baseURL: config.anthropicBaseURL, authToken: config.anthropicAPIKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        case .openaiProxy:
            let proxyKey = config.expectedClientKey.isEmpty ? "proxy-key" : config.expectedClientKey
            return .init(baseURL: config.displayURL, authToken: proxyKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        }
    }

    func activateConfiguration(_ id: String) {
        guard let config = configurations.first(where: { $0.id == id }) else { return }

        if let currentId = activatedConfigId, currentId != id {
            deactivateConfiguration(currentId)
        }

        if config.needsProxyProcess {
            startProxy(config)
        }
        settingsManager.writeEnv(envConfig(for: config))
        writePricingOverrides(config)

        activatedConfigId = id
        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = true
            configurations[index].lastUsedAt = Date()
        }
        saveConfigurations()
        saveActivatedId()
        print("✓ Node activated: \(config.name)")
    }

    func deactivateConfiguration(_ id: String) {
        guard let config = configurations.first(where: { $0.id == id }) else { return }

        if config.needsProxyProcess {
            stopProxy(config)
        }

        settingsManager.clearEnv()
        clearPricingOverrides()

        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = false
        }
        activatedConfigId = nil
        saveConfigurations()
        saveActivatedId()
        print("✓ Node deactivated: \(config.name)")
    }

    func toggleActivation(_ id: String) {
        if activatedConfigId == id {
            deactivateConfiguration(id)
        } else {
            activateConfiguration(id)
        }
    }

    // MARK: - Statistics Management

    func loadStatistics() {
        if let data = UserDefaults.standard.data(forKey: statisticsKey),
           let stats = try? JSONDecoder().decode([String: ProxyStatistics].self, from: data) {
            statistics = stats
        }
    }

    func saveStatistics() {
        if let data = try? JSONEncoder().encode(statistics) {
            UserDefaults.standard.set(data, forKey: statisticsKey)
        }
    }

    func recordRequest(_ log: ProxyRequestLog) {
        var stats = statistics[log.configId] ?? .empty
        stats.totalRequests += 1
        if log.success {
            stats.successfulRequests += 1
        } else {
            stats.failedRequests += 1
        }
        stats.totalTokensInput += log.tokensInput
        stats.totalTokensOutput += log.tokensOutput
        stats.totalTokensCache += log.tokensCache
        stats.estimatedCostUSD += log.estimatedCostUSD
        stats.lastRequestAt = log.timestamp

        let totalTime = stats.averageResponseTime * Double(stats.totalRequests - 1) + log.responseTimeMs
        stats.averageResponseTime = totalTime / Double(stats.totalRequests)

        stats.requestsByModel[log.upstreamModel, default: 0] += 1

        statistics[log.configId] = stats

        var logs = recentLogs[log.configId] ?? []
        logs.insert(log, at: 0)
        recentLogs[log.configId] = logs

        saveStatistics()
        saveLogs()
    }

    /// Fill in costs for logs that have estimatedCostUSD == 0 (pricing was missing at creation time).
    /// Logs with existing non-zero costs are preserved as-is.
    func recalculateCosts(for configId: String) {
        guard let config = configurations.first(where: { $0.id == configId }),
              let logs = recentLogs[configId] else { return }

        var changed = false
        var updatedLogs: [ProxyRequestLog] = []

        for log in logs {
            if log.estimatedCostUSD == 0, log.tokensInput + log.tokensOutput + log.tokensCache > 0 {
                let pricing = config.pricingForModel(log.upstreamModel)
                let cost = pricing?.costForTokens(input: log.tokensInput, output: log.tokensOutput, cache: log.tokensCache) ?? 0
                if cost > 0 {
                    changed = true
                    updatedLogs.append(ProxyRequestLog(
                        id: log.id, configId: log.configId, timestamp: log.timestamp,
                        method: log.method, path: log.path,
                        claudeModel: log.claudeModel, upstreamModel: log.upstreamModel,
                        success: log.success, responseTimeMs: log.responseTimeMs,
                        tokensInput: log.tokensInput, tokensOutput: log.tokensOutput,
                        tokensCache: log.tokensCache, estimatedCostUSD: cost,
                        errorMessage: log.errorMessage
                    ))
                    continue
                }
            }
            updatedLogs.append(log)
        }

        if changed {
            recentLogs[configId] = updatedLogs
            let totalCost = updatedLogs.reduce(0.0) { $0 + $1.estimatedCostUSD }
            if var stats = statistics[configId] {
                stats.estimatedCostUSD = totalCost
                statistics[configId] = stats
            }
            saveStatistics()
            saveLogs()
        }
    }

    // MARK: - Logs Management

    func loadLogs() {
        let url = URL(fileURLWithPath: logsFilePath)
        if let data = try? Data(contentsOf: url),
           let logs = try? JSONDecoder().decode([String: [ProxyRequestLog]].self, from: data) {
            recentLogs = logs
        } else if let data = UserDefaults.standard.data(forKey: logsKey),
                  let logs = try? JSONDecoder().decode([String: [ProxyRequestLog]].self, from: data) {
            recentLogs = logs
            UserDefaults.standard.removeObject(forKey: logsKey)
            saveLogs()
        }
        pruneOldLogs()
    }

    func saveLogs() {
        let url = URL(fileURLWithPath: logsFilePath)
        let dir = (logsFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(recentLogs) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func pruneOldLogs() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -logRetentionDays, to: Date()) ?? .distantPast
        var pruned = false
        for (configId, logs) in recentLogs {
            let filtered = logs.filter { $0.timestamp > cutoff }
            if filtered.count != logs.count {
                recentLogs[configId] = filtered
                pruned = true
            }
        }
        if pruned { saveLogs() }
    }

    func clearLogs(for configId: String) {
        recentLogs[configId] = []
        saveLogs()
    }

    func clearAllLogs() {
        recentLogs.removeAll()
        saveLogs()
    }

    // MARK: - Proxy Server Control

    private func startProxy(_ config: ProxyConfiguration) {
        guard config.needsProxyProcess else { return }
        if runningProcesses[config.id]?.isRunning == true {
            print("  Proxy already running for \(config.name)")
            return
        }

        killStaleProcess(port: config.port)

        var environment = ProcessInfo.processInfo.environment

        if config.nodeType == .anthropicDirect && config.usePassthroughProxy {
            environment["PROXY_MODE"] = "passthrough"
            environment["ANTHROPIC_UPSTREAM_URL"] = config.anthropicBaseURL
            environment["ANTHROPIC_UPSTREAM_KEY"] = config.anthropicAPIKey
            if !config.expectedClientKey.isEmpty {
                environment["ANTHROPIC_API_KEY"] = config.expectedClientKey
            }
        } else {
            environment["OPENAI_API_KEY"] = config.upstreamAPIKey
            environment["OPENAI_BASE_URL"] = config.upstreamBaseURL
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

        let quotaServerPath = findQuotaServerExecutable()

        guard let executablePath = quotaServerPath else {
            print("✗ QuotaServer executable not found")
            return
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
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[Proxy \(configName)] \(trimmed)")

            for line in trimmed.components(separatedBy: .newlines) {
                if line.hasPrefix("PROXY_LOG:"),
                   let jsonStart = line.firstIndex(of: Character("{")) {
                    let jsonStr = String(line[jsonStart...])
                    self?.parseProxyLog(jsonStr, configId: configId)
                }
            }
        }

        do {
            try process.run()
            runningProcesses[config.id] = process
            print("✓ Proxy started: \(config.name) on \(config.displayURL) (pid=\(process.processIdentifier))")

            process.terminationHandler = { [weak self] proc in
                print("⚠ Proxy process exited: \(config.name) code=\(proc.terminationStatus)")
                DispatchQueue.main.async {
                    self?.runningProcesses.removeValue(forKey: config.id)
                }
            }
        } catch {
            print("✗ Failed to start proxy: \(error.localizedDescription)")
        }
    }

    private func killStaleProcess(port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try? lsof.run()
        lsof.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for pidStr in output.components(separatedBy: .whitespacesAndNewlines) where !pidStr.isEmpty {
            if let pid = Int32(pidStr), pid != ProcessInfo.processInfo.processIdentifier {
                print("  Killing stale process on port \(port): pid=\(pid)")
                kill(pid, SIGTERM)
                usleep(200_000)
            }
        }
    }

    private func stopProxy(_ config: ProxyConfiguration) {
        guard let process = runningProcesses[config.id] else { return }
        process.terminate()
        runningProcesses.removeValue(forKey: config.id)
        print("✓ Proxy stopped: \(config.name)")
    }

    private static let sourceFileDir: String = {
        let filePath = #filePath
        return (filePath as NSString).deletingLastPathComponent
    }()

    private func findQuotaServerExecutable() -> String? {
        let fileManager = FileManager.default

        // Strategy 1: derive from #filePath (compile-time source location)
        let sourceProjectRoot = (Self.sourceFileDir as NSString)
            .deletingLastPathComponent
        let projectRootFromSource = (sourceProjectRoot as NSString)
            .deletingLastPathComponent

        // Strategy 2: derive from Bundle.main.bundleURL for Xcode DerivedData builds
        // e.g., .../DerivedData/.../Debug/AIUsage.app -> walk up to find workspace
        let bundlePath = Bundle.main.bundlePath

        let candidateRoots = [
            projectRootFromSource,
            bundlePath,
        ]

        let relativePaths = [
            "QuotaBackend/.build/debug/QuotaServer",
            "QuotaBackend/.build/release/QuotaServer",
        ]

        // Try each candidate root
        for root in candidateRoots {
            for relPath in relativePaths {
                let fullPath = (root as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    print("Found QuotaServer at: \(fullPath)")
                    return fullPath
                }
            }
        }

        // Strategy 3: walk up from source root looking for QuotaBackend
        var searchDir = projectRootFromSource
        for _ in 0..<5 {
            for relPath in relativePaths {
                let fullPath = (searchDir as NSString).appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: fullPath) {
                    print("Found QuotaServer at: \(fullPath)")
                    return fullPath
                }
            }
            searchDir = (searchDir as NSString).deletingLastPathComponent
        }

        // Fallback: try to build
        let quotaBackendDir = (projectRootFromSource as NSString).appendingPathComponent("QuotaBackend")
        guard fileManager.fileExists(atPath: (quotaBackendDir as NSString).appendingPathComponent("Package.swift")) else {
            print("✗ QuotaBackend package not found at: \(quotaBackendDir)")
            print("  #filePath resolved to: \(Self.sourceFileDir)")
            print("  Bundle.main.bundlePath: \(bundlePath)")
            return nil
        }

        print("QuotaServer not found, attempting to build...")
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["build", "--product", "QuotaServer"]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: quotaBackendDir)

        do {
            try buildProcess.run()
            buildProcess.waitUntilExit()

            if buildProcess.terminationStatus == 0 {
                for relPath in relativePaths {
                    let fullPath = (projectRootFromSource as NSString).appendingPathComponent(relPath)
                    if fileManager.fileExists(atPath: fullPath) {
                        print("Built and found QuotaServer at: \(fullPath)")
                        return fullPath
                    }
                }
            } else {
                print("Build failed with status: \(buildProcess.terminationStatus)")
            }
        } catch {
            print("Failed to build QuotaServer: \(error)")
        }

        return nil
    }

    // MARK: - Pricing Overrides

    private var pricingOverridePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-pricing.json")
    }

    private func writePricingOverrides(_ config: ProxyConfiguration) {
        let mapping = config.modelMapping
        var pricing: [String: [String: Double]] = [:]

        let models: [ProxyConfiguration.MappedModel] = [mapping.bigModel, mapping.middleModel, mapping.smallModel]
        for m in models where !m.name.isEmpty {
            pricing[m.name] = [
                "input_per_million": m.pricing.inputPerMillionUSD,
                "output_per_million": m.pricing.outputPerMillionUSD,
                "cache_per_million": m.pricing.cachePerMillionUSD,
            ]
        }

        let result: [String: Any] = ["pricing": pricing]

        let dir = (pricingOverridePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: pricingOverridePath))
        }
    }

    private func clearPricingOverrides() {
        try? FileManager.default.removeItem(atPath: pricingOverridePath)
    }

    func isProxyRunning(_ configId: String) -> Bool {
        return runningProcesses[configId]?.isRunning ?? false
    }

    // MARK: - Log Parsing

    private func parseProxyLog(_ jsonStr: String, configId: String) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "proxy_request_log" else { return }

        let upstreamModel = json["upstream_model"] as? String ?? "unknown"
        let tokensInput = json["input_tokens"] as? Int ?? 0
        let tokensOutput = json["output_tokens"] as? Int ?? 0
        let tokensCache = json["cache_tokens"] as? Int ?? 0

        let config = configurations.first { $0.id == configId }
        let pricing = config?.pricingForModel(upstreamModel)
        let estimatedCost = pricing?.costForTokens(input: tokensInput, output: tokensOutput, cache: tokensCache) ?? 0

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
            tokensCache: tokensCache,
            estimatedCostUSD: estimatedCost,
            errorMessage: json["error"] as? String
        )

        DispatchQueue.main.async { [weak self] in
            self?.recordRequest(log)
        }
    }

    // MARK: - Aggregation for ProxyStatsView

    func allLogs(nodeFilter: String?, modelFilter: String?) -> [ProxyRequestLog] {
        var result: [ProxyRequestLog] = []
        for (configId, logs) in recentLogs {
            if let node = nodeFilter, node != configId { continue }
            for log in logs {
                if let model = modelFilter, log.upstreamModel != model { continue }
                result.append(log)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    struct DailyAggregate: Identifiable {
        let id: String
        let date: Date
        let label: String
        var cost: Double
        var tokens: Int
        var requests: Int
    }

    func dailyAggregates(nodeFilter: String?, modelFilter: String?) -> [DailyAggregate] {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        let cal = Calendar.current
        var map: [String: DailyAggregate] = [:]
        for log in logs {
            let key = DateFormat.string(from: log.timestamp, format: "yyyy-MM-dd")
            let dayStart = cal.startOfDay(for: log.timestamp)
            var agg = map[key] ?? DailyAggregate(id: key, date: dayStart, label: key, cost: 0, tokens: 0, requests: 0)
            agg.cost += log.estimatedCostUSD
            agg.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            agg.requests += 1
            map[key] = agg
        }

        return map.values.sorted { $0.date < $1.date }
    }

    func hourlyAggregates(nodeFilter: String?, modelFilter: String?) -> [DailyAggregate] {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        let cal = Calendar.current
        var map: [String: DailyAggregate] = [:]
        for log in logs {
            let key = DateFormat.string(from: log.timestamp, format: "yyyy-MM-dd HH")
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: log.timestamp)
            let hourStart = cal.date(from: comps) ?? log.timestamp
            var agg = map[key] ?? DailyAggregate(id: key, date: hourStart, label: key, cost: 0, tokens: 0, requests: 0)
            agg.cost += log.estimatedCostUSD
            agg.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            agg.requests += 1
            map[key] = agg
        }

        return map.values.sorted { $0.date < $1.date }
    }

    struct ModelTimePoint: Identifiable {
        let id: String
        let date: Date
        let model: String
        var cost: Double
        var tokens: Int
    }

    func modelTimeSeries(nodeFilter: String?, granularity: String) -> [ModelTimePoint] {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: nil)
        guard !logs.isEmpty else { return [] }

        let cal = Calendar.current
        let format = granularity == "hourly" ? "yyyy-MM-dd HH" : "yyyy-MM-dd"

        var map: [String: ModelTimePoint] = [:]
        var allModels = Set<String>()
        var allDates = Set<String>()
        var dateMap: [String: Date] = [:]

        for log in logs {
            let timeKey = DateFormat.string(from: log.timestamp, format: format)
            let key = "\(timeKey)|\(log.upstreamModel)"
            let dateStart: Date
            if granularity == "hourly" {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: log.timestamp)
                dateStart = cal.date(from: comps) ?? log.timestamp
            } else {
                dateStart = cal.startOfDay(for: log.timestamp)
            }
            allModels.insert(log.upstreamModel)
            allDates.insert(timeKey)
            dateMap[timeKey] = dateStart

            var pt = map[key] ?? ModelTimePoint(id: key, date: dateStart, model: log.upstreamModel, cost: 0, tokens: 0)
            pt.cost += log.estimatedCostUSD
            pt.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            map[key] = pt
        }

        guard let minDate = logs.map(\.timestamp).min(),
              let maxDate = logs.map(\.timestamp).max() else { return map.values.sorted { $0.date < $1.date } }

        let step: Calendar.Component = granularity == "hourly" ? .hour : .day
        var cursor: Date
        let end: Date
        if granularity == "hourly" {
            cursor = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: minDate)) ?? minDate
            end = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: maxDate)) ?? maxDate
        } else {
            cursor = cal.startOfDay(for: minDate)
            end = cal.startOfDay(for: maxDate)
        }

        while cursor <= end {
            let timeKey = DateFormat.string(from: cursor, format: format)
            for model in allModels {
                let key = "\(timeKey)|\(model)"
                if map[key] == nil {
                    map[key] = ModelTimePoint(id: key, date: cursor, model: model, cost: 0, tokens: 0)
                }
            }
            guard let next = cal.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }

        return map.values.sorted { ($0.date, $0.model) < ($1.date, $1.model) }
    }

    struct ModelAggregate: Identifiable {
        let id: String
        let model: String
        var cost: Double
        var tokens: Int
        var requests: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheTokens: Int
    }

    func modelAggregates(nodeFilter: String?, modelFilter: String?) -> [ModelAggregate] {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        var map: [String: ModelAggregate] = [:]

        for log in logs {
            let key = log.upstreamModel
            var agg = map[key] ?? ModelAggregate(id: key, model: key, cost: 0, tokens: 0, requests: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0)
            agg.cost += log.estimatedCostUSD
            agg.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            agg.requests += 1
            agg.inputTokens += log.tokensInput
            agg.outputTokens += log.tokensOutput
            agg.cacheTokens += log.tokensCache
            map[key] = agg
        }

        return map.values.sorted { $0.cost > $1.cost }
    }

    func allUpstreamModels(nodeFilter: String?) -> [String] {
        var models = Set<String>()
        for (configId, logs) in recentLogs {
            if let node = nodeFilter, node != configId { continue }
            for log in logs { models.insert(log.upstreamModel) }
        }
        return models.sorted()
    }

    func overallStats(nodeFilter: String?, modelFilter: String?) -> (cost: Double, tokens: Int, requests: Int, successRate: Double) {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        let cost = logs.reduce(0.0) { $0 + $1.estimatedCostUSD }
        let tokens = logs.reduce(0) { $0 + $1.tokensInput + $1.tokensOutput + $1.tokensCache }
        let successCount = logs.filter(\.success).count
        let rate = logs.isEmpty ? 0 : Double(successCount) / Double(logs.count) * 100
        return (cost, tokens, logs.count, rate)
    }

    func dataDateRange(nodeFilter: String?, modelFilter: String?) -> (earliest: Date?, latest: Date?, days: Int) {
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter)
        guard let earliest = logs.last?.timestamp, let latest = logs.first?.timestamp else {
            return (nil, nil, 0)
        }
        let days = max(1, (Calendar.current.dateComponents([.day], from: earliest, to: latest).day ?? 0) + 1)
        return (earliest, latest, days)
    }
}
