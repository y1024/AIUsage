import SwiftUI
import Combine
import Sparkle
import UserNotifications
import os

private let appDelegateLog = Logger(subsystem: "com.aiusage.desktop", category: "AppDelegate")

// MARK: - Sparkle Controller
// 封装 Sparkle 自动更新：启动静默探测 + Sparkle 2 「温和提醒」。
// 后台/计划内发现新版本时不弹系统大窗，只点亮 `availableUpdateVersion`，
// 由侧边栏底部的更新按钮承接；用户点击后再走 Sparkle 标准更新流程（发行说明 → 安装并自动重启）。
final class SparkleController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    /// 发现的新版本号（`displayVersionString`）。非空 → 左下角浮现更新按钮。
    @Published private(set) var availableUpdateVersion: String?

    private var updaterController: SPUStandardUpdaterController!
    private var didRunLaunchProbe = false

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        let updater = updaterController.updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    /// 启动后的一次性静默探测：不弹任何 UI，发现新版本则点亮更新按钮。
    func startLaunchUpdateProbeIfNeeded() {
        guard !didRunLaunchProbe else { return }
        didRunLaunchProbe = true
        updaterController.updater.checkForUpdateInformation()
    }

    /// 用户主动点击「检查更新」或左下角更新按钮：走 Sparkle 标准更新流程。
    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    func setAutoCheckEnabled(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    // MARK: - SPUStandardUserDriverDelegate (温和提醒)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // 计划内（后台）更新一律交给我们的温和提醒，不抢焦点弹大窗。
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // 标准驱动将自行展示（用户主动检查）时不点亮按钮，避免重复提示。
        guard !handleShowingUpdate else { return }
        availableUpdateVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdateVersion = nil
    }

    // MARK: - SPUUpdaterDelegate (静默探测结果)

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdateVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
    }
}

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var proxyViewModel = ProxyViewModel.shared
    @StateObject private var sparkle = SparkleController()
    
    var body: some Scene {
        Window("AIUsage", id: AppState.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(ProviderActivationManager.shared)
                .environmentObject(ProviderRefreshCoordinator.shared)
                .environmentObject(AccountStore.shared)
                .environmentObject(appSettings)
                .environmentObject(proxyViewModel)
                .environmentObject(sparkle)
                .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 700)
                .preferredColorScheme(appSettings.resolvedColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    sparkle.checkForUpdates()
                }
                .disabled(!sparkle.canCheckForUpdates)
                Divider()
                Button("Preferences...") {
                    appState.presentMainWindow(section: .settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(ProviderActivationManager.shared)
                .environmentObject(ProviderRefreshCoordinator.shared)
                .environmentObject(AccountStore.shared)
                .environmentObject(appSettings)
                .environmentObject(sparkle)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var statusBarHostingView: NSHostingView<StatusBarItemView>?
    private var settingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        requestNotificationPermission()

        if UserDefaults.standard.bool(forKey: DefaultsKey.hideDockIcon) {
            NSApp.setActivationPolicy(.accessory)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            AppState.shared.refreshAllProviders()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyViewModel.shared.flushPersistence()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppState.shared.presentMainWindow(section: AppState.shared.selectedSection)
        return true
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    appDelegateLog.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let hostingView = NSHostingView(
                rootView: StatusBarItemView(
                    appState: AppState.shared,
                    refreshCoordinator: ProviderRefreshCoordinator.shared,
                    settings: AppSettings.shared
                )
            )
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            statusBarHostingView = hostingView

            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            updateStatusBarSize()
            settingsCancellable = AppSettings.shared.objectWillChange
                .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.updateStatusBarSize()
                }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
    }

    private func updateStatusBarSize() {
        guard let hostingView = statusBarHostingView else { return }
        let fittingSize = hostingView.fittingSize
        statusItem?.length = max(fittingSize.width + 8, 28)
    }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu(from: sender)
            return
        }

        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 700)
        popover.behavior = .transient
        popover.animates = true

        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(AppState.shared)
                .environmentObject(ProviderActivationManager.shared)
                .environmentObject(ProviderRefreshCoordinator.shared)
        )
        self.popover = popover

        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        DispatchQueue.main.async {
            ProviderActivationManager.shared.detectActiveCodexAccount()
            ProviderActivationManager.shared.detectActiveGeminiAccount()
        }
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("Open Dashboard", "打开仪表盘"), action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Open Cost Tracking", "打开费用追踪"), action: #selector(openCostTracking), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Refresh All", "全部刷新"), action: #selector(refreshAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Refresh Token Stats", "刷新 Token 统计"), action: #selector(refreshClaudeCode), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Settings...", "设置..."), action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Quit AIUsage", "退出 AIUsage"), action: #selector(quit), keyEquivalent: ""))

        for item in menu.items { item.target = self }

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func openDashboard() {
        revealMainWindow(section: .dashboard)
    }

    @objc func openCostTracking() {
        revealMainWindow(section: .costTracking)
    }

    func revealMainWindow(section: AppSection) {
        popover?.performClose(nil)
        AppState.shared.presentMainWindow(section: section)
    }

    @objc func refreshAll() {
        AppState.shared.refreshAllProviders()
    }

    @objc func refreshClaudeCode() {
        ProviderRefreshCoordinator.shared.refreshLocalTokenStatsOnly()
    }

    @objc func openSettings() {
        revealMainWindow(section: .settings)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
