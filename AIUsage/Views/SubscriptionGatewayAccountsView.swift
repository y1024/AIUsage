import AppKit
import Foundation
import SwiftUI

// MARK: - CPA Account Center
// 账号中心只展示已经真实存在于 CPA 的上游。尚未同步的 AIUsage 账号走顶部
// 「可从 AIUsage 接入」入口。列表行 UI 见 GatewayAccountRow；筛选/计数见 GatewayAccountListLogic。

struct SubscriptionGatewayAccountsView: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var showAddAccount: Bool
    @Binding var pendingDeletion: CLIProxyAuthFile?

    @State private var query = ""
    @State private var filter: GatewayAccountFilter = .all
    @State private var selectedDetail: CLIProxyAuthFile?
    @State private var pendingForceSync: CLIProxyAccountSyncCandidate?
    @State private var upstreamSection: GatewayUpstreamSection = .oauth
    @State private var subscriptionBridgeNotice: String?

    var body: some View {
        let syncStates = GatewayAccountListLogic.syncStatesByAuthFileName(manager: manager)
        let groups = GatewayAccountListLogic.filteredGroups(
            authFiles: manager.authFiles,
            query: query,
            filter: filter,
            syncStatesByAuthFileName: syncStates
        )
        let linkedCandidates = GatewayAccountListLogic.linkedCandidateByAuthFileName(manager: manager)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                errorBanners
                if let subscriptionBridgeNotice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(.secondary)
                        Text(subscriptionBridgeNotice)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            self.subscriptionBridgeNotice = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                }
                GatewaySectionTitle(
                    title: L("Account center", "账号中心"),
                    subtitle: L("Upstreams already in CPA. Use Add Upstream in the top bar.", "已在 CPA 中的上游。添加请用顶部「添加上游」。")
                )

                summaryRow(syncStates: syncStates)
                if unsyncedCandidateCount > 0 { aiusageEntryCard }
                toolbar

                if !runtime.state.isRunning {
                    serviceStoppedState
                } else if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        providerGroup(group, linkedCandidates: linkedCandidates)
                    }
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .sheet(isPresented: $showAddAccount) {
            CLIProxyAddUpstreamSheet(
                manager: manager,
                runtime: runtime,
                section: $upstreamSection
            )
        }
        .sheet(item: $selectedDetail) { file in
            CLIProxyAccountDetailSheet(
                file: file,
                manager: manager,
                pendingDeletion: $pendingDeletion
            )
        }
        .alert(
            L("Replace the Modified CPA Copy?", "覆盖已修改的 CPA 副本？"),
            isPresented: Binding(
                get: { pendingForceSync != nil },
                set: { if !$0 { pendingForceSync = nil } }
            ),
            presenting: pendingForceSync
        ) { candidate in
            Button(L("Replace CPA Copy", "覆盖 CPA 副本"), role: .destructive) {
                Task { await manager.syncAccount(candidate, forceOverwriteCPA: true) }
                pendingForceSync = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingForceSync = nil }
        } message: { candidate in
            Text(L(
                "The CPA copy for \(candidate.label) changed after it was synchronized. This may be a normal OAuth token rotation. Replacing it can discard a newer refresh token and may require signing in to CPA again; the original AIUsage credential is unchanged.",
                "\(candidate.label) 的 CPA 副本在同步后发生过修改，这可能只是正常的 OAuth Token 轮换。覆盖可能丢弃较新的 Refresh Token，并导致需要在 CPA 重新登录；AIUsage 原凭据不会改变。"
            ))
        }
    }

    // MARK: - Banners & Summary

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError { GatewayErrorBanner(message: error) }
        if let error = manager.syncManifestError, error != manager.lastError {
            GatewayErrorBanner(message: error)
        }
        if case .failed(let error) = runtime.state { GatewayErrorBanner(message: error) }
        if manager.authDeduplicationConflictCount > 0 { deduplicationConflictBanner }
    }

    private var deduplicationConflictBanner: some View {
        GatewayCard {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Managed-copy conflicts were kept", "托管副本冲突已保留"))
                        .font(.subheadline.weight(.semibold))
                    Text(L(
                        "CPA copy conflicts or failed safety checks were found for \(manager.authDeduplicationConflictCount) native account identities. AIUsage kept every unverified copy and did not overwrite it.",
                        "发现 \(manager.authDeduplicationConflictCount) 组 CPA 副本存在冲突或未通过安全复核。AIUsage 已保留所有未经验证的副本，没有自动删除或覆盖。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func summaryRow(syncStates: [String: CLIProxyAccountSyncState]) -> some View {
        let attention = GatewayAccountListLogic.attentionCount(
            in: manager.authFiles,
            deduplicationConflicts: manager.authDeduplicationConflictCount,
            hasSyncManifestError: manager.syncManifestError != nil,
            syncStatesByAuthFileName: syncStates
        )
        return GatewayStatCapsuleRow(
            items: [
                .init(
                    id: "all",
                    value: "\(manager.authFiles.count)",
                    title: L("in CPA", "CPA 账号"),
                    systemImage: "person.2.fill",
                    tint: .indigo
                ),
                .init(
                    id: "ready",
                    value: "\(GatewayAccountListLogic.readyCount(in: manager.authFiles, syncStatesByAuthFileName: syncStates))",
                    title: L("ready", "可用"),
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                ),
                .init(
                    id: "attention",
                    value: "\(attention)",
                    title: L("need attention", "需要处理"),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                ),
                .init(
                    id: "fromAIUsage",
                    value: "\(GatewayAccountListLogic.managedCopyCount(in: manager.authFiles))",
                    title: L("from AIUsage", "AIUsage 副本"),
                    systemImage: "arrow.right.circle.fill",
                    tint: .blue
                ),
            ],
            selectedId: filter.rawValue,
            onSelect: { id in
                if let next = GatewayAccountFilter(rawValue: id) {
                    withAnimation(.easeInOut(duration: 0.15)) { filter = next }
                }
            }
        )
    }

    private var aiusageEntryCard: some View {
        Button {
            upstreamSection = .aiusage
            showAddAccount = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text(L(
                    "\(unsyncedCandidateCount) AIUsage account(s) can be connected to CPA",
                    "可从 AIUsage 接入 \(unsyncedCandidateCount) 个账号"
                ))
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text(L("Connect", "去接入"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(
            "Connect \(unsyncedCandidateCount) AIUsage accounts to CPA",
            "可从 AIUsage 接入 \(unsyncedCandidateCount) 个账号"
        ))
    }

    private func summaryChip(value: Int, title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(tint)
            Text("\(value)").font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.055)))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchField
                filterPicker
                Spacer()
                refreshButton
            }
            VStack(alignment: .leading, spacing: 10) {
                searchField
                HStack(spacing: 10) {
                    filterPicker
                    Spacer()
                    refreshButton
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Search accounts", "搜索账号"), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(L("Search gateway accounts", "搜索网关账号"))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Clear search", "清除搜索"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: 240)
        .background(Color.primary.opacity(0.045), in: Capsule())
    }

    private var filterPicker: some View {
        GatewayCapsuleFilterBar(
            values: GatewayAccountFilter.allCases,
            selection: $filter,
            title: { $0.title }
        )
        .frame(maxWidth: 520)
    }

    private var refreshButton: some View {
        HStack(spacing: 8) {
            if manager.isManagingAccounts { ProgressView().controlSize(.small) }
            Button {
                Task { await manager.refreshAccounts() }
            } label: {
                Label(L("Refresh", "刷新"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
        }
    }

    // MARK: - Groups & Rows

    private func providerGroup(
        _ group: GatewayAccountGroup,
        linkedCandidates: [String: CLIProxyAccountSyncCandidate]
    ) -> some View {
        GatewayCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    GatewayProviderIcon(providerID: group.providerID, size: 26)
                    Text(gatewayProviderDisplayName(group.providerID))
                        .font(.subheadline.weight(.semibold))
                    Text("\(group.files.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                    let linked = linkedCandidates[file.name.lowercased()]
                    GatewayAccountRow(
                        file: file,
                        identity: manager.accountIdentity(for: file),
                        linkedCandidate: linked,
                        syncState: linked.map { manager.syncStatus(for: $0) },
                        syncMode: linked.flatMap { manager.syncMode(for: $0) },
                        isBusy: manager.isManagingAccounts,
                        onOpenDetail: { selectedDetail = file },
                        onRequestSync: requestSync,
                        onSetEnabled: { enabled in
                            Task { await manager.setAuthFile(file, disabled: !enabled) }
                        },
                        onSetSyncMode: { candidate, mode in
                            Task { await manager.setSyncMode(candidate, mode: mode) }
                        },
                        onAddToSubscription: {
                            Task { await addToSubscription(file) }
                        },
                        onDelete: { pendingDeletion = file },
                        showsAddToSubscription: file.gatewayProviderID.lowercased() == "codex"
                    )
                    if index < group.files.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
    }

    private func requestSync(_ candidate: CLIProxyAccountSyncCandidate) {
        switch manager.syncStatus(for: candidate) {
        case .cpaChanged, .conflict:
            pendingForceSync = candidate
        default:
            Task { await manager.syncAccount(candidate) }
        }
    }

    private func addToSubscription(_ file: CLIProxyAuthFile) async {
        let outcome = await CLIProxyGatewayManager.shared.addAuthFileToSubscriptionAccounts(file)
        await MainActor.run {
            switch outcome {
            case .added(let name):
                subscriptionBridgeNotice = L(
                    "Added \(name) to Subscription Accounts.",
                    "已将 \(name) 添加到订阅账号。"
                )
            case .alreadyPresent(let name):
                subscriptionBridgeNotice = L(
                    "\(name) is already in Subscription Accounts.",
                    "\(name) 已在订阅账号中，无需重复添加。"
                )
            case .unsupported:
                subscriptionBridgeNotice = L(
                    "This provider can’t be added to Subscription Accounts from CPA yet.",
                    "该服务商暂不支持从 CPA 添加到订阅账号。"
                )
            case .failed(let message):
                subscriptionBridgeNotice = message
            }
        }
    }

    // MARK: - Empty / Stopped

    private var serviceStoppedState: some View {
        GatewayCard {
            VStack(spacing: 14) {
                Image(systemName: "power.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(manager.isInstalled
                     ? L("Start CPA to load and manage its account pool", "启动 CPA 后即可载入并管理账号池")
                     : L("Install CPA to create an account pool", "安装 CPA 后即可创建账号池"))
                    .font(.headline)
                Text(L(
                    manager.isInstalled
                        ? "Your AIUsage subscription accounts are not changed when CPA is stopped."
                        : "AIUsage downloads and verifies the official macOS runtime before it is started.",
                    manager.isInstalled
                        ? "CPA 停止时，AIUsage 中的订阅账号不会受到影响。"
                        : "AIUsage 会先下载并校验官方 macOS 运行时，再启动服务。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                Button(manager.isInstalled ? L("Start CPA", "启动 CPA") : L("Install latest CPA", "安装最新版 CPA")) {
                    beginAccountPrerequisite()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.operation.isBusy || runtime.state.isTransitioning)
                if manager.operation.isBusy || runtime.state.isTransitioning {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private var emptyState: some View {
        GatewayCard {
            VStack(spacing: 14) {
                Image(systemName: query.isEmpty ? "person.2.badge.plus" : "magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(.indigo)
                Text(query.isEmpty
                     ? L("No upstreams in this view", "当前没有上游账号")
                     : L("No matching accounts", "没有匹配的账号"))
                    .font(.headline)
                Text(query.isEmpty
                     ? L("Add an upstream with CPA OAuth, an official plugin, an AIUsage copy, an API key, or a migrated auth file.", "可通过 CPA OAuth、官方插件、AIUsage 副本、API Key 或迁移认证文件添加上游。")
                     : L("Try a different search or status filter.", "请尝试其他搜索词或状态筛选。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if query.isEmpty {
                    Button(L("Add Upstream", "添加上游")) {
                        upstreamSection = .oauth
                        showAddAccount = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private var unsyncedCandidateCount: Int {
        GatewayAccountListLogic.unsyncedCandidateCount(manager: manager)
    }

    private func beginAccountPrerequisite() {
        Task {
            if !manager.isInstalled { await manager.installOrUpdateLatest() }
            guard manager.isInstalled else { return }
            await runtime.start()
            if runtime.state.isRunning { await manager.refreshAccounts() }
        }
    }
}
