import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum GatewayAccountFilter: String, CaseIterable, Hashable {
    case all
    case ready
    case attention
    case paused
    case available

    var title: String {
        switch self {
        case .all: L("All", "全部")
        case .ready: L("Ready", "可用")
        case .attention: L("Attention", "异常")
        case .paused: L("Paused", "已停用")
        case .available: L("From AIUsage", "来自 AIUsage")
        }
    }
}

private enum GatewayAccountItem: Identifiable {
    case auth(CLIProxyAuthFile)
    case candidate(CLIProxyAccountSyncCandidate)

    var id: String {
        switch self {
        case .auth(let file): "auth:\(file.id)"
        case .candidate(let candidate): "candidate:\(candidate.id)"
        }
    }

    var providerID: String {
        switch self {
        case .auth(let file): file.gatewayProviderID
        case .candidate(let candidate): candidate.providerId
        }
    }

    var searchText: String {
        switch self {
        case .auth(let file):
            [file.displayLabel, file.displayProvider, file.name, file.note ?? ""]
                .joined(separator: " ").lowercased()
        case .candidate(let candidate):
            "\(candidate.label) \(candidate.providerId)".lowercased()
        }
    }
}

private struct GatewayAccountGroup: Identifiable {
    let providerID: String
    let items: [GatewayAccountItem]
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

    var body: some View {
        let groups = filteredGroups
        let linkedCandidates = linkedCandidateByAuthFileName
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                errorBanners
                GatewaySectionTitle(
                    title: L("Account center", "账号中心"),
                    subtitle: L(
                        "CPA and eligible AIUsage accounts share one list. Verified managed copies are reconciled by native identity; conflicting copies stay visible for review.",
                        "CPA 账号与可接入的 AIUsage 账号共用一个列表；已验证副本按原生身份收敛，冲突副本会保留供检查。"
                    ),
                    actionTitle: L("Add Account", "添加账号"),
                    actionSystemImage: "plus"
                ) { showAddAccount = true }

                summaryRow
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
            CLIProxyAddAccountSheet(manager: manager, runtime: runtime)
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
                value: unsyncedCandidateCount,
                title: L("available from AIUsage", "可从 AIUsage 接入"),
                icon: "arrow.right.circle.fill",
                tint: .blue
            )
        }
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
                    Text(providerDisplayName(group.providerID)).font(.headline)
                    Text("\(group.items.count)")
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

                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case .auth(let file):
                        authRow(
                            file,
                            linkedCandidate: linkedCandidates[file.name.lowercased()]
                        )
                    case .candidate(let candidate): candidateRow(candidate)
                    }
                    if index < group.items.count - 1 {
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

    private func candidateRow(_ candidate: CLIProxyAccountSyncCandidate) -> some View {
        HStack(spacing: 13) {
            GatewayProviderIcon(providerID: candidate.providerId, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(candidate.label).font(.subheadline.weight(.semibold))
                    if manager.syncStatus(for: candidate) == .missing {
                        syncStatePill(.missing)
                    } else {
                        GatewayStatusPill(
                            text: L("AIUsage source", "AIUsage 来源"),
                            color: .blue,
                            systemImage: "arrow.right.circle.fill"
                        )
                    }
                }
                if let identitySummary = gatewayNativeIdentitySummary(candidate.accountIdentity) {
                    Text(identitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                switch candidate.compatibility {
                case .compatible:
                    Text(L(
                        "Ready to copy into CPA. The original account remains managed by AIUsage.",
                        "可复制到 CPA；原账号仍由 AIUsage 管理。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .unsupported(let reason):
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            switch candidate.compatibility {
            case .compatible:
                Button(manager.syncStatus(for: candidate) == .missing
                       ? L("Restore CPA Copy", "恢复 CPA 副本")
                       : L("Connect to CPA", "接入 CPA")) {
                    Task { await manager.syncAccount(candidate) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(manager.isManagingAccounts)
            case .unsupported:
                GatewayStatusPill(
                    text: L("Use CPA sign-in", "请使用 CPA 登录"),
                    color: .secondary,
                    systemImage: "info.circle"
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func authStatusPill(_ file: CLIProxyAuthFile) -> some View {
        if file.disabled {
            return GatewayStatusPill(text: L("Paused", "已停用"), color: .secondary, systemImage: "pause.circle.fill")
        }
        if file.gatewayNeedsAttention {
            return GatewayStatusPill(text: L("Attention", "需要处理"), color: .orange, systemImage: "exclamationmark.triangle.fill")
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
                Text(query.isEmpty ? L("No accounts in this view", "当前没有账号") : L("No matching accounts", "没有匹配的账号"))
                    .font(.headline)
                Text(query.isEmpty
                     ? L("Add an account with CPA OAuth, AIUsage sync, or a credential file.", "可通过 CPA OAuth、AIUsage 同步或凭据文件添加账号。")
                     : L("Try a different search or status filter.", "请尝试其他搜索词或状态筛选。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if query.isEmpty {
                    Button(L("Add Account", "添加账号")) { showAddAccount = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private var allItems: [GatewayAccountItem] {
        let authItems = manager.authFiles.map(GatewayAccountItem.auth)
        let unsynced = manager.syncCandidates
            .filter { !manager.isSynced($0) }
            .map(GatewayAccountItem.candidate)
        return authItems + unsynced
    }

    private var filteredGroups: [GatewayAccountGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = allItems.filter { item in
            let matchesSearch = normalizedQuery.isEmpty || item.searchText.contains(normalizedQuery)
            guard matchesSearch else { return false }
            switch (filter, item) {
            case (.all, _): return true
            case (.ready, .auth(let file)): return !file.disabled && !file.gatewayNeedsAttention
            case (.attention, .auth(let file)): return file.gatewayNeedsAttention
            case (.paused, .auth(let file)): return file.disabled
            case (.available, .candidate): return true
            default: return false
            }
        }
        return Dictionary(grouping: items, by: \.providerID)
            .map { GatewayAccountGroup(providerID: $0.key, items: $0.value) }
            .sorted { providerDisplayName($0.providerID).localizedStandardCompare(providerDisplayName($1.providerID)) == .orderedAscending }
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
    private var unsyncedCandidateCount: Int { manager.syncCandidates.filter { !manager.isSynced($0) }.count }

    private func beginAccountPrerequisite() {
        Task {
            if !manager.isInstalled { await manager.installOrUpdateLatest() }
            guard manager.isInstalled else { return }
            await runtime.start()
            if runtime.state.isRunning { await manager.refreshAccounts() }
        }
    }
}

private struct CLIProxyAddAccountSheet: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var showCustomProvider = false
    @State private var importError: String?

    private let providerColumns = [GridItem(.adaptive(minimum: 175), spacing: 11)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                ProviderIconView("cliproxyapi", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Add an account", "添加账号")).font(.title2.weight(.bold))
                    Text(L("Choose where the credential comes from.", "选择账号凭据的来源。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done", "完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(manager.oauthFlowState.isActive)
                    .help(manager.oauthFlowState.isActive
                          ? L("Cancel the active sign-in before closing.", "请先取消正在进行的登录。")
                          : L("Close", "关闭"))
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !runtime.state.isRunning { stoppedBanner }
                    if manager.oauthFlowState.isActive { oauthProgressCard }
                    else { oauthOutcomeCard }
                    if let importError { GatewayErrorBanner(message: importError) }
                    if let error = manager.lastError,
                       error != importError,
                       !oauthFlowStateContainsError {
                        GatewayErrorBanner(message: error)
                    }

                    addSection(
                        title: L("Sign in with CPA", "通过 CPA 登录"),
                        subtitle: L(
                            "These five providers are built into the installed official CPA runtime.",
                            "以下五种登录由当前安装的官方 CPA 运行时内置支持。"
                        )
                    ) {
                        LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 11) {
                            ForEach(CLIProxyOAuthProvider.allCases) { provider in
                                oauthProviderCard(provider)
                            }
                        }
                    }

                    if shouldShowPluginProviders {
                        pluginProviderSection
                    }

                    addSection(
                        title: L("Connect an existing AIUsage account", "接入现有 AIUsage 账号"),
                        subtitle: L(
                            "AIUsage sends a one-way credential copy to CPA. The original account and its monitoring remain unchanged.",
                            "AIUsage 会向 CPA 发送单向凭据副本；原账号及其监控不会改变。"
                        )
                    ) {
                        if manager.syncCandidates.isEmpty {
                            Text(L("No managed credential-backed accounts were found.", "没有找到带托管凭据的账号。"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(manager.syncCandidates.enumerated()), id: \.element.id) { index, candidate in
                                    syncCandidateRow(candidate)
                                    if index < manager.syncCandidates.count - 1 { Divider() }
                                }
                            }
                        }
                    }

                    addSection(
                        title: L("Import a CPA credential file", "导入 CPA 凭据文件"),
                        subtitle: L(
                            "Use a JSON auth file produced for CPA, including provider types that do not offer built-in OAuth here.",
                            "导入为 CPA 生成的 JSON 认证文件，也可覆盖此处没有内置 OAuth 的提供商类型。"
                        )
                    ) {
                        HStack(spacing: 13) {
                            Image(systemName: "doc.badge.plus")
                                .font(.title2)
                                .foregroundStyle(.indigo)
                                .frame(width: 42, height: 42)
                                .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("Import auth JSON", "导入认证 JSON")).font(.subheadline.weight(.semibold))
                                Text(L("Validated locally, then uploaded through CPA's loopback Management API.", "先在本地校验，再通过 CPA 本机 Management API 上传。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Choose File…", "选择文件…")) { showImporter = true }
                                .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                        }
                    }

                    addSection(
                        title: L("Add an API-compatible upstream", "添加 API 兼容上游"),
                        subtitle: L(
                            "Bring an OpenAI-compatible API key into the same CPA routing pool. The key is sent only to the loopback Management API and is never displayed again.",
                            "将 OpenAI 兼容 API Key 加入同一个 CPA 路由池。密钥只发送到本机 Management API，之后不会再次显示。"
                        )
                    ) {
                        HStack(spacing: 13) {
                            Image(systemName: "key.horizontal.fill")
                                .font(.title2)
                                .foregroundStyle(.teal)
                                .frame(width: 42, height: 42)
                                .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("OpenAI-compatible provider", "OpenAI 兼容提供商")).font(.subheadline.weight(.semibold))
                                Text(L("Name, base URL, API key, model IDs, prefix, and priority.", "配置名称、Base URL、API Key、模型 ID、前缀和优先级。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Configure…", "配置…")) { showCustomProvider = true }
                                .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                        }
                    }

                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text(L(
                            "CPA can also expose API-key and plugin providers. AIUsage only presents methods verified against the installed CPA build; imported records still appear in the same account center.",
                            "CPA 还可提供 API Key 与插件提供商。AIUsage 只展示经当前 CPA 构建验证的方法；导入后的记录仍会统一出现在账号中心。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
        }
        .frame(minWidth: 620, idealWidth: 740, maxWidth: 780,
               minHeight: 480, idealHeight: 620, maxHeight: 690)
        .interactiveDismissDisabled(manager.oauthFlowState.isActive)
        .task {
            if runtime.state.isRunning {
                await manager.refreshProviderPlugins(includeStore: true)
            }
        }
        .sheet(isPresented: $showCustomProvider) {
            CLIProxyCustomProviderSheet(manager: manager)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importError = nil
                Task {
                    await manager.importAuthFile(from: url)
                    importError = manager.lastError
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var stoppedBanner: some View {
        HStack(spacing: 13) {
            Image(systemName: "power.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.isInstalled
                     ? L("CPA must be running to add an account", "添加账号前需要启动 CPA")
                     : L("Install CPA before adding an account", "添加账号前需要安装 CPA"))
                    .font(.subheadline.weight(.semibold))
                Text(manager.isInstalled
                     ? L("The service remains local to this Mac.", "服务仍只在本机运行。")
                     : L("AIUsage verifies the official macOS runtime before starting it.", "AIUsage 会先校验官方 macOS 运行时，再启动服务。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(manager.isInstalled ? L("Start CPA", "启动 CPA") : L("Install CPA", "安装 CPA")) {
                Task {
                    if !manager.isInstalled { await manager.installOrUpdateLatest() }
                    guard manager.isInstalled else { return }
                    await runtime.start()
                    if runtime.state.isRunning { await manager.refreshAccounts() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.operation.isBusy || runtime.state.isTransitioning)
        }
        .padding(15)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.orange.opacity(0.16)))
    }

    private var shouldShowPluginProviders: Bool {
        manager.isManagingPlugins || manager.pluginError != nil
            || !manager.providerPlugins.isEmpty || !manager.providerPluginStore.isEmpty
    }

    private var pluginProviderSection: some View {
        addSection(
            title: L("Provider plugins detected from CPA", "CPA 动态提供商插件"),
            subtitle: L(
                "This list is read from the installed CPA build and its official plugin store; it is not a hard-coded promise. Installing a plugin enables CPA plugins and restarts the local service.",
                "此列表来自当前 CPA 构建及其官方插件商店，并非硬编码承诺。安装插件会启用 CPA 插件并重启本地服务。"
            )
        ) {
            VStack(alignment: .leading, spacing: 11) {
                if let pluginError = manager.pluginError {
                    GatewayErrorBanner(message: pluginError)
                }
                if manager.isManagingPlugins && manager.providerPluginStore.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(L("Loading provider capabilities from CPA…", "正在从 CPA 载入提供商能力…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                } else {
                    LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 11) {
                        ForEach(manager.providerPluginStore) { entry in
                            pluginStoreCard(entry)
                        }
                        ForEach(unlistedProviderPlugins) { plugin in
                            installedPluginCard(plugin)
                        }
                    }
                }
            }
        }
    }

    private func pluginStoreCard(_ entry: CLIProxyPluginStoreEntry) -> some View {
        let plugin = manager.providerPlugins.first { $0.id == entry.id }
        let isReady = plugin?.effectiveEnabled == true && plugin?.supportsOAuth == true
        let repositoryURL: URL? = URL(string: entry.repository).flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
            return url
        }
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                GatewayProviderIcon(providerID: plugin?.providerID ?? entry.id, size: 42)
                Spacer()
                GatewayStatusPill(
                    text: isReady ? L("Plugin OAuth", "插件 OAuth") : L("Optional plugin", "可选插件"),
                    color: isReady ? .purple : .secondary,
                    systemImage: isReady ? "puzzlepiece.extension.fill" : "puzzlepiece.extension"
                )
            }
            Text(entry.name).font(.subheadline.weight(.semibold))
            Text(entry.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack(spacing: 6) {
                if !entry.author.isEmpty { Text(entry.author) }
                if !entry.sourceID.isEmpty { Text("· \(entry.sourceID)") }
                if let repositoryURL {
                    Text("·")
                    Link(L("Source", "源码"), destination: repositoryURL)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack {
                Text("v\(entry.installedVersion?.nilIfBlank ?? entry.version)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if isReady, let plugin {
                    Button(L("Sign In", "登录")) { Task { await manager.beginPluginOAuth(plugin) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if let plugin, entry.installed {
                    Button(L("Enable", "启用")) { Task { await manager.setProviderPlugin(plugin, enabled: true) } }
                        .controlSize(.small)
                } else {
                    Button(entry.updateAvailable ? L("Update", "更新") : L("Install", "安装")) {
                        Task { await manager.installProviderPlugin(entry) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
        .disabled(manager.isManagingPlugins || manager.isManagingAccounts)
    }

    private func installedPluginCard(_ plugin: CLIProxyPlugin) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                GatewayProviderIcon(providerID: plugin.providerID, size: 42)
                Spacer()
                GatewayStatusPill(
                    text: plugin.effectiveEnabled ? L("Plugin OAuth", "插件 OAuth") : L("Disabled", "未启用"),
                    color: plugin.effectiveEnabled ? .purple : .secondary,
                    systemImage: "puzzlepiece.extension.fill"
                )
            }
            Text(plugin.displayName).font(.subheadline.weight(.semibold))
            Text(L("Dynamically registered by the installed CPA runtime.", "由当前 CPA 运行时动态注册。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack {
                Spacer()
                if plugin.effectiveEnabled {
                    Button(L("Sign In", "登录")) { Task { await manager.beginPluginOAuth(plugin) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button(L("Enable", "启用")) { Task { await manager.setProviderPlugin(plugin, enabled: true) } }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
        .disabled(manager.isManagingPlugins || manager.isManagingAccounts)
    }

    private var unlistedProviderPlugins: [CLIProxyPlugin] {
        let storeIDs = Set(manager.providerPluginStore.map(\.id))
        return manager.providerPlugins.filter { !storeIDs.contains($0.id) }
    }

    private var oauthProgressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                if let provider = manager.oauthProvider {
                    GatewayProviderIcon(providerID: provider.gatewayProviderID, size: 42)
                } else if let plugin = manager.oauthPlugin {
                    GatewayProviderIcon(providerID: plugin.providerID, size: 42)
                }
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Waiting for authorization", "等待授权"))
                        .font(.subheadline.weight(.semibold))
                    Text(manager.oauthStatusMessage ?? L("Complete sign-in in the browser.", "请在浏览器中完成登录。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = manager.oauthSession?.url {
                    Button(L("Open Browser", "打开浏览器")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless)
                }
                Button(L("Cancel", "取消"), role: .cancel) {
                    Task { await manager.cancelOAuth() }
                }
                .disabled(!manager.oauthFlowState.isActive)
            }
            if let code = manager.oauthSession?.userCode, !code.isEmpty {
                GatewayCopyField(label: L("Device code", "设备码"), value: code)
            }
        }
        .padding(15)
        .background(Color.blue.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.blue.opacity(0.16)))
    }

    @ViewBuilder
    private var oauthOutcomeCard: some View {
        switch manager.oauthFlowState {
        case .succeeded(let provider):
            oauthOutcome(
                title: L("\(provider.gatewayDisplayName) connected", "\(provider.gatewayDisplayName) 已接入"),
                detail: L("The account is now available in the CPA pool.", "该账号现在已加入 CPA 账号池。"),
                color: .green,
                icon: "checkmark.circle.fill"
            )
        case .pluginSucceeded(let name):
            oauthOutcome(
                title: L("\(name) connected", "\(name) 已接入"),
                detail: L("The plugin account is now available in the CPA pool.", "插件账号现在已加入 CPA 账号池。"),
                color: .green,
                icon: "checkmark.circle.fill"
            )
        case .failed(_, let message), .pluginFailed(_, let message):
            oauthOutcome(
                title: L("Sign-in failed", "登录失败"),
                detail: message,
                color: .orange,
                icon: "exclamationmark.triangle.fill"
            )
        case .cancelled:
            oauthOutcome(
                title: L("Sign-in cancelled", "登录已取消"),
                detail: L("No CPA account was changed.", "CPA 账号没有发生变化。"),
                color: .secondary,
                icon: "xmark.circle"
            )
        default:
            EmptyView()
        }
    }

    private func oauthOutcome(title: String, detail: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(15)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(color.opacity(0.16)))
        .accessibilityElement(children: .combine)
    }

    private var oauthFlowStateContainsError: Bool {
        switch manager.oauthFlowState {
        case .failed, .pluginFailed: true
        default: false
        }
    }

    private func oauthProviderCard(_ provider: CLIProxyOAuthProvider) -> some View {
        Button {
            Task { await manager.beginOAuth(provider) }
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    GatewayProviderIcon(providerID: provider.gatewayProviderID, size: 42)
                    Spacer()
                    GatewayStatusPill(text: "OAuth", color: .blue, systemImage: nil)
                }
                Text(provider.gatewayDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(provider.gatewaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
    }

    private func syncCandidateRow(_ candidate: CLIProxyAccountSyncCandidate) -> some View {
        HStack(spacing: 12) {
            GatewayProviderIcon(providerID: candidate.providerId, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.label).font(.subheadline.weight(.semibold))
                Text(providerDisplayName(candidate.providerId))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isSynced(candidate) {
                addSheetSyncPill(manager.syncStatus(for: candidate))
                switch manager.syncStatus(for: candidate) {
                case .cpaChanged, .conflict:
                    Button(L("Review", "查看处理")) { dismiss() }
                        .buttonStyle(.borderless)
                default:
                    Button(manager.syncStatus(for: candidate) == .sourceChanged
                           ? L("Update Copy", "更新副本")
                           : L("Resync", "重新同步")) {
                        Task { await manager.syncAccount(candidate) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                }
                Menu {
                    Button {
                        Task { await manager.setSyncMode(candidate, mode: .manualCopy) }
                    } label: {
                        Label(L("Manual copy", "手动同步"),
                              systemImage: manager.syncMode(for: candidate) == .keepUpdated ? "circle" : "checkmark")
                    }
                    Button {
                        Task { await manager.setSyncMode(candidate, mode: .keepUpdated) }
                    } label: {
                        Label(L("Keep updated", "保持单向同步"),
                              systemImage: manager.syncMode(for: candidate) == .keepUpdated ? "checkmark" : "circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
            } else {
                switch candidate.compatibility {
                case .compatible:
                    Button(L("Connect", "接入")) { Task { await manager.syncAccount(candidate) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                case .unsupported(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 270, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func addSheetSyncPill(_ state: CLIProxyAccountSyncState) -> GatewayStatusPill {
        switch state {
        case .current:
            return GatewayStatusPill(text: L("Up to date", "副本最新"), color: .green, systemImage: "checkmark.circle.fill")
        case .sourceChanged:
            return GatewayStatusPill(text: L("Source changed", "源凭据已更新"), color: .orange, systemImage: "arrow.up.circle.fill")
        case .cpaChanged:
            return GatewayStatusPill(text: L("CPA changed", "CPA 副本已修改"), color: .orange, systemImage: "pencil.circle.fill")
        case .conflict:
            return GatewayStatusPill(text: L("Conflict", "同步冲突"), color: .red, systemImage: "exclamationmark.triangle.fill")
        case .missing:
            return GatewayStatusPill(text: L("Missing", "副本缺失"), color: .orange, systemImage: "questionmark.circle.fill")
        case .notSynced:
            return GatewayStatusPill(text: L("Not connected", "未接入"), color: .secondary, systemImage: "circle")
        }
    }

    private func addSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(18)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.055)))
    }

}

private struct CLIProxyCustomProviderSheet: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelText = ""
    @State private var prefix = ""
    @State private var priority = 0
    @State private var isSaving = false
    @State private var formError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)
                    .frame(width: 44, height: 44)
                    .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("OpenAI-compatible upstream", "OpenAI 兼容上游")).font(.title3.weight(.bold))
                    Text(L("Add an API-key provider to CPA's routing pool.", "将 API Key 提供商加入 CPA 路由池。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if let formError { GatewayErrorBanner(message: formError) }

                    formField(
                        title: L("Provider name", "提供商名称"),
                        detail: L("A unique local name, for example My Team Gateway.", "唯一的本地名称，例如“团队网关”。")
                    ) {
                        TextField(L("My Provider", "我的提供商"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    formField(
                        title: "Base URL",
                        detail: L("Full HTTP(S) endpoint, usually ending in /v1.", "完整 HTTP(S) 端点，通常以 /v1 结尾。")
                    ) {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    formField(
                        title: "API Key",
                        detail: L("Sent only to CPA's loopback Management API. AIUsage does not add it to logs or the sync manifest.", "只发送到 CPA 本机 Management API；AIUsage 不会把它写入日志或同步清单。")
                    ) {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    formField(
                        title: L("Upstream model IDs", "上游模型 ID"),
                        detail: L("Separate multiple models with commas or new lines.", "多个模型可用逗号或换行分隔。")
                    ) {
                        TextEditor(text: $modelText)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 82)
                            .padding(7)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.09)))
                    }

                    HStack(alignment: .top, spacing: 16) {
                        formField(
                            title: L("Optional model prefix", "可选模型前缀"),
                            detail: L("Namespaces models when providers overlap.", "模型重名时用于命名空间隔离。")
                        ) {
                            TextField("team-a", text: $prefix).textFieldStyle(.roundedBorder)
                        }
                        formField(
                            title: L("Priority", "优先级"),
                            detail: L("Higher values are preferred.", "数值越高，选择优先级越高。")
                        ) {
                            Stepper(value: $priority, in: -100...100) {
                                Text("\(priority)").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                        .frame(width: 170)
                    }

                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                        Text(L(
                            "AIUsage first reads the current CPA provider list, rejects duplicate names, then appends this provider without replacing existing entries.",
                            "AIUsage 会先读取 CPA 当前提供商列表并拒绝重复名称，再追加此提供商，不会覆盖已有配置。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Add Provider", "添加提供商")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
            }
            .padding(16)
        }
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 650,
               minHeight: 460, idealHeight: 600, maxHeight: 670)
    }

    private func formField<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelIDs: [String] {
        modelText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelIDs.isEmpty
    }

    private func save() {
        isSaving = true
        formError = nil
        Task {
            await manager.addOpenAICompatibleProvider(
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                modelIDs: modelIDs,
                prefix: prefix,
                priority: priority
            )
            isSaving = false
            if let error = manager.lastError { formError = error }
            else {
                apiKey = ""
                dismiss()
            }
        }
    }
}

private struct CLIProxyAccountDetailSheet: View {
    let file: CLIProxyAuthFile
    @ObservedObject var manager: CLIProxyGatewayManager
    @Binding var pendingDeletion: CLIProxyAuthFile?
    @Environment(\.dismiss) private var dismiss

    @State private var draftNote: String
    @State private var draftPriority: Int
    @State private var showAllModels = false
    @State private var operationError: String?
    @State private var isUpdating = false
    @State private var isLoadingModels = false

    init(
        file: CLIProxyAuthFile,
        manager: CLIProxyGatewayManager,
        pendingDeletion: Binding<CLIProxyAuthFile?>
    ) {
        self.file = file
        self.manager = manager
        self._pendingDeletion = pendingDeletion
        self._draftNote = State(initialValue: file.note ?? "")
        self._draftPriority = State(initialValue: file.priority ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                GatewayProviderIcon(providerID: file.gatewayProviderID, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentFile.displayLabel).font(.title3.weight(.bold))
                    Text(gatewayAccountIdentitySubtitle(
                        providerID: currentFile.gatewayProviderID,
                        identity: currentIdentity
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let operationError { GatewayErrorBanner(message: operationError) }
                    HStack(spacing: 10) {
                        detailMetric(
                            value: "\(currentFile.success)",
                            title: L("Successful", "成功请求"),
                            icon: "checkmark.circle.fill",
                            tint: .green
                        )
                        detailMetric(
                            value: "\(currentFile.failed)",
                            title: L("Failed", "失败请求"),
                            icon: "xmark.circle.fill",
                            tint: currentFile.failed > 0 ? .orange : .secondary
                        )
                        detailMetric(
                            value: "\(models.count)",
                            title: L("Models", "可用模型"),
                            icon: "square.stack.3d.up.fill",
                            tint: .indigo
                        )
                    }

                    GatewayCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("Account status", "账号状态")).font(.headline)
                            detailRow(L("Status", "状态"), currentFile.disabled ? L("Paused", "已停用") : (currentFile.status ?? L("Ready", "可用")))
                            detailRow(L("Source", "来源"), currentFile.gatewaySourceTitle)
                            if let message = currentFile.statusMessage, !message.isEmpty {
                                detailRow(L("Status detail", "状态详情"), message)
                            }
                            if let plan = currentIdentity?.planDisplayName {
                                detailRow(L("Plan", "套餐"), plan)
                            }
                            if let accountID = currentIdentity?.accountID {
                                detailRow(L("Workspace ID", "工作区 ID"), accountID)
                            }
                            if let projectID = currentIdentity?.projectID {
                                detailRow(L("Project ID", "项目 ID"), projectID)
                            }
                            if let accountType = currentFile.accountType { detailRow(L("Account type", "账号类型"), accountType) }
                            if currentIdentity?.projectID == nil, let projectID = currentFile.projectID {
                                detailRow(L("Project", "项目"), projectID)
                            }
                            if let refreshed = currentFile.lastRefresh {
                                detailRow(L("Last refresh", "上次刷新"), refreshed.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let nextRetry = currentFile.nextRetryAfter {
                                detailRow(L("Next retry", "下次重试"), nextRetry.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }

                    if !currentFile.runtimeOnly {
                        GatewayCard {
                            VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Routing metadata", "路由元数据")).font(.headline)
                                Text(L(
                                    "Priority and notes are stored by CPA; credential tokens are never shown or edited here.",
                                    "优先级和备注由 CPA 保存；此处永远不会显示或编辑凭据 Token。"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("Note", "备注")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    TextField(L("Optional account note", "可选账号备注"), text: $draftNote)
                                        .textFieldStyle(.roundedBorder)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("Priority", "优先级")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Stepper(value: $draftPriority, in: -100...100) {
                                        Text("\(draftPriority)").monospacedDigit().frame(width: 36, alignment: .trailing)
                                    }
                                }
                                .frame(width: 125)
                            }
                                HStack {
                                    Spacer()
                                    Button(L("Save Metadata", "保存元数据")) {
                                        isUpdating = true
                                        operationError = nil
                                        Task {
                                            await manager.updateAuthFile(currentFile, note: draftNote, priority: draftPriority)
                                            operationError = manager.lastError
                                            isUpdating = false
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!metadataChanged || manager.isManagingAccounts || isUpdating)
                                }
                            }
                        }
                    } else {
                        GatewayCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("Provider configuration", "提供商配置")).font(.headline)
                                Text(L(
                                    "This is a CPA runtime provider. Enable/disable and deletion use the provider configuration API; auth-file notes are not applicable.",
                                    "这是 CPA 运行时提供商。启停和删除会使用提供商配置 API，认证文件备注不适用。"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GatewayCard {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L("Models available to this account", "该账号可用模型")).font(.headline)
                                    Text(L("Loaded dynamically from CPA for this credential.", "由 CPA 针对此凭据动态返回。"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    loadModels(force: true)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help(L("Refresh account models", "刷新账号模型"))
                                .accessibilityLabel(L("Refresh models", "刷新模型"))
                            }
                            if let modelError = manager.authFileModelErrors[currentFile.name] {
                                GatewayErrorBanner(message: modelError)
                            } else if isLoadingModels {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(L("Loading account models…", "正在加载账号模型…"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            } else if models.isEmpty {
                                Text(L("CPA reported no models for this account.", "CPA 未返回该账号的可用模型。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                                        HStack {
                                            Image(systemName: "cube").foregroundStyle(.secondary).frame(width: 20)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(model.displayName ?? model.id).font(.callout.weight(.medium))
                                                if model.displayName != nil { Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                            }
                                            Spacer()
                                            if let ownedBy = model.ownedBy { Text(ownedBy).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        .padding(.vertical, 8)
                                        if index < visibleModels.count - 1 { Divider() }
                                    }
                                }
                                if models.count > 8 {
                                    Button(showAllModels ? L("Show Less", "收起") : L("Show All \(models.count)", "显示全部 \(models.count) 个")) {
                                        showAllModels.toggle()
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                    GatewayCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("Technical details", "技术详情")).font(.headline)
                            detailRow(L("Provider", "提供商"), currentFile.displayProvider)
                            detailRow(L("CPA auth file", "CPA 认证文件"), currentFile.name)
                            if let authIndex = currentFile.authIndex { detailRow(L("Auth index", "Auth Index"), authIndex) }
                            if let source = currentFile.source { detailRow(L("CPA source", "CPA 来源"), source) }
                            if let size = currentFile.size { detailRow(L("File size", "文件大小"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        }
                    }
                    HStack {
                        Button(currentFile.disabled ? L("Enable Account", "启用账号") : L("Pause Account", "停用账号")) {
                            isUpdating = true
                            operationError = nil
                            Task {
                                await manager.setAuthFile(currentFile, disabled: !currentFile.disabled)
                                operationError = manager.lastError
                                isUpdating = false
                                if operationError == nil { dismiss() }
                            }
                        }
                        .disabled(isUpdating || manager.isManagingAccounts)
                        Spacer()
                        Button(L("Remove from CPA", "从 CPA 删除"), role: .destructive) {
                            dismiss()
                            pendingDeletion = currentFile
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 640,
               minHeight: 440, idealHeight: 540, maxHeight: 600)
        .task { loadModels(force: false) }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailMetric(value: String, title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.headline.monospacedDigit())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private var currentFile: CLIProxyAuthFile {
        manager.authFiles.first { $0.name == file.name } ?? file
    }

    private var currentIdentity: CLIProxyAccountIdentity? { manager.accountIdentity(for: currentFile) }
    private var models: [CLIProxyModel] { manager.models(for: currentFile) }
    private var visibleModels: [CLIProxyModel] { showAllModels ? models : Array(models.prefix(8)) }
    private var metadataChanged: Bool {
        draftNote != (currentFile.note ?? "") || draftPriority != (currentFile.priority ?? 0)
    }

    private func loadModels(force: Bool) {
        isLoadingModels = true
        Task {
            await manager.loadModels(for: currentFile, force: force)
            isLoadingModels = false
        }
    }
}

private func providerDisplayName(_ providerID: String) -> String {
    switch providerID.lowercased() {
    case "codex", "openai": "Codex"
    case "anthropic", "claude": "Claude"
    case "antigravity": "Antigravity"
    case "kimi": "Kimi"
    case "xai": "xAI"
    case "gemini", "gemini-cli": "Gemini CLI"
    case "vertex": "Vertex AI"
    case "github-copilot", "copilot": "GitHub Copilot"
    case "qwen": "Qwen"
    case "iflow": "iFlow"
    default: providerID.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

private func gatewayNativeIdentitySummary(_ identity: CLIProxyAccountIdentity?) -> String? {
    guard let identity else { return nil }
    switch identity.providerID.lowercased() {
    case "codex":
        var parts: [String] = []
        if let plan = identity.planDisplayName {
            parts.append(L("\(plan) plan", "\(plan) 套餐"))
        }
        if let accountID = identity.shortAccountID {
            parts.append(L("Workspace \(accountID)", "工作区 \(accountID)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    case "antigravity":
        guard let projectID = identity.shortProjectID else { return nil }
        return L("Project \(projectID)", "项目 \(projectID)")
    default:
        return identity.shortAccountID ?? identity.shortProjectID
    }
}

private func gatewayAccountIdentitySubtitle(
    providerID: String,
    identity: CLIProxyAccountIdentity?
) -> String {
    let provider = providerDisplayName(providerID)
    guard let summary = gatewayNativeIdentitySummary(identity) else { return provider }
    return "\(provider) · \(summary)"
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
