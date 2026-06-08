import SwiftUI
import QuotaBackend

// MARK: - ProxyManagementView Toolbar & Summary
// 顶部工具栏（cc-switch 导入/实时配置文件/节点导入导出/新建）与节点汇总条。
// 与主视图分离以控制单文件规模；依赖主视图的 @State 与过滤属性（family-scoped）。

extension ProxyManagementView {

    // MARK: - Action Bar

    var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ccSwitchImportButton
                liveConfigFileButton

                Spacer(minLength: 16)

                importNodesButton
                exportNodesButton
                newNodeButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ccSwitchImportButton
                    liveConfigFileButton
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    importNodesButton
                    exportNodesButton
                    Spacer(minLength: 8)
                    newNodeButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(actionBarBackground)
        .overlay(actionBarBorder)
    }

    private var ccSwitchImportButton: some View {
        actionBarButton(
            title: isSyncingCCSwitch ? L("Importing", "导入中") : L("Import cc-switch", "导入 cc-switch"),
            icon: isSyncingCCSwitch ? nil : "tray.and.arrow.down.fill",
            role: .secondary,
            help: L(
                "Import nodes and common config from cc-switch.",
                "从 cc-switch 导入节点和通用配置。"
            )
        ) {
            syncCCSwitch()
        }
        .disabled(isSyncingCCSwitch)
    }

    private var liveConfigFileButton: some View {
        actionBarButton(
            title: family.isCodex ? "config.toml" : "settings.json",
            icon: "doc.text.magnifyingglass",
            role: .file,
            help: family.isCodex
                ? L("Open the live Codex config.toml file.", "打开 Codex 当前生效的 config.toml 文件。")
                : L("Open the live Claude settings.json file.", "打开 Claude Code 当前生效的 settings.json 文件。")
        ) {
            showingSettingsEditor = true
        }
    }

    private var importNodesButton: some View {
        actionBarButton(
            title: L("Import Nodes", "导入节点"),
            icon: "square.and.arrow.down",
            role: .secondary,
            help: L("Import node profiles from JSON or a folder.", "从 JSON 或文件夹导入节点配置。")
        ) {
            showingImporter = true
        }
    }

    private var exportNodesButton: some View {
        actionBarButton(
            title: L("Export Nodes", "导出节点"),
            icon: "square.and.arrow.up",
            role: .secondary,
            help: L("Export the nodes shown in this view.", "导出当前视图中的节点。")
        ) {
            exportSelectedIds = Set(displayConfigs.map(\.id))
            showingExporter = true
        }
        .disabled(displayConfigs.isEmpty)
    }

    private var newNodeButton: some View {
        actionBarButton(
            title: L("New Node", "新建节点"),
            icon: "plus.circle.fill",
            role: .primary,
            help: L("Create a new proxy node.", "新建一个代理节点。")
        ) {
            showingNewConfigEditor = true
        }
    }

    private enum ActionBarButtonRole {
        case secondary
        case file
        case primary
    }

    private func actionBarButton(
        title: String,
        icon: String?,
        role: ActionBarButtonRole,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 14)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14)
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(actionButtonForeground(role))
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(actionButtonBackground(role))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(actionButtonBorder(role), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var actionBarBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.78 : 0.94))
    }

    private var actionBarBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06), lineWidth: 1)
    }

    private func actionButtonForeground(_ role: ActionBarButtonRole) -> Color {
        switch role {
        case .primary:
            return .white
        case .file:
            return family.isCodex ? Color.indigo : Color.blue
        case .secondary:
            return .primary
        }
    }

    private func actionButtonBackground(_ role: ActionBarButtonRole) -> Color {
        switch role {
        case .primary:
            return Color.accentColor
        case .file:
            return (family.isCodex ? Color.indigo : Color.blue).opacity(colorScheme == .dark ? 0.18 : 0.10)
        case .secondary:
            return colorScheme == .dark ? Color.white.opacity(0.075) : Color.primary.opacity(0.045)
        }
    }

    private func actionButtonBorder(_ role: ActionBarButtonRole) -> Color {
        switch role {
        case .primary:
            return Color.white.opacity(colorScheme == .dark ? 0.18 : 0.12)
        case .file:
            return (family.isCodex ? Color.indigo : Color.blue).opacity(colorScheme == .dark ? 0.30 : 0.18)
        case .secondary:
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08)
        }
    }

    func syncCCSwitch() {
        guard !isSyncingCCSwitch else { return }
        isSyncingCCSwitch = true
        let isCodex = family.isCodex
        Task { @MainActor in
            let result = isCodex
                ? await viewModel.profileStore.importCCSwitchCodexProfiles()
                : await viewModel.profileStore.importCCSwitchClaudeProfiles()
            importResult = result
            showImportResult = true
            viewModel.loadConfigurations()
            isSyncingCCSwitch = false
        }
    }

    // MARK: - Summary Strip

    var summaryStrip: some View {
        let agg = aggregatedStats
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            summaryCell(
                icon: "point.3.connected.trianglepath.dotted",
                title: L("Nodes", "节点数"),
                value: "\(displayConfigs.count)",
                tint: .blue
            )
            summaryCell(
                icon: "checkmark.circle.fill",
                title: L("Active", "已激活"),
                value: familyActivatedId != nil ? "1" : "0",
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

    // MARK: - Aggregated Stats

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
        let familyIds = Set(displayConfigs.map(\.id))
        for (id, s) in viewModel.statistics where familyIds.contains(id) {
            agg.requests += s.totalRequests
            agg.successful += s.successfulRequests
            agg.tokens += s.totalTokens
            agg.cost += s.estimatedCostUSD
        }
        return agg
    }
}
