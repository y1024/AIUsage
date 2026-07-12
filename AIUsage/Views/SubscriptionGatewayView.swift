import SwiftUI

struct SubscriptionGatewayView: View {
    @StateObject private var manager = CLIProxyGatewayManager.shared
    @StateObject private var runtime = CLIProxyRuntimeController.shared
    @ObservedObject private var navigation = CLIProxyGatewayNavigation.shared

    @State private var pendingVersionDeletion: CLIProxyInstalledVersion?
    @State private var pendingAuthDeletion: CLIProxyAuthFile?
    @State private var draftSettings = CLIProxyGatewaySettings.default
    @State private var settingsBase = CLIProxyGatewaySettings.default
    @State private var distributionTargets: Set<ProxyTarget> = []
    @State private var showAddAccount = false

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionNavigation
            Divider().opacity(0.55)
            sectionContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            let currentSettings = runtime.settings
            settingsBase = currentSettings
            draftSettings = currentSettings
            await manager.refresh()
            distributionTargets = currentDistributionTargets
        }
        .onChange(of: navigation.addAccountRequest) { _, _ in
            navigation.selectedSection = .accounts
            showAddAccount = true
        }
        .onChange(of: currentDistributionTargets) { _, targets in
            distributionTargets = targets
        }
        .onChange(of: runtime.settings) { _, newValue in
            // A provider-plugin action can update runtime settings while the
            // Settings tab has an unrelated dirty draft. Merge field by field
            // so neither side silently overwrites the other.
            draftSettings = draftSettings.mergingExternalChange(
                from: settingsBase,
                to: newValue
            )
            settingsBase = newValue
        }
        .alert(
            L("Delete Installed CPA Version?", "删除已安装的 CPA 版本？"),
            isPresented: Binding(
                get: { pendingVersionDeletion != nil },
                set: { if !$0 { pendingVersionDeletion = nil } }
            ),
            presenting: pendingVersionDeletion
        ) { version in
            Button(L("Delete v\(version.version)", "删除 v\(version.version)"), role: .destructive) {
                Task { await manager.delete(version) }
                pendingVersionDeletion = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingVersionDeletion = nil }
        } message: { _ in
            Text(L("Only this rollback copy is removed.", "只会删除这个回退副本。"))
        }
        .alert(
            L("Remove Account from CPA?", "从 CPA 删除账号？"),
            isPresented: Binding(
                get: { pendingAuthDeletion != nil },
                set: { if !$0 { pendingAuthDeletion = nil } }
            ),
            presenting: pendingAuthDeletion
        ) { file in
            Button(L("Remove", "删除"), role: .destructive) {
                Task { await manager.deleteAuthFile(file) }
                pendingAuthDeletion = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingAuthDeletion = nil }
        } message: { _ in
            Text(L(
                "This removes only CPA's copy. The original AIUsage subscription account remains unchanged.",
                "只删除 CPA 中的副本，AIUsage 原订阅账号不会被修改。"
            ))
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                headerIdentity
                Spacer(minLength: 18)
                headerActions
            }

            VStack(alignment: .leading, spacing: 12) {
                headerIdentity
                HStack(spacing: 10) {
                    Spacer()
                    headerActions
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 17)
        .background(.bar)
    }

    private var headerIdentity: some View {
        HStack(spacing: 15) {
            ProviderIconView("cliproxyapi", size: 50)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(L("CPA Gateway", "CPA 网关"))
                        .font(.title2.weight(.bold))
                    Text("CLIProxyAPI")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                }
                HStack(spacing: 7) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                    Text(L(
                        "One account pool for 4 AIUsage apps and multi-protocol local API clients",
                        "一个账号池，连接 4 个 AIUsage 应用与多协议本地 API 客户端"
                    ))
                    .lineLimit(2)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .layoutPriority(1)
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button {
                navigation.showAccounts(openAddAccount: true)
                showAddAccount = true
            } label: {
                Label(L("Add Account", "添加账号"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(manager.operation.isBusy)
            .help(L(
                "Open the account guide; it can install or start CPA when needed.",
                "打开账号向导；如有需要，可在向导内安装或启动 CPA。"
            ))

            runtimeBadge
        }
    }

    private var sectionNavigation: some View {
        HStack(spacing: 4) {
            ForEach(CLIProxyGatewaySection.allCases) { section in
                Button {
                    navigation.selectedSection = section
                } label: {
                    Label(section.shortTitle, systemImage: section.systemImage)
                        .font(.subheadline.weight(navigation.selectedSection == section ? .semibold : .medium))
                        .foregroundStyle(navigation.selectedSection == section ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(navigation.selectedSection == section ? Color.accentColor.opacity(0.11) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(navigation.selectedSection == section ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch navigation.selectedSection {
        case .overview:
            SubscriptionGatewayOverviewView(
                manager: manager,
                runtime: runtime,
                showAddAccount: $showAddAccount
            )
        case .accounts:
            SubscriptionGatewayAccountsView(
                manager: manager,
                runtime: runtime,
                showAddAccount: $showAddAccount,
                pendingDeletion: $pendingAuthDeletion
            )
        case .connections:
            SubscriptionGatewayConnectionsView(
                manager: manager,
                runtime: runtime,
                selectedTargets: $distributionTargets
            )
        case .settings:
            SubscriptionGatewaySettingsView(
                manager: manager,
                runtime: runtime,
                draftSettings: $draftSettings,
                pendingVersionDeletion: $pendingVersionDeletion
            )
        }
    }

    private var runtimeBadge: some View {
        GatewayStatusPill(
            text: runtimeLabel,
            color: runtime.state.isRunning ? .green : (runtime.state.isTransitioning ? .orange : .secondary),
            systemImage: runtime.state.isRunning ? "checkmark.circle.fill" : "circle.fill"
        )
    }

    private var runtimeLabel: String {
        switch runtime.state {
        case .stopped: L("CPA stopped", "CPA 已停止")
        case .starting: L("Starting…", "正在启动…")
        case .running: L("CPA running", "CPA 运行中")
        case .stopping: L("Stopping…", "正在停止…")
        case .failed: L("CPA needs attention", "CPA 需要处理")
        }
    }

    /// Keep the root view compatible while the manager owns distribution truth.
    private var currentDistributionTargets: Set<ProxyTarget> {
        manager.currentDistributionTargets
    }
}
