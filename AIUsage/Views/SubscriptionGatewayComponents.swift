import AppKit
import Combine
import SwiftUI

enum CLIProxyGatewaySection: String, CaseIterable, Identifiable {
    case overview
    case accounts
    case connections
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L("Overview", "概览")
        case .accounts: L("Accounts", "账号")
        case .connections: L("Connections", "接入应用")
        case .settings: L("Settings & Maintenance", "设置与维护")
        }
    }

    var shortTitle: String {
        switch self {
        case .overview: L("Overview", "概览")
        case .accounts: L("Accounts", "账号")
        case .connections: L("Connections", "接入")
        case .settings: L("Gateway Settings", "设置")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .accounts: "person.2.fill"
        case .connections: "arrow.triangle.branch"
        case .settings: "gearshape.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .overview: Color(red: 0.28, green: 0.50, blue: 0.96)
        case .accounts: Color(red: 0.42, green: 0.36, blue: 0.90)
        case .connections: Color(red: 0.12, green: 0.62, blue: 0.58)
        case .settings: Color(red: 0.45, green: 0.50, blue: 0.58)
        }
    }
}

@MainActor
final class CLIProxyGatewayNavigation: ObservableObject {
    static let shared = CLIProxyGatewayNavigation()
    @Published var selectedSection: CLIProxyGatewaySection = .overview
    @Published var addAccountRequest = 0

    func showAccounts(openAddAccount: Bool = false) {
        selectedSection = .accounts
        if openAddAccount { addAccountRequest += 1 }
    }
}

struct GatewayCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder let content: Content

    init(padding: CGFloat = 22, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct GatewaySectionTitle: View {
    let title: String
    let subtitle: String
    var actionTitle: String?
    var actionSystemImage: String = "plus"
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSystemImage)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }
}

struct GatewayStatusPill: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.11), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

struct GatewayMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

struct GatewayProviderIcon: View {
    let providerID: String
    var size: CGFloat = 38

    var body: some View {
        ProviderIconView(normalizedProviderID, size: size * 0.68)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    private var normalizedProviderID: String {
        switch providerID.lowercased() {
        case "anthropic", "claude-code": "claude"
        case "chatgpt": "openai"
        case "gemini-cli", "aistudio": "gemini"
        case "github-copilot": "copilot"
        default: providerID.lowercased()
        }
    }
}

struct GatewayErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(13)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.18)))
    }
}

struct GatewayCopyField: View {
    let label: String
    let value: String
    var masked = false
    var wraps = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Group {
                    if masked {
                        Text(maskedValue)
                    } else {
                        Text(value).textSelection(.enabled)
                    }
                }
                .font(.callout.monospaced())
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: false, vertical: wraps)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                    if masked {
                        let copiedSecret = value
                        Task {
                            try? await Task.sleep(for: .seconds(60))
                            guard NSPasteboard.general.string(forType: .string) == copiedSecret else { return }
                            NSPasteboard.general.clearContents()
                        }
                    }
                } label: {
                    Label(copied ? L("Copied", "已复制") : L("Copy", "复制"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L("Copy to clipboard", "复制到剪贴板"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var maskedValue: String {
        guard value.count > 8 else { return "••••••••" }
        return "••••••••••••" + value.suffix(4)
    }
}

extension CLIProxyOAuthProvider {
    var gatewayDisplayName: String {
        switch self {
        case .codex: "Codex"
        case .anthropic: "Claude"
        case .antigravity: "Antigravity"
        case .kimi: "Kimi"
        case .xai: "xAI"
        }
    }

    var gatewayProviderID: String {
        switch self {
        case .anthropic: "claude"
        default: rawValue
        }
    }

    var gatewaySubtitle: String {
        switch self {
        case .codex: L("ChatGPT / Codex subscription", "ChatGPT / Codex 订阅")
        case .anthropic: L("Claude Pro / Max subscription", "Claude Pro / Max 订阅")
        case .antigravity: L("Google Antigravity account", "Google Antigravity 账号")
        case .kimi: L("Kimi account via device sign-in", "通过设备登录连接 Kimi")
        case .xai: L("Grok account via device sign-in", "通过设备登录连接 Grok")
        }
    }
}

extension CLIProxyAuthFile {
    var gatewayProviderID: String {
        let value = (provider ?? type ?? "unknown").lowercased()
        switch value {
        case "anthropic": return "claude"
        default: return value
        }
    }

    var gatewaySourceTitle: String {
        if name.hasPrefix("aiusage-") { return L("Synced from AIUsage", "来自 AIUsage 的同步副本") }
        if runtimeOnly { return L("Runtime provider", "运行时提供商") }
        if source?.lowercased().contains("plugin") == true { return L("CPA plugin", "CPA 插件") }
        if source?.lowercased().contains("config") == true { return L("API key configuration", "API Key 配置") }
        return L("CPA OAuth or imported file", "CPA OAuth 或导入文件")
    }

    /// 列表副行用的短来源词，避免把完整句子塞进紧凑行。
    var gatewaySourceShortTitle: String {
        if name.hasPrefix("aiusage-") { return "AIUsage" }
        if runtimeOnly { return L("Runtime", "运行时") }
        if source?.lowercased().contains("plugin") == true { return L("Plugin", "插件") }
        if source?.lowercased().contains("config") == true { return "API Key" }
        return "OAuth"
    }

    var gatewayNeedsAttention: Bool {
        guard !disabled else { return false }
        if unavailable { return true }
        let value = status?.lowercased() ?? ""
        return ["error", "failed", "invalid", "expired", "unavailable"].contains(value)
    }

}

func gatewayProviderDisplayName(_ providerID: String) -> String {
    switch providerID.lowercased() {
    case "codex", "openai": "Codex"
    case "anthropic", "claude": "Claude"
    case "antigravity": "Antigravity"
    case "kimi": "Kimi"
    case "xai": "xAI"
    case "gemini", "gemini-cli": "Gemini CLI"
    case "vertex": "Vertex AI"
    case "github-copilot", "copilot": "GitHub Copilot"
    case "qwen": "Qwen"
    case "iflow": "iFlow"
    default: providerID.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

func gatewayNativeIdentitySummary(_ identity: CLIProxyAccountIdentity?) -> String? {
    guard let identity else { return nil }
    switch identity.providerID.lowercased() {
    case "codex":
        var parts: [String] = []
        if let plan = identity.planDisplayName {
            parts.append(L("\(plan) plan", "\(plan) 套餐"))
        }
        if let accountID = identity.shortAccountID {
            parts.append(L("Workspace \(accountID)", "工作区 \(accountID)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    case "antigravity":
        guard let projectID = identity.shortProjectID else { return nil }
        return L("Project \(projectID)", "项目 \(projectID)")
    default:
        return identity.shortAccountID ?? identity.shortProjectID
    }
}

func gatewayAccountIdentitySubtitle(
    providerID: String,
    identity: CLIProxyAccountIdentity?
) -> String {
    let provider = gatewayProviderDisplayName(providerID)
    guard let summary = gatewayNativeIdentitySummary(identity) else { return provider }
    return "\(provider) · \(summary)"
}

extension ProxyTarget {
    var gatewayProviderID: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .openCode: "opencode"
        case .cpa: "cpa"
        }
    }

    var gatewayTitle: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .openCode: "OpenCode"
        case .cpa: "CPA"
        }
    }

    var gatewayDetail: String {
        switch self {
        case .codex: "Responses"
        case .claude: "Anthropic"
        case .openCode: "Responses"
        case .cpa: L("OpenAI-compatible upstream", "OpenAI 兼容上游")
        }
    }
}
