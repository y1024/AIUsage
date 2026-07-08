import SwiftUI

// MARK: - Global Proxy Section Scaffold
// 三轨（Codex / Claude / OpenCode）「全局统一代理」配置卡片的统一外壳，保证视觉与交互完全一致：
//   头部：图标 + 标题/副标题 + 「激活节点」胶囊下拉（紧邻开关，运行时热切换）+ 主开关；
//   状态行：运行/停用 + 端口；
//   配置区：停用态显示紧凑可编辑字段（端口 / 接口 / 模型）；运行态折叠为一行只读 chip 摘要。
//   错误行：操作失败提示。
// 各轨通过 nodeControl / config / runningSummary 三个 @ViewBuilder 注入差异内容；通用控件样式见下方
// GlobalProxyChipMenu / GlobalProxySummaryChip / GlobalProxyField / GlobalProxyInlineLabel / GlobalProxyTip。

struct GlobalProxySectionScaffold<NodeControl: View, Config: View, Summary: View>: View {
    let brand: Color
    let subtitle: String
    let isEnabled: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusLine
            if isEnabled {
                runningSummaryBlock
            } else {
                // 停用态始终显示配置区（含接口选择器）：即使当前接口下没有节点，也必须能切换接口，
                // 否则会卡死在「无节点接口」上再也切不回去。无节点时在配置区上方给出提示。
                if !hasNodes {
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                configBlock
            }
            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isEnabled ? brand.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }

    // MARK: - Header (title + active node + master toggle)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14))
                .foregroundStyle(brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Global Proxy", "全局代理"))
                    .font(.headline.weight(.bold))
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
            Toggle("", isOn: toggle)
                .labelsHidden()
                .toggleStyle(ProxyActivationToggleStyle(brandColor: brand, isBusy: isBusy))
                // 仅在「无节点且当前未启用」时禁止开启；已启用时永远允许关闭，避免卡死无法停用。
                .disabled((!hasNodes && !isEnabled) || isBusy)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(isEnabled
                 ? L("Running on \(bindHost):\(port)", "运行中 · \(bindHost):\(port)")
                 : L("Stopped", "已停用"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Running summary (read-only chips) / editable config block

    private var runningSummaryBlock: some View {
        GlobalProxyFlowLayout(spacing: 6) {
            if allowLAN.wrappedValue {
                GlobalProxySummaryChip(
                    label: L("LAN Access", "局域网访问"),
                    value: L("Enabled", "已启用")
                )
            }
            runningSummary()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var configBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Configuration", "配置"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            lanAccessToggle
            config()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private var lanAccessToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Allow LAN Access (0.0.0.0)", "允许局域网访问 (0.0.0.0)"), isOn: allowLAN)
                .font(.caption.weight(.medium))
            if allowLAN.wrappedValue {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L(
                        "Warning: This will expose the proxy to your local network",
                        "警告：这将把代理暴露到你的局域网"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }
        }
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

struct GlobalProxyChipMenu: View {
    let brand: Color
    let title: String
    var systemImage: String? = nil
    var isDisabled: Bool = false
    let items: [GlobalProxyPickerItem]
    let selectedId: String
    let onSelect: (String) -> Void

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
        .fixedSize()
        .disabled(isDisabled)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            panel
        }
    }

    private var panel: some View {
        ScrollView {
            VStack(spacing: 2) {
                if items.isEmpty {
                    Text(L("No nodes available", "暂无可用节点"))
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
            }
            .padding(6)
        }
        .frame(width: 240)
        .frame(maxHeight: 320)
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
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
