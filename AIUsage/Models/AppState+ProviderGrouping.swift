import Foundation
import QuotaBackend

// MARK: - Provider account grouping
// Pure read-only projections over `providerCatalog`, `providers` and
// `accountStore`. Pulled out of `AppState` to keep the coordinator under the
// 400-line ceiling. No new logic here — moves only.

extension AppState {

    /// 记忆化入口（issue #28）：命中未失效缓存直接返回，否则重算并缓存。
    /// 失效由各输入源的 objectWillChange / selectedProviderIds.didSet 置 `providerGroupsCacheDirty`。
    /// AppState 为引用类型，getter 内写缓存无需 mutating；缓存字段非 @Published，写入不触发渲染回环。
    /// 全程主线程访问（视图 body 读取 + 上游 sink 在 RunLoop.main 置脏）。
    var providerAccountGroups: [ProviderAccountGroup] {
        if !providerGroupsCacheDirty, let cached = cachedProviderAccountGroups {
            return cached
        }
        let groups = computeProviderAccountGroups()
        cachedProviderAccountGroups = groups
        providerGroupsCacheDirty = false
        return groups
    }

    private func computeProviderAccountGroups() -> [ProviderAccountGroup] {
        let liveProvidersById = Dictionary(grouping: providers, by: \.baseProviderId)

        return providerCatalog
            .filter { item in
                selectedProviderIds.contains(item.id)
                    || accountStore.accountRegistry.contains(where: { $0.providerId == item.id && !$0.isHidden })
                    || !(liveProvidersById[item.id] ?? []).isEmpty
            }
            .compactMap { item in
                let liveProviders = liveProvidersById[item.id] ?? []
                let storedAccounts = accountStore.accountRegistry.filter { $0.providerId == item.id && !$0.isHidden }
                let entries = refreshCoordinator.buildProviderEntries(
                    providerId: item.id,
                    providerTitle: item.title(for: language),
                    providerSubtitle: item.summary(for: language),
                    liveProviders: liveProviders,
                    storedAccounts: storedAccounts
                )

                let sortedEntries = entries.sorted { lhs, rhs in
                    if lhs.isConnected != rhs.isConnected { return lhs.isConnected && !rhs.isConnected }
                    let emailCmp = (lhs.accountEmail ?? "").localizedCaseInsensitiveCompare(rhs.accountEmail ?? "")
                    if emailCmp != .orderedSame { return emailCmp == .orderedAscending }
                    let lhsWs = lhs.workspaceLabel ?? ""
                    let rhsWs = rhs.workspaceLabel ?? ""
                    if lhsWs != rhsWs { return lhsWs < rhsWs }
                    return (lhs.storedAccount?.accountId ?? lhs.id) < (rhs.storedAccount?.accountId ?? rhs.id)
                }

                return ProviderAccountGroup(
                    id: item.id,
                    providerId: item.id,
                    title: item.title(for: language),
                    subtitle: item.summary(for: language),
                    channel: item.channel,
                    isScanningEnabled: selectedProviderIds.contains(item.id),
                    accounts: sortedEntries
                )
            }
    }

    var hiddenAccounts: [StoredProviderAccount] {
        accountStore.hiddenAccounts()
    }
}
