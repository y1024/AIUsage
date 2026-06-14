import SwiftUI
import QuotaBackend

// MARK: - ProxyManagementView Statistics & Recent Requests
// 选中节点展开时的统计卡片网格与最近请求列表（含错误类型徽章）。
// 拆出以控制单文件规模；供 configurationsList 内联调用（family-scoped）。

extension ProxyManagementView {

    // MARK: - Statistics Section

    func statisticsSection(for config: ProxyConfiguration) -> some View {
        let stats = viewModel.statistics[config.id] ?? .empty

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Statistics", "统计信息"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                statsCard(
                    title: L("Total Requests", "总请求"),
                    value: "\(stats.totalRequests)",
                    icon: "arrow.up.arrow.down",
                    color: .blue
                )
                statsCard(
                    title: L("Successful", "成功"),
                    value: "\(stats.successfulRequests)",
                    icon: "checkmark.circle",
                    color: .green
                )
                statsCard(
                    title: L("Failed", "失败"),
                    value: "\(stats.failedRequests)",
                    icon: "xmark.circle",
                    color: .red
                )
                statsCard(
                    title: L("Avg TTFT", "平均首字"),
                    value: stats.firstTokenSamples > 0
                        ? String(format: "%.0fms", stats.averageFirstTokenTime)
                        : "—",
                    icon: "bolt.horizontal",
                    color: .orange
                )
            }

            HStack(spacing: 12) {
                statsCard(
                    title: L("Input Tokens", "输入 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensInput)),
                    icon: "arrow.down.circle",
                    color: .purple
                )
                statsCard(
                    title: L("Output Tokens", "输出 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensOutput)),
                    icon: "arrow.up.circle",
                    color: .pink
                )
                statsCard(
                    title: L("Cache Read", "缓存读取"),
                    value: formatCompactNumber(Double(stats.totalTokensCacheRead)),
                    icon: "arrow.down.doc",
                    color: .orange
                )
                statsCard(
                    title: L("Cache Write", "缓存写入"),
                    value: formatCompactNumber(Double(stats.totalTokensCacheCreation)),
                    icon: "square.and.arrow.down",
                    color: .indigo
                )
            }

            HStack(spacing: 12) {
                let cacheEligible = stats.totalTokensInput + stats.totalTokensCacheRead + stats.totalTokensCacheCreation
                statsCard(
                    title: L("Hit Rate", "命中率"),
                    value: cacheEligible > 0 ? String(format: "%.1f%%", stats.cacheHitRate) : "—",
                    icon: "scope",
                    color: .teal
                )
                statsCard(
                    title: L("Estimated Cost", "预估费用"),
                    value: formatProxyCurrency(stats.estimatedCostUSD),
                    icon: "dollarsign.circle",
                    color: .red
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func statsCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.12)))

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.05))
        )
    }

    // MARK: - Recent Requests Section

    func recentRequestsSection(for config: ProxyConfiguration) -> some View {
        let logs = viewModel.recentLogs[config.id] ?? []

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Recent Requests", "最近请求"))
                    .font(.headline.weight(.bold))
                Spacer()
                if !logs.isEmpty {
                    Button(L("Clear", "清除")) {
                        viewModel.clearLogs(for: config.id)
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if logs.isEmpty {
                Text(L("No requests yet", "暂无请求"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 0) {
                    let displayedLogs = Array(logs.suffix(10).reversed())
                    ForEach(Array(displayedLogs.enumerated()), id: \.element.id) { index, log in
                        requestLogRow(log)
                        if index < displayedLogs.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func requestLogRow(_ log: ProxyRequestLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(log.success ? .green : .red)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(log.upstreamModel)
                        .font(.caption.weight(.semibold))
                    if log.tokensCacheRead > 0 {
                        cacheIndicator(L("Read", "读"), color: .green)
                    }
                    if log.tokensCacheCreation > 0 {
                        cacheIndicator(L("Write", "写"), color: .purple)
                    }
                    if !log.success, let errorType = log.errorType {
                        errorTypeBadge(errorType)
                    }
                }
                if log.success {
                    HStack(spacing: 6) {
                        tokenLabel("In", value: log.tokensInput, color: .blue)
                        tokenLabel("Out", value: log.tokensOutput, color: .cyan)
                        if log.tokensCacheRead > 0 {
                            tokenLabel("CR", value: log.tokensCacheRead, color: .green)
                        }
                        if log.tokensCacheCreation > 0 {
                            tokenLabel("CW", value: log.tokensCacheCreation, color: .purple)
                        }
                    }
                }
                if !log.success, let errorMsg = log.errorMessage, !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text(String(format: "%.0fms", log.responseTimeMs))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                if log.success {
                    Text(formatProxyCurrency(log.estimatedCostUSD))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                } else if let code = log.statusCode {
                    Text("HTTP \(code)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }

            Text(formatRelativeTime(log.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(log.success ? Color.clear : Color.red.opacity(0.04))
        .help(log.success ? "" : (log.errorMessage ?? ""))
    }

    private func cacheIndicator(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func tokenLabel(_ tag: String, value: Int, color: Color) -> some View {
        Text("\(tag) \(formatCompactNumber(Double(value)))")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color.opacity(0.85))
    }

    // MARK: - Error Type Display

    private func errorTypeBadge(_ type: String) -> some View {
        Text(errorTypeLabel(type))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(errorTypeColor(type))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(errorTypeColor(type).opacity(0.12)))
    }

    private func errorTypeLabel(_ type: String) -> String {
        switch type {
        case "rate_limit_error": return L("Rate Limited", "限流")
        case "authentication_error": return L("Auth Error", "认证错误")
        case "billing_error": return L("Billing", "计费错误")
        case "permission_error": return L("Permission", "权限错误")
        case "not_found_error": return L("Not Found", "未找到")
        case "request_too_large": return L("Too Large", "请求过大")
        case "timeout_error": return L("Timeout", "超时")
        case "overloaded_error": return L("Overloaded", "过载")
        case "invalid_request_error": return L("Bad Request", "请求无效")
        case "network_error": return L("Network", "网络错误")
        case "api_error": return L("API Error", "API 错误")
        default: return type
        }
    }

    private func errorTypeColor(_ type: String) -> Color {
        switch type {
        case "rate_limit_error": return .orange
        case "authentication_error": return .purple
        case "billing_error": return .red
        case "timeout_error": return .yellow
        case "overloaded_error": return .orange
        case "network_error": return .gray
        default: return .red
        }
    }
}
