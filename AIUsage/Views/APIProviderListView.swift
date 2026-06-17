import SwiftUI

// MARK: - API Provider List
// 「服务商 → API 提供商」分类下的列表：新增/编辑统一上游配置，并把它分发到三套代理。
// 分发与同步委托 APIProviderDistributor；分发状态实时取自各代理 store（故观察它们以刷新）。

struct APIProviderListView: View {
    var searchText: String = ""
    /// 顶部工具栏「新增」触发信号：置 true 即打开新建编辑器（由本视图复位）。
    @Binding var requestNew: Bool

    @ObservedObject private var store = APIProviderStore.shared
    @ObservedObject private var profileStore = NodeProfileStore.shared
    @ObservedObject private var openCodeStore = OpenCodeNodeStore.shared

    @State private var editorContext: EditorContext?
    @State private var deletingProvider: APIProvider?

    // 手势驱动的「拖拽实时让位」重排状态（与三套代理节点列表同一套手感）。
    @State private var draggingId: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var rowHeights: [String: CGFloat] = [:]

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
        content
        .onChange(of: requestNew) { _, newValue in
            guard newValue else { return }
            editorContext = EditorContext(id: "new", provider: APIProvider(), initialTargets: [])
            requestNew = false
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

    @ViewBuilder
    private var content: some View {
        if filteredProviders.isEmpty {
            emptyState
        } else {
            ScrollView {
                providerList
                    .padding(18)
            }
        }
    }

    /// 条目列表 + 跟手让位拖拽重排。搜索过滤时禁用拖拽（避免对部分列表整表重写顺序）。
    private var providerList: some View {
        let reorderEnabled = searchText.isEmpty
        let ids = filteredProviders.map(\.id)
        let srcIdx = draggingId.flatMap { id in ids.firstIndex(of: id) }
        let target = srcIdx.map { dragTarget(ids: ids, srcIdx: $0) }
        return LazyVStack(spacing: 0) {
            ForEach(Array(filteredProviders.enumerated()), id: \.element.id) { index, provider in
                let isDragging = draggingId == provider.id
                providerRow(provider, reorderEnabled: reorderEnabled)
                    .offset(y: reorderEnabled ? rowOffset(index: index, id: provider.id, srcIdx: srcIdx, target: target) : 0)
                    .scaleEffect(isDragging ? 1.02 : 1, anchor: .center)
                    .shadow(color: .black.opacity(isDragging ? 0.22 : 0),
                            radius: isDragging ? 9 : 0, y: isDragging ? 5 : 0)
                    .zIndex(isDragging ? 1 : 0)
                    .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
                    .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.85), value: draggingId)
            }
        }
        .onPreferenceChange(APIProviderRowHeightKey.self) { heights in
            guard draggingId != nil, rowHeights != heights else { return }
            rowHeights = heights
        }
        .onChange(of: draggingId) { _, id in
            if id == nil, !rowHeights.isEmpty { rowHeights.removeAll() }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: APIProvider, reorderEnabled: Bool) -> some View {
        APIProviderCard(
            provider: provider,
            distributedTargets: distributor.currentTargets(for: provider.id),
            onDragChanged: { translation in
                guard reorderEnabled else { return }
                if draggingId != provider.id { draggingId = provider.id }
                dragTranslation = translation
            },
            onDragEnded: {
                if reorderEnabled {
                    commitDrag()
                } else {
                    // 拖拽中途进入搜索（禁用重排）：不提交，但仍复位拖拽态，避免残留高亮/偏移。
                    draggingId = nil
                    dragTranslation = 0
                }
            },
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
        .background {
            if draggingId != nil { rowHeightReader(for: provider.id) }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Drag Reorder Helpers

    // 卡片在 LazyVStack(spacing:0) 中各带 .padding(.vertical,4)，上下合计 8 作为行间距。
    private static let rowSpacing: CGFloat = 8
    private static let fallbackHeight: CGFloat = 84

    private func rowHeightReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: APIProviderRowHeightKey.self, value: [id: geo.size.height])
        }
    }

    private func rowStride(_ id: String) -> CGFloat {
        (rowHeights[id] ?? Self.fallbackHeight) + Self.rowSpacing
    }

    /// 各行在基础布局中的中心 Y（被拖行仍按原槽位计入），用于阈值判断。
    private func rowBaseCenters(_ ids: [String]) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for id in ids {
            let height = rowHeights[id] ?? Self.fallbackHeight
            centers.append(top + height / 2)
            top += height + Self.rowSpacing
        }
        return centers
    }

    /// 由跟手位移推出被拖行应落入的目标条目下标。
    private func dragTarget(ids: [String], srcIdx: Int) -> Int {
        guard !ids.isEmpty, srcIdx < ids.count else { return srcIdx }
        let centers = rowBaseCenters(ids)
        let draggedCenter = centers[srcIdx] + dragTranslation
        var target = srcIdx
        while target < ids.count - 1 && draggedCenter > centers[target + 1] { target += 1 }
        while target > 0 && draggedCenter < centers[target - 1] { target -= 1 }
        return target
    }

    /// 单行 y 位移：被拖行跟手；其余行按「让位」规则平移一个被拖行步幅。
    private func rowOffset(index: Int, id: String, srcIdx: Int?, target: Int?) -> CGFloat {
        if id == draggingId { return dragTranslation }
        guard let srcIdx, let target, let dragId = draggingId else { return 0 }
        let step = rowStride(dragId)
        if target > srcIdx, index > srcIdx, index <= target { return -step }
        if target < srcIdx, index >= target, index < srcIdx { return step }
        return 0
    }

    /// 松手时把被拖卡片落到目标下标并整表持久化顺序。
    private func commitDrag() {
        let ids = store.providers.map(\.id)
        defer {
            draggingId = nil
            dragTranslation = 0
        }
        guard let id = draggingId, let srcIdx = ids.firstIndex(of: id) else { return }
        let target = dragTarget(ids: ids, srcIdx: srcIdx)
        guard target != srcIdx else { return }
        var reordered = ids
        reordered.remove(at: srcIdx)
        reordered.insert(id, at: target)
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
            store.applyOrder(ids: reordered)
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
