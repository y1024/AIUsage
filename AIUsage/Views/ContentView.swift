import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.openWindow) private var openWindow
    private var sectionBinding: Binding<AppSection> {
        Binding(
            get: { appState.selectedSection },
            set: { appState.selectedSection = $0 }
        )
    }

    // 给系统导航图标加品牌化强调色，让侧边栏整体更协调（macOS 系统设置风格）。
    private func navLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    private var inboxLabel: some View {
        HStack {
            navLabel(
                L("Inbox", "消息", key: "nav.inbox"),
                systemImage: appState.unreadAlertCount > 0 ? "bell.badge.fill" : "bell.fill",
                tint: .orange
            )
            Spacer()
            if appState.unreadAlertCount > 0 {
                Text("\(appState.unreadAlertCount)")
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: sectionBinding) {
                navLabel(L("Dashboard", "仪表盘", key: "nav.dashboard"), systemImage: "chart.bar.doc.horizontal", tint: .blue)
                    .tag(AppSection.dashboard)

                navLabel(L("Providers", "服务商", key: "nav.providers"), systemImage: "square.grid.2x2", tint: .indigo)
                    .tag(AppSection.providers)

                Label {
                    Text(L("Claude Code Proxy", "Claude Code 代理", key: "nav.proxy_management"))
                } icon: {
                    ProviderIconView("claude", size: 18)
                }
                .tag(AppSection.proxyManagement)

                Label {
                    Text(L("CodeX Proxy", "CodeX 代理", key: "nav.codex_proxy_management"))
                } icon: {
                    ProviderIconView("codex", size: 18)
                }
                .tag(AppSection.codexProxyManagement)

                navLabel(L("Usage Stats", "用量统计", key: "nav.cost_tracking"), systemImage: "chart.bar.xaxis", tint: .green)
                    .tag(AppSection.costTracking)

                Divider()

                inboxLabel
                    .tag(AppSection.inbox)

                navLabel(L("Settings", "设置", key: "nav.settings"), systemImage: "gearshape", tint: .gray)
                    .tag(AppSection.settings)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)
            .navigationTitle("AIUsage")
        } detail: {
            // 主内容区
            ZStack {
                switch appState.selectedSection {
                case .dashboard:
                    DashboardView()
                case .providers:
                    ProvidersView()
                case .costTracking:
                    StatsHubView()
                case .proxyManagement:
                    ProxyManagementView()
                case .codexProxyManagement:
                    CodexProxyManagementView()
                case .inbox:
                    InboxView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await appState.performStartupFlowIfNeeded()
        }
        .onAppear {
            appState.registerMainWindowPresenter { section in
                appState.selectedSection = section
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppState.mainWindowID)
                let candidateWindows = NSApp.windows.filter { !($0 is NSPanel) }
                let window = candidateWindows.max(by: { $0.frame.width < $1.frame.width }) ?? candidateWindows.first
                window?.makeKeyAndOrderFront(nil)
            }
        }
        .sheet(item: $appState.providerPickerMode) { mode in
            ProviderPickerView(mode: mode)
                .environmentObject(appState)
                .interactiveDismissDisabled(mode == .initialSetup)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { refreshCoordinator.refreshAllProviders() }) {
                    HStack(spacing: 5) {
                        if refreshCoordinator.isAnyRefreshInProgress {
                            SmallProgressView().frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(L("Refresh All", "全部刷新", key: "actions.refresh_all"))
                            .font(.subheadline)
                    }
                }
                .help(L("Refresh every app and every account", "刷新所有应用和所有账号", key: "help.refresh_all"))
                .disabled(refreshCoordinator.isAnyRefreshInProgress)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .environmentObject(AccountStore.shared)
        .environmentObject(ProviderActivationManager.shared)
        .environmentObject(AppSettings.shared)
        .environmentObject(ProxyViewModel())
        .environmentObject(SparkleController())
        .frame(width: 1100, height: 700)
}
