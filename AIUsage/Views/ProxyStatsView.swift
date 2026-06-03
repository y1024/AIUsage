import SwiftUI
import Charts
import QuotaBackend

// MARK: - ProxyStatsView
// 用量统计页主视图。数据源为 JSONL 本地日志（通过 StatsDataAdapter 聚合），
// 与仪表盘热力图/概览共享同一口径，不再依赖代理请求日志。

struct ProxyStatsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator

    // 统一控制台口径：metric（费用/Tokens）与 period（今日/本周/本月/全部）全页共用，均持久化。
    @AppStorage(DefaultsKey.proxyStatsMetric) var metric: StatMetric = .cost
    @AppStorage(DefaultsKey.proxyStatsChartRange) var chartTimeRange: ChartTimeRange = .today
    @AppStorage(DefaultsKey.proxyStatsPeriod) var period: DistributionPeriod = .overall
    @AppStorage(DefaultsKey.proxyStatsFamily) var familyRaw: String = SourceFamily.all.rawValue
    @AppStorage(DefaultsKey.proxyStatsTrack) var trackRaw: String = UsageTrack.combined.rawValue
    @State var contentWidth: CGFloat = 0
    @State var expandedModels: Set<String> = []
    @State var selectedModels: Set<String> = []

    // MARK: - Types

    enum StatMetric: String, CaseIterable { case cost, tokens }

    enum SourceFamily: String, CaseIterable {
        case all, claude, codex

        var adapterFamily: StatsDataAdapter.SourceFamily {
            switch self {
            case .all:    return .all
            case .claude: return .claude
            case .codex:  return .codex
            }
        }
    }

    // MARK: - Data

    static let adapter = StatsDataAdapter()

    var localProviders: [ProviderData] {
        appState.localCostProviders(from: refreshCoordinator.providers)
    }

    var claudeLocalProviders: [ProviderData] {
        localProviders.filter { $0.baseProviderId == "claude" }
    }

    var codexLocalProviders: [ProviderData] {
        localProviders.filter { $0.baseProviderId == "codex-cost" }
    }

    var sourceFamily: SourceFamily {
        SourceFamily(rawValue: familyRaw) ?? .all
    }

    var familyBinding: Binding<SourceFamily> {
        Binding(get: { sourceFamily }, set: { familyRaw = $0.rawValue })
    }

    var selectedTrack: UsageTrack {
        UsageTrack(rawValue: trackRaw) ?? .combined
    }

    var trackBinding: Binding<UsageTrack> {
        Binding(get: { selectedTrack }, set: { trackRaw = $0.rawValue })
    }

    /// 仅 Codex 家族才有 API/订阅两轨；其它家族强制合计。
    var effectiveTrack: UsageTrack {
        sourceFamily == .codex ? selectedTrack : .combined
    }

    /// 轨道切换器仅在 Codex 家族显示（Claude 单轨、综合含无后缀的 Claude 行不宜按轨过滤）。
    var showsTrackPicker: Bool {
        sourceFamily == .codex && !codexLocalProviders.isEmpty
    }

    /// 订阅制不按 token 计费 → 选「订阅」轨时全页隐藏费用相关 UI（费用 tile / 费用-Tokens 切换 /
    /// 费用列 / 按费用的占比与饼图），只呈现 token 用量。其它轨道正常显示费用。
    var showsCost: Bool {
        effectiveTrack != .subscription
    }

    /// 隐藏费用时（订阅轨），分布/详情/趋势一律按 Tokens 口径（不改持久化的 metric 偏好）。
    var effectiveMetric: StatMetric {
        showsCost ? metric : .tokens
    }

    var summary: CostSummary? {
        Self.adapter.summary(
            providers: localProviders,
            family: sourceFamily.adapterFamily,
            track: effectiveTrack
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if localProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    let ranked = rankedTrendSeries
                    let colorMap = buildModelColorMap(from: ranked)
                    LazyVStack(spacing: 16) {
                        controlDeck
                        summaryStrip
                        heatmapSection
                            // 抬高层级，让热力图 tooltip 绘制在下方分布/详情卡片之上，不被遮挡。
                            .zIndex(1)
                        insightPanelsSection(colorMap: colorMap, sparklineMap: buildSparklineMap(from: ranked))
                    }
                    .padding(20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: StatsContentWidthKey.self, value: proxy.size.width)
                        }
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: familyRaw) { _, _ in
            pruneSelectedModels()
        }
        .onChange(of: trackRaw) { _, _ in
            pruneSelectedModels()
        }
        .onPreferenceChange(StatsContentWidthKey.self) { newWidth in
            if abs(newWidth - contentWidth) > 8 {
                contentWidth = newWidth
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(L("No usage data", "暂无用量数据"))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L("Usage data will appear once Claude Code or Codex starts generating local logs.",
                   "当 Claude Code 或 Codex 开始产生本地日志后，用量数据将自动展示。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Control Deck
    // 统一控制台：左「数据源」（家族 + Codex 轨道），右「视图」（时间段 + 费用/Tokens）。
    // 宽屏一行（中间分隔），窄屏自动折成两行。时间段与口径全页共用，移除了卡片内重复 picker。

    var controlDeck: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                controlCluster(L("Source", "数据源")) { scopeControls }
                Divider().frame(height: 20)
                controlCluster(L("View", "视图")) { lensControls }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                controlCluster(L("Source", "数据源")) { scopeControls }
                controlCluster(L("View", "视图")) { lensControls }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func controlCluster<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var scopeControls: some View {
        Picker("", selection: familyBinding) {
            Text(L("Combined", "综合")).tag(SourceFamily.all)
            Text("Claude Code").tag(SourceFamily.claude)
            Text("Codex").tag(SourceFamily.codex)
        }
        .pickerStyle(.segmented)
        .fixedSize()

        if showsTrackPicker {
            Picker("", selection: trackBinding) {
                ForEach(UsageTrack.allCases) { track in
                    Text(track.label).tag(track)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help(L("Split Codex usage into API (proxy logs) and Subscription (local logs) tracks.",
                    "将 Codex 用量拆分为 API（代理日志）与订阅（本地日志）两轨。"))
        }
    }

    @ViewBuilder
    private var lensControls: some View {
        Picker("", selection: $period) {
            ForEach(DistributionPeriod.allCases) { p in
                Text(p.label).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()

        if showsCost {
            Picker("", selection: $metric) {
                Text(L("Cost", "费用")).tag(StatMetric.cost)
                Text("Tokens").tag(StatMetric.tokens)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    // MARK: - Heatmap

    /// Codex 热力图标题：单轨时附带轨道名（如「Codex · 订阅」），合计时仅品牌名。
    var codexHeatmapLabel: String {
        effectiveTrack == .combined ? "Codex" : "Codex · \(effectiveTrack.label)"
    }

    @ViewBuilder
    var heatmapSection: some View {
        let showClaude = sourceFamily != .codex
        let showCodex = sourceFamily != .claude

        VStack(spacing: 16) {
            if showClaude && !claudeLocalProviders.isEmpty {
                LocalTokenUsageHeatmap(
                    providers: claudeLocalProviders,
                    brandLabel: "Claude Code",
                    brandAsset: "claude",
                    accent: Color(red: 0.85, green: 0.47, blue: 0.26)
                )
                .zIndex(1)
            }
            if showCodex && !codexLocalProviders.isEmpty {
                LocalTokenUsageHeatmap(
                    providers: codexLocalProviders,
                    brandLabel: codexHeatmapLabel,
                    brandAsset: "codex",
                    accent: .indigo,
                    track: effectiveTrack
                )
            }
        }
    }

    // MARK: - Shared Helpers

    /// 家族 / 轨道切换后，模型名集合会变（订阅/API 过滤、剥后缀），剔除已不存在的对比选择。
    func pruneSelectedModels() {
        let available = Set(Self.adapter.allModels(from: summary))
        selectedModels = selectedModels.filter { available.contains($0) }
    }

    let chartColors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .red, .yellow, .mint, .indigo]

    func colorForModel(_ model: String, from colorMap: [String: Color]) -> Color {
        colorMap[model] ?? chartColors[stablePaletteIndex(for: model, paletteCount: chartColors.count)]
    }

    func buildModelColorMap(from ranked: [TrendSeriesDescriptor]) -> [String: Color] {
        var map: [String: Color] = [:]
        for (idx, descriptor) in ranked.enumerated() {
            map[descriptor.model] = chartColors[idx % chartColors.count]
        }
        return map
    }

    var usesStackedInsightsLayout: Bool {
        contentWidth > 0 && contentWidth < 1080
    }

    var granularity: CostGranularity { chartTimeRange.isHourly ? .hourly : .daily }

    enum InsightsLayout {
        case split
        case stacked
    }
}

// MARK: - PreferenceKey

struct StatsContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    ProxyStatsView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .frame(width: 900, height: 700)
}
