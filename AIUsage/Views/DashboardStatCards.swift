import SwiftUI

// MARK: - Dashboard Stat Cards
// 仪表盘概览/聚合统计卡片组件，从 DashboardView 拆出以控制单文件规模。
// 仅承载纯展示型卡片，不持有业务状态。

// MARK: - Stat Card Component

struct DashboardSummaryCard: Identifiable {
    let title: String
    let value: String
    let note: String
    let icon: String
    let color: Color

    var id: String { title }
}

struct StatCard: View {
    let stat: DashboardSummaryCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: stat.icon)
                    .foregroundStyle(stat.color)
                    .font(.title3)
                Spacer()
                Text(stat.value)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(stat.color)
            }

            Spacer(minLength: 8)

            Text(stat.title)
                .font(.subheadline)
                .bold()
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            Text(stat.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(14)
        .background(stat.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(stat.color.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Aggregate Stats Cards (Token Stats / Proxy)

private struct AggregateStatsCard<Footer: View>: View {
    let tint: Color
    let icon: String
    let title: String
    let subtitle: String
    let primaryValue: String
    let primaryLabel: String
    let metrics: [(title: String, value: String)]
    let onTap: () -> Void
    @ViewBuilder let footer: () -> Footer

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(tint.opacity(colorScheme == .dark ? 0.20 : 0.12))
                        .frame(width: 50, height: 50)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline.weight(.bold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryValue)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(primaryLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(metric.value)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.09))
                    )
                }
            }

            footer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(tint.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { onTap() }
    }
}

struct LocalTokenAggregateCard: View {
    let providers: [ProviderData]
    let onTap: () -> Void

    private var monthUsd: Double { providers.reduce(0) { $0 + ($1.costSummary?.month?.usd ?? 0) } }
    private var todayUsd: Double { providers.reduce(0) { $0 + ($1.costSummary?.today?.usd ?? 0) } }
    private var weekUsd: Double { providers.reduce(0) { $0 + ($1.costSummary?.week?.usd ?? 0) } }
    private var monthTokens: Int { providers.reduce(0) { $0 + ($1.costSummary?.month?.tokens ?? 0) } }

    var body: some View {
        let top = providers
            .sorted { ($0.costSummary?.month?.usd ?? 0) > ($1.costSummary?.month?.usd ?? 0) }
            .prefix(3)

        AggregateStatsCard(
            tint: .orange,
            icon: "chart.line.uptrend.xyaxis",
            title: L("Token Stats", "Token 统计"),
            subtitle: L("\(providers.count) accounts · monthly view",
                        "\(providers.count) 个账号 · 本月视图"),
            primaryValue: formatCurrency(monthUsd),
            primaryLabel: L("This month", "本月费用"),
            metrics: [
                (L("Today", "今日"), formatCurrency(todayUsd)),
                (L("Week", "本周"), formatCurrency(weekUsd)),
                (L("Tokens", "Tokens"), formatCompactNumber(Double(monthTokens)))
            ],
            onTap: onTap,
            footer: {
                if top.isEmpty {
                    EmptyView()
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(top), id: \.id) { provider in
                            HStack(spacing: 4) {
                                Circle().fill(Color.orange.opacity(0.7)).frame(width: 6, height: 6)
                                Text(provider.label).font(.caption2).lineLimit(1)
                                Text(formatCurrency(provider.costSummary?.month?.usd ?? 0))
                                    .font(.caption2.weight(.medium).monospacedDigit())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                        Spacer()
                    }
                }
            }
        )
    }

    private func formatCurrency(_ value: Double) -> String {
        AIUsage.formatCurrency(value)
    }
}

struct ProxyStatsAggregateCard: View {
    let proxyVM: ProxyViewModel
    let onTap: () -> Void

    var body: some View {
        let stats = proxyVM.overallStats(nodeFilter: nil, modelFilter: nil)
        let models = proxyVM.modelAggregates(nodeFilter: nil, modelFilter: nil)
        let range = proxyVM.dataDateRange(nodeFilter: nil, modelFilter: nil)
        let nodeCount = proxyVM.configurations.count

        AggregateStatsCard(
            tint: .teal,
            icon: "server.rack",
            title: L("Proxy Stats", "代理统计"),
            subtitle: L("\(nodeCount) nodes · \(range.days) days",
                        "\(nodeCount) 个节点 · 近 \(range.days) 天"),
            primaryValue: AIUsage.formatCurrency(stats.cost),
            primaryLabel: L("Total cost", "累计费用"),
            metrics: [
                (L("Tokens", "Tokens"), formatCompactNumber(Double(stats.tokens))),
                (L("Requests", "请求"), "\(stats.requests)"),
                (L("Success", "成功率"), String(format: "%.0f%%", stats.successRate))
            ],
            onTap: onTap,
            footer: {
                if models.isEmpty {
                    EmptyView()
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(models.prefix(3))) { m in
                            HStack(spacing: 4) {
                                Circle().fill(Color.teal.opacity(0.7)).frame(width: 6, height: 6)
                                Text(m.model).font(.caption2).lineLimit(1)
                                Text(AIUsage.formatCurrency(m.cost))
                                    .font(.caption2.weight(.medium).monospacedDigit())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                        Spacer()
                    }
                }
            }
        )
    }
}
