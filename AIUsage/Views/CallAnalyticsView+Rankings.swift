import SwiftUI
import QuotaBackend

// MARK: - Call Analytics Rankings
// Top-N 排行：按 MCP（server 折叠）/ 技能 / 工具 维度展示调用次数条形榜。

extension CallAnalyticsView {
    var rankingCard: some View {
        let rows = Array(derived.ranking(for: lens).prefix(12))
        let maxCount = max(rows.map(\.count).max() ?? 1, 1)
        return cardContainer(title: rankingTitle, subtitle: rankingSubtitle) {
            Picker("", selection: $lens) {
                ForEach(CallLens.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if rows.isEmpty {
                Text(L("No \(lens.title) calls in range", "范围内暂无\(lens.title)调用", key: "calls.rank.empty"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { rankingRow($0, maxCount: maxCount) }
                }
                .padding(.top, 2)
            }
        }
    }

    private var rankingTitle: String {
        switch lens {
        case .mcp: return L("Top MCP Servers", "MCP Server 排行", key: "calls.rank.mcp")
        case .skill: return L("Top Skills", "技能排行", key: "calls.rank.skill")
        case .tools: return L("Top Tools", "工具排行", key: "calls.rank.tools")
        }
    }

    private var rankingSubtitle: String {
        switch lens {
        case .mcp: return L("Calls grouped by MCP server", "按 MCP server 折叠计数", key: "calls.rank.mcp.sub")
        case .skill: return L("Skill invocations by name", "按技能名统计调用", key: "calls.rank.skill.sub")
        case .tools: return L("Built-in / web tools by name", "内置 / 网络工具调用", key: "calls.rank.tools.sub")
        }
    }

    private func rankingRow(_ row: RankedRow, maxCount: Int) -> some View {
        HStack(spacing: 10) {
            Text(row.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200, alignment: .leading)

            GeometryReader { proxy in
                let ratio = CGFloat(row.count) / CGFloat(maxCount)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(4, proxy.size.width * ratio))
                }
            }
            .frame(height: 14)

            HStack(spacing: 3) {
                ForEach(Array(row.sources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                    Circle().fill(CallAnalyticsView.color(for: source)).frame(width: 6, height: 6)
                }
            }
            .frame(width: 40, alignment: .trailing)

            Text("\(row.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var barColor: Color {
        switch lens {
        case .mcp: return .purple
        case .skill: return .pink
        case .tools: return .teal
        }
    }
}
