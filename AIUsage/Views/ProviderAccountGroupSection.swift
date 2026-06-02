import SwiftUI

struct ProviderAccountGroupSection: View {
    let group: ProviderAccountGroup
    let onAddAccount: () -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @State private var isBatchManaging = false
    @State private var selectedForDeletion: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ProviderIconView(group.providerId, size: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.title3)
                        .bold()

                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        pill(
                            text: group.isScanningEnabled ? L("Scanning", "扫描中") : L("Paused", "已暂停"),
                            tint: group.isScanningEnabled ? .green : .orange
                        )
                        pill(text: L("\(group.connectedCount) live", "\(group.connectedCount) 个在线"), tint: .green)
                        pill(text: L("\(group.accounts.count) accounts", "\(group.accounts.count) 个账号"), tint: .blue)
                    }

                    HStack(spacing: 10) {
                        Button {
                            refreshCoordinator.refreshProvider(group.providerId)
                        } label: {
                            Label(
                                refreshCoordinator.isProviderRefreshInFlight(group.providerId)
                                    ? L("Refreshing App", "刷新该应用中")
                                    : L("Refresh App", "刷新该应用"),
                                systemImage: "arrow.clockwise"
                            )
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(refreshCoordinator.isProviderRefreshInFlight(group.providerId))
                        .help(L("Refresh every account under \(group.title)", "刷新 \(group.title) 下的所有账号"))

                        Button {
                            appState.setProviderScanningEnabled(group.providerId, isEnabled: !group.isScanningEnabled)
                        } label: {
                            Label(
                                group.isScanningEnabled ? L("Pause Scan", "暂停扫描") : L("Resume Scan", "恢复扫描"),
                                systemImage: group.isScanningEnabled ? "pause.circle" : "play.circle"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)

                        if group.accounts.count > 1 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isBatchManaging.toggle()
                                    if !isBatchManaging { selectedForDeletion.removeAll() }
                                }
                            } label: {
                                Label(
                                    isBatchManaging
                                        ? L("Done", "完成")
                                        : L("Batch Manage", "批量管理"),
                                    systemImage: isBatchManaging ? "checkmark" : "checklist"
                                )
                                .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                        }

                        Button(action: onAddAccount) {
                            Label(L("Connect Account", "连接账号"), systemImage: "plus")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }

                    if let refreshedAt = refreshCoordinator.providerRefreshDate(for: group.providerId) {
                        HStack(spacing: 4) {
                            Text(L("This app updated", "本应用更新于"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            RefreshableTimeView(
                                date: refreshedAt,
                                language: appState.language,
                                font: .caption2,
                                foregroundStyle: .secondary
                            )
                        }
                    }
                }
            }

            if group.accounts.isEmpty {
                EmptyProviderAccountState(group: group, onAddAccount: onAddAccount)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(group.accounts) { account in
                        if isBatchManaging {
                            batchSelectableCard(for: account)
                        } else {
                            accountCard(for: account)
                        }
                    }
                }
            }

            if isBatchManaging, !group.accounts.isEmpty {
                batchActionBar
            }
        }
        .alert(
            L("Remove Selected Accounts", "移除选中的账号"),
            isPresented: $showBatchDeleteConfirm
        ) {
            Button(L("Remove", "移除"), role: .destructive) {
                performBatchDelete()
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L(
                "Remove \(selectedForDeletion.count) account(s) from monitoring? Credentials will be deleted from Keychain.",
                "确认从监控中移除 \(selectedForDeletion.count) 个账号？凭据将从钥匙串中删除。"
            ))
        }
    }

    // MARK: - Account Card Routing
    // 与仪表盘卡片保持一致：未连接（缺 Key / 未登录）→ 引导卡；
    // 首屏或该应用刷新中、还没拿到 live 数据 → 加载占位卡（骨架/转圈）；
    // 否则 live → ManagedProviderAccountCard，已保存但暂无 live → SavedAccountCard。
    @ViewBuilder
    private func accountCard(for account: ProviderAccountEntry) -> some View {
        if let liveProvider = account.liveProvider {
            if liveProvider.needsCredentialConnection {
                NeedsConnectionCard(
                    providerId: account.providerId,
                    title: account.cardTitle,
                    subtitle: account.cardSubtitle,
                    onConnect: onAddAccount
                )
            } else {
                ManagedProviderAccountCard(account: account, provider: liveProvider)
                    .environmentObject(appState)
                    .environmentObject(refreshCoordinator)
            }
        } else if isAccountLoading(account) {
            LoadingAccountCard(
                providerId: account.providerId,
                title: account.cardTitle,
                subtitle: account.cardSubtitle
            )
        } else {
            SavedAccountCard(account: account, onReconnect: { onAddAccount() })
                .environmentObject(appState)
        }
    }

    /// 首次全量刷新还没完成，或该应用正在刷新时，未拿到 live 数据的账号显示「加载中」占位，
    /// 而不是 SavedAccountCard 的「凭证可能已过期」误导态。
    private func isAccountLoading(_ account: ProviderAccountEntry) -> Bool {
        !refreshCoordinator.hasCompletedInitialLoad
            || refreshCoordinator.isProviderRefreshInFlight(account.providerId)
    }

    // MARK: - Batch Selection

    @ViewBuilder
    private func batchSelectableCard(for account: ProviderAccountEntry) -> some View {
        let isSelected = selectedForDeletion.contains(account.id)
        HStack(spacing: 0) {
            Button {
                if isSelected {
                    selectedForDeletion.remove(account.id)
                } else {
                    selectedForDeletion.insert(account.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 36)
            }
            .buttonStyle(.plain)

            Group {
                if let liveProvider = account.liveProvider {
                    ManagedProviderAccountCard(account: account, provider: liveProvider)
                        .environmentObject(appState)
                        .environmentObject(refreshCoordinator)
                } else {
                    SavedAccountCard(account: account, onReconnect: { onAddAccount() })
                        .environmentObject(appState)
                }
            }
            .allowsHitTesting(false)
            .opacity(isSelected ? 0.7 : 1.0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedForDeletion.remove(account.id)
            } else {
                selectedForDeletion.insert(account.id)
            }
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 12) {
            Button {
                if selectedForDeletion.count == group.accounts.count {
                    selectedForDeletion.removeAll()
                } else {
                    selectedForDeletion = Set(group.accounts.map(\.id))
                }
            } label: {
                Text(selectedForDeletion.count == group.accounts.count
                     ? L("Deselect All", "取消全选")
                     : L("Select All", "全选"))
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)

            Text(L("Selected \(selectedForDeletion.count)", "已选 \(selectedForDeletion.count) 个"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label(
                    L("Remove Selected (\(selectedForDeletion.count))", "移除选中 (\(selectedForDeletion.count))"),
                    systemImage: "trash"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(selectedForDeletion.isEmpty)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func performBatchDelete() {
        let entriesToDelete = group.accounts.filter { selectedForDeletion.contains($0.id) }
        guard !entriesToDelete.isEmpty else { return }
        appState.deleteAccounts(entriesToDelete)
        selectedForDeletion.removeAll()
        isBatchManaging = false
    }

    private func pill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }
}

struct EmptyProviderAccountState: View {
    let group: ProviderAccountGroup
    let onAddAccount: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("No account connected yet", "还没有连接账号"))
                .font(.headline)

            Text(
                L(
                    "This app is already in your scan list. Connect one account and AIUsage will start monitoring it here.",
                    "这个应用已经在扫描列表里了。连接任意一个账号后，AIUsage 就会开始在这里监控它。"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(action: onAddAccount) {
                Label(L("Connect Account", "连接账号"), systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

struct ManagedProviderAccountCard: View {
    let account: ProviderAccountEntry
    let provider: ProviderData

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator

    var body: some View {
        ProviderCard(
            provider: provider,
            titleOverride: account.cardTitle,
            subtitleOverride: account.cardSubtitle,
            footerAccountLabelOverride: account.footerAccountLabel,
            accountEntry: account,
            refreshAction: refreshThisAccount
        )
    }

    private func refreshThisAccount() async {
        await refreshCoordinator.refreshProviderCardNow(provider)
    }
}
