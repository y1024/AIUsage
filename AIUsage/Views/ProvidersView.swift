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
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var selectedChannel: String = "all"
    @State private var selectedProviderFilter: String = "all"
    @State private var selectedCategory: ProviderListCategory = .accounts
    @State private var accountEditorTarget: ProviderEditorTarget?
    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if selectedCategory == .accounts {
                filterBar
                Divider()
                accountsBody
            } else {
                Divider()
                APIProviderListView(searchText: searchText)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $accountEditorTarget) { target in
            ProviderAccountEditorView(providerId: target.providerId)
                .environmentObject(appState)
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
        serviceGroups.filter { selectedChannel == "all" || $0.channel == selectedChannel }
    }

    private var hiddenAccounts: [StoredProviderAccount] {
        accountStore.hiddenAccounts()
    }

    private var filteredGroups: [ProviderAccountGroup] {
        availableProviderFilters.compactMap { group -> ProviderAccountGroup? in
            guard selectedProviderFilter == "all" || group.providerId == selectedProviderFilter else { return nil }

            if group.accounts.isEmpty {
                let matchesGroup = searchText.isEmpty || group.title.localizedCaseInsensitiveContains(searchText)
                return matchesGroup ? group : nil
            }

            let filteredAccounts = group.accounts.filter { account in
                searchText.isEmpty ||
                group.title.localizedCaseInsensitiveContains(searchText) ||
                (account.accountEmail?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                (account.accountDisplayName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                (account.accountNote?.localizedCaseInsensitiveContains(searchText) ?? false)
            }

            if filteredAccounts.isEmpty {
                let matchesGroup = searchText.isEmpty || group.title.localizedCaseInsensitiveContains(searchText)
                guard matchesGroup else { return nil }
                return ProviderAccountGroup(
                    id: group.id,
                    providerId: group.providerId,
                    title: group.title,
                    subtitle: group.subtitle,
                    channel: group.channel,
                    isScanningEnabled: group.isScanningEnabled,
                    accounts: []
                )
            }

            return ProviderAccountGroup(
                id: group.id,
                providerId: group.providerId,
                title: group.title,
                subtitle: group.subtitle,
                channel: group.channel,
                isScanningEnabled: group.isScanningEnabled,
                accounts: filteredAccounts
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchControl
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 440)

                categoryControl
                    .frame(width: 260)

                Spacer(minLength: 8)
                if selectedCategory == .accounts {
                    toolbarActions
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    searchControl
                        .frame(maxWidth: .infinity)

                    if selectedCategory == .accounts {
                        toolbarActions
                    }
                }

                categoryControl
                    .frame(width: 260)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(toolbarBackground)
    }

    private var searchControl: some View {
        ProviderSearchControl(
            placeholder: selectedCategory == .accounts
                ? L("Search accounts...", "搜索账号...", key: "providers.search.placeholder")
                : L("Search API providers...", "搜索 API 提供商..."),
            text: $searchText
        )
    }

    private var categoryControl: some View {
        HStack(spacing: 8) {
            Label {
                Text(L("Channel", "渠道", key: "providers.channel"))
                    .font(.caption.weight(.semibold))
            } icon: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Picker("", selection: $selectedCategory) {
                Text(L("Accounts", "账号")).tag(ProviderListCategory.accounts)
                Text(L("API Providers", "API 提供商")).tag(ProviderListCategory.apiProviders)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 172)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(height: 34)
        .background(controlBackground)
        .overlay(controlBorder)
    }

    private var toolbarActions: some View {
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
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.35 : 0.55))
                    .frame(height: 0.5)
            }
    }

    private var controlBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.82 : 0.94))
    }

    private var controlBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.38 : 0.55), lineWidth: 0.5)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                providerFilterChip(id: "all", title: L("All Apps", "全部应用", key: "providers.all_apps"))

                ForEach(availableProviderFilters) { group in
                    providerFilterChip(id: group.providerId, title: group.title, providerId: group.providerId)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func providerFilterChip(id: String, title: String, providerId: String? = nil) -> some View {
        let isSelected = selectedProviderFilter == id

        return Button {
            selectedProviderFilter = id
        } label: {
            HStack(spacing: 8) {
                if let providerId {
                    ProviderIconView(providerId, size: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16, height: 16)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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

            if !searchText.isEmpty {
                Text(L("Try another app filter or search keyword.", "试试其他应用筛选或搜索关键词。"))
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
