import SwiftUI

// MARK: - Main View

struct CostTrackingView: View {
    static let allSourcesId = "__all-local-token-sources__"

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @AppStorage(DefaultsKey.ccStatsMetric) var selectedMetric: CostMetric = .usd
    @AppStorage(DefaultsKey.ccStatsChartRange) var chartTimeRange: ChartTimeRange = .today
    @State var selectedModels: Set<String> = []
    @AppStorage(DefaultsKey.ccStatsDistMetric) var distributionMetric: CostMetric = .usd
    @AppStorage(DefaultsKey.ccStatsDistPeriod) var distributionPeriod: DistributionPeriod = .today
    @State var detailProvider: ProviderData?
    @State var expandedModels: Set<String> = []
    @State var contentWidth: CGFloat = 0
    @State var chartHoverDate: Date?
    @AppStorage(DefaultsKey.ccStatsSelectedProviderId) var selectedCostProviderId: String = ""
    @State var aggregateCostSummary: CostSummary?
    @State var aggregateCostSignature: String = ""
    @State var derivedCostSignature: String = ""
    @State var cachedAggregateChartPoints: [CostTimelinePoint] = []
    @State var cachedSortedChartSeries: [ChartSeriesDescriptor] = []
    @State var cachedModelColorMap: [String: Color] = [:]
    @State var cachedDistributionModels: [ModelCostBreakdown] = []
    @State var cachedRankedDistributionModels: [ModelCostBreakdown] = []
    @State var cachedSparklineValuesByModel: [String: [Double]] = [:]

    var selectedGranularity: CostGranularity { chartTimeRange.isHourly ? .hourly : .daily }

    var costProviders: [ProviderData] {
        appState.localCostProviders(from: refreshCoordinator.providers)
    }

    var primaryProvider: ProviderData? {
        if selectedCostProviderId == Self.allSourcesId {
            // Transparent fallback: when "All Sources" is selected but only one provider remains
            // (e.g. account disconnected between renders, before `ensureSelectedCostProvider`
            // normalizes the selection), surface that single provider so the summary, chart and
            // distribution panels keep rendering instead of flashing the empty state for a frame.
            return costProviders.count == 1 ? costProviders.first : nil
        }
        return costProviders.first { $0.id == selectedCostProviderId } ?? costProviders.first
    }

    var costSummary: CostSummary? {
        if selectedCostProviderId == Self.allSourcesId {
            if costProviders.count > 1 { return aggregateCostSummary }
            return costProviders.first?.costSummary
        }
        return primaryProvider?.costSummary
    }

    var selectedCostIncludesCodex: Bool {
        if selectedCostProviderId == Self.allSourcesId {
            return costProviders.contains { $0.baseProviderId == "codex-cost" }
        }
        return primaryProvider?.baseProviderId == "codex-cost"
    }

    var costProviderSummarySignature: String {
        let fragments: [String] = costProviders.map { provider -> String in
            guard let summary = provider.costSummary else {
                let parts: [String] = [
                    provider.id,
                    provider.status.rawValue,
                    provider.fetchedAt ?? "",
                    "empty"
                ]
                return parts.joined(separator: ":")
            }

            let parts: [String] = [
                provider.id,
                provider.status.rawValue,
                provider.fetchedAt ?? "",
                summary.today.signatureFragment,
                summary.week.signatureFragment,
                summary.month.signatureFragment,
                summary.overall.signatureFragment,
                summary.timeline?.hourly.signatureFragment ?? "hourly:nil",
                summary.timeline?.daily.signatureFragment ?? "daily:nil",
                summary.modelBreakdownToday?.signatureFragment ?? "todayModels:nil",
                summary.modelBreakdownWeek?.signatureFragment ?? "weekModels:nil",
                summary.modelBreakdown?.signatureFragment ?? "monthModels:nil",
                summary.modelBreakdownOverall?.signatureFragment ?? "overallModels:nil",
                summary.modelTimelines?.signatureFragment ?? "timelines:nil"
            ]
            return parts.joined(separator: ":")
        }
        return fragments.joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            if costProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        sourceSelector
                        summaryStrip
                        chartSection
                        insightPanels
                    }
                    .padding(20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: CostTrackingContentWidthPreferenceKey.self, value: proxy.size.width)
                        }
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $detailProvider) { provider in
            ProviderDetailView(provider: provider)
        }
        .onAppear {
            normalizeInitialCostRangeDefaultsIfNeeded()
            ensureSelectedCostProvider()
            refreshAggregateCostSummaryIfNeeded(force: true)
            refreshDerivedCostCachesIfNeeded(force: true)
            requestCodexFullHistoryImportIfNeeded()
        }
        .onChange(of: costProviders.map(\.id)) { _, _ in
            ensureSelectedCostProvider()
            refreshAggregateCostSummaryIfNeeded(force: true)
            refreshDerivedCostCachesIfNeeded(force: true)
            requestCodexFullHistoryImportIfNeeded()
        }
        .onChange(of: costProviderSummarySignature) { _, _ in
            refreshAggregateCostSummaryIfNeeded()
            refreshDerivedCostCachesIfNeeded(force: true)
        }
        .onChange(of: selectedMetric) { _, _ in
            refreshDerivedCostCachesIfNeeded(force: true)
        }
        .onChange(of: chartTimeRange) { _, _ in
            refreshDerivedCostCachesIfNeeded(force: true)
        }
        .onChange(of: distributionMetric) { _, _ in
            refreshDerivedCostCachesIfNeeded(force: true)
        }
        .onChange(of: distributionPeriod) { _, _ in
            refreshDerivedCostCachesIfNeeded(force: true)
        }
        .onPreferenceChange(CostTrackingContentWidthPreferenceKey.self) { newWidth in
            // Threshold avoids rebuilding the whole body on sub-pixel width jitter
            // during scroll or expand/collapse. 8pt is well below the 1080pt
            // breakpoint used by usesStackedInsightsLayout.
            if abs(newWidth - contentWidth) > 8 {
                contentWidth = newWidth
            }
        }
    }

    @ViewBuilder
    var sourceSelector: some View {
        if costProviders.count > 1 {
            HStack(spacing: 10) {
                Text(L("Local Source", "本地来源"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { selectedCostProviderId.isEmpty ? defaultCostProviderSelection : selectedCostProviderId },
                    set: { newValue in
                        selectedCostProviderId = newValue
                        selectedModels.removeAll()
                        expandedModels.removeAll()
                        chartHoverDate = nil
                        if newValue == Self.allSourcesId {
                            refreshAggregateCostSummaryIfNeeded()
                        }
                        refreshDerivedCostCachesIfNeeded(force: true)
                        requestCodexFullHistoryImportIfNeeded()
                    }
                )) {
                    Text(L("All Sources", "综合")).tag(Self.allSourcesId)
                    ForEach(costProviders) { provider in
                        Text(provider.label).tag(provider.id)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()
            }
        }
    }

    var defaultCostProviderSelection: String {
        costProviders.count > 1 ? Self.allSourcesId : (costProviders.first?.id ?? "")
    }

    func ensureSelectedCostProvider() {
        guard !costProviders.isEmpty else {
            selectedCostProviderId = ""
            return
        }
        let isValidAggregate = costProviders.count > 1 && selectedCostProviderId == Self.allSourcesId
        let isValidProvider = costProviders.contains { $0.id == selectedCostProviderId }
        if !isValidAggregate && !isValidProvider {
            selectedCostProviderId = defaultCostProviderSelection
            selectedModels.removeAll()
            expandedModels.removeAll()
            chartHoverDate = nil
            refreshDerivedCostCachesIfNeeded(force: true)
        }
    }

    func selectChartTimeRange(_ newValue: ChartTimeRange) {
        chartTimeRange = newValue
        chartHoverDate = nil
        refreshDerivedCostCachesIfNeeded(force: true)
        requestCodexFullHistoryImportIfNeeded()
    }

    func selectDistributionPeriod(_ newValue: DistributionPeriod) {
        distributionPeriod = newValue
        refreshDerivedCostCachesIfNeeded(force: true)
        requestCodexFullHistoryImportIfNeeded()
    }

    func requestCodexFullHistoryImportIfNeeded() {
        guard selectedCostIncludesCodex,
              chartTimeRange == .all || distributionPeriod == .overall else {
            return
        }
        refreshCoordinator.refreshCodexCostFullHistoryIfNeeded()
    }

    func normalizeInitialCostRangeDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKey.ccStatsDidDefaultToTodayForCodexArchive) else {
            return
        }
        if chartTimeRange == .all {
            chartTimeRange = .today
        }
        if distributionPeriod == .overall {
            distributionPeriod = .today
        }
        defaults.set(true, forKey: DefaultsKey.ccStatsDidDefaultToTodayForCodexArchive)
    }

    func refreshAggregateCostSummaryIfNeeded(force: Bool = false) {
        let signature = costProviderSummarySignature
        guard force || signature != aggregateCostSignature else { return }

        aggregateCostSignature = signature
        aggregateCostSummary = costProviders.count > 1
            ? aggregateCostSummaries(costProviders)
            : nil
    }

    var derivedCostCacheSignature: String {
        [
            selectedCostProviderId.isEmpty ? defaultCostProviderSelection : selectedCostProviderId,
            costProviderSummarySignature,
            selectedMetric.rawValue,
            chartTimeRange.rawValue,
            distributionMetric.rawValue,
            distributionPeriod.rawValue
        ].joined(separator: "|")
    }

    func refreshDerivedCostCachesIfNeeded(force: Bool = false) {
        let signature = derivedCostCacheSignature
        guard force || signature != derivedCostSignature else { return }
        derivedCostSignature = signature

        guard let summary = costSummary else {
            cachedAggregateChartPoints = []
            cachedSortedChartSeries = []
            cachedModelColorMap = [:]
            cachedDistributionModels = []
            cachedRankedDistributionModels = []
            cachedSparklineValuesByModel = [:]
            return
        }

        cachedAggregateChartPoints = makeAggregateChartPoints(from: summary)
        cachedSortedChartSeries = makeSortedChartSeries(from: summary)
        let availableModels = Set(cachedSortedChartSeries.map(\.model))
        let prunedSelection = selectedModels.intersection(availableModels)
        if prunedSelection != selectedModels {
            DispatchQueue.main.async {
                selectedModels = prunedSelection
            }
        }
        cachedModelColorMap = makeModelColorMap(from: cachedSortedChartSeries)
        cachedDistributionModels = makeDistributionModels(from: summary)
        cachedRankedDistributionModels = makeRankedDistributionModels(from: cachedDistributionModels)
        cachedSparklineValuesByModel = makeSparklineValuesByModel(from: cachedSortedChartSeries)
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("No cost data found", "未发现费用数据"))
                .font(.title3.weight(.bold))
            Text(L("Local Claude and Codex token logs will appear here.", "本地 Claude 与 Codex Token 日志将在这里显示。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum CostTrackingInsightsLayout {
    case split
    case stacked
}

private struct CostTrackingContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension Optional where Wrapped == CostPeriod {
    var signatureFragment: String {
        guard let period = self else { return "nil" }
        return "\(period.usd):\(period.tokens ?? -1):\(period.rangeLabel ?? "")"
    }
}

private extension Array where Element == CostTimelinePoint {
    var signatureFragment: String {
        var hash = CostTrackingSignatureHash()
        for point in self {
            hash.combine(point.bucket)
            hash.combine(point.usd)
            hash.combine(point.tokens)
        }
        return "\(count):\(hash.hexDigest)"
    }
}

private extension Array where Element == ModelCostBreakdown {
    var signatureFragment: String {
        var hash = CostTrackingSignatureHash()
        for item in sorted(by: { $0.model < $1.model }) {
            hash.combine(item.model)
            hash.combine(item.totalTokens)
            hash.combine(item.inputTokens)
            hash.combine(item.outputTokens)
            hash.combine(item.cacheReadTokens)
            hash.combine(item.cacheCreateTokens)
            hash.combine(item.estimatedCostUsd)
        }
        return "\(count):\(hash.hexDigest)"
    }
}

private extension Array where Element == ModelTimelineSeries {
    var signatureFragment: String {
        var hash = CostTrackingSignatureHash()
        for item in sorted(by: { $0.model < $1.model }) {
            hash.combine(item.model)
            hash.combine(item.hourly.signatureFragment)
            hash.combine(item.daily.signatureFragment)
        }
        return "\(count):\(hash.hexDigest)"
    }
}

private struct CostTrackingSignatureHash {
    private var value: UInt64 = 0xcbf29ce484222325

    mutating func combine(_ value: String) {
        for byte in value.utf8 {
            self.value ^= UInt64(byte)
            self.value = self.value &* 0x100000001b3
        }
    }

    mutating func combine(_ value: Int) {
        combine(String(value))
    }

    mutating func combine(_ value: Double) {
        combine(String(format: "%.6f", value))
    }

    var hexDigest: String {
        String(format: "%016llx", value)
    }
}
