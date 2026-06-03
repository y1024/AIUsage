import SwiftUI
import QuotaBackend

// MARK: - MenuBarView Cost Tracking Section
// Claude Code / Codex 各自的「费用 + 用量」汇总（今日 / 本月 / 总计）。
// 数据源统一为对应本地 cost provider 的 costSummary（refreshCoordinator 已聚合）：
//   · Claude：来自代理日志永久归档（费用与 token 同源）。
//   · Codex：费用 = API 轨（代理日志，订阅不计费恒 0）；token = API + 订阅合计，
//     这样常用的「订阅用量」在费用看不出时也能从 token 列直接看到。
// 「总计」口径 = 归档全历史（比旧的代理保留窗求和更完整）。

extension MenuBarView {

    @ViewBuilder
    var costTrackingSection: some View {
        let families = costFamilyProviders
        if !families.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(L("Cost & Usage", "费用 · 用量"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                ForEach(families) { item in
                    familyCostRow(item.family, summary: item.summary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// 一个家族的费用/用量数据（供 ForEach 稳定标识）。
    struct FamilyCost: Identifiable {
        let family: ProxyNodeFamily
        let summary: CostSummary
        var id: Bool { family.isCodex }
    }

    /// 有费用/用量数据的家族（Claude / Codex）及其 costSummary。
    /// 改用 cost provider 而非代理节点判定，故仅用订阅的 Codex（无 API 节点）也会展示。
    var costFamilyProviders: [FamilyCost] {
        let providers = appState.localCostProviders(from: refreshCoordinator.providers)
        var result: [FamilyCost] = []
        if let summary = providers.first(where: { $0.baseProviderId == "claude" })?.costSummary {
            result.append(FamilyCost(family: .claude, summary: summary))
        }
        if let summary = providers.first(where: { $0.baseProviderId == "codex-cost" })?.costSummary {
            result.append(FamilyCost(family: .codex, summary: summary))
        }
        return result
    }

    private func familyCostRow(_ family: ProxyNodeFamily, summary: CostSummary) -> some View {
        let tint = family.isCodex
            ? Color(red: 0.40, green: 0.52, blue: 0.92)   // Codex 靛蓝
            : Color(red: 0.85, green: 0.45, blue: 0.25)   // Claude 橙
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIconView(family.isCodex ? "codex" : "claude", size: 14)
                Text(family.isCodex ? "Codex" : "Claude Code")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }

            // 今日 / 本月 / 总计：三枚等宽胶囊卡片，两家族上下对齐。
            HStack(spacing: 6) {
                metricChip(L("Today", "今日"), cost: summary.today?.usd, tokens: summary.today?.tokens, tint: tint)
                metricChip(L("Month", "本月"), cost: summary.month?.usd, tokens: summary.month?.tokens, tint: tint)
                metricChip(L("Total", "总计"), cost: summary.overall?.usd, tokens: summary.overall?.tokens, tint: tint)
            }
        }
    }

    /// 单个周期的指标胶囊：内联「标签 · 费用(橙) · 用量」，等宽自适应、不换行不裁切。
    private func metricChip(_ label: String, cost: Double?, tokens: Int?, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(formatCostCompact(cost ?? 0))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text("·")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text((tokens ?? 0) > 0 ? formatCompactNumber(Double(tokens ?? 0)) : "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        )
    }
}
