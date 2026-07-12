import Foundation

// MARK: - CPA Upstream Capability Matrix
// 单一事实来源：判断一个 AIUsage 订阅账号相对 CPA 网关的角色。
// 能力由已验证的适配器与 CPA 内置 OAuth 路由决定，而不是根据应用名称或
// 账号是否存在进行猜测；未知 Provider 一律视为“不能作为 CPA 上游”。

/// The role an AIUsage-monitored provider can play for the CPA gateway.
nonisolated enum CLIProxyUpstreamCapability: Equatable, Sendable {
    /// AIUsage holds a credential that a verified adapter can copy into CPA.
    case syncableFromAIUsage
    /// CPA supports this provider through its built-in OAuth, but AIUsage
    /// credentials cannot be copied; the user must authorize inside CPA.
    case requiresCPAOAuth(CLIProxyOAuthProvider)
    /// CPA supports this provider only through an official provider plugin.
    case requiresPlugin(pluginHint: String)
    /// The provider is a downstream client or monitoring-only account and can
    /// never become a CPA upstream. It must not appear as a candidate.
    case notAnUpstream
}

nonisolated enum CLIProxyCapabilityMatrix {
    /// Provider types CPA can persist as auth files. Anything outside this
    /// list (plus currently installed plugin providers) is blocked on import.
    static let importableAuthTypes: Set<String> = [
        "codex", "claude", "anthropic", "antigravity",
        "kimi", "xai", "gemini", "gemini-cli", "vertex",
        "qwen", "iflow"
    ]

    static func capability(forAIUsageProvider providerId: String) -> CLIProxyUpstreamCapability {
        switch providerId.lowercased() {
        case "codex", "antigravity":
            return .syncableFromAIUsage
        case "claude", "anthropic":
            return .requiresCPAOAuth(.anthropic)
        case "kimi":
            return .requiresCPAOAuth(.kimi)
        case "xai", "grok":
            return .requiresCPAOAuth(.xai)
        case "gemini", "gemini-cli":
            return .requiresPlugin(pluginHint: "gemini-cli")
        default:
            return .notAnUpstream
        }
    }

    static func normalizedAuthType(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return nil }
        switch normalized {
        case "chatgpt", "openai": return "codex"
        case "google-antigravity": return "antigravity"
        default: return normalized
        }
    }
}

/// A provider the user monitors in AIUsage that cannot be credential-copied,
/// but has a legitimate CPA path (independent OAuth or an official plugin).
nonisolated struct CLIProxyUpstreamAuthHint: Identifiable, Equatable, Sendable {
    let providerId: String
    let capability: CLIProxyUpstreamCapability
    let accountCount: Int

    var id: String { providerId }
}
