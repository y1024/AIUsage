import SwiftUI
import Combine
import Sparkle
import UserNotifications

final class SparkleController: ObservableObject {
    @Published var canCheckForUpdates = false
    
    let updaterController: SPUStandardUpdaterController
    
    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
    
    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @StateObject private var proxyViewModel = ProxyViewModel()
    @StateObject private var sparkle = SparkleController()
    
    var body: some Scene {
        WindowGroup {
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
                    appState.showSettings = true
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        requestNotificationPermission()

        if UserDefaults.standard.bool(forKey: "hideDockIcon") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
            if granted {
                print("Notification permission granted")
            } else {
                print("Notification permission denied")
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "AIUsage")
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
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
        popover.contentSize = NSSize(width: 400, height: 700)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(AppState.shared)
                .environmentObject(ProviderActivationManager.shared)
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
        menu.addItem(NSMenuItem(title: menuText("Open Dashboard", "打开仪表盘"), action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: menuText("Open Cost Tracking", "打开费用追踪"), action: #selector(openCostTracking), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: menuText("Refresh All", "全部刷新"), action: #selector(refreshAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: menuText("Refresh Claude Code", "刷新 Claude Code"), action: #selector(refreshClaudeCode), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: menuText("Settings...", "设置..."), action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: menuText("Quit AIUsage", "退出 AIUsage"), action: #selector(quit), keyEquivalent: ""))

        for item in menu.items { item.target = self }

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func openDashboard() {
        openMainWindow(section: .dashboard)
    }

    @objc func openCostTracking() {
        openMainWindow(section: .costTracking)
    }

    func openMainWindow(section: AppSection) {
        popover?.performClose(nil)
        AppState.shared.selectedSection = section
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.max(by: { $0.frame.width < $1.frame.width }) ?? NSApp.windows.first
        if let window {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func refreshAll() {
        AppState.shared.refreshAllProviders()
    }

    @objc func refreshClaudeCode() {
        AppState.shared.refreshClaudeCodeOnly()
    }

    @objc func openSettings() {
        popover?.performClose(nil)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func menuText(_ en: String, _ zh: String) -> String {
        AppSettings.shared.language == "zh" ? zh : en
    }
}
