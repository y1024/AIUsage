import SwiftUI

// MARK: - OpenCode Management View
// 「OpenCode 代理」主视图：节点列表 + 一键接管/还原 opencode.json。
// 与 Claude/Codex 代理不同：OpenCode 原生支持 OpenAI 兼容上游，无本地代理进程，
// 激活即把节点（baseURL/APIKey/模型）写入受管 provider 块，停用即整文还原。

struct OpenCodeManagementView: View {
    @ObservedObject private var store = OpenCodeNodeStore.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var editingNode: OpenCodeNode?
    @State private var pendingDeletion: OpenCodeNode?
    @State private var actionError: String?

    static let brand = Color(red: 0.18, green: 0.83, blue: 0.75)

    var body: some View {
        VStack(spacing: 0) {
            if store.nodes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        statusBanner
                        actionBar
                        nodeList
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
                message: L(
                    "OpenCode now talks to this node directly. Restart OpenCode sessions for the change to take effect.",
                    "OpenCode 将直连该节点。重启 OpenCode 会话后生效。"
                ),
                trailing: AnyView(
                    Button(L("Deactivate", "停用")) { deactivate() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
        VStack(spacing: 10) {
            ForEach(store.nodes) { node in
                OpenCodeNodeCard(
                    node: node,
                    isActive: node.id == store.activeNodeId,
                    activationDisabled: store.usesJSONC || !node.isComplete,
                    onActivate: { activate(node) },
                    onDeactivate: { deactivate() },
                    onEdit: { editingNode = node },
                    onDelete: { pendingDeletion = node }
                )
            }
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
                "Add an OpenAI-compatible endpoint (base URL + API key + models). Activating a node writes it into opencode.json so OpenCode talks to it directly — no local proxy involved.",
                "添加一个 OpenAI 兼容接入点（Base URL + API Key + 模型）。激活节点会把它写入 opencode.json，OpenCode 直连该接入点，无需本地代理。"
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
        do {
            try store.activate(node)
        } catch {
            actionError = error.localizedDescription
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

    @Environment(\.colorScheme) private var colorScheme

    private var brand: Color { OpenCodeManagementView.brand }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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

#Preview {
    OpenCodeManagementView()
        .frame(width: 800, height: 600)
}
