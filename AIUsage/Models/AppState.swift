import SwiftUI
import Combine
import QuotaBackend

// 全局应用状态
class AppState: ObservableObject {
    static let shared = AppState()
    static let mainWindowID = "main-window"
    let settings = AppSettings.shared
    let refreshCoordinator = ProviderRefreshCoordinator.shared

    private struct InitialState {
        let accounts: [StoredProviderAccount]
        let selectedProviderIds: Set<String>
    }

    /// One-shot migration that auto-enrolls existing installs into newly-added
    /// `kind == .costTracking` catalog items. Without this, upgrading users keep their
    /// previously-saved `selectedProviderIds` set forever and never see new local-source
    /// providers (Codex Logs etc.) until they manually opt in via Settings.
    ///
    /// Bumped to `v2` because the original `v1` flag was rolled back in an earlier
    /// review-fix commit; users who already toggled it manually still control their
    /// selection because we only insert, never remove.
    private static let costTrackingSelectionMigrationKey = "selectedProviderIdsMigration.costTracking.v2"

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
        ProviderCatalogItem(id: "claude", titleEn: "Claude Code", titleZh: "Claude Code", summaryEn: "Local token and cost ledger from Claude Code logs", summaryZh: "基于 Claude Code 本地日志的 Token 与费用账本", channel: "local", kind: .costTracking),
        ProviderCatalogItem(id: "codex-cost", titleEn: "Codex Logs", titleZh: "Codex 日志", summaryEn: "Local token ledger from Codex session logs", summaryZh: "基于 Codex 本地会话日志的 Token 账本", channel: "local", kind: .costTracking)
    ]

    private static let initialState: InitialState = {
        let defaults = UserDefaults.standard
        let accounts = SecureAccountVault.shared.loadAccounts()
        let hasSavedProviderSelection = defaults.object(forKey: DefaultsKey.selectedProviderIds) != nil
        let saved = Set(defaults.stringArray(forKey: DefaultsKey.selectedProviderIds) ?? [])
        let storedProviderIDs = accounts.filter { !$0.isHidden }.map(\.providerId)
        let validIDs = Set(providerCatalogItems.map(\.id))
        var merged = Set(saved.union(storedProviderIDs).filter { validIDs.contains($0) })

        // Auto-enroll existing installs into any newly-added cost-tracking catalog item
        // exactly once. Skip first-launch installs (no saved selection AND no accounts) so
        // the onboarding picker still gets to drive the initial selection. Persist the
        // expanded selection back so future launches see it via the normal saved path.
        if !defaults.bool(forKey: costTrackingSelectionMigrationKey) {
            if hasSavedProviderSelection || !accounts.isEmpty {
                let costTrackingIds = providerCatalogItems
                    .filter { $0.kind == .costTracking }
                    .map(\.id)
                var didInsert = false
                for id in costTrackingIds where !merged.contains(id) {
                    merged.insert(id)
                    didInsert = true
                }
                if didInsert {
                    let orderedSelection = providerCatalogItems.map(\.id).filter { merged.contains($0) }
                    defaults.set(orderedSelection, forKey: DefaultsKey.selectedProviderIds)
                }
            }
            defaults.set(true, forKey: costTrackingSelectionMigrationKey)
        }

        return InitialState(accounts: accounts, selectedProviderIds: merged)
    }()

    var providers: [ProviderData] { refreshCoordinator.providers }
    var overview: DashboardOverview? { refreshCoordinator.overview }
    var isLoading: Bool { refreshCoordinator.isLoading }
    var errorMessage: String? { refreshCoordinator.errorMessage }
    var lastRefreshTime: Date? { refreshCoordinator.lastRefreshTime }
    var isRefreshingAllProviders: Bool { refreshCoordinator.isRefreshingAllProviders }
    let accountStore = AccountStore.shared
    let activationManager = ProviderActivationManager.shared

    typealias ActivationResult = ProviderActivationManager.ActivationResult

    var language: String { settings.language }

    @Published var showSettings = false
    @Published var selectedProviderId: String?
    @Published var selectedSection: AppSection = .dashboard
    @Published var providerPickerMode: ProviderPickerMode?
    @Published var selectedProviderIds: Set<String> = AppState.initialState.selectedProviderIds

    @Published var readAlertIds: Set<String> = {
        let arr = UserDefaults.standard.stringArray(forKey: DefaultsKey.readAlertIds) ?? []
        return Set(arr)
    }()

    var unreadAlertCount: Int {
        let alerts = overview?.alerts ?? []
        return alerts.filter { !readAlertIds.contains($0.id) }.count
    }

    func markAlertRead(_ id: String) {
        readAlertIds.insert(id)
        UserDefaults.standard.set(Array(readAlertIds), forKey: DefaultsKey.readAlertIds)
    }

    func markAllAlertsRead() {
        let ids = (overview?.alerts ?? []).map { $0.id }
        readAlertIds.formUnion(ids)
        UserDefaults.standard.set(Array(readAlertIds), forKey: DefaultsKey.readAlertIds)
    }

    private var cancellables = Set<AnyCancellable>()
    private var didRunStartupFlow = false
    private var mainWindowPresenter: ((AppSection) -> Void)?

    private init() {
        settings.onRemoteSettingsChanged = { url in
            APIService.shared.updateBaseURL(url)
        }

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

    func registerMainWindowPresenter(_ presenter: @escaping (AppSection) -> Void) {
        mainWindowPresenter = presenter
    }

    func presentMainWindow(section: AppSection) {
        selectedSection = section

        if let mainWindowPresenter {
            mainWindowPresenter(section)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let candidateWindows = NSApp.windows.filter { !($0 is NSPanel) }
        let window = candidateWindows.max(by: { $0.frame.width < $1.frame.width }) ?? candidateWindows.first
        window?.makeKeyAndOrderFront(nil)
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

    /// Single source of truth for "is this provider a local token / cost tracking source?".
    /// Treats normalized `category == ProviderCategory.localCost` and catalog
    /// `kind == .costTracking` as equivalent so DashboardView, CostTrackingView and
    /// MenuBarView can never drift apart.
    func isLocalCostProvider(_ provider: ProviderData) -> Bool {
        if provider.category == ProviderCategory.localCost { return true }
        return providerCatalogItem(for: provider.baseProviderId)?.kind == .costTracking
    }

    /// Convenience: filter a provider list down to local cost / token tracking sources.
    func localCostProviders(from providers: [ProviderData]) -> [ProviderData] {
        providers.filter(isLocalCostProvider)
    }

    var unselectedProviderCatalog: [ProviderCatalogItem] {
        providerCatalog.filter { !selectedProviderIds.contains($0.id) }
    }

    var needsInitialProviderSetup: Bool {
        selectedProviderIds.isEmpty && accountStore.accountRegistry.isEmpty
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
            saveSelectedProviderIds()
            refreshProvider(providerId)
        } else {
            guard selectedProviderIds.contains(providerId) else { return }
            selectedProviderIds.remove(providerId)
            refreshCoordinator.removeProviders(matchingBaseProviderId: providerId)
            saveSelectedProviderIds()
        }
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

    func deleteAccounts(_ entries: [ProviderAccountEntry]) {
        accountStore.deleteAccounts(entries) { [weak self] in
            self?.refreshCoordinator.reapplyVisibleSortedProviders()
        }
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountStore.accountNote(for: provider)
    }

    // `providerAccountGroups` and `hiddenAccounts` live in
    // `AppState+ProviderGrouping.swift`.

    func setupAutoRefresh() {
        refreshCoordinator.setupAutoRefresh()
    }

    func setupClaudeCodeAutoRefresh() {
        refreshCoordinator.setupClaudeCodeAutoRefresh()
    }

    func refreshAllProviders() {
        refreshCoordinator.refreshAllProviders()
    }

    func refreshProvider(_ providerId: String) {
        refreshCoordinator.refreshProvider(providerId)
    }

    private func saveSelectedProviderIds() {
        UserDefaults.standard.set(selectedProviderIDList(), forKey: DefaultsKey.selectedProviderIds)
    }

    private func selectedProviderIDList() -> [String] {
        providerCatalog.map(\.id).filter { selectedProviderIds.contains($0) }
    }

    private func sanitizedProviderIDs<S: Sequence>(_ ids: S) -> Set<String> where S.Element == String {
        let validIDs = Set(Self.providerCatalogItems.map(\.id))
        return Set(ids.filter { validIDs.contains($0) })
    }

    // MARK: - Activation (still used by Views via appState)

    var activationResult: ActivationResult? {
        get { activationManager.activationResult }
        set { activationManager.activationResult = newValue }
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
}
