import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var sectionBinding: Binding<AppSection> {
        Binding(
            get: { appState.selectedSection },
            set: { appState.selectedSection = $0 }
        )
    }

    private var inboxLabel: some View {
        HStack {
            Label(t("Inbox", "消息"), systemImage: appState.unreadAlertCount > 0 ? "bell.badge.fill" : "bell.fill")
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
                Label(t("Dashboard", "仪表盘"), systemImage: "chart.bar.doc.horizontal")
                    .tag(AppSection.dashboard)

                Label(t("Providers", "服务商"), systemImage: "square.grid.2x2")
                    .tag(AppSection.providers)

                Label(t("Claude Code Stats", "Claude Code 统计"), systemImage: "chart.bar.xaxis")
                    .tag(AppSection.costTracking)

                Label(t("Claude Code Proxy", "Claude Code 代理"), systemImage: "server.rack")
                    .tag(AppSection.proxyManagement)

                Label(t("Proxy Stats", "代理统计"), systemImage: "chart.line.uptrend.xyaxis")
                    .tag(AppSection.proxyStats)

                inboxLabel
                    .tag(AppSection.inbox)

                Divider()

                Label(t("Settings", "设置"), systemImage: "gearshape")
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
        .sheet(item: $appState.providerPickerMode) { mode in
            ProviderPickerView(mode: mode)
                .environmentObject(appState)
                .interactiveDismissDisabled(mode == .initialSetup)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { appState.refreshAllProviders() }) {
                    HStack(spacing: 5) {
                        if appState.isLoading || appState.isRefreshingAllProviders {
                            SmallProgressView().frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(t("Refresh All", "全部刷新"))
                            .font(.subheadline)
                    }
                }
                .help(t("Refresh every app and every account", "刷新所有应用和所有账号"))
                .disabled(appState.isLoading || appState.isRefreshingAllProviders)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .frame(width: 1100, height: 700)
}
