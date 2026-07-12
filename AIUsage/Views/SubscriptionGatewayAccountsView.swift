import AppKit
import Foundation
import SwiftUI

// MARK: - CPA Account Center
// 账号中心只展示已经真实存在于 CPA 的上游（OAuth、插件、导入文件、AIUsage
// 托管副本、API 兼容上游）。尚未同步的 AIUsage 账号不再混入主列表，只保留
// 顶部“可从 AIUsage 接入 N 个账号”的紧凑入口，点击后进入“添加上游”向导的
// “从 AIUsage 接入”分区。

private enum GatewayAccountFilter: String, CaseIterable, Hashable {
    case all
    case ready
    case attention
    case paused
    case fromAIUsage

    var title: String {
        switch self {
        case .all: L("All", "全部")
        case .ready: L("Ready", "可用")
        case .attention: L("Attention", "异常")
        case .paused: L("Paused", "已停用")
        case .fromAIUsage: L("From AIUsage", "来自 AIUsage")
        }
    }
}

private struct GatewayAccountGroup: Identifiable {
    let providerID: String
    let files: [CLIProxyAuthFile]
    var id: String { providerID }
}

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

    var body: some View {
        let groups = filteredGroups
        let linkedCandidates = linkedCandidateByAuthFileName
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                errorBanners
                GatewaySectionTitle(
                    title: L("Account center", "账号中心"),
                    subtitle: L(
                        "Upstreams that actually exist in CPA: OAuth accounts, plugin accounts, imported auth files, AIUsage-managed copies, and API upstreams.",
                        "此处只展示真实存在于 CPA 的上游：OAuth 账号、插件账号、导入的认证文件、AIUsage 托管副本与 API 兼容上游。"
                    ),
                    actionTitle: L("Add Upstream", "添加上游"),
                    actionSystemImage: "plus"
                ) {
                    upstreamSection = .oauth
                    showAddAccount = true
                }

                summaryRow
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

    private var summaryRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
            summaryChip(
                value: manager.authFiles.count,
                title: L("in CPA", "CPA 账号"),
                icon: "person.2.fill",
                tint: .indigo
            )
            summaryChip(
                value: readyCount,
                title: L("ready", "可用"),
                icon: "checkmark.circle.fill",
                tint: .green
            )
            summaryChip(
                value: attentionCount,
                title: L("need attention", "需要处理"),
                icon: "exclamationmark.triangle.fill",
                tint: .orange
            )
            summaryChip(
                value: managedCopyCount,
                title: L("from AIUsage", "AIUsage 副本"),
                icon: "arrow.right.circle.fill",
                tint: .blue
            )
        }
    }

    /// The compact entry replacing candidate rows in the main list. It leads
    /// straight to the wizard's "From AIUsage" section, which only lists
    /// accounts with a verified conversion adapter.
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
        .padding(.vertical, 8)
        .frame(maxWidth: 290)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private var filterPicker: some View {
        Picker(L("Account filter", "账号筛选"), selection: $filter) {
            ForEach(GatewayAccountFilter.allCases, id: \.self) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 430)
        .accessibilityLabel(L("Account filter", "账号筛选"))
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

    private func providerGroup(
        _ group: GatewayAccountGroup,
        linkedCandidates: [String: CLIProxyAccountSyncCandidate]
    ) -> some View {
        GatewayCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    GatewayProviderIcon(providerID: group.providerID, size: 38)
                    Text(gatewayProviderDisplayName(group.providerID)).font(.headline)
                    Text("\(group.files.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider()

                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                    authRow(
                        file,
                        linkedCandidate: linkedCandidates[file.name.lowercased()]
                    )
                    if index < group.files.count - 1 {
                        Divider().padding(.leading, 70)
                    }
                }
            }
        }
    }

    private func authRow(
        _ file: CLIProxyAuthFile,
        linkedCandidate: CLIProxyAccountSyncCandidate?
    ) -> some View {
        let identitySummary = gatewayNativeIdentitySummary(manager.accountIdentity(for: file))
        return HStack(spacing: 13) {
            GatewayProviderIcon(providerID: file.gatewayProviderID, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 7) {
                    authStatusPill(file)
                    if let linkedCandidate {
                        syncStatePill(manager.syncStatus(for: linkedCandidate))
                    }
                }
                Text(file.gatewaySourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let identitySummary {
                    Text(identitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if file.gatewayNeedsAttention, let message = file.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let note = file.gatewayVisibleNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 13) {
                    if let priority = file.priority {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L("Priority", "优先级")).font(.caption2).foregroundStyle(.secondary)
                            Text("\(priority)").font(.caption.monospacedDigit())
                        }
                    }

                    if file.success > 0 || file.failed > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L("Requests", "请求")).font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                Text("✓ \(file.success)").foregroundStyle(.green)
                                if file.failed > 0 { Text("× \(file.failed)").foregroundStyle(.orange) }
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
                EmptyView()
            }

            if let linkedCandidate {
                Button {
                    requestSync(linkedCandidate)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help(L("Resync the AIUsage copy", "重新同步 AIUsage 副本"))
                .accessibilityLabel(L("Resync \(file.displayLabel)", "重新同步 \(file.displayLabel)"))
                .disabled(manager.isManagingAccounts)
            }

            Toggle(
                L("Enable \(file.displayLabel)", "启用 \(file.displayLabel)"),
                isOn: Binding(
                    get: { !file.disabled },
                    set: { enabled in Task { await manager.setAuthFile(file, disabled: !enabled) } }
                )
            )
            .labelsHidden()
            .accessibilityLabel(L("Enable account \(file.displayLabel)", "启用账号 \(file.displayLabel)"))
            .disabled(manager.isManagingAccounts)

            Button {
                selectedDetail = file
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help(L("Account details", "账号详情"))
            .accessibilityLabel(L("Show details for \(file.displayLabel)", "查看 \(file.displayLabel) 的详情"))

            Menu {
                Button {
                    selectedDetail = file
                } label: {
                    Label(L("Account Details", "账号详情"), systemImage: "info.circle")
                }
                if let linkedCandidate {
                    Button {
                        requestSync(linkedCandidate)
                    } label: {
                        Label(L("Resync from AIUsage", "从 AIUsage 重新同步"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Menu {
                        Button {
                            Task { await manager.setSyncMode(linkedCandidate, mode: .manualCopy) }
                        } label: {
                            if manager.syncMode(for: linkedCandidate) != .keepUpdated {
                                Label(L("Manual copy", "手动同步副本"), systemImage: "checkmark")
                            } else {
                                Text(L("Manual copy", "手动同步副本"))
                            }
                        }
                        Button {
                            Task { await manager.setSyncMode(linkedCandidate, mode: .keepUpdated) }
                        } label: {
                            if manager.syncMode(for: linkedCandidate) == .keepUpdated {
                                Label(L("Keep updated", "保持单向同步"), systemImage: "checkmark")
                            } else {
                                Text(L("Keep updated", "保持单向同步"))
                            }
                        }
                    } label: {
                        Label(L("Sync mode", "同步模式"), systemImage: "arrow.left.arrow.right")
                    }
                }
                Divider()
                Button(role: .destructive) { pendingDeletion = file } label: {
                    Label(L("Remove from CPA", "从 CPA 删除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L("More actions for \(file.displayLabel)", "\(file.displayLabel) 的更多操作"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .onTapGesture { selectedDetail = file }
        .accessibilityAction(named: L("Show account details", "查看账号详情")) {
            selectedDetail = file
        }
    }

    private func authStatusPill(_ file: CLIProxyAuthFile) -> some View {
        if file.disabled {
            return GatewayStatusPill(text: L("Paused", "已停用"), color: .secondary, systemImage: "pause.circle.fill")
        }
        if file.gatewayNeedsAttention {
            return GatewayStatusPill(text: L("Attention", "需要处理"), color: .orange, systemImage: "exclamationmark.triangle.fill")
        }
        if file.gatewayProviderID == "unknown" {
            return GatewayStatusPill(text: L("Unrecognized · review", "无法识别 · 需要检查"), color: .orange, systemImage: "questionmark.circle.fill")
        }
        let text = file.status?.isEmpty == false ? file.status!.capitalized : L("Ready", "可用")
        return GatewayStatusPill(text: text, color: .green, systemImage: "checkmark.circle.fill")
    }

    private func syncStatePill(_ state: CLIProxyAccountSyncState) -> GatewayStatusPill {
        switch state {
        case .notSynced:
            return GatewayStatusPill(text: L("Not connected", "未接入"), color: .secondary, systemImage: "circle")
        case .current:
            return GatewayStatusPill(text: L("Synced", "副本最新"), color: .blue, systemImage: "checkmark.circle.fill")
        case .sourceChanged:
            return GatewayStatusPill(text: L("AIUsage changed", "AIUsage 已更新"), color: .orange, systemImage: "arrow.up.circle.fill")
        case .cpaChanged:
            return GatewayStatusPill(text: L("CPA changed", "CPA 副本已修改"), color: .orange, systemImage: "pencil.circle.fill")
        case .conflict:
            return GatewayStatusPill(text: L("Sync conflict", "同步冲突"), color: .red, systemImage: "exclamationmark.triangle.fill")
        case .missing:
            return GatewayStatusPill(text: L("CPA copy missing", "CPA 副本缺失"), color: .orange, systemImage: "questionmark.circle.fill")
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
                Text(query.isEmpty ? L("No upstreams in this view", "当前没有上游账号") : L("No matching accounts", "没有匹配的账号"))
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

    private var filteredGroups: [GatewayAccountGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let files = manager.authFiles.filter { file in
            let searchText = [file.displayLabel, file.displayProvider, file.name, file.note ?? ""]
                .joined(separator: " ").lowercased()
            let matchesSearch = normalizedQuery.isEmpty || searchText.contains(normalizedQuery)
            guard matchesSearch else { return false }
            switch filter {
            case .all: return true
            case .ready: return !file.disabled && !file.gatewayNeedsAttention
            case .attention: return file.gatewayNeedsAttention
            case .paused: return file.disabled
            case .fromAIUsage: return file.name.lowercased().hasPrefix("aiusage-")
            }
        }
        return Dictionary(grouping: files, by: \.gatewayProviderID)
            .map { GatewayAccountGroup(providerID: $0.key, files: $0.value) }
            .sorted {
                gatewayProviderDisplayName($0.providerID)
                    .localizedStandardCompare(gatewayProviderDisplayName($1.providerID)) == .orderedAscending
            }
    }

    private var linkedCandidateByAuthFileName: [String: CLIProxyAccountSyncCandidate] {
        let candidatesByIdentity = manager.syncCandidates.reduce(
            into: [String: CLIProxyAccountSyncCandidate]()
        ) { result, candidate in
            result["\(candidate.providerId.lowercased()):\(candidate.credentialId.lowercased())"] = candidate
        }
        var result: [String: CLIProxyAccountSyncCandidate] = [:]
        for record in manager.syncRecords {
            let identity = "\(record.providerId.lowercased()):\(record.credentialId.lowercased())"
            if let candidate = candidatesByIdentity[identity] {
                result[record.authFileName.lowercased()] = candidate
            }
        }
        for candidate in manager.syncCandidates {
            let fileName = manager.authFileName(for: candidate).lowercased()
            if result[fileName] == nil { result[fileName] = candidate }
        }
        return result
    }

    private var readyCount: Int {
        manager.authFiles.filter { !$0.disabled && !$0.gatewayNeedsAttention }.count
    }

    private var attentionCount: Int {
        manager.authFiles.filter(\.gatewayNeedsAttention).count
            + manager.authDeduplicationConflictCount
            + (manager.syncManifestError == nil ? 0 : 1)
    }

    private var managedCopyCount: Int {
        manager.authFiles.filter { $0.name.lowercased().hasPrefix("aiusage-") }.count
    }

    private var unsyncedCandidateCount: Int {
        manager.syncCandidates.filter { candidate in
            guard case .compatible = candidate.compatibility else { return false }
            return !manager.isSynced(candidate)
        }.count
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

private extension CLIProxyAuthFile {
    var gatewayVisibleNote: String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        let normalized = note.lowercased()
        if normalized == "synced from aiusage" || normalized == "来自 aiusage 的同步副本" {
            return nil
        }
        return note
    }
}
