import SwiftUI

// MARK: - Global Proxy Section Scaffold
// 三轨（Codex / Claude / OpenCode）「全局统一代理」配置卡片的统一外壳，保证视觉与交互完全一致：
//   头部：图标 + 标题/副标题 + 「激活节点」下拉（紧邻开关，运行时热切换）+ 主开关；
//   状态行：运行/停用 + 端口；
//   「配置」折叠区：只在停用态可改的端口 / 接口 / 模型名（停用展开、运行收起）；
//   错误行：操作失败提示。
// 各轨仅通过 nodeControl / config 两个 @ViewBuilder 注入差异内容；通用字段样式见下方
// GlobalProxyField / GlobalProxyInlineLabel / GlobalProxyTip。

struct GlobalProxySectionScaffold<NodeControl: View, Config: View>: View {
    let brand: Color
    let subtitle: String
    let isEnabled: Bool
    let isBusy: Bool
    let port: Int
    let hasNodes: Bool
    let emptyHint: String
    let errorText: String?
    let toggle: Binding<Bool>
    @ViewBuilder let nodeControl: () -> NodeControl
    @ViewBuilder let config: () -> Config

    /// 配置区展开态：停用时默认展开（方便配置），运行时收起（不可改且让位状态展示）。
    @State private var isExpanded: Bool

    init(
        brand: Color,
        subtitle: String,
        isEnabled: Bool,
        isBusy: Bool,
        port: Int,
        hasNodes: Bool,
        emptyHint: String,
        errorText: String?,
        toggle: Binding<Bool>,
        @ViewBuilder nodeControl: @escaping () -> NodeControl,
        @ViewBuilder config: @escaping () -> Config
    ) {
        self.brand = brand
        self.subtitle = subtitle
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.port = port
        self.hasNodes = hasNodes
        self.emptyHint = emptyHint
        self.errorText = errorText
        self.toggle = toggle
        self.nodeControl = nodeControl
        self.config = config
        _isExpanded = State(initialValue: !isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusLine
            if hasNodes {
                configDisclosure
            } else {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .onChange(of: isEnabled) { _, enabled in
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded = !enabled }
        }
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
                .disabled(!hasNodes || isBusy)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(isEnabled
                 ? L("Running on 127.0.0.1:\(port)", "运行中 · 127.0.0.1:\(port)")
                 : L("Stopped", "已停用"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Collapsible Configuration

    private var configDisclosure: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                config()
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(L("Configuration", "配置"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
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
