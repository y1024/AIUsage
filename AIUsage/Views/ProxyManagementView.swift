import SwiftUI
import UniformTypeIdentifiers
import QuotaBackend

// MARK: - Proxy Management View

struct ProxyManagementView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: ProxyViewModel
    @State private var showingNewConfigEditor = false
    @State private var editingConfig: ProxyConfiguration?
    @State private var editingProfile: NodeProfile?
    @State private var selectedConfigId: String?
    @State private var pendingDeletionConfig: ProxyConfiguration?
    @State private var draggingConfigId: String?
    @State private var dropTargetIndex: Int?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var importResult: NodeProfileStore.ImportResult?
    @State private var showImportResult = false
    @State private var exportSelectedIds: Set<String> = []
    @State private var showingSettingsEditor = false
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.configurations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        actionBar
                        summaryStrip
                        GlobalConfigSection()
                        configurationsList
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                let accessingURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
                let importResult = viewModel.profileStore.importProfiles(from: urls)
                for url in accessingURLs { url.stopAccessingSecurityScopedResource() }
                self.importResult = importResult
                self.showImportResult = true
                viewModel.loadConfigurations()
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showingExporter) {
            ProfileExportView(
                profiles: viewModel.profileStore.profiles,
                selectedIds: $exportSelectedIds
            )
            .environmentObject(viewModel)
        }
        .alert(
            L("Import Result", "导入结果"),
            isPresented: $showImportResult,
            presenting: importResult
        ) { _ in
            Button("OK") { importResult = nil }
        } message: { result in
            let gcNote = result.importedGlobalConfig
                ? "\n" + L("Global config imported.", "通用配置已导入。")
                : ""
            Text(L(
                "\(result.succeeded) imported, \(result.failed) failed, \(result.skipped) skipped",
                "\(result.succeeded) 个导入成功，\(result.failed) 个失败，\(result.skipped) 个跳过"
            ) + gcNote)
        }
        .sheet(isPresented: $showingSettingsEditor) {
            LocalSettingsEditorView()
        }
        .sheet(isPresented: $showingNewConfigEditor) {
            ProxyConfigEditorView()
                .environmentObject(viewModel)
                .environmentObject(appState)
        }
        .sheet(item: $editingProfile) { profile in
            ProxyConfigEditorView(profile: profile)
                .environmentObject(viewModel)
                .environmentObject(appState)
        }
        .sheet(item: $editingConfig) { config in
            ProxyConfigEditorView(config: config)
                .environmentObject(viewModel)
                .environmentObject(appState)
        }
        .alert(
            L("Node Operation Failed", "节点操作失败"),
            isPresented: Binding(
                get: { viewModel.operationErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        viewModel.operationErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.operationErrorMessage = nil
            }
        } message: {
            Text(viewModel.operationErrorMessage ?? "")
        }
        .alert(
            L("Delete Node?", "确认删除节点？"),
            isPresented: Binding(
                get: { pendingDeletionConfig != nil },
                set: { newValue in
                    if !newValue {
                        pendingDeletionConfig = nil
                    }
                }
            ),
            presenting: pendingDeletionConfig
        ) { config in
            Button(L("Delete", "删除"), role: .destructive) {
                let deletingConfig = config
                pendingDeletionConfig = nil
                Task { await deleteConfig(deletingConfig) }
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingDeletionConfig = nil
            }
        } message: { config in
            Text(
                L(
                    "This will permanently remove the node \"\(config.name)\" and its local proxy stats/logs.",
                    "这会永久删除节点“\(config.name)”及其本地代理统计和日志。"
                )
            )
        }
    }

    // MARK: - Action Bar

    @Environment(\.colorScheme) private var colorScheme

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()

            actionBarButton(
                title: L("settings.json", "settings.json"),
                icon: "doc.text.fill",
                tint: .secondary
            ) {
                showingSettingsEditor = true
            }

            actionBarButton(
                title: L("Import", "导入"),
                icon: "square.and.arrow.down",
                tint: .secondary
            ) {
                showingImporter = true
            }

            actionBarButton(
                title: L("Export", "导出"),
                icon: "square.and.arrow.up",
                tint: .secondary
            ) {
                exportSelectedIds = Set(viewModel.configurations.map(\.id))
                showingExporter = true
            }
            .disabled(viewModel.configurations.isEmpty)

            actionBarButton(
                title: L("New Node", "新建节点"),
                icon: "plus.circle.fill",
                tint: .accentColor,
                prominent: true
            ) {
                showingNewConfigEditor = true
            }
        }
    }

    private func actionBarButton(
        title: String,
        icon: String,
        tint: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? .white : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    prominent
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                )
            )
            .overlay(
                Capsule().stroke(
                    prominent ? Color.clear : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary Strip

    private var summaryStrip: some View {
        let agg = aggregatedStats
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            summaryCell(
                icon: "point.3.connected.trianglepath.dotted",
                title: L("Nodes", "节点数"),
                value: "\(viewModel.configurations.count)",
                tint: .blue
            )
            summaryCell(
                icon: "checkmark.circle.fill",
                title: L("Active", "已激活"),
                value: viewModel.activatedConfigId != nil ? "1" : "0",
                tint: .green
            )
            summaryCell(
                icon: "arrow.up.arrow.down",
                title: L("Total Requests", "总请求"),
                value: formatCompactNumber(Double(agg.requests)),
                tint: .orange
            )
            summaryCell(
                icon: "checkmark.shield.fill",
                title: L("Success Rate", "成功率"),
                value: String(format: "%.1f%%", agg.successRate),
                tint: .purple
            )
            summaryCell(
                icon: "bolt.fill",
                title: L("Total Tokens", "总 Tokens"),
                value: formatCompactNumber(Double(agg.tokens)),
                tint: .pink
            )
            summaryCell(
                icon: "dollarsign.circle.fill",
                title: L("Total Cost", "总费用"),
                value: formatProxyCurrency(agg.cost),
                tint: .red
            )
        }
    }

    private func summaryCell(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Configurations List

    private var configurationsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Node Configurations", "节点配置"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.configurations.enumerated()), id: \.element.id) { index, config in
                    let stats = viewModel.statistics[config.id] ?? .empty
                    let isSelected = selectedConfigId == config.id
                    VStack(spacing: 0) {
                        dropIndicator(at: index)
                        ConfigurationCardView(
                            config: config,
                            isActive: viewModel.activatedConfigId == config.id,
                            isProxyOnlyRunning: viewModel.proxyOnlyRunningIds.contains(config.id),
                            isBusy: viewModel.isOperationInProgress(config.id),
                            isSelected: isSelected,
                            statsRequests: stats.totalRequests,
                            statsSuccessRate: stats.successRate,
                            lastRequestAt: stats.lastRequestAt,
                            onDragStart: { draggingConfigId = config.id },
                            onToggleActivation: { Task { await viewModel.toggleActivation(config.id) } },
                            onToggleProxyOnly: { Task { await viewModel.toggleProxyOnly(config.id) } },
                            onCopyLaunchCommand: { viewModel.copyLaunchCommand(for: config.id) },
                            onEdit: {
                                if let profile = viewModel.profileStore.profile(for: config.id) {
                                    editingProfile = profile
                                } else {
                                    editingConfig = config
                                }
                            },
                            onDelete: { pendingDeletionConfig = config },
                            onDuplicate: { duplicateConfig(config) },
                            onToggleSelection: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedConfigId = selectedConfigId == config.id ? nil : config.id
                                }
                            }
                        )
                        .equatable()
                        .opacity(draggingConfigId == config.id ? 0.3 : 1.0)
                        .onDrop(of: [.text], delegate: CardDropDelegate(
                            targetIndex: index,
                            draggingId: $draggingConfigId,
                            dropTarget: $dropTargetIndex,
                            viewModel: viewModel
                        ))
                        .padding(.vertical, 4)

                        if isSelected && config.needsProxyProcess {
                            statisticsSection(for: config)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                            recentRequestsSection(for: config)
                                .padding(.bottom, 4)
                        }
                    }
                }
                dropIndicator(at: viewModel.configurations.count)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Drag & Drop Helpers

    private func dropIndicator(at index: Int) -> some View {
        let isActive = dropTargetIndex == index
        return HStack(spacing: 0) {
            if isActive {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(height: isActive ? 2 : 0)
        }
        .frame(height: isActive ? 6 : 2)
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    // MARK: - Statistics Section

    private func statisticsSection(for config: ProxyConfiguration) -> some View {
        let stats = viewModel.statistics[config.id] ?? .empty

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Statistics", "统计信息"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                statsCard(
                    title: L("Total Requests", "总请求"),
                    value: "\(stats.totalRequests)",
                    icon: "arrow.up.arrow.down",
                    color: .blue
                )
                statsCard(
                    title: L("Successful", "成功"),
                    value: "\(stats.successfulRequests)",
                    icon: "checkmark.circle",
                    color: .green
                )
                statsCard(
                    title: L("Failed", "失败"),
                    value: "\(stats.failedRequests)",
                    icon: "xmark.circle",
                    color: .red
                )
                statsCard(
                    title: L("Avg Response", "平均响应"),
                    value: String(format: "%.0fms", stats.averageResponseTime),
                    icon: "timer",
                    color: .orange
                )
            }

            HStack(spacing: 12) {
                statsCard(
                    title: L("Input Tokens", "输入 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensInput)),
                    icon: "arrow.down.circle",
                    color: .purple
                )
                statsCard(
                    title: L("Output Tokens", "输出 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensOutput)),
                    icon: "arrow.up.circle",
                    color: .pink
                )
                statsCard(
                    title: L("Cache Read", "缓存读取"),
                    value: formatCompactNumber(Double(stats.totalTokensCacheRead)),
                    icon: "arrow.down.doc",
                    color: .orange
                )
                statsCard(
                    title: L("Cache Write", "缓存写入"),
                    value: formatCompactNumber(Double(stats.totalTokensCacheCreation)),
                    icon: "square.and.arrow.down",
                    color: .indigo
                )
            }

            HStack(spacing: 12) {
                let cacheEligible = stats.totalTokensInput + stats.totalTokensCacheRead + stats.totalTokensCacheCreation
                statsCard(
                    title: L("Hit Rate", "命中率"),
                    value: cacheEligible > 0 ? String(format: "%.1f%%", stats.cacheHitRate) : "—",
                    icon: "scope",
                    color: .teal
                )
                statsCard(
                    title: L("Estimated Cost", "预估费用"),
                    value: formatProxyCurrency(stats.estimatedCostUSD),
                    icon: "dollarsign.circle",
                    color: .red
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func statsCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.12)))

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.05))
        )
    }

    // MARK: - Recent Requests Section

    private func recentRequestsSection(for config: ProxyConfiguration) -> some View {
        let logs = viewModel.recentLogs[config.id] ?? []

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Recent Requests", "最近请求"))
                    .font(.headline.weight(.bold))
                Spacer()
                if !logs.isEmpty {
                    Button(L("Clear", "清除")) {
                        viewModel.clearLogs(for: config.id)
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if logs.isEmpty {
                Text(L("No requests yet", "暂无请求"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 0) {
                    let displayedLogs = Array(logs.suffix(10).reversed())
                    ForEach(Array(displayedLogs.enumerated()), id: \.element.id) { index, log in
                        requestLogRow(log)
                        if index < displayedLogs.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func requestLogRow(_ log: ProxyRequestLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(log.success ? .green : .red)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(log.method) \(log.path)")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 4) {
                    Text(log.upstreamModel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !log.success, let errorType = log.errorType {
                        errorTypeBadge(errorType)
                    }
                }
                if !log.success, let errorMsg = log.errorMessage, !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text(String(format: "%.0fms", log.responseTimeMs))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                if log.success {
                    Text(formatCompactNumber(Double(log.tokensInput + log.tokensOutput)))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.blue)

                    Text(formatProxyCurrency(log.estimatedCostUSD))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                } else if let code = log.statusCode {
                    Text("HTTP \(code)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }

            Text(formatRelativeTime(log.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(log.success ? Color.clear : Color.red.opacity(0.04))
        .help(log.success ? "" : (log.errorMessage ?? ""))
    }

    // MARK: - Error Type Display

    private func errorTypeBadge(_ type: String) -> some View {
        Text(errorTypeLabel(type))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(errorTypeColor(type))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(errorTypeColor(type).opacity(0.12)))
    }

    private func errorTypeLabel(_ type: String) -> String {
        switch type {
        case "rate_limit_error": return L("Rate Limited", "限流")
        case "authentication_error": return L("Auth Error", "认证错误")
        case "billing_error": return L("Billing", "计费错误")
        case "permission_error": return L("Permission", "权限错误")
        case "not_found_error": return L("Not Found", "未找到")
        case "request_too_large": return L("Too Large", "请求过大")
        case "timeout_error": return L("Timeout", "超时")
        case "overloaded_error": return L("Overloaded", "过载")
        case "invalid_request_error": return L("Bad Request", "请求无效")
        case "network_error": return L("Network", "网络错误")
        case "api_error": return L("API Error", "API 错误")
        default: return type
        }
    }

    private func errorTypeColor(_ type: String) -> Color {
        switch type {
        case "rate_limit_error": return .orange
        case "authentication_error": return .purple
        case "billing_error": return .red
        case "timeout_error": return .yellow
        case "overloaded_error": return .orange
        case "network_error": return .gray
        default: return .red
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("No Nodes", "暂无节点"))
                .font(.title3.weight(.bold))
            Text(L("Add Anthropic Direct or OpenAI Proxy nodes to manage Claude Code endpoints.",
                    "添加 Anthropic 直连或 OpenAI 代理节点来管理 Claude Code 端点。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { showingNewConfigEditor = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(L("Add Node", "添加节点"))
                }
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed Properties

    private var selectedConfiguration: ProxyConfiguration? {
        guard let id = selectedConfigId else { return nil }
        return viewModel.configurations.first { $0.id == id }
    }

    private struct AggregatedStats {
        var requests: Int = 0
        var successful: Int = 0
        var tokens: Int = 0
        var cost: Double = 0

        var successRate: Double {
            guard requests > 0 else { return 0 }
            return Double(successful) / Double(requests) * 100
        }
    }

    private var aggregatedStats: AggregatedStats {
        var agg = AggregatedStats()
        for s in viewModel.statistics.values {
            agg.requests += s.totalRequests
            agg.successful += s.successfulRequests
            agg.tokens += s.totalTokens
            agg.cost += s.estimatedCostUSD
        }
        return agg
    }

    // MARK: - Actions

    private func editConfig(_ config: ProxyConfiguration) {
        if let profile = viewModel.profileStore.profile(for: config.id) {
            editingProfile = profile
        } else {
            editingConfig = config
        }
    }

    private func duplicateConfig(_ config: ProxyConfiguration) {
        if let duplicated = viewModel.profileStore.duplicate(config.id) {
            let newConfig = duplicated.metadata.proxy.toProxyConfiguration(metadata: duplicated.metadata)
            viewModel.configurations.append(newConfig)
            if newConfig.nodeType == .openaiProxy {
                viewModel.statistics[newConfig.id] = .empty
                viewModel.recentLogs[newConfig.id] = []
            }
            viewModel.flushLogsRefresh()
        } else {
            let usedPorts = Set(viewModel.configurations.map(\.port))
            var newPort = config.port + 1
            while usedPorts.contains(newPort) && newPort < 65535 { newPort += 1 }

            let copy = ProxyConfiguration(
                name: config.name + " " + L("(Copy)", "(副本)"),
                nodeType: config.nodeType,
                anthropicBaseURL: config.anthropicBaseURL,
                anthropicAPIKey: config.anthropicAPIKey,
                usePassthroughProxy: config.usePassthroughProxy,
                host: config.host,
                port: newPort,
                allowLAN: config.allowLAN,
                upstreamBaseURL: config.upstreamBaseURL,
                openAIUpstreamAPI: config.openAIUpstreamAPI,
                upstreamAPIKey: config.upstreamAPIKey,
                expectedClientKey: config.expectedClientKey,
                defaultModel: config.defaultModel,
                modelMapping: config.modelMapping,
                maxOutputTokens: config.maxOutputTokens
            )
            viewModel.addConfiguration(copy)
        }
    }

    private func deleteConfig(_ config: ProxyConfiguration) async {
        if selectedConfigId == config.id { selectedConfigId = nil }
        await viewModel.deleteConfiguration(config.id)
    }

    // MARK: - Helpers

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func formatRelativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

}

// MARK: - Configuration Card (Equatable)

/// Standalone Equatable View so SwiftUI can skip re-rendering cards whose inputs haven't changed.
/// When `selectedConfigId` changes, only the previously-selected and newly-selected cards re-render;
/// the rest are skipped entirely. Same optimization applies during drag-and-drop state changes.
private struct ConfigurationCardView: View, Equatable {
    let config: ProxyConfiguration
    let isActive: Bool
    let isProxyOnlyRunning: Bool
    let isBusy: Bool
    let isSelected: Bool
    let statsRequests: Int
    let statsSuccessRate: Double
    let lastRequestAt: Date?

    var onDragStart: () -> Void = {}
    var onToggleActivation: () -> Void = {}
    var onToggleProxyOnly: () -> Void = {}
    var onCopyLaunchCommand: () -> Void = {}
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
        lhs.lastRequestAt == rhs.lastRequestAt
    }

    private static let anthropicBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let openAIBrand = Color(red: 0.29, green: 0.73, blue: 0.56)

    private var brandColor: Color {
        config.nodeType == .anthropicDirect ? Self.anthropicBrand : Self.openAIBrand
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
                    .onDrag {
                        onDragStart()
                        return NSItemProvider(object: config.id as NSString)
                    }

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

// MARK: - Drag & Drop Delegate

private struct CardDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggingId: String?
    @Binding var dropTarget: Int?
    let viewModel: ProxyViewModel

    func dropEntered(info: DropInfo) {
        guard draggingId != nil else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            dropTarget = targetIndex
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget == targetIndex {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                dropTarget = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggingId else { return false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            viewModel.moveConfiguration(fromId: id, toIndex: targetIndex)
        }
        draggingId = nil
        dropTarget = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingId != nil
    }
}

// MARK: - Proxy Activation Toggle Style

private struct ProxyActivationToggleStyle: ToggleStyle {
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

// MARK: - Format Helpers

// formatCompactNumber is defined in Utilities.swift

fileprivate func formatProxyCurrency(_ value: Double) -> String {
    formatCurrency(value)
}

#Preview {
    ProxyManagementView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 1100, height: 700)
}
