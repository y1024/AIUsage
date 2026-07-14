import AppKit
import SwiftUI

struct SubscriptionGatewayConnectionsView: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var selectedTargets: Set<ProxyTarget>

    @State private var pendingRemoval: Set<ProxyTarget>?
    @State private var lastAppliedAt: Date?
    @State private var showAdditionalRoutes = false
    @State private var endpointScope: GatewayEndpointScope = .thisMac
    @State private var selectedLANAddress: String?
    @State private var selectedProtocol: GatewayProtocolEndpoint?
    /// 接入页草稿：仅点「应用」后才写入 Manager / 分发到 OpenCode 节点。
    @State private var draftOpenCodeProtocol: OpenCodeProtocol = .openAIResponses
    /// Claude 系列（Code + Science）共用草稿。
    @State private var draftClaudeProtocol: ManagedClaudeProtocol = .anthropicPassthrough

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                errorBanners

                GatewayCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("AIUsage managed connections", "AIUsage 托管接入"))
                                    .font(.subheadline.weight(.semibold))
                                Text(L(
                                    "Pick apps that should use the CPA pool.",
                                    "选择要使用 CPA 账号池的应用。"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if hasPendingChanges {
                                GatewayQuietBadge(text: L("Unsaved", "未保存"), tint: .orange)
                            } else {
                                GatewayQuietBadge(
                                    text: L(
                                        "\(actualTargets.count) connected",
                                        "已接 \(actualTargets.count)"
                                    ),
                                    tint: .blue
                                )
                            }
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(ProxyTarget.localProxyTargets) { target in
                                targetCard(target)
                            }
                        }

                        connectionFooter
                    }
                }

                localAPIClientsCard
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .onAppear {
            // 有未应用改动时保留草稿，避免切 Tab 回来被静默重置。
            guard !hasPendingChanges else { return }
            selectedTargets = actualTargets
            draftOpenCodeProtocol = manager.managedOpenCodeProtocol
            draftClaudeProtocol = manager.managedClaudeProtocol
        }
        .sheet(item: $selectedProtocol) { endpoint in
            GatewayEndpointDetailSheet(
                endpoint: endpoint,
                origin: selectedOrigin,
                clientAPIKey: runtime.clientAPIKey,
                modelOptions: endpoint.requiresModel
                    ? manager.modelCatalog
                        .filter { $0.protocols.contains(.gemini) }
                        .flatMap { $0.models(for: .gemini) }
                    : []
            )
        }
        .alert(
            L("Remove Existing Connections?", "移除已有接入？"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { _ in
            Button(L("Remove and Apply", "移除并应用"), role: .destructive) {
                pendingRemoval = nil
                applyConnections()
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingRemoval = nil }
        } message: { targets in
            Text(L(
                "AIUsage will remove the managed gateway node from: \(targetNames(targets)). Other nodes and the CPA account pool are unchanged.",
                "AIUsage 将从以下代理中删除托管网关节点：\(targetNames(targets))。其他节点和 CPA 账号池不会改变。"
            ))
        }
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError { GatewayErrorBanner(message: error) }
        if case .failed(let error) = runtime.state { GatewayErrorBanner(message: error) }
    }

    private func targetCard(_ target: ProxyTarget) -> some View {
        let selected = selectedTargets.contains(target)
        let connected = actualTargets.contains(target)
        return Button {
            if selected { selectedTargets.remove(target) }
            else { selectedTargets.insert(target) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    GatewayProviderIcon(providerID: target.gatewayProviderID, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.gatewayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(targetSubtitle(target, selected: selected))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                }
                connectionPill(selected: selected, connected: connected)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.22) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if target == .openCode {
                openCodeProtocolContextMenu
            } else if target == .claude {
                claudeProtocolContextMenu
            }
        }
        .accessibilityLabel(target.gatewayTitle)
        .accessibilityValue(selected ? L("Selected", "已选择") : L("Not selected", "未选择"))
        .accessibilityHint(protocolHint(for: target))
    }

    private func protocolHint(for target: ProxyTarget) -> String {
        switch target {
        case .openCode:
            return L("Right-click to choose OpenCode protocol", "右键可选择 OpenCode 协议")
        case .claude:
            return L("Right-click to choose Claude / Science mode", "右键可选择 Claude / Science 形态")
        case .codex, .cpa:
            return ""
        }
    }

    private func targetSubtitle(_ target: ProxyTarget, selected: Bool) -> String {
        if target == .openCode, selected {
            return draftOpenCodeProtocol.badgeName
        }
        if target == .claude, selected {
            return "\(target.gatewayDetail) · \(draftClaudeProtocol.badgeName)"
        }
        return target.gatewayDetail
    }

    @ViewBuilder
    private var openCodeProtocolContextMenu: some View {
        Section(L("OpenCode protocol", "OpenCode 协议")) {
            ForEach(OpenCodeProtocol.allCases, id: \.self) { proto in
                Button {
                    draftOpenCodeProtocol = proto
                    if !selectedTargets.contains(.openCode) {
                        selectedTargets.insert(.openCode)
                    }
                } label: {
                    if draftOpenCodeProtocol == proto {
                        Label(proto.displayName, systemImage: "checkmark")
                    } else {
                        Text(proto.displayName)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var claudeProtocolContextMenu: some View {
        Section(L("Claude / Science mode", "Claude / Science 形态")) {
            ForEach(ManagedClaudeProtocol.allCases) { proto in
                Button {
                    draftClaudeProtocol = proto
                    if !selectedTargets.contains(.claude) {
                        selectedTargets.insert(.claude)
                    }
                } label: {
                    if draftClaudeProtocol == proto {
                        Label(proto.displayName, systemImage: "checkmark")
                    } else {
                        Text(proto.displayName)
                    }
                }
            }
        }
    }

    private func connectionPill(selected: Bool, connected: Bool) -> some View {
        let text: String
        let color: Color
        let icon: String
        if selected == connected {
            text = connected ? L("Connected", "已连接") : L("Not connected", "未连接")
            color = connected ? .green : .secondary
            icon = connected ? "checkmark.circle.fill" : "circle"
        } else if selected {
            text = L("Will connect", "将连接")
            color = .blue
            icon = "plus.circle.fill"
        } else {
            text = L("Will remove", "将移除")
            color = .orange
            icon = "minus.circle.fill"
        }
        return GatewayStatusPill(text: text, color: color, systemImage: icon)
    }

    private var localAPIClientsCard: some View {
        GatewayCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Client API endpoints", "客户端 API 接口"))
                            .font(.subheadline.weight(.semibold))
                        Text(L(
                            "Copy origin, Base URL, or full endpoint for each protocol.",
                            "按协议复制 Origin、Base URL 或完整端点。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        endpointSecuritySummary
                        Spacer(minLength: 10)
                        endpointAccessControls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        endpointSecuritySummary
                        endpointAccessControls
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(protocolEndpoints) { endpoint in
                        protocolEndpointRow(endpoint)
                    }
                }

                if runtime.clientAPIKey == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(L("Start CPA to load the client key.", "启动 CPA 后即可读取客户端密钥。"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                DisclosureGroup(isExpanded: $showAdditionalRoutes) {
                    VStack(alignment: .leading, spacing: 7) {
                        routeLine("POST", "/v1/completions", L("Legacy OpenAI Completions", "旧版 OpenAI Completions"))
                        routeLine(
                            "GET",
                            "/v1/responses",
                            L("Responses WebSocket", "Responses WebSocket"),
                            transport: .webSocket
                        )
                        routeLine("GET", "/v1/models", L("OpenAI / Anthropic model list", "OpenAI / Anthropic 模型列表"))
                        routeLine("POST", "/v1/messages/count_tokens", L("Anthropic token count", "Anthropic Token 计数"))
                        routeLine("GET", "/v1beta/models", L("Gemini model list", "Gemini 模型列表"))
                        routeLine("GET", "/v1beta/models/{model}", L("Gemini model details", "Gemini 模型详情"))
                        routeLine("POST", "/v1beta/models/{model}:streamGenerateContent", L("Gemini streaming", "Gemini 流式生成"))
                        routeLine("POST", "/v1beta/models/{model}:countTokens", L("Gemini token count", "Gemini Token 计数"))
                        routeLine("POST", "/v1beta/interactions", L("Gemini interactions", "Gemini Interactions"))
                        routeLine("POST", "/v1/responses/compact", L("Responses compact", "Responses 压缩"))
                        routeLine(
                            "GET",
                            "/backend-api/codex/responses",
                            L("Codex WebSocket alias", "Codex WebSocket 别名"),
                            transport: .webSocket
                        )
                        routeLine("POST", "/backend-api/codex/responses", L("Codex HTTP alias", "Codex HTTP 别名"))
                        routeLine("POST", "/backend-api/codex/responses/compact", L("Codex compact alias", "Codex 压缩接口别名"))
                        Text(L(
                            "Anthropic SDKs normally add Anthropic-Version automatically; manual requests must include it.",
                            "Anthropic SDK 通常会自动携带 Anthropic-Version；手动请求时需要自行添加。"
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    }
                    .padding(.top, 10)
                } label: {
                    Text(L("More supported routes", "更多受支持路由"))
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var protocolEndpoints: [GatewayProtocolEndpoint] {
        [
            GatewayProtocolEndpoint(
                id: "openai-responses",
                providerID: "openai",
                title: "OpenAI Responses",
                method: "POST",
                basePath: "/v1",
                routePath: "/v1/responses",
                shortPurpose: L("Responses and Codex clients", "Responses 与 Codex 客户端"),
                detail: L(
                    "Use this for clients built on the OpenAI Responses API, including Codex-style request flows.",
                    "适用于基于 OpenAI Responses API 的客户端，也适合 Codex 风格的请求流程。"
                ),
                authLines: ["Authorization: Bearer <client-key>"],
                requiresModel: false
            ),
            GatewayProtocolEndpoint(
                id: "openai-chat",
                providerID: "openai",
                title: "OpenAI Chat Completions",
                method: "POST",
                basePath: "/v1",
                routePath: "/v1/chat/completions",
                shortPurpose: L("OpenAI-compatible chat clients", "OpenAI 兼容聊天客户端"),
                detail: L(
                    "Use this for apps that ask for an OpenAI-compatible Base URL and call Chat Completions.",
                    "适用于要求填写 OpenAI 兼容 Base URL，并调用 Chat Completions 的应用。"
                ),
                authLines: ["Authorization: Bearer <client-key>"],
                requiresModel: false
            ),
            GatewayProtocolEndpoint(
                id: "anthropic-messages",
                providerID: "claude",
                title: "Anthropic Messages",
                method: "POST",
                basePath: "",
                routePath: "/v1/messages",
                shortPurpose: L("Claude SDK and Messages clients", "Claude SDK 与 Messages 客户端"),
                detail: L(
                    "Use this for Anthropic-native SDKs and clients. SDKs normally add Anthropic-Version automatically.",
                    "适用于 Anthropic 原生 SDK 与 Messages 客户端；SDK 通常会自动添加 Anthropic-Version。"
                ),
                authLines: [
                    "X-Api-Key: <client-key>",
                    "Anthropic-Version: 2023-06-01"
                ],
                requiresModel: false
            ),
            GatewayProtocolEndpoint(
                id: "gemini-generate-content",
                providerID: "gemini",
                title: "Gemini GenerateContent",
                method: "POST",
                basePath: "/v1beta",
                routePath: "/v1beta/models/{model}:generateContent",
                shortPurpose: L("Gemini REST and SDK setup", "Gemini REST 与 SDK 接入"),
                detail: L(
                    "Use the REST API root for direct requests. Google GenAI SDKs use the server origin as base_url and v1beta as api_version.",
                    "直接请求时使用 REST API Root；Google GenAI SDK 需要把服务器地址设为 base_url，并把 api_version 设为 v1beta。"
                ),
                authLines: ["X-Goog-Api-Key: <client-key>"],
                requiresModel: true
            )
        ]
    }

    private func protocolEndpointRow(_ endpoint: GatewayProtocolEndpoint) -> some View {
        Button {
            selectedProtocol = endpoint
        } label: {
            HStack(spacing: 8) {
                GatewayProviderIcon(providerID: endpoint.providerID, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(endpoint.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(endpoint.method)
                            .font(.caption2.weight(.bold).monospaced())
                            .foregroundStyle(.blue)
                    }
                    Text(endpoint.shortPurpose)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(endpoint.basePath.isEmpty ? "/" : endpoint.basePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L(
            "Open details and choose what to copy",
            "打开详情并选择要复制的地址层级"
        ))
        .accessibilityLabel(L("Open \(endpoint.title) details", "打开 \(endpoint.title) 接入详情"))
    }

    private func routeLine(
        _ method: String,
        _ path: String,
        _ description: String,
        transport: GatewayRouteTransport = .http
    ) -> some View {
        HStack(spacing: 9) {
            Text(method)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.blue)
                .frame(width: 62, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .layoutPriority(1)
            Spacer()
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(endpoint(path, transport: transport), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(path.contains("{model}")
                  ? L("Copy endpoint template", "复制端点模板")
                  : L("Copy full endpoint", "复制完整端点"))
            .accessibilityLabel(L("Copy \(description)", "复制 \(description)"))
        }
    }

    private func endpoint(_ path: String, transport: GatewayRouteTransport) -> String {
        var components = URLComponents(url: selectedOrigin, resolvingAgainstBaseURL: false)
        if transport == .webSocket {
            let isSecureOrigin = components?.scheme == "https"
            components?.scheme = isSecureOrigin ? "wss" : "ws"
        }
        let origin = (components?.url ?? selectedOrigin).absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return origin + path
    }

    private var availableLANURLs: [URL] {
        guard runtime.settings.allowLANAccess else { return [] }
        return runtime.lanBaseURLs
    }

    private var selectedLANURL: URL? {
        if let selectedLANAddress,
           let selected = availableLANURLs.first(where: { $0.absoluteString == selectedLANAddress }) {
            return selected
        }
        return availableLANURLs.first
    }

    private var selectedOrigin: URL {
        if endpointScope == .localNetwork, let selectedLANURL { return selectedLANURL }
        return runtime.baseURL
    }

    private var endpointSecuritySummary: some View {
        HStack(spacing: 8) {
            Label(L("One client key", "同一客户端密钥"), systemImage: "key.horizontal.fill")
            Text("·")
            Text(L(
                "Bearer / X-Api-Key / X-Goog-Api-Key",
                "Bearer / X-Api-Key / X-Goog-Api-Key"
            ))
                .fixedSize(horizontal: false, vertical: true)
            if runtime.clientAPIKey != nil {
                Label(L("Ready", "已就绪"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var endpointAccessControls: some View {
        HStack(spacing: 8) {
            if selectedLANURL != nil {
                Picker("", selection: $endpointScope) {
                    Text(L("This Mac", "本机")).tag(GatewayEndpointScope.thisMac)
                    Text(L("Local Network", "局域网")).tag(GatewayEndpointScope.localNetwork)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 155)
                .accessibilityLabel(L("Endpoint network", "接口网络范围"))
            }
            if endpointScope == .localNetwork, availableLANURLs.count > 1 {
                Menu {
                    ForEach(availableLANURLs, id: \.absoluteString) { url in
                        Button(url.host ?? url.absoluteString) {
                            selectedLANAddress = url.absoluteString
                        }
                    }
                } label: {
                    Label(selectedLANURL?.host ?? L("Address", "地址"), systemImage: "network")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Choose a local network address", "选择局域网地址"))
            }
            GatewayStatusPill(
                text: endpointScope == .localNetwork && selectedLANURL != nil
                    ? L("LAN address", "局域网地址")
                    : L("This Mac", "本机地址"),
                color: endpointScope == .localNetwork && selectedLANURL != nil ? .orange : .green,
                systemImage: endpointScope == .localNetwork && selectedLANURL != nil
                    ? "network"
                    : "lock.shield.fill"
            )
        }
    }

    private var actualTargets: Set<ProxyTarget> {
        manager.currentDistributionTargets
    }

    private var hasProtocolPending: Bool {
        let openCodePending = (selectedTargets.contains(.openCode) || actualTargets.contains(.openCode))
            && draftOpenCodeProtocol != manager.managedOpenCodeProtocol
        let claudePending = (selectedTargets.contains(.claude) || actualTargets.contains(.claude))
            && draftClaudeProtocol != manager.managedClaudeProtocol
        return openCodePending || claudePending
    }

    private var hasPendingChanges: Bool {
        selectedTargets != actualTargets || hasProtocolPending
    }

    private var removedTargets: Set<ProxyTarget> { actualTargets.subtracting(selectedTargets) }

    private var connectionFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                connectionSummary
                Spacer(minLength: 10)
                connectionActions
            }
            VStack(alignment: .leading, spacing: 9) {
                connectionSummary
                HStack {
                    Spacer()
                    connectionActions
                }
            }
        }
    }

    private var connectionSummary: some View {
        HStack(spacing: 6) {
            Text(L(
                "\(selectedTargets.count) selected · \(actualTargets.count) connected",
                "已选 \(selectedTargets.count) · 已接 \(actualTargets.count)"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            if let lastAppliedAt {
                Text("· \(lastAppliedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var connectionActions: some View {
        HStack(spacing: 9) {
            Button(L("Discard", "放弃修改")) {
                selectedTargets = actualTargets
                draftOpenCodeProtocol = manager.managedOpenCodeProtocol
                draftClaudeProtocol = manager.managedClaudeProtocol
            }
            .buttonStyle(.borderless)
            .disabled(!hasPendingChanges || manager.isApplyingDistribution)
            Button {
                applyOrConfirm()
            } label: {
                if manager.isApplyingDistribution {
                    ProgressView().controlSize(.small)
                } else {
                    Label(L("Apply Connections", "应用接入设置"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !runtime.state.isRunning ||
                !hasPendingChanges ||
                manager.isManagingAccounts ||
                manager.isApplyingDistribution
            )
        }
    }

    private func applyOrConfirm() {
        if removedTargets.isEmpty { applyConnections() }
        else { pendingRemoval = removedTargets }
    }

    private func applyConnections() {
        let requested = selectedTargets
        let requestedOpenCode = draftOpenCodeProtocol
        let requestedClaude = draftClaudeProtocol
        Task {
            if requested.contains(.openCode) {
                manager.managedOpenCodeProtocol = requestedOpenCode
            }
            if requested.contains(.claude) {
                manager.managedClaudeProtocol = requestedClaude
            }
            await manager.upsertManagedProvider(targets: requested)
            let refreshed = manager.currentDistributionTargets
            selectedTargets = refreshed
            draftOpenCodeProtocol = manager.managedOpenCodeProtocol
            draftClaudeProtocol = manager.managedClaudeProtocol
            if refreshed == requested, manager.lastError == nil { lastAppliedAt = Date() }
        }
    }

    private func targetNames(_ targets: Set<ProxyTarget>) -> String {
        ProxyTarget.localProxyTargets
            .filter { targets.contains($0) }
            .map(\.gatewayTitle)
            .joined(separator: L(", ", "、"))
    }
}

private struct GatewayProtocolEndpoint: Identifiable {
    let id: String
    let providerID: String
    let title: String
    let method: String
    let basePath: String
    let routePath: String
    let shortPurpose: String
    let detail: String
    let authLines: [String]
    let requiresModel: Bool
}

private struct GatewayEndpointDetailSheet: View {
    let endpoint: GatewayProtocolEndpoint
    let origin: URL
    let clientAPIKey: String?
    let modelOptions: [CLIProxyModel]

    @Environment(\.dismiss) private var dismiss
    @State private var modelID: String

    init(
        endpoint: GatewayProtocolEndpoint,
        origin: URL,
        clientAPIKey: String?,
        modelOptions: [CLIProxyModel]
    ) {
        self.endpoint = endpoint
        self.origin = origin
        self.clientAPIKey = clientAPIKey
        self.modelOptions = modelOptions
        // Keep the route template visible until the user deliberately chooses
        // a concrete model. This avoids silently copying an arbitrary first
        // item from CPA's dynamically ordered model catalog.
        _modelID = State(initialValue: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                GatewayProviderIcon(providerID: endpoint.providerID, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(endpoint.title)
                            .font(.title3.weight(.bold))
                        Text(endpoint.method)
                            .font(.caption.weight(.bold).monospaced())
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.1), in: Capsule())
                    }
                    Text(endpoint.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                GatewayStatusPill(
                    text: isLANOrigin ? L("Local network", "局域网") : L("This Mac", "本机"),
                    color: isLANOrigin ? .orange : .green,
                    systemImage: isLANOrigin ? "network" : "desktopcomputer"
                )
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Choose what to copy", "选择复制层级"))
                            .font(.headline)
                        Text(copyGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    GatewayCopyField(
                        label: L("Server origin", "服务器地址（Origin）"),
                        value: originString,
                        wraps: true
                    )

                    GatewayCopyField(
                        label: endpoint.requiresModel
                            ? L("REST API root", "REST API Root")
                            : L("Client Base URL", "客户端 Base URL"),
                        value: absolute(endpoint.basePath),
                        wraps: true
                    )

                    if endpoint.requiresModel {
                        Label(
                            L(
                                "Google GenAI SDK: copy Server origin as base_url and set api_version to v1beta.",
                                "Google GenAI SDK：将上方服务器地址复制为 base_url，并把 api_version 设为 v1beta。"
                            ),
                            systemImage: "info.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if endpoint.requiresModel {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(L("Model in endpoint", "端点中的模型"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 9) {
                                TextField(L("Enter a model ID", "输入模型 ID"), text: $modelID)
                                    .textFieldStyle(.roundedBorder)
                                if !modelOptions.isEmpty {
                                    Menu {
                                        ForEach(modelOptions) { model in
                                            Button(model.displayName ?? model.id) { modelID = model.id }
                                        }
                                    } label: {
                                        Label(L("Live models", "实时模型"), systemImage: "cube.fill")
                                    }
                                }
                            }
                            if let modelInputError {
                                Label(modelInputError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text(L(
                                    "Leave it empty to copy the {model} template. Both gemini-… and models/gemini-… are accepted.",
                                    "留空时复制包含 {model} 的模板；可输入 gemini-… 或 models/gemini-…，都会生成正确地址。"
                                ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GatewayCopyField(
                        label: endpoint.requiresModel && !hasValidResolvedModel
                            ? L("Request endpoint template", "请求端点模板")
                            : L("Full request endpoint", "完整请求端点"),
                        value: absolute(resolvedRoutePath),
                        wraps: true
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 9) {
                        Text(L("Authentication", "认证方式"))
                            .font(.headline)
                        ForEach(endpoint.authLines, id: \.self) { line in
                            Text(line)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                        if let clientAPIKey {
                            GatewayCopyField(
                                label: L("CPA client key", "CPA 客户端密钥"),
                                value: clientAPIKey,
                                masked: true
                            )
                        } else {
                            Label(
                                L("Start CPA to load the client key.", "启动 CPA 后即可读取客户端密钥。"),
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if isLANOrigin {
                        Label(
                            L(
                                "LAN access uses unencrypted HTTP. Use it only on a trusted network.",
                                "局域网访问使用未加密 HTTP，请只在可信网络中使用。"
                            ),
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text(L("Every copy button uses the complete value shown here.", "每个复制按钮都会复制这里显示的完整值。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Done", "完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 620)
    }

    private var originString: String {
        origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var copyGuidance: String {
        if endpoint.requiresModel {
            return L(
                "Use the REST API root or full endpoint for direct HTTP requests; SDK configuration is shown below.",
                "直接发送 HTTP 请求时使用 REST API Root 或完整端点；SDK 的配置方式见下方说明。"
            )
        }
        return L(
            "Use Base URL in client settings; use the full endpoint for direct HTTP requests.",
            "客户端设置通常填写 Base URL；直接发送 HTTP 请求时使用完整请求端点。"
        )
    }

    private var normalizedModelID: String {
        var value = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("models/") {
            value.removeFirst("models/".count)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var modelInputError: String? {
        guard endpoint.requiresModel, !normalizedModelID.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard normalizedModelID.count <= 256,
              normalizedModelID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              normalizedModelID.unicodeScalars.first.map({ CharacterSet.alphanumerics.contains($0) }) == true else {
            return L(
                "Use a single model ID without spaces, /, ?, #, or path fragments.",
                "请输入单个模型 ID，不能包含空格、/、?、# 或路径片段。"
            )
        }
        return nil
    }

    private var hasValidResolvedModel: Bool {
        endpoint.requiresModel && !normalizedModelID.isEmpty && modelInputError == nil
    }

    private var resolvedRoutePath: String {
        guard hasValidResolvedModel else { return endpoint.routePath }
        return endpoint.routePath.replacingOccurrences(of: "{model}", with: normalizedModelID)
    }

    private func absolute(_ path: String) -> String {
        originString + path
    }

    private var isLANOrigin: Bool {
        guard let host = origin.host else { return false }
        return host != "127.0.0.1" && host.lowercased() != "localhost"
    }
}

private enum GatewayEndpointScope: String, Identifiable {
    case thisMac
    case localNetwork

    var id: String { rawValue }
}

private enum GatewayRouteTransport {
    case http
    case webSocket
}
