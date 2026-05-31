import SwiftUI

// MARK: - Stats Domain
// Token 统计页的一级数据域。两者测量的是「相互重叠」的流量，但口径不同，
// 故分层展示、绝不相加，避免重复计数：
//   - local：CLI 自己写的本地日志（~/.claude、~/.codex 会话日志），是「真账」。
//   - proxy：QuotaServer 代理实测日志（仅当 Claude Code / CodeX 走本机代理时才有）。

enum StatsDomain: String, CaseIterable {
    case local
    case proxy
}

// MARK: - Stats Hub
// 统一的「Token 统计」入口：顶部用分段控件在 本地日志 / 代理实测 之间切换，
// 复用既有的 CostTrackingView（本地）与 ProxyStatsView（代理）两套完整 UI。

struct StatsHubView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var proxyVM: ProxyViewModel

    @AppStorage(DefaultsKey.statsDomain) private var domainRaw: String = StatsDomain.local.rawValue

    private var domain: StatsDomain { StatsDomain(rawValue: domainRaw) ?? .local }
    private var domainBinding: Binding<StatsDomain> {
        Binding(get: { domain }, set: { domainRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch domain {
            case .local:
                CostTrackingView()
            case .proxy:
                ProxyStatsView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: domainBinding) {
                Text(L("Local Logs", "本地日志")).tag(StatsDomain.local)
                Text(L("Proxy Logs", "代理日志")).tag(StatsDomain.proxy)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Text(domain == .local
                 ? L("Tokens recorded by Claude Code / Codex themselves", "Claude Code / Codex 本地日志记录的真实用量")
                 : L("Usage recorded by the local proxy logs (do not add to local logs)", "本机代理日志记录的用量（与本地日志相互重叠，勿相加）"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

#Preview {
    StatsHubView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 980, height: 700)
}
