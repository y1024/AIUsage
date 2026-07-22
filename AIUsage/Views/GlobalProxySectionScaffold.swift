import SwiftUI

// MARK: - Global Proxy Section Scaffold
// 三轨（Codex / Claude / OpenCode）「全局统一代理」配置卡片的统一外壳，保证视觉与交互完全一致：
//   头部：图标 + 标题/状态 + 「激活节点」胶囊下拉 + 按需配置按钮 + 主开关；
//   摘要行：始终展示端口 / 接口 / 模型等高频信息；
//   配置区：默认收起，仅停用态由用户显式展开编辑，避免低频参数长期占据首屏。
//   错误行：操作失败提示。
// 各轨通过 nodeControl / config / runningSummary 三个 @ViewBuilder 注入差异内容；通用控件样式见下方
// GlobalProxyChipMenu / GlobalProxySummaryChip / GlobalProxyField / GlobalProxyInlineLabel / GlobalProxyTip。

struct GlobalProxySectionScaffold<NodeControl: View, Config: View, Summary: View>: View {
    let brand: Color
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let isRunning: Bool
    /// True when another consumer owns this shared runtime. The visible track
    /// toggle remains off, but connection settings must stay locked.
    let isRuntimeOwnedByAnotherConsumer: Bool
    let otherConsumerStatus: String?
    let isBusy: Bool
    let port: Int
    let bindHost: String
    let allowLAN: Binding<Bool>
    let hasNodes: Bool
    let emptyHint: String
    let errorText: String?
    let toggle: Binding<Bool>
    @ViewBuilder let nodeControl: () -> NodeControl
    @ViewBuilder let config: () -> Config
    @ViewBuilder let runningSummary: () -> Summary

    @State private var isConfigurationExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summaryLine

            if !hasNodes {
                emptyStateHint
            }

            if isConfigurationExpanded, !isConfigurationLocked {
                Divider()
                    .opacity(0.55)
                    .padding(.top, 12)
                configBlock
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let errorText {
                errorLine(errorText)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke((isEnabled || isRuntimeOwnedByAnotherConsumer) ? brand.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .animation(.easeInOut(duration: 0.18), value: isConfigurationExpanded)
        .onChange(of: isEnabled) { _, enabled in
            if enabled { isConfigurationExpanded = false }
        }
        .onChange(of: isRuntimeOwnedByAnotherConsumer) { _, owned in
            if owned { isConfigurationExpanded = false }
        }
    }

    // MARK: - Header (title + active node + master toggle)

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(brand.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(brand)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.headline.weight(.bold))
                    statusBadge
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if hasNodes {
                nodeControl()
            }
            if isBusy {
                ProgressView().controlSize(.small)
            }
            configurationButton
            Toggle("", isOn: toggle)
                .labelsHidden()
                .toggleStyle(ProxyActivationToggleStyle(brandColor: brand, isBusy: isBusy))
                // 仅在「无节点且当前未启用」时禁止开启；已启用时永远允许关闭，避免卡死无法停用。
                .disabled((!hasNodes && !isEnabled) || isBusy)
                .help(isEnabled
                      ? L("Turn off the global proxy", "停用全局代理")
                      : L("Turn on the global proxy", "启用全局代理"))
                .accessibilityLabel(isEnabled
                                    ? L("Turn off global proxy", "停用全局代理")
                                    : L("Turn on global proxy", "启用全局代理"))
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(statusColor.opacity(0.11)))
    }

    private var statusColor: Color {
        if isBusy { return .orange }
        if isEnabled, isRunning { return .green }
        if isEnabled { return .orange }
        if isRuntimeOwnedByAnotherConsumer, isRunning { return brand }
        if isRuntimeOwnedByAnotherConsumer { return .orange }
        return .secondary
    }

    private var statusText: String {
        if isBusy { return L("Working", "处理中") }
        if isEnabled, isRunning { return L("Running", "运行中") }
        if isEnabled { return L("Waiting", "等待启动") }
        if isRuntimeOwnedByAnotherConsumer, isRunning {
            return otherConsumerStatus ?? L("Shared", "共享中")
        }
        if isRuntimeOwnedByAnotherConsumer { return L("Waiting", "等待启动") }
        return L("Off", "未启用")
    }

    private var isConfigurationLocked: Bool {
        isEnabled || isRuntimeOwnedByAnotherConsumer
    }

    private var configurationButton: some View {
        Button {
            isConfigurationExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isConfigurationLocked ? "lock.fill" : "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text(isConfigurationExpanded ? L("Done", "完成") : L("Configure", "配置"))
                    .font(.system(size: 11, weight: .semibold))
                if !isConfigurationLocked {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isConfigurationExpanded ? 180 : 0))
                }
            }
            .foregroundStyle(isConfigurationLocked ? Color.secondary : brand)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.045)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isConfigurationLocked || isBusy)
        .help(isConfigurationLocked
              ? L("Disconnect every consumer of this runtime before editing connection settings",
                  "请先断开此运行时的所有消费者，再修改连接设置")
              : L("Edit connection settings", "编辑连接设置"))
        .accessibilityLabel(isConfigurationExpanded
                            ? L("Collapse global proxy settings", "收起全局代理设置")
                            : L("Configure global proxy", "配置全局代理"))
    }

    // MARK: - Always-visible summary / on-demand editor

    private var summaryLine: some View {
        HStack(alignment: .center, spacing: 8) {
            GlobalProxyFlowLayout(spacing: 6) {
                GlobalProxySummaryChip(
                    label: L("Endpoint", "入口"),
                    value: "\(bindHost):\(port)"
                )
                if allowLAN.wrappedValue {
                    GlobalProxySummaryChip(
                        label: L("LAN", "局域网"),
                        value: L("On", "已开放")
                    )
                }
                runningSummary()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 10)
    }

    private var configBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(L("Connection Settings", "连接设置"), systemImage: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(L("LAN Access", "局域网访问"), isOn: allowLAN)
                    .font(.system(size: 11, weight: .medium))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(L(
                        "Off keeps the proxy available only on this Mac. Turn it on only when another device on your local network must connect.",
                        "关闭时仅本机可用；只有同一局域网中的其它设备需要连接时才开启。"
                    ))
            }
            lanWarning
            config()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(brand.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(brand.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder private var lanWarning: some View {
        if allowLAN.wrappedValue {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L(
                    "Other devices on your local network can now reach this proxy.",
                    "同一局域网中的其它设备现在可以访问此代理。"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.1)))
        }
    }

    private var emptyStateHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(emptyHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    private func errorLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }
}

// MARK: - Chip Picker (custom popover; unified with menu bar panel)
// 胶囊触发器 + 自定义 popover 面板：取代旧的系统 `.menu` 下拉。面板行样式与顶部菜单栏
// 节点切换面板（MenuBarPanelRowView）完全一致：激活行品牌色高亮 + 勾选 + 左侧色条 + hover。
// 数据驱动（items + selectedId + onSelect），节点选择与接口选择共用同一套观感。

/// 选择面板里的一项（节点 / 接口）。
struct GlobalProxyPickerItem: Identifiable {
    let id: String
    let name: String
}

/// Chip 菜单底部操作（新建 / 重命名 / 危险操作等）。
struct GlobalProxyChipMenuAction: Identifiable {
    let id: String
    let title: String
    var systemImage: String? = nil
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void
}

struct GlobalProxyChipMenu: View {
    let brand: Color
    let title: String
    var systemImage: String? = nil
    var isDisabled: Bool = false
    let items: [GlobalProxyPickerItem]
    let selectedId: String
    let onSelect: (String) -> Void
    var footerActions: [GlobalProxyChipMenuAction] = []
    var emptyMessage: String = L("No nodes available", "暂无可用节点")

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .opacity(0.9)
            }
        }
        .buttonStyle(GlobalProxyChipButtonStyle(brand: brand, isDisabled: isDisabled))
        .disabled(isDisabled)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            panel
        }
    }

    private var panel: some View {
        ScrollView {
            VStack(spacing: 2) {
                if items.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                } else {
                    ForEach(items) { item in
                        GlobalProxyPickerRow(
                            brand: brand,
                            name: item.name,
                            isActive: item.id == selectedId
                        ) {
                            onSelect(item.id)
                            isOpen = false
                        }
                    }
                }
                if !footerActions.isEmpty {
                    Divider().padding(.vertical, 4)
                    ForEach(footerActions) { action in
                        GlobalProxyChipFooterRow(
                            title: action.title,
                            systemImage: action.systemImage,
                            isDestructive: action.isDestructive,
                            isDisabled: action.isDisabled
                        ) {
                            guard !action.isDisabled else { return }
                            isOpen = false
                            action.action()
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 260)
        .frame(maxHeight: 360)
    }
}

private struct GlobalProxyChipFooterRow: View {
    let title: String
    let systemImage: String?
    let isDestructive: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(isDestructive ? Color.red.opacity(isDisabled ? 0.4 : 0.9) : Color.secondary)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDestructive ? Color.red.opacity(isDisabled ? 0.4 : 1) : Color.primary.opacity(isDisabled ? 0.4 : 1))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered && !isDisabled ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovered = $0 }
    }
}

/// 面板内一行：与菜单栏 MenuBarPanelRowView 同款（激活高亮 + 勾选 + 左侧色条 + hover）。
private struct GlobalProxyPickerRow: View {
    let brand: Color
    let name: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? brand : Color.secondary.opacity(0.45))
                Text(name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? brand.opacity(0.16)
                          : (hovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(brand)
                        .frame(width: 3, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// 胶囊触发器外观由 ButtonStyle 绘制，保证边框/底色一定可见。
private struct GlobalProxyChipButtonStyle: ButtonStyle {
    let brand: Color
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isDisabled ? Color.secondary : brand)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(brand.opacity(isDisabled ? 0.08 : 0.20))
            )
            .overlay(
                Capsule().stroke(brand.opacity(isDisabled ? 0.25 : 0.65), lineWidth: 1.2)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Read-only summary chip (running state)

struct GlobalProxySummaryChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Flow layout (wrapping row of chips)

struct GlobalProxyFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Shared Field Components
// 三轨配置区共用的字段样式，确保「端口 / 接口 / 模型」在三套卡片里完全一致。

/// 小标签在上、控件在下的竖排字段（端口 / 模型 / 接口）。
struct GlobalProxyField<Content: View>: View {
    let label: String
    var fillWidth: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }
}

/// 横排「标签 + 控件」里的标签（用于头部「激活节点」）。
struct GlobalProxyInlineLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// 配置区底部的浅色说明（模型名可任意取名等）。
struct GlobalProxyTip: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.tertiary)
        .help(text)
    }
}

// MARK: - Claude Model Mode Selector

/// Shared Code/Desktop mode control. The layout is deliberately content-sized:
/// the two choices read as one product decision instead of two full-width cards.
struct ClaudeModelModeSelector: View {
    let selection: ClaudeDesktopCatalogMode
    let brand: Color
    let nodeModelsDetail: String
    let isDisabled: Bool
    let onSelect: (ClaudeDesktopCatalogMode) -> Void

    var body: some View {
        HStack(spacing: 8) {
            option(
                .smartRoutes,
                title: L("Hot switch", "热切换"),
                detail: L("4 stable model routes", "固定 4 个模型入口"),
                symbol: "arrow.triangle.2.circlepath"
            )
            option(
                .fullNodeCatalog,
                title: L("Node models", "节点模型"),
                detail: nodeModelsDetail,
                symbol: "square.stack.3d.up"
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func option(
        _ mode: ClaudeDesktopCatalogMode,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        let selected = selection == mode
        return Button {
            guard !selected else { return }
            onSelect(mode)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? brand : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? brand.opacity(0.13) : Color.primary.opacity(0.04))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? brand : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 246, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? brand.opacity(0.065) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? brand.opacity(0.34) : Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shared Claude Model Catalog

/// A compact, adaptive model directory shared by Code, Desktop and Science.
/// Keeping this visual grammar identical makes a real upstream catalog
/// recognizable across products while each product retains its own behavior.
struct ClaudeModelCatalogItem: Identifiable, Equatable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    var help: String? = nil
    var isDefault = false
}

struct ClaudeModelCatalogGrid: View {
    let items: [ClaudeModelCatalogItem]
    let brand: Color
    @Binding var showAll: Bool
    var collapsedLimit = 6

    private var visibleItems: ArraySlice<ClaudeModelCatalogItem> {
        showAll ? items[...] : items.prefix(collapsedLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(visibleItems) { item in
                    row(item)
                }
            }

            if items.count > collapsedLimit {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showAll.toggle() }
                } label: {
                    Label(
                        showAll
                            ? L("Show less", "收起")
                            : L("Show all \(items.count) models", "显示全部 \(items.count) 个模型"),
                        systemImage: showAll ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(brand)
            }
        }
    }

    private func row(_ item: ClaudeModelCatalogItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isDefault ? "star.fill" : "circle.fill")
                .font(.system(size: item.isDefault ? 10 : 5, weight: .semibold))
                .foregroundStyle(item.isDefault ? brand : Color.secondary.opacity(0.55))
                .frame(width: 14, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = item.subtitle?.nilIfBlank, subtitle != item.title {
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let badge = item.badge?.nilIfBlank {
                Text(badge)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(brand)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(brand.opacity(0.10)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(item.isDefault ? brand.opacity(0.24) : Color.primary.opacity(0.055), lineWidth: 1)
        )
        .help(item.help ?? item.subtitle ?? item.title)
    }
}

// MARK: - Shared Claude Product Model Routes

/// Compact four-route editor used by product gateways. The color belongs to
/// the route role, while the surrounding brand color keeps Code and Desktop
/// visually distinct. Selecting a model never mutates the Node configuration.
struct ClaudeModelRouteBoard: View {
    let productName: String
    let brand: Color
    var showsStableRouteNames = true
    let catalog: [String]
    let nodeDefaults: ClaudeAppResolvedModels
    let resolved: ClaudeAppResolvedModels
    let overrides: ClaudeAppNodeModelOverride?
    let isDisabled: Bool
    let onSelect: (ClaudeAppModelRoute, String) -> Void
    let onReset: () -> Void

    private var hasOverrides: Bool { overrides?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L("Application model routes", "应用模型映射"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L("4 routes", "4 个入口"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(brand)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(brand.opacity(0.10)))
                Spacer(minLength: 8)
                if hasOverrides {
                    Button(action: onReset) {
                        Label(L("Reset", "恢复默认"), systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(brand)
                    .disabled(isDisabled)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 245, maximum: 360), spacing: 9)],
                alignment: .leading,
                spacing: 9
            ) {
                ForEach(ClaudeAppModelRoute.allCases) { route in
                    routeMenu(route)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(brand.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(brand.opacity(0.13)))
    }

    private func routeMenu(_ route: ClaudeAppModelRoute) -> some View {
        let effective = resolved.model(for: route)
        let nodeDefault = nodeDefaults.model(for: route)
        let overridden = overrides?.model(for: route) != nil
        let color = routeColor(route)

        return HStack(spacing: 10) {
            Image(systemName: routeSymbol(route))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.13)))

            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    Button {
                        onSelect(route, nodeDefault)
                    } label: {
                        Label(
                            L("Node default · \(nodeDefault)", "节点默认 · \(nodeDefault)"),
                            systemImage: effective == nodeDefault ? "checkmark" : "arrow.counterclockwise"
                        )
                    }
                    Divider()
                    ForEach(catalog, id: \.self) { model in
                        Button {
                            onSelect(route, model)
                        } label: {
                            if model == effective {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(showsStableRouteNames ? "AIUsage \(route.title)" : route.title)
                            .font(.caption.weight(.bold))
                        Text(overridden ? L("Override", "应用覆盖") : L("Node", "跟随节点"))
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(overridden ? color : Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(overridden ? color.opacity(0.14) : Color.primary.opacity(0.055))
                            )
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(isDisabled)

                HStack(spacing: 5) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color.opacity(0.82))
                    Text(effective)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Capsule())
        .background(Capsule().fill(color.opacity(overridden ? 0.13 : 0.055)))
        .overlay(Capsule().stroke(color.opacity(overridden ? 0.42 : 0.17), lineWidth: 1))
        .opacity(isDisabled ? 0.55 : 1)
        .help(L(
            "Changes only \(productName)'s route for this node. The Node default is untouched.",
            "只修改当前节点在 \(productName) 中的映射，不会改动节点默认配置。"
        ))
    }

    private func routeColor(_ route: ClaudeAppModelRoute) -> Color {
        switch route {
        case .defaultModel: return brand
        case .opus: return Color(red: 0.62, green: 0.39, blue: 0.90)
        case .sonnet: return Color(red: 0.91, green: 0.49, blue: 0.24)
        case .haiku: return Color(red: 0.18, green: 0.66, blue: 0.62)
        }
    }

    private func routeSymbol(_ route: ClaudeAppModelRoute) -> String {
        switch route {
        case .defaultModel: return "sparkles"
        case .opus: return "diamond.fill"
        case .sonnet: return "waveform.path"
        case .haiku: return "bolt.fill"
        }
    }
}

/// Makes ownership explicit where the product itself already controls effort.
struct ClaudeEffortOwnershipRow: View {
    let productName: String
    let brand: Color
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(brand)
                .frame(width: 27, height: 27)
                .background(Circle().fill(brand.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Reasoning effort", "思考强度"))
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(L("Controlled by \(productName)", "由 \(productName) 控制"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(brand)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(brand.opacity(0.10)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.055)))
    }
}
