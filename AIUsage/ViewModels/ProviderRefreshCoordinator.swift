import Foundation
import Combine
import os.log
import QuotaBackend

internal let providerRefreshLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderRefresh")

// MARK: - ProviderRefreshCoordinator
// Owns provider snapshot refresh, dashboard fetch, localization of fetched data, and account-registry reconciliation.

final class ProviderRefreshCoordinator: ObservableObject {
    static let shared = ProviderRefreshCoordinator()

    @Published var providers: [ProviderData] = []
    @Published var overview: DashboardOverview?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var lastRefreshTime: Date?
    @Published var isRefreshingAllProviders = false
    @Published private(set) var refreshingProviderIDs: Set<String> = []
    @Published private(set) var refreshingAccountIDs: Set<String> = []
    @Published var providerRefreshTimes: [String: Date] = [:]
    @Published var accountRefreshTimes: [String: Date] = [:]

    let engine = ProviderEngine()
    private var refreshTimer: Timer?
    private var claudeCodeRefreshTimer: Timer?

    var isAnyRefreshInProgress: Bool {
        isLoading
            || isRefreshingAllProviders
            || !refreshingProviderIDs.isEmpty
            || !refreshingAccountIDs.isEmpty
    }

    let settings = AppSettings.shared
    let accountStore = AccountStore.shared

    var discoveryFailureBackoff: [String: Date] = [:]
    let discoveryFailureCooldown: TimeInterval = 5 * 60

    var selectedProviderIds: () -> Set<String> = { [] }
    var providerCatalogIds: () -> [String] = { [] }
    var ensureProviderSelected: (String) -> Void = { _ in }
    var providerTitleForId: (String) -> String = { $0 }

    private init() {
        setupAutoRefresh()
        setupClaudeCodeAutoRefresh()
    }

    func configure(
        selectedProviderIds: @escaping () -> Set<String>,
        providerCatalogIds: @escaping () -> [String],
        ensureProviderSelected: @escaping (String) -> Void,
        providerTitleForId: @escaping (String) -> String
    ) {
        self.selectedProviderIds = selectedProviderIds
        self.providerCatalogIds = providerCatalogIds
        self.ensureProviderSelected = ensureProviderSelected
        self.providerTitleForId = providerTitleForId
    }

    // MARK: - Timers

    func setupAutoRefresh() {
        refreshTimer?.invalidate()
        let normalized = AppSettings.normalizedAutoRefreshInterval(settings.autoRefreshInterval)
        if settings.autoRefreshInterval != normalized {
            settings.autoRefreshInterval = normalized
        }

        if settings.autoRefreshInterval > 0 {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.autoRefreshInterval), repeats: true) { [weak self] _ in
                self?.refreshAllProviders()
            }
        }
    }

    func setupClaudeCodeAutoRefresh() {
        claudeCodeRefreshTimer?.invalidate()
        let normalized = AppSettings.normalizedClaudeCodeRefreshInterval(settings.claudeCodeRefreshInterval)
        if settings.claudeCodeRefreshInterval != normalized {
            settings.claudeCodeRefreshInterval = normalized
        }

        if settings.claudeCodeRefreshInterval > 0 {
            claudeCodeRefreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.claudeCodeRefreshInterval), repeats: true) { [weak self] _ in
                self?.refreshLocalTokenStatsOnly()
            }
        }
    }

    // MARK: - Public refresh API

    func refreshAllProviders() {
        Task { @MainActor in
            guard !isRefreshingAllProviders else { return }
            isRefreshingAllProviders = true
            defer { isRefreshingAllProviders = false }
            _ = await fetchDashboard()
        }
    }

    func refreshLocalTokenStatsOnly() {
        Task { @MainActor in
            for providerId in ["claude", "codex-cost"] where selectedProviderIds().contains(providerId) {
                await refreshProviderNow(providerId)
            }
            checkClaudeCodeDailyThreshold()
        }
    }

    func refreshCodexCostFullHistoryIfNeeded() {
        Task { @MainActor in
            let providerId = "codex-cost"
            let provider = ProviderRegistry.provider(for: providerId) as? CodexCostProvider
            guard settings.backendMode == "local",
                  selectedProviderIds().contains(providerId),
                  !refreshingProviderIDs.contains(providerId),
                  let provider,
                  await provider.needsFullHistoryImport() else {
                return
            }
            await provider.requestFullHistoryImport()
            await refreshProviderNow(providerId)
        }
    }

    func refreshProvider(_ providerId: String) {
        Task { @MainActor in
            await refreshProviderNow(providerId)
        }
    }

    func refreshProviderCard(_ provider: ProviderData) {
        Task {
            await refreshProviderCardNow(provider)
        }
    }

    @MainActor
    func refreshProviderCardNow(_ provider: ProviderData) async {
        if let credentialId = credentialID(for: provider) {
            await refreshAccountNow(credentialId: credentialId, providerId: provider.baseProviderId)
        } else {
            await refreshProviderNow(provider.baseProviderId)
        }
    }

    func refreshAccount(credentialId: String, providerId: String) {
        Task {
            await refreshAccountNow(credentialId: credentialId, providerId: providerId)
        }
    }

    @MainActor
    func refreshProviderNow(_ providerId: String) async {
        guard selectedProviderIds().contains(providerId),
              !refreshingProviderIDs.contains(providerId) else { return }
        refreshingProviderIDs.insert(providerId)
        defer { refreshingProviderIDs.remove(providerId) }
        errorMessage = nil
        let result = await fetchSingleProvider(providerId)
        completeProviderRefresh(providerId: providerId, result: result)
        errorMessage = result.userMessage
    }

    @MainActor
    func refreshAccountNow(credentialId: String, providerId: String) async {
        guard selectedProviderIds().contains(providerId) else { return }
        let refreshKey = accountRefreshKey(providerId: providerId, credentialId: credentialId)
        guard !refreshingAccountIDs.contains(refreshKey) else { return }
        refreshingAccountIDs.insert(refreshKey)
        defer { refreshingAccountIDs.remove(refreshKey) }
        errorMessage = nil
        let result = await fetchAccountByCredential(
            credentialId: credentialId,
            providerId: providerId
        )
        completeAccountRefresh(refreshKey: refreshKey, result: result)
        errorMessage = result.userMessage
    }

    @MainActor
    func fetchSingleProvider(_ providerId: String) async -> ProviderRefreshResult {
        guard selectedProviderIds().contains(providerId) else {
            return .failure()
        }
        if settings.backendMode == "local" {
            return await fetchSingleProviderLocal(providerId)
        } else {
            return await fetchSingleProviderRemote(providerId)
        }
    }

    @MainActor
    @discardableResult
    func fetchDashboard() async -> ProviderRefreshResult {
        let isInitialLoad = providers.isEmpty && overview == nil
        if isInitialLoad { isLoading = true }
        errorMessage = nil

        guard !selectedProviderIds().isEmpty else {
            providers = []
            overview = localizeOverview(convertOverview(UsageNormalizer.createDashboardOverview(
                summaries: [],
                generatedAt: SharedFormatters.iso8601String(from: Date())
            )))
            isLoading = false
            return .emptySuccess()
        }

        let result: ProviderRefreshResult
        if settings.backendMode == "local" {
            result = await fetchDashboardLocal()
        } else {
            result = await fetchDashboardRemote(showMessageOnFailure: providers.isEmpty)
        }

        completeGlobalRefresh(result)
        errorMessage = result.userMessage
        isLoading = false
        return result
    }

    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String?,
        providerDisplayTitle: String
    ) throws {
        try accountStore.registerAuthenticatedCredential(
            credential,
            usage: usage,
            note: note,
            providerDisplayTitle: providerDisplayTitle,
            insertImmediateProviderData: { [weak self] providerId, credentialId, accountLabel, usage in
                self?.insertImmediateProviderData(
                    providerId: providerId,
                    credentialId: credentialId,
                    accountLabel: accountLabel,
                    usage: usage
                )
            },
            ensureProviderSelected: ensureProviderSelected
        )
    }

    func insertImmediateProviderData(
        providerId: String,
        credentialId: String,
        accountLabel: String?,
        usage: ProviderUsage
    ) {
        guard let providerFetcher = ProviderRegistry.provider(for: providerId) else { return }

        var summary = UsageNormalizer.normalize(provider: providerFetcher, usage: usage)
        summary.id = "\(providerId):cred:\(credentialId)"
        summary.providerId = providerId
        summary.accountId = usage.usageAccountId
        if summary.accountLabel?.nilIfBlank == nil {
            summary.accountLabel = accountLabel
        }

        let providerData = localizeProviderData(convertSummary(summary))

        if let index = providers.firstIndex(where: { $0.id == providerData.id }) {
            providers[index] = providerData
        } else {
            providers.append(providerData)
            providers = providers.sorted(by: providerSort)
        }
    }

    func removeProviders(matchingBaseProviderIds removed: Set<String>) {
        providers.removeAll { removed.contains($0.baseProviderId) }
    }

    func removeProviders(matchingBaseProviderId providerId: String) {
        providers.removeAll { $0.baseProviderId == providerId }
    }

    func reapplyVisibleSortedProviders() {
        providers = visibleProviders(from: providers).sorted(by: providerSort)
    }

    func buildProviderEntries(
        providerId: String,
        providerTitle: String,
        providerSubtitle: String?,
        liveProviders: [ProviderData],
        storedAccounts: [StoredProviderAccount]
    ) -> [ProviderAccountEntry] {
        var remainingLive = liveProviders
        var entries: [ProviderAccountEntry] = []

        for stored in storedAccounts {
            let matches = remainingLive.filter { accountStore.matchesStoredWithLive(stored, provider: $0) }

            if let preferredLive = preferredLiveProvider(among: matches, storedAccount: stored) {
                let consumedIDs = Set(matches.map(\.id))
                remainingLive.removeAll { consumedIDs.contains($0.id) }
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: preferredLive,
                        storedAccount: stored
                    )
                )
            } else {
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: nil,
                        storedAccount: stored
                    )
                )
            }
        }

        let unmatchedLive = Dictionary(grouping: remainingLive, by: liveProviderIdentity(_:))
            .values
            .compactMap { preferredLiveProvider(among: Array($0), storedAccount: nil) }

        for live in unmatchedLive {
            entries.append(
                ProviderAccountEntry(
                    id: live.id,
                    providerId: providerId,
                    providerTitle: providerTitle,
                    providerSubtitle: providerSubtitle,
                    liveProvider: live,
                    storedAccount: nil
                )
            )
        }

        return entries
    }

    func providerRefreshDate(for providerId: String) -> Date? {
        if let refreshedAt = providerRefreshTimes[providerId] {
            return refreshedAt
        }

        return providers
            .filter { $0.baseProviderId == providerId }
            .compactMap { accountRefreshDate(for: $0) }
            .max()
    }

    func accountRefreshDate(for provider: ProviderData) -> Date? {
        for key in accountRefreshKeys(for: provider) {
            if let refreshedAt = accountRefreshTimes[key] {
                return refreshedAt
            }
        }

        guard let fetchedAt = provider.fetchedAt else { return nil }
        return parseISO8601(fetchedAt)
    }

    func isProviderRefreshInFlight(_ providerId: String) -> Bool {
        isRefreshingAllProviders || refreshingProviderIDs.contains(providerId)
    }

    func isRefreshInProgress(for provider: ProviderData) -> Bool {
        if isRefreshingAllProviders || refreshingProviderIDs.contains(provider.baseProviderId) {
            return true
        }

        return accountRefreshKeys(for: provider).contains { refreshingAccountIDs.contains($0) }
    }
}
