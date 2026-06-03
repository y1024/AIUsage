import SwiftUI
import Charts
import QuotaBackend

// MARK: - Trend Data Helpers
// 趋势数据计算：为模型详情表的 sparkline 和颜色映射提供数据源。

extension ProxyStatsView {

    struct TrendSeriesDescriptor: Identifiable {
        let model: String
        let points: [StatsDataAdapter.ModelTimePoint]
        let totalCost: Double
        let totalTokens: Int

        var id: String { model }
    }

    var maxVisibleTrendModels: Int { 8 }

    var rankedTrendSeries: [TrendSeriesDescriptor] {
        let allPoints = Self.adapter.modelTimeSeries(
            from: summary,
            granularity: granularity,
            timeRange: chartTimeRange
        )

        return Dictionary(grouping: allPoints, by: \.model)
            .map { model, points in
                let sorted = points.sorted { $0.date < $1.date }
                return TrendSeriesDescriptor(
                    model: model,
                    points: sorted,
                    totalCost: sorted.reduce(0) { $0 + $1.cost },
                    totalTokens: sorted.reduce(0) { $0 + $1.tokens }
                )
            }
            .sorted { lhs, rhs in
                let lv = effectiveMetric == .cost ? lhs.totalCost : Double(lhs.totalTokens)
                let rv = effectiveMetric == .cost ? rhs.totalCost : Double(rhs.totalTokens)
                if lv == rv { return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending }
                return lv > rv
            }
    }

    func buildSparklineMap(from ranked: [TrendSeriesDescriptor]) -> [String: [Double]] {
        var map: [String: [Double]] = [:]
        for descriptor in ranked {
            map[descriptor.model] = descriptor.points.map {
                effectiveMetric == .cost ? $0.cost : Double($0.tokens)
            }
        }
        return map
    }

    func toggleModel(_ model: String) {
        if selectedModels.contains(model) {
            selectedModels.remove(model)
        } else {
            selectedModels.insert(model)
        }
    }
}
