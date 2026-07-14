import SwiftUI
import QuotaBackend

/// 服务商页一级分类：账号（现有登录类 provider）/ API 提供商（统一上游配置）。
enum ProviderListCategory: String, CaseIterable {
    case accounts
    case apiProviders
}

struct ProvidersView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var accountStore: AccountStore
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.colorScheme) private var colorScheme
    /// 单类目页面：由侧边栏的「订阅账号」/「API 提供商」分别承载（不再内置切换）。
    let category: ProviderListCategory
    @State private var searchText = ""
    @State private var selectedProviderFilter: String = "all"
    @State private var statusFilter: SubscriptionAccountFilter = .all
    @State private var accountEditorTarget: ProviderEditorTarget?
    /// 顶部工具栏「新增 API 提供商」的触发信号（按钮在工具栏，编辑器在 APIProviderListView）。
    @State private var requestNewAPIProvider = false
    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if category == .accounts {
                accountsChrome
                Divider()
                accountsBody
            } else {
                Divider()
                APIProviderListView(
                    searchText: searchText,
                    requestNew: $requestNewAPIProvider,
                    onClearSearch: { searchText = "" }
                )
            }
        }
        .background(AppSurface.page(colorScheme))
        .sheet(item: $accountEditorTarget) { target in
            ProviderAccountEditorView(providerId: target.providerId)
                .environmentObject(appState)
        }
    }

    // MARK: - Accounts Chrome (stats + status filter)

    private var accountsChrome: some View {
        VStack(alignment: .leading, spacing: 12) {
            if attentionCount > 0 {
                attentionBanner
            }

            HStack(alignment: .center, spacing: 10) {
                SubscriptionAppScopeControl(
                    options: appScopeOptions,
                    selection: $selectedProviderFilter
                )
                summaryRow
            }

            GatewayCapsuleFilterBar(
                values: SubscriptionAccountFilter.allCases,
                selection: $statusFilter,
                title: \.title
            )
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var appScopeOptions: [SubscriptionAppScopeOption] {
        let total = flatEntries.count
        var options: [SubscriptionAppScopeOption] = [.all(accountCount: total)]
        options.append(contentsOf: availableProviderFilters.map { group in
            SubscriptionAppScopeOption(
                id: group.providerId,
                title: group.title,
                providerId: group.providerId,
                accountCount: group.accounts.count
            )
        })
        return options
    }

    private var summaryRow: some View {
        let entries = flatEntries
        let loading = isLoadingClosure
        return GatewayStatCapsuleRow(items: [
            .init(
                id: "total",
                value: "\(entries.count)",
                title: L("accounts", "账号"),
                systemImage: "person.2.fill",
                tint: .indigo
            ),
            .init(
                id: "ready",
                value: "\(SubscriptionAccountListLogic.count(.ready, in: entries, isLoading: loading))",
                title: L("online", "在线"),
                systemImage: "checkmark.circle.fill",
                tint: .green
            ),
            .init(
                id: "attention",
                value: "\(SubscriptionAccountListLogic.count(.attention, in: entries, isLoading: loading))",
                title: L("need attention", "需处理"),
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            ),
            .init(
                id: "offline",
                value: "\(SubscriptionAccountListLogic.count(.offline, in: entries, isLoading: loading))",
                title: L("offline", "离线"),
                systemImage: "icloud.slash",
                tint: .secondary
            ),
            .init(
                id: "needsConnection",
                value: "\(SubscriptionAccountListLogic.count(.needsConnection, in: entries, isLoading: loading))",
                title: L("not connected", "未连接"),
                systemImage: "link.badge.plus",
                tint: .blue
            ),
        ])
    }

    private var attentionBanner: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                statusFilter = .attention
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(L(
                    "\(attentionCount) account(s) need attention",
                    "\(attentionCount) 个账号需要处理"
                ))
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text(L("Filter", "筛选"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.orange.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var flatEntries: [ProviderAccountEntry] {
        SubscriptionAccountListLogic.allEntries(in: serviceGroups)
    }

    private var attentionCount: Int {
        SubscriptionAccountListLogic.count(.attention, in: flatEntries, isLoading: isLoadingClosure)
    }

    private var isLoadingClosure: (ProviderAccountEntry) -> Bool {
        { entry in
            SubscriptionAccountListLogic.isAccountLoading(
                entry,
                hasCompletedInitialLoad: refreshCoordinator.hasCompletedInitialLoad,
                isProviderRefreshInFlight: { refreshCoordinator.isProviderRefreshInFlight($0) }
            )
        }
    }

    @ViewBuilder
    private var accountsBody: some View {
        if filteredGroups.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(filteredGroups) { group in
                        ProviderAccountGroupSection(
                            group: group,
                            onAddAccount: {
                                accountEditorTarget = ProviderEditorTarget(providerId: group.providerId)
                            }
                        )
                        .environmentObject(appState)
                    }
                }
                .padding()
            }
        }
    }

    private var serviceGroups: [ProviderAccountGroup] {
        appState.providerAccountGroups.filter { group in
            appState.providerCatalogItem(for: group.providerId)?.kind == .official
        }
    }

    private var availableProviderFilters: [ProviderAccountGroup] {
        serviceGroups
    }

    private var hiddenAccounts: [StoredProviderAccount] {
        accountStore.hiddenAccounts()
    }

    private var filteredGroups: [ProviderAccountGroup] {
        SubscriptionAccountListLogic.filteredGroups(
            groups: availableProviderFilters,
            query: searchText,
            providerFilter: selectedProviderFilter,
            statusFilter: statusFilter,
            isLoading: isLoadingClosure
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            searchControl
                .frame(maxWidth: .infinity)

            toolbarActions
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(toolbarBackground)
    }

    private var searchControl: some View {
        ProviderSearchControl(
            placeholder: category == .accounts
                ? L("Search accounts...", "搜索账号...", key: "providers.search.placeholder")
                : L("Search API providers...", "搜索 API 提供商..."),
            text: $searchText
        )
    }

    /// 右侧操作区：按当前类目渲染对应操作。
    @ViewBuilder
    private var toolbarActions: some View {
        switch category {
        case .accounts:
            accountToolbarActions
        case .apiProviders:
            apiProviderToolbarActions
        }
    }

    private var apiProviderToolbarActions: some View {
        Button {
            requestNewAPIProvider = true
        } label: {
            ProviderActionLabel(
                title: L("New API Provider", "新增 API 提供商"),
                systemImage: "plus",
                style: .primary,
                minWidth: 120
            )
        }
        .buttonStyle(.plain)
    }

    private var accountToolbarActions: some View {
        HStack(spacing: 8) {
            Button {
                appState.presentManageProviderPicker()
            } label: {
                ProviderActionLabel(
                    title: L("Manage Sources", "管理来源", key: "providers.manage_sources"),
                    systemImage: "slider.horizontal.3"
                )
            }
            .buttonStyle(.plain)

            if !hiddenAccounts.isEmpty {
                Menu {
                    ForEach(hiddenAccounts) { storedAccount in
                        Button {
                            appState.restoreAccount(storedAccount.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(storedAccount.preferredLabel)
                                Text(appState.providerCatalogItem(for: storedAccount.providerId)?.title(for: appState.language) ?? storedAccount.providerId)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    ProviderActionLabel(
                        title: L("Hidden Accounts", "已隐藏账号", key: "providers.hidden_accounts"),
                        systemImage: "eye.slash"
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                if appState.unselectedProviderCatalog.filter({ $0.kind == .official }).isEmpty {
                    appState.presentManageProviderPicker()
                } else {
                    appState.presentAddProviderPicker()
                }
            } label: {
                ProviderActionLabel(
                    title: L("Add App", "添加应用", key: "providers.add_app"),
                    systemImage: "plus",
                    style: .primary,
                    minWidth: 96
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var toolbarBackground: some View {
        Rectangle()
            .fill(AppSurface.toolbar(colorScheme))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppStroke.subtle(colorScheme))
                    .frame(height: 0.5)
            }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 56))
                .foregroundColor(.secondary)

            Text(L("No accounts found", "未找到账号", key: "providers.empty.title"))
                .font(.title2)
                .bold()

            if !searchText.isEmpty || statusFilter != .all || selectedProviderFilter != "all" {
                Text(L(
                    "Try another app filter, status filter, or search keyword.",
                    "试试其他应用筛选、状态筛选或搜索关键词。"
                ))
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                Text(L("Add a provider app first, then each app can keep multiple accounts under the same group.", "先添加服务应用，之后每个应用都可以在同一分组下管理多个账号。"))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                Button {
                    appState.presentAddProviderPicker()
                } label: {
                    ProviderActionLabel(
                        title: L("Add App", "添加应用", key: "providers.add_app"),
                        systemImage: "plus",
                        style: .primary,
                        minWidth: 104
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ProviderEditorTarget: Identifiable {
    let providerId: String
    var id: String { providerId }
}

struct ProviderSearchControl: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 34

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .lineLimit(1)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear Search", "清空搜索"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.82 : 0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.38 : 0.55), lineWidth: 0.5)
        )
    }
}

struct ProviderActionLabel: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    let systemImage: String
    var style: Style = .secondary
    var minWidth: CGFloat?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 11)
        .frame(minWidth: minWidth, minHeight: 32)
        .background(backgroundShape)
        .overlay(borderShape)
        .opacity(isEnabled ? 1 : 0.56)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .help(title)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .white
        case .secondary:
            return .primary
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(backgroundColor)
    }

    private var borderShape: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(borderColor, lineWidth: 0.5)
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return isEnabled
                ? Color.accentColor.opacity(isHovered ? 0.92 : 1.0)
                : Color.accentColor.opacity(0.46)
        case .secondary:
            if colorScheme == .dark {
                return Color.white.opacity(isHovered ? 0.105 : 0.075)
            }
            return Color.primary.opacity(isHovered ? 0.070 : 0.045)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return Color.white.opacity(colorScheme == .dark ? 0.18 : 0.12)
        case .secondary:
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08)
        }
    }
}
