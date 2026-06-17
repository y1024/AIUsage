import SwiftUI

// MARK: - API Provider List
// 「服务商 → API 提供商」分类下的列表：新增/编辑统一上游配置，并把它分发到三套代理。
// 分发与同步委托 APIProviderDistributor；分发状态实时取自各代理 store（故观察它们以刷新）。

struct APIProviderListView: View {
    var searchText: String = ""

    @ObservedObject private var store = APIProviderStore.shared
    @ObservedObject private var profileStore = NodeProfileStore.shared
    @ObservedObject private var openCodeStore = OpenCodeNodeStore.shared

    @State private var editorContext: EditorContext?
    @State private var deletingProvider: APIProvider?

    private var distributor: APIProviderDistributor { APIProviderDistributor.shared }

    private struct EditorContext: Identifiable {
        let id: String
        let provider: APIProvider
        let initialTargets: Set<ProxyTarget>
    }

    private var filteredProviders: [APIProvider] {
        guard !searchText.isEmpty else { return store.providers }
        return store.providers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.baseURL.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .sheet(item: $editorContext) { ctx in
            APIProviderEditorView(provider: ctx.provider, initialTargets: ctx.initialTargets) { provider, targets in
                let saved = store.upsert(provider)
                Task { await distributor.setDistribution(saved, targets: targets) }
            }
        }
        .confirmationDialog(
            L("Delete API Provider", "删除 API 提供商"),
            isPresented: Binding(get: { deletingProvider != nil }, set: { if !$0 { deletingProvider = nil } }),
            presenting: deletingProvider
        ) { provider in
            Button(L("Delete linked nodes too", "一并删除链接节点"), role: .destructive) {
                deleteProvider(provider, deleteChildren: true)
            }
            Button(L("Unlink, keep nodes", "解除链接，保留节点")) {
                deleteProvider(provider, deleteChildren: false)
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: { provider in
            Text(L(
                "\"\(provider.displayName)\" is distributed to its linked proxy nodes. Choose how to handle them.",
                "「\(provider.displayName)」已分发到代理的链接节点，请选择如何处理它们。"
            ))
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text(L("API Providers", "API 提供商"))
                .font(.headline)
            Spacer()
            Button {
                editorContext = EditorContext(id: "new", provider: APIProvider(), initialTargets: [])
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if filteredProviders.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 560), spacing: 16)], spacing: 16) {
                    ForEach(filteredProviders) { provider in
                        APIProviderCard(
                            provider: provider,
                            distributedTargets: distributor.currentTargets(for: provider.id),
                            onEdit: {
                                editorContext = EditorContext(
                                    id: provider.id,
                                    provider: provider,
                                    initialTargets: distributor.currentTargets(for: provider.id)
                                )
                            },
                            onSync: {
                                store.markUsed(id: provider.id)
                                Task { await distributor.syncFromMaster(provider) }
                            },
                            onDelete: {
                                if distributor.currentTargets(for: provider.id).isEmpty {
                                    // 无链接节点：直接删，无需询问处理方式。
                                    store.delete(id: provider.id)
                                } else {
                                    deletingProvider = provider
                                }
                            }
                        )
                    }
                }
                .padding(18)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("No API providers yet", "还没有 API 提供商"))
                .font(.title3.weight(.semibold))
            Text(L(
                "Create one unified upstream config and distribute it to Codex / Claude / OpenCode proxies at once.",
                "创建一份统一的上游配置，一键分发到 Codex / Claude / OpenCode 三套代理。"
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            Button {
                editorContext = EditorContext(id: "new", provider: APIProvider(), initialTargets: [])
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func deleteProvider(_ provider: APIProvider, deleteChildren: Bool) {
        Task {
            await distributor.handleProviderDeletion(provider, deleteChildren: deleteChildren)
            store.delete(id: provider.id)
        }
    }
}
