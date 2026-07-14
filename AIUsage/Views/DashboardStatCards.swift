import SwiftUI

// MARK: - Dashboard Stat Cards
// 仪表盘顶部紧凑统计条：统一胶囊高度，对齐 GatewayStatCapsuleRow。
// 聚焦用量/费用；账号治理数字交给「订阅账号」页。

struct DashboardOverviewStatRow: View {
    let todayTokens: String
    let monthTokens: String
    let todayCost: String
    let monthCost: String

    var body: some View {
        GatewayStatCapsuleRow(items: [
            .init(
                id: "todayTokens",
                value: todayTokens,
                title: L("tokens today", "今日 Token"),
                systemImage: "bolt.fill",
                tint: .purple
            ),
            .init(
                id: "monthTokens",
                value: monthTokens,
                title: L("tokens this month", "本月 Token"),
                systemImage: "chart.bar.fill",
                tint: .indigo
            ),
            .init(
                id: "todayCost",
                value: todayCost,
                title: L("cost today", "今日费用"),
                systemImage: "dollarsign.circle.fill",
                tint: .orange
            ),
            .init(
                id: "monthCost",
                value: monthCost,
                title: L("cost this month", "本月费用"),
                systemImage: "creditcard.fill",
                tint: .green
            ),
        ])
    }
}

struct DashboardManageAccountsBanner: View {
    let totalCount: Int
    let attentionCount: Int
    let onManage: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onManage) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Manage all accounts", "管理全部账号"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppContent.primary(colorScheme))
                    if attentionCount > 0 {
                        Text(L(
                            "\(attentionCount) need attention · \(totalCount) total",
                            "\(attentionCount) 个需处理 · 共 \(totalCount) 个"
                        ))
                        .font(.caption2)
                        .foregroundStyle(AppContent.secondary(colorScheme))
                    } else {
                        Text(L("\(totalCount) accounts in Subscriptions", "订阅账号中共 \(totalCount) 个"))
                            .font(.caption2)
                            .foregroundStyle(AppContent.secondary(colorScheme))
                    }
                }
                Spacer(minLength: 0)
                Text(L("Open", "打开"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppSurface.row(colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppStroke.subtle(colorScheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
