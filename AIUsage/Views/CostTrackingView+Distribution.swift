import SwiftUI
import Charts

extension CostTrackingView {

    var distributionModels: [ModelCostBreakdown] {
        cachedDistributionModels
    }

    func makeDistributionModels(from summary: CostSummary) -> [ModelCostBreakdown] {
        let models: [ModelCostBreakdown]
        switch distributionPeriod {
        case .today: models = summary.modelBreakdownToday ?? []
        case .week: models = summary.modelBreakdownWeek ?? []
        case .month: models = summary.modelBreakdown ?? []
        case .overall: models = summary.modelBreakdownOverall ?? []
        }
        return models.filter(hasUsage)
    }

    var rankedDistributionModels: [ModelCostBreakdown] {
        cachedRankedDistributionModels
    }

    func makeRankedDistributionModels(from models: [ModelCostBreakdown]) -> [ModelCostBreakdown] {
        models.sorted { lhs, rhs in
            let lhsValue = distributionMetric == .usd ? lhs.estimatedCostUsd : Double(lhs.totalTokens)
            let rhsValue = distributionMetric == .usd ? rhs.estimatedCostUsd : Double(rhs.totalTokens)
            if lhsValue == rhsValue {
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
    }

    var usesStackedInsightsLayout: Bool {
        contentWidth > 0 && contentWidth < 1080
    }

    var splitDistributionWidth: CGFloat {
        let availableWidth = max(contentWidth, 980)
        return min(max(availableWidth * 0.34, 310), 380)
    }

    var insightPanels: some View {
        Group {
            if usesStackedInsightsLayout {
                VStack(alignment: .leading, spacing: 16) {
                    modelDistribution(layout: .stacked)
                    modelTable(layout: .stacked)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    modelDistribution(layout: .split)
                        .frame(width: splitDistributionWidth, alignment: .topLeading)
                    modelTable(layout: .split)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
            }
        }
    }

    func distributionChartHeight(for layout: CostTrackingInsightsLayout) -> CGFloat {
        layout == .split ? 210 : 230
    }

    func modelDistribution(layout: CostTrackingInsightsLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Model Distribution", "模型分布"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { distributionPeriod },
                        set: { selectDistributionPeriod($0) }
                    )) {
                        Text(L("Today", "今日")).tag(DistributionPeriod.today)
                        Text(L("Week", "本周")).tag(DistributionPeriod.week)
                        Text(L("Month", "本月")).tag(DistributionPeriod.month)
                        Text(L("All", "全部")).tag(DistributionPeriod.overall)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    Spacer(minLength: 8)

                    Picker("", selection: $distributionMetric) {
                        Text("USD").tag(CostMetric.usd)
                        Text("Tokens").tag(CostMetric.tokens)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: Binding(
                        get: { distributionPeriod },
                        set: { selectDistributionPeriod($0) }
                    )) {
                        Text(L("Today", "今日")).tag(DistributionPeriod.today)
                        Text(L("Week", "本周")).tag(DistributionPeriod.week)
                        Text(L("Month", "本月")).tag(DistributionPeriod.month)
                        Text(L("All", "全部")).tag(DistributionPeriod.overall)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Spacer()
                        Picker("", selection: $distributionMetric) {
                            Text("USD").tag(CostMetric.usd)
                            Text("Tokens").tag(CostMetric.tokens)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                }
            }

            let distModels = rankedDistributionModels
            let colorMap = modelColorMap
            let tokenTotal = distModels.reduce(0) { $0 + $1.totalTokens }
            if distModels.isEmpty {
                Text(L("No data for this period", "该时段暂无数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                donutChart(colorMap: colorMap, tokenTotal: tokenTotal)
                    .frame(height: distributionChartHeight(for: layout))

                VStack(spacing: 6) {
                    ForEach(Array(distModels.prefix(6)), id: \.id) { model in
                        let color = modelColor(for: model.model, from: colorMap)
                        HStack(spacing: 8) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(model.model)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(model.model)
                            Spacer()
                            let share = distributionShare(for: model, totalTokens: tokenTotal)
                            if distributionMetric == .usd {
                                Text(formatCurrency(model.estimatedCostUsd))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(color)
                                Text(String(format: "%.1f%%", share))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(formatCompactNumber(Double(model.totalTokens)))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(color)
                                Text(String(format: "%.1f%%", share))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    func donutChart(colorMap: [String: Color], tokenTotal: Int) -> some View {
        let items = Array(rankedDistributionModels.prefix(6))
        return Chart(items, id: \.id) { model in
            SectorMark(
                angle: .value("Value", max(donutValue(model), 0.001)),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .foregroundStyle(modelColor(for: model.model, from: colorMap))
            .cornerRadius(4)
            .annotation(position: .overlay) {
                let pct = distributionShare(for: model, totalTokens: tokenTotal)
                if pct >= 10 {
                    Text(String(format: "%.0f%%", pct))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .chartLegend(.hidden)
    }

    func donutValue(_ model: ModelCostBreakdown) -> Double {
        distributionMetric == .usd ? model.estimatedCostUsd : Double(model.totalTokens)
    }
}
