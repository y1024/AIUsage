import SwiftUI
import Combine
import Foundation
import os.log
import QuotaBackend

// MARK: - Proxy ViewModel

internal let proxyPersistenceLog = Logger(subsystem: "com.aiusage.desktop", category: "ProxyPersistence")
internal let proxyRuntimeLog = Logger(subsystem: "com.aiusage.desktop", category: "ProxyRuntime")

enum ProxyRuntimeError: LocalizedError {
    case configurationNotFound
    case quotaServerNotFound
    case proxyStartFailed(String)
    case activationStatePersistFailed
    case deactivationStatePersistFailed
    case pricingOverridesWriteFailed
    case pricingOverridesClearFailed

    var errorDescription: String? {
        switch self {
        case .configurationNotFound:
            return AppSettings.shared.t("The selected node could not be found.", "找不到所选节点。")
        case .quotaServerNotFound:
            return AppSettings.shared.t(
                "QuotaServer helper not found. Rebuild or reinstall AIUsage, then try again.",
                "找不到 QuotaServer 辅助程序。请重新构建或重新安装 AIUsage 后再试。"
            )
        case .proxyStartFailed(let reason):
            return AppSettings.shared.t("Failed to start proxy: \(reason)", "启动代理失败：\(reason)")
        case .activationStatePersistFailed:
            return AppSettings.shared.t("The node started, but AIUsage could not persist the activated state.", "节点已启动，但 AIUsage 无法保存激活状态。")
        case .deactivationStatePersistFailed:
            return AppSettings.shared.t("The node stopped, but AIUsage could not persist the deactivated state.", "节点已停止，但 AIUsage 无法保存停用状态。")
        case .pricingOverridesWriteFailed:
            return AppSettings.shared.t("Failed to write proxy pricing overrides.", "写入代理计费覆盖失败。")
        case .pricingOverridesClearFailed:
            return AppSettings.shared.t("Failed to clear proxy pricing overrides.", "清理代理计费覆盖失败。")
        }
    }
}

@MainActor
class ProxyViewModel: ObservableObject {
    static let shared = ProxyViewModel()

    @Published var configurations: [ProxyConfiguration] = []
    @Published var activatedConfigId: String?
    @Published var proxyOnlyRunningIds: Set<String> = []
    // `statistics` and `recentLogs` are intentionally NOT @Published: writes happen on every
    // proxied request (potentially many per second during streaming) and each publish would
    // force every observing view to rebuild body + re-aggregate on the main thread. Instead,
    // mutations feed `logsChangeSubject`, which throttles UI notifications to `logsPublishInterval`
    // via `objectWillChange.send()`. Persistence is debounced via `schedulePersistence()` to
    // avoid redundant full-JSON encodes on every request; critical exit points flush immediately.
    var statistics: [String: ProxyStatistics] = [:]
    var recentLogs: [String: [ProxyRequestLog]] = [:]
    @Published var operationErrorMessage: String?
    @Published var operationInProgressConfigIds: Set<String> = []

    struct LogCacheKey: Hashable {
        let nodeFilter: String?
        let modelFilter: String?
    }

    var _logCache: [LogCacheKey: [ProxyRequestLog]] = [:]

    // Cache dictionaries for derived aggregations. All are cleared together with `_logCache`
    // whenever the throttled log refresh fires.
    struct TimeSeriesKey: Hashable {
        let nodeFilter: String?
        let granularity: String
    }
    struct AggregateKey: Hashable {
        let nodeFilter: String?
        let modelFilter: String?
        let since: Date?
    }
    var _timeSeriesCache: [TimeSeriesKey: Any] = [:]
    var _modelAggCache: [AggregateKey: Any] = [:]
    var _overallStatsCache: [AggregateKey: Any] = [:]
    var _dateRangeCache: [LogCacheKey: (earliest: Date?, latest: Date?, days: Int)] = [:]
    var _upstreamModelsCache: [String: [String]] = [:]

    let logsChangeSubject = PassthroughSubject<Void, Never>()
    var logsChangeCancellable: AnyCancellable?
    /// Set by `scheduleLogsRefresh`, cleared by both the throttle sink and `flushLogsRefresh`.
    /// Prevents a stale throttle event from triggering a redundant `objectWillChange` after
    /// a synchronous flush already refreshed the UI.
    private var logsDirty = false
    /// Throttle window for coalescing log-driven UI refreshes. Individual log writes still hit
    /// storage immediately; only the SwiftUI invalidation is batched.
    static let logsPublishInterval: TimeInterval = 0.5

    var persistenceWorkItem: DispatchWorkItem?
    static let persistenceDebounceInterval: TimeInterval = 2.0

    let runtimeService: ProxyRuntimeService

    var logRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: DefaultsKey.proxyLogRetentionDays)
        return days > 0 ? days : 30
    }

    var logsFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/proxy-logs.json")
    }

    init() {
        runtimeService = ProxyRuntimeService()
        runtimeService.delegate = self
        logsChangeCancellable = logsChangeSubject
            .throttle(for: .seconds(Self.logsPublishInterval), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.logsDirty else { return }
                self.logsDirty = false
                self.objectWillChange.send()
            }
        loadConfigurations()
        loadStatistics()
        loadLogs()
        restoreActivatedNode()
    }

    /// Marks that logs/statistics have changed. Caches are invalidated immediately so that
    /// any SwiftUI re-evaluation (even triggered by other @Published fields) reads fresh data.
    /// The actual `objectWillChange` notification is coalesced by the throttle in `init`;
    /// callers that need the UI to update synchronously (e.g. user-initiated delete/clear)
    /// should additionally call `flushLogsRefresh()`.
    func scheduleLogsRefresh() {
        invalidateLogCaches()
        logsDirty = true
        logsChangeSubject.send(())
    }

    /// Forces any pending throttled refresh to fire immediately. Used by user-initiated
    /// operations (add/delete node, clear logs) where we don't want up-to-0.5s staleness.
    func flushLogsRefresh() {
        logsDirty = false
        invalidateLogCaches()
        objectWillChange.send()
    }

    func invalidateLogCaches() {
        _logCache.removeAll()
        _timeSeriesCache.removeAll()
        _modelAggCache.removeAll()
        _overallStatsCache.removeAll()
        _dateRangeCache.removeAll()
        _upstreamModelsCache.removeAll()
    }

    // MARK: - Profile Store Bridge

    /// Reference to the file-based profile store (injected or shared singleton).
    var profileStore: NodeProfileStore { NodeProfileStore.shared }

    // MARK: - Configuration Management

    func loadConfigurations() {
        configurations = profileStore.profiles.map { $0.metadata.proxy.toProxyConfiguration(metadata: $0.metadata) }
    }

    @discardableResult
    func saveConfigurations() -> Bool {
        return true
    }

    /// Persist a single profile to its JSON file via the store.
    @discardableResult
    func saveProfile(_ profile: NodeProfile) -> Bool {
        profileStore.save(profile)
    }

    func saveActivatedId() {
        if let id = activatedConfigId {
            UserDefaults.standard.set(id, forKey: DefaultsKey.proxyActivatedConfigId)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.proxyActivatedConfigId)
        }
        profileStore.activatedProfileId = activatedConfigId
        profileStore.saveActivatedId()
    }

    func moveConfiguration(fromId: String, toIndex: Int) {
        guard let fromIndex = configurations.firstIndex(where: { $0.id == fromId }) else { return }
        let clampedTarget = min(max(toIndex, 0), configurations.count)
        guard fromIndex != clampedTarget, fromIndex != clampedTarget - 1 else { return }
        let item = configurations.remove(at: fromIndex)
        let insertAt = clampedTarget > fromIndex ? clampedTarget - 1 : clampedTarget
        configurations.insert(item, at: insertAt)
        profileStore.move(fromId: fromId, toIndex: toIndex)
    }

    func addConfiguration(_ config: ProxyConfiguration) {
        let profile = NodeProfile.fromLegacyConfiguration(config)
        profileStore.save(profile)
        configurations.append(config)
        if config.nodeType == .openaiProxy {
            statistics[config.id] = .empty
            recentLogs[config.id] = []
        }
        saveStatistics()
        saveLogs()
        flushLogsRefresh()
    }

    func addProfile(_ profile: NodeProfile) {
        profileStore.save(profile)
        let config = profile.metadata.proxy.toProxyConfiguration(metadata: profile.metadata)
        configurations.append(config)
        if profile.metadata.nodeType == .openaiProxy {
            statistics[profile.id] = .empty
            recentLogs[profile.id] = []
        }
        saveStatistics()
        saveLogs()
        flushLogsRefresh()
    }

    func updateProfile(_ profile: NodeProfile) async {
        let config = profile.metadata.proxy.toProxyConfiguration(metadata: profile.metadata)
        profileStore.save(profile)

        if let index = configurations.firstIndex(where: { $0.id == profile.id }) {
            let wasActivated = activatedConfigId == profile.id
            let wasProxyOnly = proxyOnlyRunningIds.contains(profile.id)
            let busyIds: Set<String> = [profile.id]
            setOperationInProgress(busyIds, isActive: true)
            defer { setOperationInProgress(busyIds, isActive: false) }
            if wasActivated {
                do {
                    try await performDeactivationTransaction(profile.id)
                } catch {
                    reportOperationError(error)
                    return
                }
            } else if wasProxyOnly {
                runtimeService.stopProxyOnly(for: configurations[index])
                proxyOnlyRunningIds.remove(profile.id)
            }
            configurations[index] = config
            if wasActivated {
                do {
                    try await performActivationTransaction(profile.id)
                } catch {
                    reportOperationError(error)
                }
            } else if wasProxyOnly {
                do {
                    try await runtimeService.startProxyOnly(for: config)
                    proxyOnlyRunningIds.insert(profile.id)
                } catch {
                    proxyRuntimeLog.error("Failed to restart proxy-only after profile update for \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                saveProxyOnlyIds()
            }
        }
    }

    func updateConfiguration(_ config: ProxyConfiguration) async {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            let wasActivated = activatedConfigId == config.id
            let wasProxyOnly = proxyOnlyRunningIds.contains(config.id)
            let busyIds: Set<String> = [config.id]
            setOperationInProgress(busyIds, isActive: true)
            defer { setOperationInProgress(busyIds, isActive: false) }
            if wasActivated {
                do {
                    try await performDeactivationTransaction(config.id)
                } catch {
                    reportOperationError(error)
                    return
                }
            } else if wasProxyOnly {
                runtimeService.stopProxyOnly(for: configurations[index])
                proxyOnlyRunningIds.remove(config.id)
            }
            configurations[index] = config
            let profile = NodeProfile.fromLegacyConfiguration(config)
            profileStore.save(profile)
            if wasActivated {
                do {
                    try await performActivationTransaction(config.id)
                } catch {
                    reportOperationError(error)
                }
            } else if wasProxyOnly {
                do {
                    try await runtimeService.startProxyOnly(for: config)
                    proxyOnlyRunningIds.insert(config.id)
                } catch {
                    proxyRuntimeLog.error("Failed to restart proxy-only after config update for \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                saveProxyOnlyIds()
            }
        }
    }

    func deleteConfiguration(_ id: String) async {
        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }

        if activatedConfigId == id {
            do {
                try await performDeactivationTransaction(id)
            } catch {
                reportOperationError(error)
                return
            }
        }

        if proxyOnlyRunningIds.contains(id),
           let config = configurations.first(where: { $0.id == id }) {
            runtimeService.stopProxyOnly(for: config)
            proxyOnlyRunningIds.remove(id)
            saveProxyOnlyIds()
        }

        configurations.removeAll { $0.id == id }
        statistics.removeValue(forKey: id)
        recentLogs.removeValue(forKey: id)
        profileStore.delete(id)
        saveStatistics()
        saveLogs()
        flushLogsRefresh()
    }

    // MARK: - Activate / Deactivate

    func envConfig(for config: ProxyConfiguration) -> ClaudeSettingsManager.EnvConfig {
        let m = config.modelMapping
        let dm = config.defaultModel.isEmpty ? nil : config.defaultModel
        let opus   = m.bigModel.name.isEmpty    ? nil : m.bigModel.name
        let sonnet = m.middleModel.name.isEmpty ? nil : m.middleModel.name
        let haiku  = m.smallModel.name.isEmpty  ? nil : m.smallModel.name

        let certPath: String? = config.enableHTTPS ? TLSCertificateManager.shared.certFilePath : nil

        switch config.nodeType {
        case .anthropicDirect:
            if config.usePassthroughProxy {
                let proxyURL: String
                if config.enableHTTPS {
                    proxyURL = "https://\(config.host):\(config.effectiveHTTPSPort)"
                } else {
                    proxyURL = "http://\(config.host):\(config.port)"
                }
                return .init(baseURL: proxyURL, authToken: config.anthropicAPIKey,
                             defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku,
                             nodeExtraCACerts: certPath)
            }
            return .init(baseURL: config.anthropicBaseURL, authToken: config.anthropicAPIKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku)
        case .openaiProxy:
            let proxyKey = config.expectedClientKey.isEmpty ? "proxy-key" : config.expectedClientKey
            let baseURL: String
            if config.enableHTTPS {
                baseURL = "https://\(config.host):\(config.effectiveHTTPSPort)"
            } else {
                baseURL = config.displayURL
            }
            return .init(baseURL: baseURL, authToken: proxyKey,
                         defaultModel: dm, opusModel: opus, sonnetModel: sonnet, haikuModel: haiku,
                         nodeExtraCACerts: certPath)
        }
    }

    func activateConfiguration(_ id: String) async {
        let busyIds = Set([id, activatedConfigId].compactMap { $0 })
        guard !busyIds.contains(where: { operationInProgressConfigIds.contains($0) }) else { return }

        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        operationErrorMessage = nil

        do {
            try await performActivationTransaction(id)
        } catch {
            reportOperationError(error)
        }
    }

    func deactivateConfiguration(_ id: String) async {
        guard !operationInProgressConfigIds.contains(id) else { return }

        let busyIds: Set<String> = [id]
        setOperationInProgress(busyIds, isActive: true)
        defer { setOperationInProgress(busyIds, isActive: false) }
        operationErrorMessage = nil

        do {
            try await performDeactivationTransaction(id)
        } catch {
            reportOperationError(error)
        }
    }

    func toggleActivation(_ id: String) async {
        if activatedConfigId == id {
            await deactivateConfiguration(id)
        } else {
            await activateConfiguration(id)
        }
    }

    func performActivationTransaction(_ id: String) async throws {
        guard let config = configurations.first(where: { $0.id == id }) else {
            throw ProxyRuntimeError.configurationNotFound
        }

        if activatedConfigId == id {
            return
        }

        let wasProxyOnly = proxyOnlyRunningIds.contains(id)

        let previousActiveConfig = activatedConfigId.flatMap { currentId in
            configurations.first(where: { $0.id == currentId })
        }

        if let previousActiveConfig {
            try await deactivateRuntime(for: previousActiveConfig)
        }

        do {
            try await activateRuntime(for: config)
            proxyOnlyRunningIds.remove(id)
            saveProxyOnlyIds()
            do {
                try persistActivationSelection(config.id, touchLastUsedAt: true)
            } catch {
                do {
                    try await deactivateRuntime(for: config)
                } catch {
                    proxyRuntimeLog.error("Failed to roll back runtime for newly activated node \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                if wasProxyOnly {
                    proxyOnlyRunningIds.insert(id)
                    saveProxyOnlyIds()
                }
                if let previousActiveConfig {
                    do {
                        try await activateRuntime(for: previousActiveConfig)
                    } catch {
                        proxyRuntimeLog.error("Failed to restore previous node \(previousActiveConfig.name, privacy: .public) after persistence failure: \(String(describing: error), privacy: .public)")
                    }
                }
                throw error
            }
        } catch {
            if wasProxyOnly {
                proxyOnlyRunningIds.insert(id)
                saveProxyOnlyIds()
            }
            if let previousActiveConfig {
                do {
                    try await activateRuntime(for: previousActiveConfig)
                } catch {
                    proxyRuntimeLog.error("Failed to restore previous node \(previousActiveConfig.name, privacy: .public) after activation failure: \(String(describing: error), privacy: .public)")
                }
            }
            throw error
        }

        proxyRuntimeLog.info("Node activated: \(config.name, privacy: .public)")
    }

    func performDeactivationTransaction(_ id: String) async throws {
        guard activatedConfigId == id,
              let config = configurations.first(where: { $0.id == id }) else {
            return
        }

        try await deactivateRuntime(for: config)

        do {
            try persistActivationSelection(nil, touchLastUsedAt: false)
        } catch {
            do {
                try await activateRuntime(for: config)
            } catch {
                proxyRuntimeLog.error("Failed to restore node \(config.name, privacy: .public) after deactivation persistence failure: \(String(describing: error), privacy: .public)")
            }
            throw error
        }

        proxyRuntimeLog.info("Node deactivated: \(config.name, privacy: .public)")
    }

    func persistActivationSelection(_ activeId: String?, touchLastUsedAt: Bool) throws {
        let previousConfigurations = configurations
        let previousActivatedConfigId = activatedConfigId
        let now = touchLastUsedAt ? Date() : nil

        activatedConfigId = activeId
        for index in configurations.indices {
            let isActive = configurations[index].id == activeId
            configurations[index].isEnabled = isActive
            if isActive, let now {
                configurations[index].lastUsedAt = now
            }
        }

        if let activeId, touchLastUsedAt, let now,
           var profile = profileStore.profile(for: activeId) {
            profile.metadata.lastUsedAt = now
            profileStore.save(profile)
        }

        saveActivatedId()
    }

    func setOperationInProgress(_ ids: Set<String>, isActive: Bool) {
        if isActive {
            operationInProgressConfigIds.formUnion(ids)
        } else {
            operationInProgressConfigIds.subtract(ids)
        }
    }

    func isOperationInProgress(_ configId: String) -> Bool {
        operationInProgressConfigIds.contains(configId)
    }

    func reportOperationError(_ error: Error) {
        let redactedMessage = SensitiveDataRedactor.redactedMessage(for: error)
        operationErrorMessage = redactedMessage
        proxyRuntimeLog.error("Proxy operation failed: \(redactedMessage, privacy: .public)")
    }

    func logPersistenceError(_ action: String, error: Error) {
        proxyPersistenceLog.error("Failed to \(action, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}
