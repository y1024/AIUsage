import SwiftUI
import QuotaBackend

// MARK: - Configuration Card (Equatable)

/// Standalone Equatable View so SwiftUI can skip re-rendering cards whose inputs haven't changed.
/// When `selectedConfigId` changes, only the previously-selected and newly-selected cards re-render;
/// the rest are skipped entirely. Same optimization applies during drag-and-drop state changes.
struct ConfigurationCardView: View, Equatable {
    let config: ProxyConfiguration
    let isActive: Bool
    let isProxyOnlyRunning: Bool
    let isBusy: Bool
    let isSelected: Bool
    let statsRequests: Int
    let statsSuccessRate: Double
    let lastRequestAt: Date?
    let connectivityState: ProxyConnectivityTestState?

    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onToggleActivation: () -> Void = {}
    var onToggleProxyOnly: () -> Void = {}
    var onCopyLaunchCommand: () -> Void = {}
    var onTestConnectivity: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onToggleSelection: () -> Void = {}

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.config == rhs.config &&
        lhs.isActive == rhs.isActive &&
        lhs.isProxyOnlyRunning == rhs.isProxyOnlyRunning &&
        lhs.isBusy == rhs.isBusy &&
        lhs.isSelected == rhs.isSelected &&
        lhs.statsRequests == rhs.statsRequests &&
        lhs.statsSuccessRate == rhs.statsSuccessRate &&
        lhs.lastRequestAt == rhs.lastRequestAt &&
        lhs.connectivityState == rhs.connectivityState
    }

    private static let anthropicBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let openAIBrand = Color(red: 0.29, green: 0.73, blue: 0.56)
    private static let codexBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    private var brandColor: Color {
        switch config.nodeType {
        case .anthropicDirect: return Self.anthropicBrand
        case .openaiProxy: return Self.openAIBrand
        case .codexProxy: return Self.codexBrand
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            nodeTypeBadge

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
                    statPill(icon: "arrow.up.arrow.down", value: "\(statsRequests)", color: .blue)
                        .help(L("Total Requests", "总请求数"))
                    statPill(icon: "checkmark.circle", value: String(format: "%.0f%%", statsSuccessRate), color: .green)
                        .help(L("Success Rate", "成功率"))
                }
                .frame(width: 80)
                .opacity(config.needsProxyProcess ? 1 : 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(config.name)
                        .font(.system(size: 15, weight: .bold))
                    Text(config.displayURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { isActive },
                        set: { newValue in if newValue != isActive { onToggleActivation() } }
                    ))
                    .toggleStyle(ProxyActivationToggleStyle(
                        brandColor: brandColor,
                        isBusy: isBusy
                    ))
                    .disabled(isBusy)
                    .instantTooltip(isActive
                          ? L("Disconnect Claude", "断开 Claude")
                          : L("Apply to Claude", "接入 Claude"))

                    if config.needsProxyProcess {
                        Button(action: onToggleProxyOnly) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14))
                                .foregroundStyle(isActive ? .gray.opacity(0.4) : isProxyOnlyRunning ? .orange : .purple)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy || isActive)
                        .instantTooltip(isActive
                              ? L("Unavailable while connected to Claude", "接入 Claude 时不可用")
                              : isProxyOnlyRunning
                              ? L("Stop Proxy", "停止代理")
                              : L("Start Proxy", "启动代理"))
                    }

                    Button(action: onCopyLaunchCommand) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .instantTooltip(L("Copy Launch Command", "复制启动命令"))

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
                    .instantTooltip(connectivityTooltip)

                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .instantTooltip(L("Edit", "编辑"))

                    Button(action: onDelete) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .instantTooltip(L("Delete", "删除"))
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
            if isActive || isProxyOnlyRunning {
                let statusColor = isActive ? brandColor : Color.purple
                Capsule()
                    .fill(statusColor)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
                    .shadow(color: statusColor.opacity(0.4), radius: 4, x: 0, y: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(cardBorderColor, lineWidth: (isActive || isProxyOnlyRunning) ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelection)
        .contextMenu { cardContextMenu }
    }

    // MARK: - Card Styling

    private var cardBackgroundColor: Color {
        if isActive { return brandColor.opacity(0.06) }
        if isProxyOnlyRunning { return Color.purple.opacity(0.04) }
        if isSelected { return brandColor.opacity(0.04) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    private var cardBorderColor: Color {
        if isActive { return brandColor.opacity(0.5) }
        if isProxyOnlyRunning { return Color.purple.opacity(0.35) }
        if isSelected { return brandColor.opacity(0.25) }
        return Color.primary.opacity(0.06)
    }

    private var connectivityTint: Color {
        switch connectivityState?.lastSucceeded {
        case true: return .green
        case false: return .red
        case nil: return .orange
        }
    }

    private var connectivityTooltip: String {
        if connectivityState?.isTesting == true {
            return L("Testing Connectivity", "正在测试连通性")
        }
        if let message = connectivityState?.message, !message.isEmpty {
            return message
        }
        return L("Test Connectivity", "测试连通性")
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        Button { onToggleActivation() } label: {
            Label(
                isActive ? L("Disconnect Claude", "断开 Claude") : L("Apply to Claude", "接入 Claude"),
                systemImage: isActive ? "stop.circle" : "power.circle"
            )
        }
        .disabled(isBusy)

        if config.needsProxyProcess {
            Button { onToggleProxyOnly() } label: {
                Label(
                    isActive
                        ? L("Unavailable while connected to Claude", "接入 Claude 时不可用")
                        : isProxyOnlyRunning ? L("Stop Proxy", "停止代理") : L("Start Proxy", "启动代理"),
                    systemImage: "antenna.radiowaves.left.and.right"
                )
            }
            .disabled(isBusy || isActive)
        }

        Button { onCopyLaunchCommand() } label: {
            Label(L("Copy Launch Command", "复制启动命令"), systemImage: "doc.on.clipboard")
        }

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

    // MARK: - Subviews

    private var nodeTypeBadge: some View {
        let (label, icon, color): (String, String, Color) = {
            switch config.nodeType {
            case .anthropicDirect:
                if config.usePassthroughProxy {
                    return ("Anthropic Proxy", "bolt.shield.fill", Self.anthropicBrand)
                }
                return ("Anthropic Direct", "bolt.horizontal.fill", Self.anthropicBrand)
            case .openaiProxy:
                return ("OpenAI Proxy", "arrow.triangle.swap", Self.openAIBrand)
            case .codexProxy:
                return ("Codex Proxy", "terminal.fill", Self.codexBrand)
            }
        }()

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
            Text(label)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch config.nodeType {
            case .anthropicDirect:
                detailItem(label: "Base URL", value: config.anthropicBaseURL)
                if config.usePassthroughProxy {
                    detailItem(label: L("Local Proxy", "本地代理"), value: "http://\(config.host):\(config.port)")
                    if config.enableHTTPS {
                        detailItem(label: "HTTPS", value: "https://\(config.host):\(config.effectiveHTTPSPort)")
                    }
                    detailItem(label: L("LAN Access", "局域网访问"), value: config.allowLAN ? L("Enabled", "已启用") : L("Disabled", "已禁用"))
                }
            case .openaiProxy:
                detailItem(label: L("Upstream", "上游"), value: config.normalizedUpstreamBaseURL)
                detailItem(label: L("API Mode", "接口模式"), value: config.openAIUpstreamAPI == .chatCompletions ? "Chat Completions" : "Responses")
                detailItem(
                    label: L("Model Mapping", "模型映射"),
                    value: "Opus\u{2192}\(config.modelMapping.bigModel.name), Sonnet\u{2192}\(config.modelMapping.middleModel.name), Haiku\u{2192}\(config.modelMapping.smallModel.name)"
                )
                detailItem(label: L("Local Proxy", "本地代理"), value: "http://\(config.host):\(config.port)")
                if config.enableHTTPS {
                    detailItem(label: "HTTPS", value: "https://\(config.host):\(config.effectiveHTTPSPort)")
                }
                detailItem(label: L("LAN Access", "局域网访问"), value: config.allowLAN ? L("Enabled", "已启用") : L("Disabled", "已禁用"))
            case .codexProxy:
                detailItem(label: L("Upstream", "上游"), value: config.normalizedUpstreamBaseURL)
                detailItem(label: L("API Mode", "接口模式"), value: "Responses")
                detailItem(label: L("Model", "模型"), value: config.codexModel.isEmpty ? "—" : config.codexModel)
                detailItem(label: L("Codex Endpoint", "Codex 接入"), value: "http://\(config.host):\(config.port)/v1")
                detailItem(label: L("LAN Access", "局域网访问"), value: config.allowLAN ? L("Enabled", "已启用") : L("Disabled", "已禁用"))
            }
            if let lastUsed = lastRequestAt ?? config.lastUsedAt {
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
        }
    }
}

// MARK: - Proxy Activation Toggle Style

// 复用：Codex 账号列表的激活开关也用此样式，保持与节点列表一致。
struct ProxyActivationToggleStyle: ToggleStyle {
    let brandColor: Color
    let isBusy: Bool

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 22
    private let thumbDiameter: CGFloat = 16
    private let thumbPadding: CGFloat = 3

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        Button {
            guard !isBusy else { return }
            configuration.isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? brandColor : Color.gray.opacity(0.35))
                    .frame(width: trackWidth, height: trackHeight)

                Capsule()
                    .strokeBorder(isOn ? brandColor.opacity(0.6) : Color.gray.opacity(0.2), lineWidth: 0.5)
                    .frame(width: trackWidth, height: trackHeight)

                HStack {
                    if isOn { Spacer() }

                    Group {
                        if isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: thumbDiameter, height: thumbDiameter)
                        } else {
                            Circle()
                                .fill(.white)
                                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                                .frame(width: thumbDiameter, height: thumbDiameter)
                        }
                    }

                    if !isOn { Spacer() }
                }
                .padding(.horizontal, thumbPadding)
                .frame(width: trackWidth)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
    }
}

// MARK: - Instant Tooltip Modifier

private struct InstantTooltip: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isHovering {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .fixedSize()
                        .offset(y: 26)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                        .zIndex(100)
                }
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
    }
}

extension View {
    fileprivate func instantTooltip(_ text: String) -> some View {
        modifier(InstantTooltip(text: text))
    }
}
