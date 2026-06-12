import SwiftUI
import QuotaBackend

// MARK: - OpenCode Node Card
// 节点卡片：与 Claude/Codex 节点卡片同一套视觉语言——
// 顶部协议徽章（Direct/Proxy 变体）、拖拽把手、左侧统计 pills（请求数/费用，来自
// opencode.db 节点归因）、名称/URL/连通性状态行、右侧动作区（激活开关 + 代理模式
// antenna + 连通性测试 + 编辑 + 删除）。单击内联展开配置明细，右键含复制节点。
// Equatable 化：输入不变的卡片跳过重渲染（选中态切换只重渲染两张卡）。

struct OpenCodeNodeCard: View, Equatable {
    let node: OpenCodeNode
    let isActive: Bool
    let isSelected: Bool
    let isBusy: Bool
    /// 激活开关不可用（jsonc 接管被禁 / 节点字段不完整）。
    let activationDisabled: Bool
    /// opencode.db 节点归因聚合（请求数/费用/最后使用）；尚无用量时为 nil。
    let statsRequests: Int
    let statsCostUsd: Double
    let lastRequestAt: Date?
    let connectivityState: ProxyConnectivityTestState?

    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onToggleActivation: () -> Void = {}
    var onToggleProxyMode: () -> Void = {}
    var onTestConnectivity: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onDelete: () -> Void = {}
    var onToggleSelection: () -> Void = {}

    /// 失败明细 Popover 的展开态。属于本卡片局部 UI 状态，不参与 Equatable 比较。
    /// 注意：必须为 internal（非 private），否则结构体的成员初始化器降级为 private，
    /// 破坏 OpenCodeManagementView 跨文件构造。
    @State var showConnectivityDetail = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node &&
        lhs.isActive == rhs.isActive &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isBusy == rhs.isBusy &&
        lhs.activationDisabled == rhs.activationDisabled &&
        lhs.statsRequests == rhs.statsRequests &&
        lhs.statsCostUsd == rhs.statsCostUsd &&
        lhs.lastRequestAt == rhs.lastRequestAt &&
        lhs.connectivityState == rhs.connectivityState
    }

    private static let openAIBrand = Color(red: 0.29, green: 0.73, blue: 0.56)
    private static let anthropicBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let responsesBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    private var brand: Color { OpenCodeManagementView.brand }

    /// 协议主题色（徽章用）。
    private var protocolColor: Color {
        switch node.protocolType {
        case .openAICompatible: return Self.openAIBrand
        case .anthropic: return Self.anthropicBrand
        case .openAIResponses: return Self.responsesBrand
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            protocolBadge

            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.quaternary)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.openHand.push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { onDragChanged($0.translation.height) }
                            .onEnded { _ in onDragEnded() }
                    )

                VStack(alignment: .trailing, spacing: 4) {
                    statPill(icon: "arrow.up.arrow.down", value: formatCompactNumber(Double(statsRequests)), color: .blue)
                        .help(L("Total Requests (opencode.db)", "总请求数（opencode.db）"))
                    statPill(icon: "dollarsign.circle", value: formatProxyCurrency(statsCostUsd), color: .green)
                        .help(L("Total Cost (opencode.db)", "总费用（opencode.db）"))
                }
                .frame(width: 80)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayName)
                        .font(.system(size: 15, weight: .bold))
                    Text(node.baseURL.nilIfBlank ?? L("Base URL not set", "未设置 Base URL"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    connectivityStatusLine
                }

                Spacer()

                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { isActive },
                        set: { newValue in if newValue != isActive { onToggleActivation() } }
                    ))
                    .toggleStyle(ProxyActivationToggleStyle(brandColor: brand, isBusy: isBusy))
                    .disabled(isBusy || (!isActive && activationDisabled))
                    .help(isActive
                          ? L("Restore opencode.json", "还原 opencode.json")
                          : L("Apply to OpenCode", "接入 OpenCode"))

                    Button(action: onToggleProxyMode) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14))
                            .foregroundStyle(node.proxyEnabled ? .purple : .gray.opacity(0.55))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(node.proxyEnabled
                          ? L("Proxy mode on: requests go through 127.0.0.1:\(String(node.proxyPort)) for request logs. Click to switch to direct.", "代理模式已开：请求经 127.0.0.1:\(String(node.proxyPort)) 以获得请求日志。点击切回直连。")
                          : L("Direct mode: click to route through a local proxy for request logs.", "直连模式：点击改走本地代理以获得请求日志。"))

                    connectivityControl

                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(L("Edit", "编辑"))

                    Button(action: onDelete) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(L("Delete", "删除"))
                }
            }

            if isSelected {
                Divider()
                detailContent
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(cardBackgroundColor)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(brand)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
                    .shadow(color: brand.opacity(0.4), radius: 4, x: 0, y: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(cardBorderColor, lineWidth: isActive ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelection)
        .contextMenu { cardContextMenu }
    }

    // MARK: - Card Styling

    private var cardBackgroundColor: Color {
        if isActive { return brand.opacity(0.06) }
        if isSelected { return brand.opacity(0.04) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    private var cardBorderColor: Color {
        if isActive { return brand.opacity(0.5) }
        if isSelected { return brand.opacity(0.25) }
        return Color.primary.opacity(0.06)
    }

    // MARK: - Protocol Badge

    private var protocolBadge: some View {
        let label = node.proxyEnabled
            ? "\(node.protocolType.displayName) Proxy"
            : "\(node.protocolType.displayName) Direct"
        let icon = node.proxyEnabled ? "bolt.shield.fill" : "bolt.horizontal.fill"

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
            Text(label)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(protocolColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(protocolColor.opacity(0.12)))
        .help(L(
            "Upstream protocol: OpenCode talks to this node via \(node.protocolType.requestPath).",
            "上游协议：OpenCode 通过 \(node.protocolType.requestPath) 与该节点通信。"
        ))
    }

    private func statPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Connectivity Test

    private var connectivityTint: Color {
        guard let succeeded = connectivityState?.lastSucceeded else { return .secondary }
        return succeeded ? .green : .red
    }

    private var connectivityControl: some View {
        Button(action: onTestConnectivity) {
            Group {
                if connectivityState?.isTesting == true {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(connectivityTint)
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || connectivityState?.isTesting == true)
        .help(connectivityState?.isTesting == true
              ? L("Testing Connectivity", "正在测试连通性")
              : L("Test Connectivity", "测试连通性"))
    }

    /// 连通性结果状态行（节点名/URL 下方常驻）：状态点 + 摘要 + 上次测试时间；
    /// 失败时整行可点开 Popover 查看完整报文。
    @ViewBuilder
    private var connectivityStatusLine: some View {
        if let state = connectivityState, !state.isTesting, let succeeded = state.lastSucceeded {
            if succeeded {
                connectivityStatusContent(
                    state: state,
                    color: .green,
                    systemImage: "checkmark.circle.fill",
                    text: connectivitySuccessText(state)
                )
            } else {
                Button {
                    showConnectivityDetail = true
                } label: {
                    HStack(spacing: 4) {
                        connectivityStatusContent(
                            state: state,
                            color: .red,
                            systemImage: "exclamationmark.circle.fill",
                            text: connectivityFailureText(state)
                        )
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(L("View error details", "查看错误详情"))
                .popover(isPresented: $showConnectivityDetail, arrowEdge: .bottom) {
                    connectivityDetailPopover(state)
                }
            }
        }
    }

    private func connectivityStatusContent(state: ProxyConnectivityTestState, color: Color, systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            if let testedAt = state.testedAt {
                Text(Self.relativeFormatter.localizedString(for: testedAt, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func connectivitySuccessText(_ state: ProxyConnectivityTestState) -> String {
        switch (state.statusCode, state.latencyMs) {
        case let (code?, ms?): return "\(code) · \(ms)ms"
        case let (code?, nil): return "\(code)"
        case let (nil, ms?): return "\(ms)ms"
        case (nil, nil): return L("OK", "正常")
        }
    }

    private func connectivityFailureText(_ state: ProxyConnectivityTestState) -> String {
        if let code = state.statusCode { return "\(code)" }
        return L("Failed", "失败")
    }

    private func connectivityDetailPopover(_ state: ProxyConnectivityTestState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(L("Connectivity Test Failed", "连通性测试失败"))
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: 8)
                if let code = state.statusCode {
                    Text("HTTP \(code)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ScrollView {
                Text((state.message?.isEmpty == false ? state.message : nil) ?? L("Unknown error", "未知错误"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            HStack(spacing: 8) {
                if let testedAt = state.testedAt {
                    Text(Self.relativeFormatter.localizedString(for: testedAt, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(state.message ?? "", forType: .string)
                } label: {
                    Label(L("Copy", "复制"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button {
                    showConnectivityDetail = false
                    onTestConnectivity()
                } label: {
                    Label(L("Retry", "重试"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isBusy)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        Button { onToggleActivation() } label: {
            Label(
                isActive ? L("Restore opencode.json", "还原 opencode.json") : L("Apply to OpenCode", "接入 OpenCode"),
                systemImage: isActive ? "stop.circle" : "power.circle"
            )
        }
        .disabled(isBusy || (!isActive && activationDisabled))

        Button { onToggleProxyMode() } label: {
            Label(
                node.proxyEnabled ? L("Switch to Direct", "切回直连") : L("Enable Proxy Mode", "开启代理模式"),
                systemImage: "antenna.radiowaves.left.and.right"
            )
        }
        .disabled(isBusy)

        Button { onTestConnectivity() } label: {
            Label(L("Test Connectivity", "测试连通性"), systemImage: "bolt.horizontal.circle")
        }
        .disabled(isBusy || connectivityState?.isTesting == true)

        Divider()

        Button { onEdit() } label: {
            Label(L("Edit", "编辑"), systemImage: "pencil")
        }
        Button { onDuplicate() } label: {
            Label(L("Duplicate", "复制节点"), systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) { onDelete() } label: {
            Label(L("Delete", "删除"), systemImage: "trash")
        }
    }

    // MARK: - Detail Content (inline expansion)

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailItem(label: "Base URL", value: node.baseURL.nilIfBlank ?? "—")
            detailItem(
                label: L("Protocol", "协议"),
                value: "\(node.protocolType.displayName) (\(node.protocolType.requestPath))"
            )
            detailItem(
                label: L("Models", "模型"),
                value: node.models.isEmpty
                    ? "—"
                    : L("\(node.models.count) models, default \(node.effectiveDefaultModel ?? "—")",
                        "\(node.models.count) 个，默认 \(node.effectiveDefaultModel ?? "—")")
            )
            detailItem(label: "Provider ID", value: node.managedProviderId)
            if node.proxyEnabled {
                detailItem(label: L("Local Proxy", "本地代理"), value: "http://127.0.0.1:\(String(node.proxyPort))")
            }
            if let lastUsed = lastRequestAt ?? node.lastUsedAt {
                detailItem(label: L("Last Used", "最后使用"), value: Self.relativeFormatter.localizedString(for: lastUsed, relativeTo: Date()))
            }
        }
        .font(.caption)
    }

    private func detailItem(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Row Height Key
// 测量节点卡片真实高度，供拖拽让位的阈值/步幅计算（与 Claude/Codex 节点列表同一套手感）。

struct OpenCodeNodeRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
