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
    @State private var pendingSection: CLIProxyGatewaySection?
    @State private var showDiscardSectionConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionNavigation
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
        .confirmationDialog(
            L("Discard unsaved changes?", "放弃未保存的更改？"),
            isPresented: $showDiscardSectionConfirm
        ) {
            Button(L("Discard", "放弃"), role: .destructive) {
                if let pendingSection {
                    discardDirtyState(for: navigation.selectedSection)
                    navigation.selectedSection = pendingSection
                }
                pendingSection = nil
            }
            Button(L("Stay", "留下"), role: .cancel) {
                pendingSection = nil
            }
        } message: {
            Text(L(
                "Switching tabs will discard edits that have not been applied yet.",
                "切换分区会丢弃尚未应用的修改。"
            ))
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                headerIdentity
                Spacer(minLength: 12)
                headerActions
            }

            VStack(alignment: .leading, spacing: 10) {
                headerIdentity
                HStack(spacing: 10) {
                    Spacer()
                    headerActions
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var headerIdentity: some View {
        HStack(spacing: 10) {
            ProviderIconView("cliproxyapi", size: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(L("CPA Gateway", "CPA 网关"))
                        .font(.title3.weight(.bold))
                    if let version = manager.currentVersion {
                        Text("v\(version)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                Text(L("Shared account pool for apps & local APIs", "应用与本地 API 共用账号池"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .layoutPriority(1)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                navigation.showAccounts(openAddAccount: true)
                showAddAccount = true
            } label: {
                Label(L("Add Upstream", "添加上游"), systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(manager.operation.isBusy)

            runtimeBadge
        }
    }

    private var sectionNavigation: some View {
        HStack(spacing: 4) {
            ForEach(CLIProxyGatewaySection.allCases) { section in
                let selected = navigation.selectedSection == section
                Button {
                    requestSectionChange(to: section)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(section.shortTitle)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        if isSectionDirty(section) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.78))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selected ? section.accentColor : Color.primary.opacity(0.05))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(section.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private func requestSectionChange(to section: CLIProxyGatewaySection) {
        guard navigation.selectedSection != section else { return }
        if isSectionDirty(navigation.selectedSection) {
            pendingSection = section
            showDiscardSectionConfirm = true
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            navigation.selectedSection = section
        }
    }

    private func isSectionDirty(_ section: CLIProxyGatewaySection) -> Bool {
        switch section {
        case .connections:
            return distributionTargets != manager.currentDistributionTargets
        case .settings:
            return draftSettings.normalized != settingsBase.normalized
        case .overview, .accounts:
            return false
        }
    }

    private func discardDirtyState(for section: CLIProxyGatewaySection) {
        switch section {
        case .connections:
            distributionTargets = manager.currentDistributionTargets
        case .settings:
            draftSettings = settingsBase
        case .overview, .accounts:
            break
        }
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
        Menu {
            if runtime.state.isRunning {
                Button(L("Stop CPA", "停止 CPA")) {
                    Task { await runtime.stop() }
                }
                Button(L("Restart CPA", "重启 CPA")) {
                    Task { await runtime.restart() }
                }
            } else {
                Button(L("Start CPA", "启动 CPA")) {
                    Task { await runtime.start() }
                }
            }
            Divider()
            Button(L("Open Settings", "打开设置")) {
                requestSectionChange(to: .settings)
            }
            Button(L("Refresh Status", "刷新状态")) {
                Task { await manager.refresh() }
            }
        } label: {
            GatewayStatusPill(
                text: runtimeLabel,
                color: runtime.state.isRunning ? .green : (runtime.state.isTransitioning ? .orange : .secondary),
                systemImage: runtime.state.isRunning ? "checkmark.circle.fill" : "circle.fill"
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(runtime.state.isTransitioning || manager.operation.isBusy)
        .help(L("CPA runtime actions", "CPA 运行操作"))
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
