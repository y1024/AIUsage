import SwiftUI

// MARK: - OpenCode Management View
// 「OpenCode 代理」主视图：节点列表 + 一键接管/还原 opencode.json。
// 直连模式: 激活即把节点（baseURL/APIKey/模型）写入受管 provider 块，停用即整文还原。
// 代理模式（路线 B）: 激活同时拉起本地透传进程，opencode.json 指向 127.0.0.1，
// 底部展示实时请求日志（仅观测，计费仍以 opencode.db 为准）。

struct OpenCodeManagementView: View {
    @ObservedObject private var store = OpenCodeNodeStore.shared
    @ObservedObject private var proxyRuntime = OpenCodeProxyRuntime.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var editingNode: OpenCodeNode?
    @State private var pendingDeletion: OpenCodeNode?
    @State private var actionError: String?
    @State private var activationInProgress = false

    // 手势驱动的「拖拽实时让位」重排状态（与 Claude/Codex 节点列表同一套手感）。
    @State private var draggingNodeId: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var nodeRowHeights: [String: CGFloat] = [:]

    static let brand = Color(red: 0.18, green: 0.83, blue: 0.75)

    var body: some View {
        VStack(spacing: 0) {
            if store.nodes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        statusBanner
                        proxyErrorBanner
                        actionBar
                        nodeList
                        if store.activeNode?.proxyEnabled == true {
                            OpenCodeRequestLogSection()
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingNode) { node in
            OpenCodeNodeEditorView(node: node) { saved in
                store.upsert(saved)
            }
        }
        .alert(
            L("Delete this node?", "删除该节点？"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button(L("Delete", "删除"), role: .destructive) {
                if let node = pendingDeletion { store.delete(node) }
                pendingDeletion = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L(
                "The node and its API key will be removed. If it is active, opencode.json will be restored first.",
                "节点及其 API Key 将被移除。若该节点正在生效，将先还原 opencode.json。"
            ))
        }
        .alert(
            L("Operation Failed", "操作失败"),
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Status Banner

    @ViewBuilder
    private var statusBanner: some View {
        if store.usesJSONC {
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: L("opencode.jsonc detected", "检测到 opencode.jsonc"),
                message: L(
                    "AIUsage cannot safely rewrite JSONC (comments would be lost). Migrate it to opencode.json to enable node switching.",
                    "AIUsage 无法安全改写 JSONC（注释会丢失）。请先迁移为 opencode.json 再使用节点切换。"
                )
            )
        } else if let active = store.activeNode {
            banner(
                icon: "checkmark.circle.fill",
                tint: Self.brand,
                title: L("Managing opencode.json — \(active.displayName)", "已接管 opencode.json — \(active.displayName)"),
                message: active.proxyEnabled
                    ? (proxyRuntime.isRunning
                        ? L(
                            "OpenCode goes through the local proxy at 127.0.0.1:\(String(active.proxyPort)) — request logs below. Restart OpenCode sessions for the change to take effect.",
                            "OpenCode 经本地代理 127.0.0.1:\(String(active.proxyPort)) 访问上游，下方可查看请求日志。重启 OpenCode 会话后生效。"
                        )
                        : L(
                            "Local proxy is not running — OpenCode requests will fail until it is restarted.",
                            "本地代理未在运行——重启代理前 OpenCode 请求将失败。"
                        ))
                    : L(
                        "OpenCode now talks to this node directly. Restart OpenCode sessions for the change to take effect.",
                        "OpenCode 将直连该节点。重启 OpenCode 会话后生效。"
                    ),
                trailing: AnyView(
                    HStack(spacing: 8) {
                        if active.proxyEnabled, !proxyRuntime.isRunning {
                            Button(L("Restart Proxy", "重启代理")) {
                                Task { await proxyRuntime.restart() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                        Button(L("Deactivate", "停用")) { deactivate() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                )
            )
        } else {
            banner(
                icon: "circle.dashed",
                tint: .secondary,
                title: L("Not managing opencode.json", "未接管 opencode.json"),
                message: L(
                    "OpenCode is using its own configuration. Activate a node to route OpenCode to that endpoint.",
                    "OpenCode 正在使用自身配置。激活某个节点后，OpenCode 将切换到该接入点。"
                )
            )
        }
    }

    /// 代理进程异常（多次自动重启失败）时的提示。
    @ViewBuilder
    private var proxyErrorBanner: some View {
        if store.activeNode?.proxyEnabled == true, let error = proxyRuntime.lastError {
            banner(
                icon: "bolt.trianglebadge.exclamationmark.fill",
                tint: .red,
                title: L("Local proxy error", "本地代理异常"),
                message: error,
                trailing: AnyView(
                    Button(L("Restart Proxy", "重启代理")) {
                        Task { await proxyRuntime.restart() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                )
            )
        }
    }

    private func banner(icon: String, tint: Color, title: String, message: String, trailing: AnyView? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            ProviderIconView("opencode", size: 18)
            Text(L("Nodes", "接入节点"))
                .font(.headline)
            Text("\(store.nodes.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))

            Spacer()

            Button {
                revealConfigFile()
            } label: {
                Label(L("Open Config", "打开配置"), systemImage: "doc.text.magnifyingglass")
            }
            .controlSize(.small)
            .help(L("Reveal opencode.json in Finder", "在访达中显示 opencode.json"))

            Button {
                editingNode = OpenCodeNode()
            } label: {
                Label(L("Add Node", "添加节点"), systemImage: "plus")
            }
            .controlSize(.small)
            .keyboardShortcut("n", modifiers: [.command])
        }
    }

    // MARK: - Node List

    private var nodeList: some View {
        let ids = store.nodes.map(\.id)
        let srcIdx = draggingNodeId.flatMap { id in ids.firstIndex(of: id) }
        let target = srcIdx.map { dragTarget(ids: ids, srcIdx: $0) }

        return LazyVStack(spacing: Self.nodeRowSpacing) {
            ForEach(Array(store.nodes.enumerated()), id: \.element.id) { index, node in
                let isDragging = draggingNodeId == node.id
                OpenCodeNodeCard(
                    node: node,
                    isActive: node.id == store.activeNodeId,
                    activationDisabled: store.usesJSONC || !node.isComplete || activationInProgress,
                    onActivate: { activate(node) },
                    onDeactivate: { deactivate() },
                    onEdit: { editingNode = node },
                    onDelete: { pendingDeletion = node },
                    onDragChanged: { translation in
                        if draggingNodeId != node.id {
                            draggingNodeId = node.id
                        }
                        dragTranslation = translation
                    },
                    onDragEnded: { commitNodeDrag() }
                )
                .background {
                    if draggingNodeId != nil {
                        rowHeightReader(for: node.id)
                    }
                }
                .offset(y: rowOffset(index: index, id: node.id, srcIdx: srcIdx, target: target))
                .scaleEffect(isDragging ? 1.02 : 1, anchor: .center)
                .shadow(color: .black.opacity(isDragging ? 0.22 : 0),
                        radius: isDragging ? 9 : 0, y: isDragging ? 5 : 0)
                .zIndex(isDragging ? 1 : 0)
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
                .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.85), value: draggingNodeId)
            }
        }
        .onPreferenceChange(OpenCodeNodeRowHeightKey.self) { heights in
            guard draggingNodeId != nil, nodeRowHeights != heights else { return }
            nodeRowHeights = heights
        }
        .onChange(of: draggingNodeId) { _, id in
            if id == nil, !nodeRowHeights.isEmpty {
                nodeRowHeights.removeAll()
            }
        }
    }

    // MARK: - Drag Reorder Helpers

    private static let nodeRowSpacing: CGFloat = 10
    private static let nodeFallbackHeight: CGFloat = 84

    private func rowHeightReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: OpenCodeNodeRowHeightKey.self, value: [id: geo.size.height])
        }
    }

    private func rowStride(_ id: String) -> CGFloat {
        (nodeRowHeights[id] ?? Self.nodeFallbackHeight) + Self.nodeRowSpacing
    }

    /// 各行在基础布局中的中心 Y（被拖行仍按原槽位计入），用于阈值判断。
    private func rowBaseCenters(_ ids: [String]) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for id in ids {
            let height = nodeRowHeights[id] ?? Self.nodeFallbackHeight
            centers.append(top + height / 2)
            top += height + Self.nodeRowSpacing
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
        if id == draggingNodeId { return dragTranslation }
        guard let srcIdx, let target, let dragId = draggingNodeId else { return 0 }
        let step = rowStride(dragId)
        if target > srcIdx, index > srcIdx, index <= target { return -step }
        if target < srcIdx, index >= target, index < srcIdx { return step }
        return 0
    }

    /// 松手时把被拖卡片落到目标下标并整表持久化顺序。
    private func commitNodeDrag() {
        let ids = store.nodes.map(\.id)
        defer {
            draggingNodeId = nil
            dragTranslation = 0
        }
        guard let id = draggingNodeId, let srcIdx = ids.firstIndex(of: id) else { return }
        let target = dragTarget(ids: ids, srcIdx: srcIdx)
        guard target != srcIdx else { return }
        var reordered = ids
        reordered.remove(at: srcIdx)
        reordered.insert(id, at: target)
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
            store.applyOrder(ids: reordered)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            ProviderIconView("opencode", size: 46)
            Text(L("No OpenCode nodes yet", "还没有 OpenCode 节点"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L(
                "Add an OpenAI-compatible endpoint (base URL + API key + models). Activating a node writes it into opencode.json — directly, or through a local proxy when you want per-request logs.",
                "添加一个 OpenAI 兼容接入点（Base URL + API Key + 模型）。激活节点会把它写入 opencode.json——默认直连；需要请求日志时可开启本地代理模式。"
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            Button {
                editingNode = OpenCodeNode()
            } label: {
                Label(L("Add Node", "添加节点"), systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Self.brand)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func activate(_ node: OpenCodeNode) {
        guard !activationInProgress else { return }
        activationInProgress = true
        Task {
            defer { activationInProgress = false }
            do {
                try await store.activate(node)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func deactivate() {
        do {
            try store.deactivate()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func revealConfigFile() {
        let path = store.configPath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        }
    }
}

// MARK: - Node Card

private struct OpenCodeNodeCard: View {
    let node: OpenCodeNode
    let isActive: Bool
    let activationDisabled: Bool
    let onActivate: () -> Void
    let onDeactivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    private var brand: Color { OpenCodeManagementView.brand }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.quaternary)
                .frame(width: 14, height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { onDragChanged($0.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )
                .help(L("Drag to reorder", "拖拽排序"))

            ProviderIconView("opencode", size: 24)
                .opacity(isActive ? 1 : 0.65)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(node.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if isActive {
                        Text(L("Active", "生效中"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(brand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(brand.opacity(0.14)))
                    }
                    if node.proxyEnabled {
                        Text(L("Proxy", "代理"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.purple.opacity(0.12)))
                            .help(L(
                                "Goes through the local passthrough proxy on port \(String(node.proxyPort)) for request logs.",
                                "经端口 \(String(node.proxyPort)) 的本地透传代理访问上游，以获得请求日志。"
                            ))
                    }
                }
                Text(node.baseURL.nilIfBlank ?? L("Base URL not set", "未设置 Base URL"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Label("\(node.models.count)", systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let model = node.effectiveDefaultModel {
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(node.managedProviderId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(L(
                            "Provider id written into opencode.json. Usage Stats attributes model usage to this node via the \"\(node.managedProviderId)/model\" label.",
                            "写入 opencode.json 的 provider 标识。用量统计通过「\(node.managedProviderId)/模型」标签把用量归因到该节点。"
                        ))
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if isActive {
                    Button(L("Deactivate", "停用"), action: onDeactivate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button(L("Activate", "激活"), action: onActivate)
                        .buttonStyle(.borderedProminent)
                        .tint(brand)
                        .controlSize(.small)
                        .disabled(activationDisabled)
                }

                Menu {
                    Button(L("Edit", "编辑"), action: onEdit)
                    Divider()
                    Button(L("Delete", "删除"), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isActive ? brand.opacity(0.45) : Color.primary.opacity(0.06),
                    lineWidth: isActive ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2, perform: onEdit)
    }
}

// MARK: - Row Height Key
// 测量节点卡片真实高度，供拖拽让位的阈值/步幅计算（与 Codex 订阅列表同一套手感）。

private struct OpenCodeNodeRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

#Preview {
    OpenCodeManagementView()
        .frame(width: 800, height: 600)
}
