import SwiftUI

// MARK: - OpenCode Request Log Section
// OpenCode 代理模式的实时请求日志区块（嵌在 OpenCodeManagementView 底部）。
// 数据来自 OpenCodeProxyRuntime 内存环形缓冲（最多 200 条，不落盘）；
// 仅观测展示：不估算费用，避免与 opencode.db 的用量统计双重计账。

struct OpenCodeRequestLogSection: View {
    @ObservedObject private var runtime = OpenCodeProxyRuntime.shared

    private static let brand = OpenCodeManagementView.brand

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if runtime.requestLogs.isEmpty {
                emptyState
            } else {
                logList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13))
                .foregroundStyle(Self.brand)
            Text(L("Request Logs", "请求日志"))
                .font(.headline)
            Text("\(runtime.requestLogs.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))

            Spacer()

            if !runtime.requestLogs.isEmpty {
                Button {
                    runtime.clearLogs()
                } label: {
                    Label(L("Clear", "清空"), systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text(L(
                    "No requests yet. Logs appear in real time once OpenCode sends traffic through the proxy.",
                    "暂无请求。OpenCode 经代理发出流量后，这里会实时展示日志。"
                ))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            }
            .padding(.vertical, 22)
            Spacer()
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    // MARK: - Log List

    private var logList: some View {
        VStack(spacing: 0) {
            ForEach(Array(runtime.requestLogs.enumerated()), id: \.element.id) { index, log in
                logRow(log)
                if index < runtime.requestLogs.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func logRow(_ log: ProxyRequestLog) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(log.success ? Color.green : Color.red)

                Text(Self.timeFormatter.string(from: log.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(log.claudeModel)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if log.tokensInput > 0 || log.tokensOutput > 0 {
                    Text("\(log.tokensInput)→\(log.tokensOutput)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(L(
                            "Input → output tokens (cache read: \(log.tokensCacheRead))",
                            "输入 → 输出 token（缓存读取：\(log.tokensCacheRead)）"
                        ))
                }

                Text(formatDuration(log.responseTimeMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                if let statusCode = log.statusCode, !log.success {
                    Text("\(statusCode)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.red)
                }
            }

            if let errorMessage = log.errorMessage, !log.success {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        if milliseconds >= 1000 {
            return String(format: "%.1fs", milliseconds / 1000)
        }
        return "\(Int(milliseconds))ms"
    }
}

#Preview {
    OpenCodeRequestLogSection()
        .padding(20)
        .frame(width: 700)
}
