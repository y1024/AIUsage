import SwiftUI

// MARK: - Menu Bar Track Panel
// 顶部菜单栏三轨切换器的自定义面板（取代原生 Menu 行）。以内嵌覆盖层形式弹出，
// 因为菜单栏宿主是 transient NSPopover，嵌套系统 popover 不可靠。
// 组成：头部「全局代理」开关 + 端口/热切换说明（仅 ON）+ 高亮节点行 + 底部停用。
// 轨道差异（节点来源、订阅、动作）由调用方算成 section/closure 注入，本视图只渲染。

/// 面板内一行（节点 / 订阅账号）。
struct MenuBarTrackPanelRow: Identifiable {
    let id: String
    let name: String
    var subtitle: String? = nil
    var isActive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void
}

/// 面板内一个分区（可选标题 + 若干行）。
struct MenuBarTrackPanelSection: Identifiable {
    let id: String
    var title: String? = nil
    let rows: [MenuBarTrackPanelRow]
}

struct MenuBarTrackPanel: View {
    let title: String
    let brandAsset: String
    let accent: Color
    @ObservedObject var manager: GlobalProxyManager

    /// 该轨是否有可参与全局代理的节点（决定能否开启全局）。
    let canEnableGlobal: Bool
    /// 各分区（调用方按「全局开/关」模式算好）。
    let sections: [MenuBarTrackPanelSection]
    /// 每节点激活模式下的「停用当前节点」；无激活时为 nil。
    let onDeactivateActiveNode: (() -> Void)?
    /// 开启全局代理（调用方算好初始激活节点）。
    let onEnableGlobal: () -> Void
    /// 停用全局代理。
    let onDisableGlobal: () -> Void

    private var isGlobal: Bool { manager.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isGlobal {
                Text(routeSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            if let t = section.title {
                                Text(t)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 2)
                            }
                            if section.rows.isEmpty {
                                Text(L("None", "暂无"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(section.rows) { row in
                                    MenuBarPanelRowView(row: row, accent: accent)
                                        .disabled(manager.isBusy)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 300)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderIconView(brandAsset, size: 18)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
            Spacer(minLength: 8)
            if manager.isBusy {
                SmallProgressView().frame(width: 12, height: 12)
            }
            Text(manager.track == .claude ? L("Use Gateway", "接入 Gateway") : L("Global", "全局代理"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { isGlobal },
                set: { newValue in newValue ? onEnableGlobal() : onDisableGlobal() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(accent)
            .disabled(manager.isBusy || (!isGlobal && !canEnableGlobal))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var footer: some View {
        if isGlobal {
            Divider()
            footerButton(title: manager.track == .claude
                         ? L("Disconnect Code Gateway", "断开 Code Gateway")
                         : L("Disable global proxy", "停用全局代理"),
                         icon: "bolt.slash.fill", tint: .red, action: onDisableGlobal)
                .disabled(manager.isBusy)
        } else if let onDeactivateActiveNode {
            Divider()
            footerButton(title: L("Deactivate node", "停用当前节点"),
                         icon: "stop.circle", tint: .secondary, action: onDeactivateActiveNode)
        }
    }

    private var routeSummary: String {
        if manager.track == .claude,
           manager.config.effectiveClaudeCodeCatalogMode == .fullNodeCatalog {
            return L(
                "Fixed port :\(manager.config.port) · node models · restart Code",
                "固定端口 :\(manager.config.port) · 节点模型 · 需重启 Code"
            )
        }
        return L(
            "Fixed port :\(manager.config.port) · hot-swap",
            "固定端口 :\(manager.config.port) · 热切换"
        )
    }

    private func footerButton(title: String, icon: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct MenuBarPanelRowView: View {
    let row: MenuBarTrackPanelRow
    let accent: Color
    @State private var hovered = false

    var body: some View {
        Button(action: row.action) {
            HStack(spacing: 9) {
                Image(systemName: row.isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(row.isActive ? accent : Color.secondary.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 12, weight: row.isActive ? .semibold : .regular))
                        .foregroundStyle(row.isDisabled ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let sub = row.subtitle {
                        Text(sub)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(row.isActive ? accent.opacity(0.16)
                          : (hovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if row.isActive {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent)
                        .frame(width: 3, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.isDisabled)
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
    }
}
