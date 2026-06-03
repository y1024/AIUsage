import SwiftUI
import QuotaBackend

// MARK: - ProxyManagementView Toolbar & Summary
// 顶部工具栏（导入/导出/新建/settings.json）与节点汇总条（节点数/激活/请求/成功率/Token/费用）。
// 与主视图分离以控制单文件规模；依赖主视图的 @State 与过滤属性（family-scoped）。

extension ProxyManagementView {

    // MARK: - Action Bar

    var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()

            // Codex 的 config.toml 编辑入口统一收敛到下方「通用配置」卡片，避免与工具栏按钮重复。
            if !family.isCodex {
                actionBarButton(
                    title: L("settings.json", "settings.json"),
                    icon: "doc.text.fill",
                    tint: .secondary
                ) {
                    showingSettingsEditor = true
                }
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
                exportSelectedIds = Set(displayConfigs.map(\.id))
                showingExporter = true
            }
            .disabled(displayConfigs.isEmpty)

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
