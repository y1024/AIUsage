import SwiftUI

// MARK: - System Proxy Notice Banner
// 在「CodeX 代理」菜单顶部的轻量信息提示：检测到系统代理时，说明接入 CodeX 代理后会自动往
// ~/.codex/.env 写入 no_proxy，让 codex 跳过本地回环（系统代理会拦截本地连接并回 502）。
// 此处仅作信息说明——实际写入在节点激活时由 ProxyRuntimeService 自动完成。
//
// 自管理可见性：仅当系统代理开启且未被忽略时渲染，否则零高度。

struct SystemProxyWarningBanner: View {
    @State private var snapshot: SystemProxyDetector.Snapshot = .empty
    @State private var copied = false
    @State private var dismissed = false

    private var shouldShow: Bool {
        snapshot.isAnyEnabled && !dismissed
    }

    var body: some View {
        Group {
            if shouldShow {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: refresh)
    }

    // MARK: - Content

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L("System proxy detected — handled automatically",
                       "检测到系统代理 — 已自动处理"))
                    .font(.system(size: 13, weight: .bold))

                explanation

                actionRow
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { dismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help(L("Dismiss", "忽略"))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.blue.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
        )
    }

    private var explanation: some View {
        let detail = snapshot.summary.map { " (\($0))" } ?? ""
        return Text(L(
            "Your system proxy\(detail) would make CodeX route requests to the local proxy through it and get 502. When you connect a CodeX node, AIUsage writes no_proxy to \(CodexNoProxyFixer.displayEnvPath) so CodeX bypasses the proxy for local addresses (CodeX-only; external traffic still uses the proxy). If CodeX is already running, restart it.",
            "你的系统代理\(detail) 会让 CodeX 把发往本地代理的请求误走系统代理而报 502。接入 CodeX 节点时，AIUsage 会自动往 \(CodexNoProxyFixer.displayEnvPath) 写入 no_proxy，让 CodeX 对本地地址跳过代理（仅对 CodeX 生效；访问外网仍走代理）。若 CodeX 已在运行，请重启它。"
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: copyCommand) {
                Label(
                    copied ? L("Copied", "已复制") : L("Copy no_proxy", "复制 no_proxy"),
                    systemImage: copied ? "checkmark" : "doc.on.clipboard"
                )
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    // MARK: - Actions

    private func refresh() {
        snapshot = SystemProxyDetector.current()
    }

    private func copyCommand() {
        CodexNoProxyFixer.copyCommandToClipboard()
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

#Preview {
    SystemProxyWarningBanner()
        .frame(width: 700)
}
