import SwiftUI

// MARK: - Stats Hub
// 「用量统计」入口：数据源为 JSONL 本地日志（Claude Code / Codex），
// 通过 StatsDataAdapter 统一聚合，与仪表盘概览共享同一口径。

struct StatsHubView: View {
    var body: some View {
        ProxyStatsView()
    }
}

#Preview {
    StatsHubView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .frame(width: 980, height: 700)
}
