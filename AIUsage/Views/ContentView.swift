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

    private var inboxLabel: some View {
        HStack {
            Label(L("Inbox", "消息", key: "nav.inbox"), systemImage: appState.unreadAlertCount > 0 ? "bell.badge.fill" : "bell.fill")
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
                Label(L("Dashboard", "仪表盘", key: "nav.dashboard"), systemImage: "chart.bar.doc.horizontal")
                    .tag(AppSection.dashboard)

                Label(L("Providers", "服务商", key: "nav.providers"), systemImage: "square.grid.2x2")
                    .tag(AppSection.providers)

                Label(L("Token Stats", "Token 统计", key: "nav.cost_tracking"), systemImage: "chart.bar.xaxis")
                    .tag(AppSection.costTracking)

                Label(L("Claude Code Proxy", "Claude Code 代理", key: "nav.proxy_management"), systemImage: "server.rack")
                    .tag(AppSection.proxyManagement)

                Label(L("Proxy Stats", "代理统计", key: "nav.proxy_stats"), systemImage: "chart.line.uptrend.xyaxis")
                    .tag(AppSection.proxyStats)

                inboxLabel
                    .tag(AppSection.inbox)

                Divider()

                Label(L("Settings", "设置", key: "nav.settings"), systemImage: "gearshape")
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
                    CostTrackingView()
                case .proxyManagement:
                    ProxyManagementView()
                case .proxyStats:
                    ProxyStatsView()
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
