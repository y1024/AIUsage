import SwiftUI
import Combine
import QuotaBackend

// 全局应用状态
class AppState: ObservableObject {
    static let shared = AppState()
    let settings = AppSettings.shared
    let refreshCoordinator = ProviderRefreshCoordinator.shared

    private static let selectedProvidersKey = "selectedProviderIds"
    private struct InitialState {
        let accounts: [StoredProviderAccount]
        let selectedProviderIds: Set<String>
    }

    private static let providerCatalogItems: [ProviderCatalogItem] = [
        ProviderCatalogItem(id: "codex", titleEn: "Codex", titleZh: "Codex", summaryEn: "Official OpenAI subscription windows and quotas", summaryZh: "OpenAI 官方订阅窗口与配额", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "copilot", titleEn: "Copilot", titleZh: "Copilot", summaryEn: "GitHub Copilot account entitlements and premium lanes", summaryZh: "GitHub Copilot 账号权益与高级通道", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "cursor", titleEn: "Cursor", titleZh: "Cursor", summaryEn: "Cursor membership allowances and plan usage", summaryZh: "Cursor 会员额度与计划用量", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "antigravity", titleEn: "Antigravity", titleZh: "Antigravity", summaryEn: "Per-model IDE subscription quotas across many model families", summaryZh: "按模型拆分的 IDE 订阅配额", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "kiro", titleEn: "Kiro", titleZh: "Kiro", summaryEn: "Kiro IDE request lanes from the live app account", summaryZh: "来自 Kiro 应用账号的实时请求通道", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "warp", titleEn: "Warp", titleZh: "Warp", summaryEn: "Warp request reserves and desktop app credits", summaryZh: "Warp 请求余额与桌面应用额度", channel: "ide", kind: .official),
        ProviderCatalogItem(id: "gemini", titleEn: "Gemini CLI", titleZh: "Gemini CLI", summaryEn: "Gemini CLI project quotas and model-family windows", summaryZh: "Gemini CLI 项目配额与模型族窗口", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "amp", titleEn: "Amp", titleZh: "Amp", summaryEn: "Replenishing credit pool and refill cadence", summaryZh: "会回补的额度池与回补节奏", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "droid", titleEn: "Droid", titleZh: "Droid", summaryEn: "Token-heavy usage pools and remaining allowances", summaryZh: "以 token 为主的额度池与剩余额度", channel: "cli", kind: .official),
        ProviderCatalogItem(id: "claude", titleEn: "Claude Code Spend", titleZh: "Claude Code 费用", summaryEn: "Local log-based spend ledger from Claude Code usage", summaryZh: "基于 Claude Code 本地日志的费用账本", channel: "local", kind: .costTracking)
    ]

    private static let initialState: InitialState = {
        let accounts = SecureAccountVault.shared.loadAccounts()
        let saved = Set(UserDefaults.standard.stringArray(forKey: selectedProvidersKey) ?? [])
        let storedProviderIDs = accounts.filter { !$0.isHidden }.map(\.providerId)
        let validIDs = Set(providerCatalogItems.map(\.id))
        let merged = Set(saved.union(storedProviderIDs).filter { validIDs.contains($0) })
        return InitialState(accounts: accounts, selectedProviderIds: merged)
    }()

    var providers: [ProviderData] { refreshCoordinator.providers }
    var overview: DashboardOverview? { refreshCoordinator.overview }
    var isLoading: Bool { refreshCoordinator.isLoading }
    var errorMessage: String? { refreshCoordinator.errorMessage }
    var lastRefreshTime: Date? { refreshCoordinator.lastRefreshTime }
    var isRefreshingAllProviders: Bool { refreshCoordinator.isRefreshingAllProviders }
    var refreshingProviderIDs: Set<String> { refreshCoordinator.refreshingProviderIDs }
    var refreshingAccountIDs: Set<String> { refreshCoordinator.refreshingAccountIDs }
    var providerRefreshTimes: [String: Date] { refreshCoordinator.providerRefreshTimes }
    var accountRefreshTimes: [String: Date] { refreshCoordinator.accountRefreshTimes }

    let accountStore = AccountStore.shared
    let activationManager = ProviderActivationManager.shared

    typealias ActivationResult = ProviderActivationManager.ActivationResult
    typealias CodexActivationResult = ProviderActivationManager.CodexActivationResult

    var accountRegistry: [StoredProviderAccount] {
        accountStore.accountRegistry
    }

    // MARK: - Settings (read-through for existing `appState.*` callers; mutations go through `AppSettings.shared`)

    var isDarkMode: Bool { settings.isDarkMode }
    var themeMode: String { settings.themeMode }
    var resolvedColorScheme: ColorScheme? { settings.resolvedColorScheme }
    var autoRefreshInterval: Int { settings.autoRefreshInterval }
    var claudeCodeRefreshInterval: Int { settings.claudeCodeRefreshInterval }
    var language: String { settings.language }
    var quotaIndicatorStyle: CardQuotaIndicatorStyle { settings.quotaIndicatorStyle }
    var quotaIndicatorMetric: CardQuotaIndicatorMetric { settings.quotaIndicatorMetric }
    var claudeCodeDailyThreshold: Double { settings.claudeCodeDailyThreshold }
    var backendMode: String { settings.backendMode }
    var remoteHost: String { settings.remoteHost }
    var remotePort: Int { settings.remotePort }

    @Published var showSettings = false
    @Published var selectedProviderId: String?
    @Published var selectedSection: AppSection = .dashboard
    @Published var providerPickerMode: ProviderPickerMode?
    @Published var selectedProviderIds: Set<String> = AppState.initialState.selectedProviderIds

    @Published var readAlertIds: Set<String> = {
        let arr = UserDefaults.standard.stringArray(forKey: "readAlertIds") ?? []
        return Set(arr)
    }()

    var unreadAlertCount: Int {
        let alerts = overview?.alerts ?? []
        return alerts.filter { !readAlertIds.contains($0.id) }.count
    }

    func markAlertRead(_ id: String) {
        readAlertIds.insert(id)
        UserDefaults.standard.set(Array(readAlertIds), forKey: "readAlertIds")
    }

    func markAllAlertsRead() {
        let ids = (overview?.alerts ?? []).map { $0.id }
        readAlertIds.formUnion(ids)
        UserDefaults.standard.set(Array(readAlertIds), forKey: "readAlertIds")
    }

    private var cancellables = Set<AnyCancellable>()
    private var didRunStartupFlow = false

    private init() {
        accountStore.bootstrapFromDisk(providerCatalogOrder: Self.providerCatalogItems.map(\.id))

        refreshCoordinator.configure(
            selectedProviderIds: { [weak self] in self?.selectedProviderIds ?? [] },
            providerCatalogIds: { Self.providerCatalogItems.map(\.id) },
            ensureProviderSelected: { [weak self] providerId in
                guard let self else { return }
                self.selectedProviderIds.insert(providerId)
                self.saveSelectedProviderIds()
            },
            providerTitleForId: { [weak self] id in
                self?.providerCatalogItem(for: id)?.title(for: self?.settings.language ?? "en") ?? id
            }
        )

        activationManager.detectActiveCodexAccount()
        activationManager.detectActiveGeminiAccount()

        activationManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        accountStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        refreshCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    @MainActor
    func performStartupFlowIfNeeded() async {
        if !didRunStartupFlow {
            didRunStartupFlow = true
            if needsInitialProviderSetup {
                await Task.yield()
                providerPickerMode = .initialSetup
            }
        }
        await refreshCoordinator.fetchDashboard()
    }

    var providerCatalog: [ProviderCatalogItem] {
        Self.providerCatalogItems
    }

    func providerCatalogItem(for id: String) -> ProviderCatalogItem? {
        providerCatalog.first { $0.id == id }
    }

    var unselectedProviderCatalog: [ProviderCatalogItem] {
        providerCatalog.filter { !selectedProviderIds.contains($0.id) }
    }

    var needsInitialProviderSetup: Bool {
        selectedProviderIds.isEmpty && accountRegistry.isEmpty
    }

    func presentAddProviderPicker() {
        guard !unselectedProviderCatalog.isEmpty else { return }
        providerPickerMode = .add
    }

    func presentManageProviderPicker() {
        providerPickerMode = .manage
    }

    func dismissProviderPicker() {
        providerPickerMode = nil
    }

    func completeInitialProviderSetup(with ids: Set<String>) {
        selectedProviderIds = sanitizedProviderIDs(ids)
        saveSelectedProviderIds()
        providerPickerMode = nil
        refreshAllProviders()
    }

    func addProviders(_ ids: Set<String>) {
        guard !ids.isEmpty else {
            providerPickerMode = nil
            return
        }
        selectedProviderIds.formUnion(sanitizedProviderIDs(ids))
        saveSelectedProviderIds()
        providerPickerMode = nil
        refreshAllProviders()
    }

    func updateProviderSelection(with ids: Set<String>) {
        let sanitized = sanitizedProviderIDs(ids)
        let removed = selectedProviderIds.subtracting(sanitized)

        selectedProviderIds = sanitized
        saveSelectedProviderIds()
        providerPickerMode = nil

        if !removed.isEmpty {
            refreshCoordinator.removeProviders(matchingBaseProviderIds: removed)
        }

        refreshAllProviders()
    }

    func setProviderScanningEnabled(_ providerId: String, isEnabled: Bool) {
        guard providerCatalog.contains(where: { $0.id == providerId }) else { return }

        if isEnabled {
            guard !selectedProviderIds.contains(providerId) else { return }
            selectedProviderIds.insert(providerId)
        } else {
            guard selectedProviderIds.contains(providerId) else { return }
            selectedProviderIds.remove(providerId)
            refreshCoordinator.removeProviders(matchingBaseProviderId: providerId)
        }

        saveSelectedProviderIds()
        refreshAllProviders()
    }

    func saveAccount(
        providerId: String,
        email: String,
        displayName: String?,
        note: String? = nil,
        accountId: String? = nil,
        credentialId: String? = nil,
        providerResultId: String? = nil
    ) {
        accountStore.saveAccount(
            providerId: providerId,
            email: email,
            displayName: displayName,
            note: note,
            accountId: accountId,
            credentialId: credentialId,
            providerResultId: providerResultId,
            ensureProviderSelected: { [weak self] providerId in
                guard let self else { return }
                self.selectedProviderIds.insert(providerId)
                self.saveSelectedProviderIds()
            }
        )
    }

    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String? = nil
    ) throws {
        let providerTitle = providerCatalogItem(for: credential.providerId)?.title(for: language) ?? credential.providerId
        try refreshCoordinator.registerAuthenticatedCredential(
            credential,
            usage: usage,
            note: note,
            providerDisplayTitle: providerTitle
        )
    }

    func updateAccountNote(for entry: ProviderAccountEntry, note: String?) {
        accountStore.updateAccountNote(for: entry, note: note) { [weak self] providerId in
            guard let self else { return }
            if self.selectedProviderIds.insert(providerId).inserted {
                self.saveSelectedProviderIds()
            }
        }
    }

    func restoreAccount(_ storedAccountId: String) {
        accountStore.restoreAccount(storedAccountId) { [weak self] providerId in
            guard let self else { return }
            self.selectedProviderIds.insert(providerId)
            self.saveSelectedProviderIds()
            self.refreshProvider(providerId)
        }
    }

    func deleteAccount(_ entry: ProviderAccountEntry) {
        accountStore.deleteAccount(entry) { [weak self] in
            self?.refreshCoordinator.reapplyVisibleSortedProviders()
        }
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountStore.accountNote(for: provider)
    }

    var providerAccountGroups: [ProviderAccountGroup] {
        let liveProvidersById = Dictionary(grouping: providers, by: \.baseProviderId)

        return providerCatalog
            .filter { item in
                selectedProviderIds.contains(item.id)
                    || accountRegistry.contains(where: { $0.providerId == item.id && !$0.isHidden })
                    || !(liveProvidersById[item.id] ?? []).isEmpty
            }
            .compactMap { item in
                let liveProviders = liveProvidersById[item.id] ?? []
                let storedAccounts = accountRegistry.filter { $0.providerId == item.id && !$0.isHidden }
                let entries = refreshCoordinator.buildProviderEntries(
                    providerId: item.id,
                    providerTitle: item.title(for: language),
                    providerSubtitle: item.summary(for: language),
                    liveProviders: liveProviders,
                    storedAccounts: storedAccounts
                )

                let sortedEntries = entries.sorted { lhs, rhs in
                    if lhs.isConnected != rhs.isConnected { return lhs.isConnected && !rhs.isConnected }
                    return (lhs.accountEmail ?? "").localizedCaseInsensitiveCompare(rhs.accountEmail ?? "") == .orderedAscending
                }

                return ProviderAccountGroup(
                    id: item.id,
                    providerId: item.id,
                    title: item.title(for: language),
                    subtitle: item.summary(for: language),
                    channel: item.channel,
                    isScanningEnabled: selectedProviderIds.contains(item.id),
                    accounts: sortedEntries
                )
            }
    }

    var hiddenAccounts: [StoredProviderAccount] {
        accountStore.hiddenAccounts()
    }

    func setupAutoRefresh() {
        refreshCoordinator.setupAutoRefresh()
    }

    func setupClaudeCodeAutoRefresh() {
        refreshCoordinator.setupClaudeCodeAutoRefresh()
    }

    func refreshAllProviders() {
        refreshCoordinator.refreshAllProviders()
    }

    func refreshClaudeCodeOnly() {
        refreshCoordinator.refreshClaudeCodeOnly()
    }

    func refreshProvider(_ providerId: String) {
        refreshCoordinator.refreshProvider(providerId)
    }

    func refreshProviderCard(_ provider: ProviderData) {
        refreshCoordinator.refreshProviderCard(provider)
    }

    func refreshProviderCardNow(_ provider: ProviderData) async {
        await refreshCoordinator.refreshProviderCardNow(provider)
    }

    func refreshAccount(credentialId: String, providerId: String) {
        refreshCoordinator.refreshAccount(credentialId: credentialId, providerId: providerId)
    }

    func refreshProviderNow(_ providerId: String) async {
        await refreshCoordinator.refreshProviderNow(providerId)
    }

    func refreshAccountNow(credentialId: String, providerId: String) async {
        await refreshCoordinator.refreshAccountNow(credentialId: credentialId, providerId: providerId)
    }

    func fetchDashboard() async {
        await refreshCoordinator.fetchDashboard()
    }

    func fetchSingleProvider(_ providerId: String) async {
        await refreshCoordinator.fetchSingleProvider(providerId)
    }

    func providerRefreshDate(for providerId: String) -> Date? {
        refreshCoordinator.providerRefreshDate(for: providerId)
    }

    func accountRefreshDate(for provider: ProviderData) -> Date? {
        refreshCoordinator.accountRefreshDate(for: provider)
    }

    func isProviderRefreshInFlight(_ providerId: String) -> Bool {
        refreshCoordinator.isProviderRefreshInFlight(providerId)
    }

    func isRefreshInProgress(for provider: ProviderData) -> Bool {
        refreshCoordinator.isRefreshInProgress(for: provider)
    }

    private func saveSelectedProviderIds() {
        UserDefaults.standard.set(selectedProviderIDList(), forKey: Self.selectedProvidersKey)
    }

    private func selectedProviderIDList() -> [String] {
        providerCatalog.map(\.id).filter { selectedProviderIds.contains($0) }
    }

    private func sanitizedProviderIDs<S: Sequence>(_ ids: S) -> Set<String> where S.Element == String {
        let validIDs = Set(Self.providerCatalogItems.map(\.id))
        return Set(ids.filter { validIDs.contains($0) })
    }

    // MARK: - Provider Account Activation (forwarded)

    static var activatableProviders: Set<String> { ProviderActivationManager.activatableProviders }

    var activeProviderAccountIds: [String: String] { activationManager.activeProviderAccountIds }

    var activationResult: ActivationResult? {
        get { activationManager.activationResult }
        set { activationManager.activationResult = newValue }
    }

    var activeCodexAccountId: String? {
        get { activationManager.activeCodexAccountId }
        set { activationManager.activeCodexAccountId = newValue }
    }

    var codexActivationResult: CodexActivationResult? {
        get { activationManager.codexActivationResult }
        set { activationManager.codexActivationResult = newValue }
    }

    func canActivateProvider(_ providerId: String) -> Bool {
        activationManager.canActivateProvider(providerId)
    }

    func activateAccount(entry: ProviderAccountEntry) throws {
        try activationManager.activateAccount(entry: entry)
    }

    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool {
        activationManager.isActiveAccount(entry)
    }

    func activateCodexAccount(entry: ProviderAccountEntry) throws {
        try activationManager.activateCodexAccount(entry: entry)
    }

    func activateGeminiAccount(entry: ProviderAccountEntry) throws {
        try activationManager.activateGeminiAccount(entry: entry)
    }

    func detectActiveCodexAccount() {
        activationManager.detectActiveCodexAccount()
    }

    func detectActiveGeminiAccount() {
        activationManager.detectActiveGeminiAccount()
    }

    func isActiveCodexAccount(_ entry: ProviderAccountEntry) -> Bool {
        activationManager.isActiveCodexAccount(entry)
    }
}
