import AppKit
import SwiftUI

struct SubscriptionGatewayOverviewView: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var showAddAccount: Bool
    @ObservedObject private var navigation = CLIProxyGatewayNavigation.shared
    @State private var modelQuery = ""
    @State private var showAllModels = false

    private let metricColumns = [GridItem(.adaptive(minimum: 210), spacing: 10)]
    private let modelColumns = [GridItem(.adaptive(minimum: 245), spacing: 9)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                errorBanners
                if manager.isInstalled { serviceCard }
                nextStepCard

                Text(L("Live overview", "运行概况"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 10) {
                    GatewayMetricCard(
                        title: L("Accounts", "账号"),
                        value: "\(readyAccountCount) / \(manager.authFiles.count)",
                        detail: L("ready in the CPA pool", "CPA 池中可用 / 总数"),
                        systemImage: "person.2.fill",
                        tint: .indigo
                    )
                    GatewayMetricCard(
                        title: L("Models", "模型"),
                        value: "\(manager.modelCatalog.count)",
                        detail: L("reported by CPA now", "CPA 当前动态上报"),
                        systemImage: "square.stack.3d.up.fill",
                        tint: .purple
                    )
                    GatewayMetricCard(
                        title: L("Connected apps", "已接入应用"),
                        value: "\(connectedApplicationCount) / 4",
                        detail: L("apps through \(connectedTargets.count) config targets", "通过 \(connectedTargets.count) 个配置目标接入"),
                        systemImage: "arrow.triangle.branch",
                        tint: .blue
                    )
                    GatewayMetricCard(
                        title: L("CPA version", "CPA 版本"),
                        value: manager.currentVersion.map { "v\($0)" } ?? "—",
                        detail: updateDetail,
                        systemImage: manager.hasUpdate ? "arrow.down.circle.fill" : "checkmark.seal.fill",
                        tint: manager.hasUpdate ? .orange : .green
                    )
                }

                modelCatalogCard
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .task(id: runtime.state.isRunning) {
            guard runtime.state.isRunning else { return }
            await manager.refreshAvailableModels()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await manager.refreshAvailableModels()
            }
        }
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError {
            GatewayErrorBanner(message: error)
        }
        if case .failed(let error) = runtime.state {
            GatewayErrorBanner(message: error)
        }
    }

    @ViewBuilder
    private var nextStepCard: some View {
        if !manager.isInstalled {
            onboardingCard(
                icon: "square.and.arrow.down.fill",
                tint: .blue,
                title: L("Install the managed CPA runtime", "安装托管的 CPA 运行时"),
                detail: L(
                    "Install and update CPA inside AIUsage, with independent rollback copies.",
                    "直接在 AIUsage 内安装、更新 CPA，并保留独立的回退版本。"
                ),
                actionTitle: L("Install latest CPA", "安装最新版 CPA")
            ) { Task { await manager.installOrUpdateLatest() } }
        } else if runtime.state.isRunning, manager.authFiles.isEmpty {
            onboardingCard(
                icon: "person.badge.plus",
                tint: .indigo,
                title: L("Add your first subscription account", "添加第一个订阅账号"),
                detail: L(
                    "Use CPA OAuth, connect a compatible AIUsage account, or import a CPA auth JSON file.",
                    "可通过 CPA OAuth、接入兼容的 AIUsage 账号，或导入 CPA 认证 JSON 文件。"
                ),
                actionTitle: L("Add account", "添加账号")
            ) {
                navigation.showAccounts(openAddAccount: true)
                showAddAccount = true
            }
        } else if runtime.state.isRunning, connectedTargets.isEmpty {
            onboardingCard(
                icon: "arrow.triangle.branch",
                tint: .purple,
                title: L("Connect the gateway to your apps", "把网关接入应用"),
                detail: L(
                    "Your CPA account pool is ready. Choose which AIUsage proxies should receive the managed gateway node.",
                    "CPA 账号池已经就绪，接下来选择要接收托管网关节点的 AIUsage 代理。"
                ),
                actionTitle: L("Choose apps", "选择接入应用")
            ) { navigation.selectedSection = .connections }
        }
    }

    private func onboardingCard(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 17) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(manager.operation.isBusy || runtime.state.isTransitioning)
        }
        .padding(18)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.16)))
    }

    private var modelCatalogCard: some View {
        GatewayCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Live model catalog", "实时模型目录")).font(.headline)
                        Text(modelCatalogDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    GatewayStatusPill(
                        text: runtime.state.isRunning
                            ? L("\(manager.modelCatalog.count) live", "实时 \(manager.modelCatalog.count) 个")
                            : L("Offline", "未运行"),
                        color: runtime.state.isRunning ? .green : .secondary,
                        systemImage: runtime.state.isRunning ? "dot.radiowaves.left.and.right" : "circle"
                    )
                    Button {
                        Task { await manager.refreshAvailableModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!runtime.state.isRunning || manager.isRefreshingModels)
                    .help(L("Refresh model catalog", "刷新模型目录"))
                    .accessibilityLabel(L("Refresh model catalog", "刷新模型目录"))
                }

                if manager.modelCatalog.count > 8 || !normalizedModelQuery.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("Search model ID", "搜索模型 ID"), text: $modelQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(L("Search live models", "搜索实时模型"))
                }

                if let error = manager.modelCatalogError, runtime.state.isRunning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L("Model refresh failed: \(error)", "模型刷新失败：\(error)"))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if !manager.unavailableModelProtocols.isEmpty, runtime.state.isRunning {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(L(
                            "Partial catalog: \(unavailableProtocolNames) could not be read.",
                            "目录不完整：暂时无法读取 \(unavailableProtocolNames)。"
                        ))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !runtime.state.isRunning && !manager.modelCatalog.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(L(
                            "CPA is offline; showing the last successful catalog.",
                            "CPA 当前未运行，下面显示上次成功读取的目录。"
                        ))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !runtime.state.isRunning && manager.modelCatalog.isEmpty {
                    compactModelEmptyState(
                        icon: "play.circle",
                        text: L("Start CPA to load its current model catalog.", "启动 CPA 后即可载入当前模型目录。")
                    )
                } else if manager.isRefreshingModels && manager.modelCatalog.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(L("Loading models…", "正在载入模型…"))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                } else if filteredModels.isEmpty {
                    compactModelEmptyState(
                        icon: modelQuery.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass",
                        text: modelQuery.isEmpty
                            ? L("CPA reported no models.", "CPA 当前未上报模型。")
                            : L("No model matches this search.", "没有匹配的模型。")
                    )
                } else {
                    LazyVGrid(columns: modelColumns, alignment: .leading, spacing: 9) {
                        ForEach(visibleModels) { model in
                            modelRow(model)
                        }
                    }
                    if filteredModels.count > 10 && modelQuery.isEmpty {
                        Button(showAllModels
                               ? L("Show fewer", "收起")
                               : L("Show all \(filteredModels.count) models", "查看全部 \(filteredModels.count) 个模型")) {
                            showAllModels.toggle()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func modelRow(_ entry: CLIProxyModelCatalogEntry) -> some View {
        let model = entry.model
        return HStack(spacing: 9) {
            GatewayProviderIcon(providerID: modelProviderID(entry), size: 29)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName ?? model.id)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if model.displayName != nil {
                        Text(model.id).font(.caption2.monospaced()).lineLimit(1)
                    }
                    if let ownedBy = model.ownedBy?.nilIfBlank {
                        Text(model.displayName == nil ? ownedBy : "· \(ownedBy)")
                            .font(.caption2)
                    }
                    if !entry.protocols.isEmpty {
                        Spacer(minLength: 4)
                        Text(protocolNames(entry.protocols))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button(L("Copy model ID", "复制模型 ID")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.id, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func compactModelEmptyState(icon: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    }

    private var serviceCard: some View {
        GatewayCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("CPA runtime", "CPA 运行服务"))
                            .font(.headline)
                        Text(serviceDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        GatewayStatusPill(
                            text: runtime.state.isRunning ? L("Healthy", "运行正常") : L("Offline", "未运行"),
                            color: runtime.state.isRunning ? .green : .secondary,
                            systemImage: runtime.state.isRunning ? "checkmark.circle.fill" : "circle"
                        )
                        if runtime.settings.allowLANAccess {
                            GatewayStatusPill(
                                text: L("LAN enabled", "局域网已开启"),
                                color: .orange,
                                systemImage: "network"
                            )
                        }
                    }
                }
                GatewayCopyField(
                    label: L("This Mac", "本机地址"),
                    value: runtime.baseURL.absoluteString
                )
                if runtime.settings.allowLANAccess {
                    if !runtime.lanBaseURLs.isEmpty {
                        ForEach(runtime.lanBaseURLs, id: \.absoluteString) { lanURL in
                            GatewayCopyField(
                                label: runtime.state.isRunning
                                    ? L("Local network · \(lanURL.host ?? "")", "局域网地址 · \(lanURL.host ?? "")")
                                    : L("Local network after start · \(lanURL.host ?? "")", "启动后的局域网地址 · \(lanURL.host ?? "")"),
                                value: lanURL.absoluteString
                            )
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                            Text(L(
                                "LAN access is enabled, but no active private or shared IPv4 address was found.",
                                "已开启局域网访问，但当前未找到可用的私有或共享 IPv4 地址。"
                            ))
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button {
                        Task {
                            if runtime.state.isRunning { await runtime.stop() }
                            else {
                                await runtime.start()
                                if runtime.state.isRunning { await manager.refreshAccounts() }
                            }
                        }
                    } label: {
                        Label(
                            runtime.state.isRunning ? L("Stop CPA", "停止 CPA") : L("Start CPA", "启动 CPA"),
                            systemImage: runtime.state.isRunning ? "stop.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(runtime.state.isTransitioning || !manager.isInstalled)

                    Button {
                        Task { await manager.refreshAccounts() }
                    } label: {
                        Label(L("Refresh", "刷新"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var readyAccountCount: Int {
        manager.authFiles.filter { !$0.disabled && !$0.unavailable && !$0.gatewayNeedsAttention }.count
    }

    private var connectedTargets: Set<ProxyTarget> {
        manager.currentDistributionTargets
    }

    private var filteredModels: [CLIProxyModelCatalogEntry] {
        let query = normalizedModelQuery
        guard !query.isEmpty else { return manager.modelCatalog }
        return manager.modelCatalog.filter { entry in
            let model = entry.model
            return [model.id, model.displayName ?? "", model.ownedBy ?? "", model.type ?? ""]
                .joined(separator: " ")
                .lowercased()
                .contains(query) || protocolNames(entry.protocols).lowercased().contains(query)
        }
    }

    private var visibleModels: [CLIProxyModelCatalogEntry] {
        if !normalizedModelQuery.isEmpty {
            return Array(filteredModels.prefix(50))
        }
        return showAllModels ? filteredModels : Array(filteredModels.prefix(10))
    }

    private var normalizedModelQuery: String {
        modelQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var connectedApplicationCount: Int {
        connectedTargets.reduce(into: 0) { count, target in
            count += target == .claude ? 2 : 1
        }
    }

    private var updateDetail: String {
        if manager.hasUpdate { return L("an official update is available", "有可用的官方更新") }
        if manager.isInstalled { return L("managed independently", "由 AIUsage 独立管理") }
        return L("not installed", "尚未安装")
    }

    private var modelCatalogDetail: String {
        guard let updatedAt = manager.modelCatalogUpdatedAt else {
            return L("Auto-refreshes from CPA while this page is open", "页面打开时自动从 CPA 刷新")
        }
        return L(
            "Updated at \(updatedAt.formatted(date: .omitted, time: .shortened)) · refreshes every 30s",
            "更新于 \(updatedAt.formatted(date: .omitted, time: .shortened)) · 每 30 秒刷新"
        )
    }

    private func modelProviderID(_ entry: CLIProxyModelCatalogEntry) -> String {
        if entry.protocols == [.anthropic] { return "claude" }
        if entry.protocols == [.gemini] { return "gemini" }
        let model = entry.model
        let hint = [model.ownedBy, model.type, model.id]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if hint.contains("anthropic") || hint.contains("claude") { return "claude" }
        if hint.contains("gemini") || hint.contains("google") { return "gemini" }
        if hint.contains("openai") || hint.contains("gpt") || hint.contains("codex") { return "codex" }
        return "cliproxyapi"
    }

    private func protocolNames(_ protocols: Set<CLIProxyModelProtocol>) -> String {
        protocols.sorted { $0.sortOrder < $1.sortOrder }.map(\.title).joined(separator: " · ")
    }

    private var unavailableProtocolNames: String {
        protocolNames(manager.unavailableModelProtocols)
    }

    private var serviceDetail: String {
        let access = runtime.settings.allowLANAccess
            ? L("This Mac and local network", "本机与局域网")
            : L("This Mac only", "仅限本机")
        if case .running(let pid) = runtime.state {
            return "\(access) · PID \(pid)"
        }
        return L(
            "\(access) · port \(runtime.settings.normalized.port)",
            "\(access) · 端口 \(runtime.settings.normalized.port)"
        )
    }
}
