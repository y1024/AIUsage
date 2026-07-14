import Foundation
import os.log

// MARK: - Global Proxy Track
// 全局统一代理覆盖的三条轨道。每条轨道一个常驻 QuotaServer 进程 + 一份独立持久化配置。
enum GlobalProxyTrack: String, Codable, CaseIterable {
    case codex
    case claude
    case opencode
    /// Claude Science：免订阅启动 Science（隔离沙箱 + 本地虚拟登录），推理经代理走第三方模型。
    /// 复用 Claude 轨的 Anthropic→OpenAI 转换代理（同 admin 路由），差异在于沙箱/虚拟登录生命周期。
    case science

    /// 持久化文件名（~/.config/aiusage 下）。
    var configFileName: String { "global-proxy-\(rawValue).json" }
}

// MARK: - Global Proxy Config
// 全局统一代理：给某条轨一个「固定入口」——固定端口 + 固定 client key + 固定虚拟模型名，
// CLI 一次性指向它即可。切换激活节点只在常驻代理进程内热替换上游（base_url/key/model），
// 进程不重启、端口不变、CLI 配置不重写，因此正在运行的 CLI 无感。
//
// 数据来源/写入目标: ~/.config/aiusage/global-proxy-<track>.json（含 client key，0600 权限）。
// 工作方式: isEnabled=true 时接管对应 CLI 配置（config.toml / settings.json / opencode.json）并拉起常驻代理。
//
// 模型字段语义：
//   - Codex / OpenCode：仅用 virtualModel（单一虚拟模型名）。
//   - Claude：三层模型 virtualModel(=opus) / sonnetModel / haikuModel；值需含 opus/sonnet/haiku
//     关键字，便于后端按层映射到激活节点的真实 big/middle/small 模型。

private let globalProxyLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxy")

struct GlobalProxyConfig: Codable, Equatable {
    /// 是否启用全局代理模式（启用时接管 CLI 配置、拉起常驻代理；停用时还原）。
    var isEnabled: Bool
    /// 常驻监听端口（固定，CLI 永远指向它）。
    var port: Int
    /// 对客户端固定不变的 client key。
    var clientKey: String
    /// 主虚拟模型名（Codex/OpenCode 唯一模型；Claude 的 opus 层）。
    var virtualModel: String
    /// Claude sonnet 层虚拟模型名（仅 Claude 轨使用）。
    var sonnetModel: String?
    /// Claude haiku 层虚拟模型名（仅 Claude 轨使用）。
    var haikuModel: String?
    /// OpenCode 轨选定的接口协议（仅 OpenCode 轨使用）。决定 CLI 受管块的 npm 包、后端复用的透传轨道、
    /// 以及可参与切换的节点集合（只能切同接口节点，保证格式兼容）。旧档案缺省为 OpenAI 兼容。
    var openCodeInterface: OpenCodeProtocol?
    /// 当前激活的参与节点 id；nil 表示未选定。
    var activeNodeId: String?
    /// Science 沙箱监听端口（仅 Science 轨；即 `claude-science serve --port`）。缺省 14410（AIUsage 端口族）。
    var sciencePort: Int? = nil
    /// Science 沙箱假账号邮箱（仅 Science 轨；必须以 .invalid 保留顶级域结尾，保证不可路由）。缺省 aiusage@cslocal.invalid。
    var sandboxEmail: String? = nil
    /// 接管真实实例（仅 Science 轨）：内部 daemon 跑在独立 data-dir、由 8765 反向代理注入会话，
    /// 使双击桌面 app 也免登录。**不触碰真实 ~/.claude-science 凭证**，仅改写运行期 operon.lock（停用即删）。
    /// 缺省 false（安全默认，只做隔离沙箱）。
    var adoptRealInstance: Bool? = nil
    /// 是否允许局域网访问（监听 0.0.0.0 而非 127.0.0.1）。缺省 false（安全默认，仅本机可用）。
    var allowLAN: Bool? = nil

    // MARK: Defaults

    // 全局代理端口提到 1 万段（避开常用低端口、降低与其他本地服务冲突概率）。
    static let defaultCodexPort = 14399
    static let defaultClaudePort = 14400
    static let defaultOpenCodePort = 14401
    // Science 轨端口全部落在 AIUsage 自有的 144xx 端口族（区别于其它同类工具，避免撞常用端口）：
    // 代理端口 14402、沙箱公开入口 14410、接管内部 daemon 14411、沙箱内部 daemon 14412；
    // 对外唯一例外是 8765（桌面 app 硬编码默认端口）。
    static let defaultSciencePort = 14402
    static let defaultScienceListenPort = 14410
    /// 默认沙箱的内部 daemon 端口。浏览器只访问 `defaultScienceListenPort`，
    /// `ScienceAuthProxy` 在二者之间反代并提供即时模型目录。
    static let defaultScienceSandboxInternalPort = 14412
    // 假账号邮箱缺省值：以 `.invalid`（RFC 2606 保留顶级域，永不可解析）保证是不可路由假账号，带 AIUsage 标识。
    static let defaultSandboxEmail = "aiusage@cslocal.invalid"
    // 接管真实实例模式下 Science 对外固定端口（= 桌面 app 默认端口）：由本地反向代理（ScienceAuthProxy）占用，
    // 负责给每个请求注入 operon 会话 cookie，使双击桌面 app / 浏览器打开 8765 都免登录。
    static let realInstancePort = 8765
    // 接管模式下内部 Claude Science daemon 的监听端口（反代把 8765 的流量转发到这里）。
    static let realInstanceInternalPort = 14411
    // 虚拟模型名仅作 CLI 固定入口名，可任意取——会被代理改写为激活节点真实上游模型，故取通用短名。
    static let defaultVirtualModel = "gpt"
    // Claude 三层名需含 opus/sonnet/haiku 关键字（后端据此映射到节点 big/middle/small），裸关键字即可。
    static let defaultClaudeOpus = "opus"
    static let defaultClaudeSonnet = "sonnet"
    static let defaultClaudeHaiku = "haiku"
    static let defaultOpenCodeModel = "LLM"

    private static func freshClientKey() -> String {
        "aiusage-global-\(UUID().uuidString.prefix(8))"
    }

    static func makeDefault(track: GlobalProxyTrack) -> GlobalProxyConfig {
        switch track {
        case .codex:
            return GlobalProxyConfig(
                isEnabled: false, port: defaultCodexPort, clientKey: freshClientKey(),
                virtualModel: defaultVirtualModel, sonnetModel: nil, haikuModel: nil,
                openCodeInterface: nil, activeNodeId: nil
            )
        case .claude:
            return GlobalProxyConfig(
                isEnabled: false, port: defaultClaudePort, clientKey: freshClientKey(),
                virtualModel: defaultClaudeOpus, sonnetModel: defaultClaudeSonnet,
                haikuModel: defaultClaudeHaiku, openCodeInterface: nil, activeNodeId: nil
            )
        case .opencode:
            return GlobalProxyConfig(
                isEnabled: false, port: defaultOpenCodePort, clientKey: freshClientKey(),
                virtualModel: defaultOpenCodeModel, sonnetModel: nil, haikuModel: nil,
                openCodeInterface: .openAICompatible, activeNodeId: nil
            )
        case .science:
            return GlobalProxyConfig(
                isEnabled: false, port: defaultSciencePort, clientKey: freshClientKey(),
                virtualModel: defaultClaudeOpus, sonnetModel: defaultClaudeSonnet,
                haikuModel: defaultClaudeHaiku, openCodeInterface: nil, activeNodeId: nil,
                sciencePort: defaultScienceListenPort, sandboxEmail: defaultSandboxEmail
            )
        }
    }

    // MARK: Derived

    /// client key 兜底：空则用稳定占位，避免 admin/CLI 鉴权两端空值不一致。
    var effectiveClientKey: String {
        let trimmed = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "aiusage-global-key" : trimmed
    }

    /// 含 /v1 的本地地址（Codex 在其后拼 /responses）。
    var codexBaseURL: String { "http://127.0.0.1:\(port)/v1" }
    /// 不含 /v1 的本地地址（Claude Code 自行拼 /v1/messages）。
    var localBaseURL: String { "http://127.0.0.1:\(port)" }

    /// Claude 三层虚拟模型（缺省回退到默认值）。
    var claudeOpus: String { virtualModel.nilIfBlank ?? Self.defaultClaudeOpus }
    var claudeSonnet: String { (sonnetModel?.nilIfBlank) ?? Self.defaultClaudeSonnet }
    var claudeHaiku: String { (haikuModel?.nilIfBlank) ?? Self.defaultClaudeHaiku }

    /// OpenCode 选定接口（缺省回退到 OpenAI 兼容）。
    var effectiveOpenCodeInterface: OpenCodeProtocol { openCodeInterface ?? .openAICompatible }

    /// 不含 /v1 的本地地址（Anthropic 接口的 OpenCode 上游需要根地址 + /v1/messages）。
    var rootBaseURL: String { "http://127.0.0.1:\(port)" }

    /// Science 沙箱监听端口（缺省 14410；绝不占用真实实例保留端口 8765）。
    var effectiveSciencePort: Int {
        let p = sciencePort ?? Self.defaultScienceListenPort
        return p == 8765 ? Self.defaultScienceListenPort : p
    }
    /// Science 沙箱假账号邮箱（缺省 aiusage@cslocal.invalid）。
    var effectiveSandboxEmail: String { (sandboxEmail?.nilIfBlank) ?? Self.defaultSandboxEmail }

    /// 是否接管真实实例（缺省 false）。
    var effectiveAdoptReal: Bool { adoptRealInstance ?? false }

    /// 是否允许局域网访问（缺省 false）。
    var effectiveAllowLAN: Bool { allowLAN ?? false }

    /// QuotaServer 绑定地址：开启局域网时监听 0.0.0.0，否则仅本机 127.0.0.1。
    var bindAddress: String { effectiveAllowLAN ? "0.0.0.0" : "127.0.0.1" }

    /// UI 展示用绑定主机名（与 bindAddress 一致）。
    var displayBindHost: String { bindAddress }

    /// 当前 Science 实际监听端口：接管真实实例走 8765，否则走沙箱端口。
    var effectiveScienceListenPort: Int {
        effectiveAdoptReal ? Self.realInstancePort : effectiveSciencePort
    }
}

// MARK: - Persistence

/// GlobalProxyConfig 的按轨文件持久化（与 OpenCodeNodeStore 等一致：~/.config/aiusage 下 0600 JSON）。
enum GlobalProxyStore {
    private static func configPath(track: GlobalProxyTrack) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/\(track.configFileName)")
    }

    static func load(track: GlobalProxyTrack) -> GlobalProxyConfig {
        let path = configPath(track: track)
        guard let data = FileManager.default.contents(atPath: path) else {
            return .makeDefault(track: track)
        }
        do {
            return try JSONDecoder().decode(GlobalProxyConfig.self, from: data)
        } catch {
            globalProxyLog.error("Failed to decode global proxy config (\(track.rawValue, privacy: .public)), using default: \(String(describing: error), privacy: .public)")
            return .makeDefault(track: track)
        }
    }

    static func save(_ config: GlobalProxyConfig, track: GlobalProxyTrack) {
        let path = configPath(track: track)
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            globalProxyLog.error("Failed to persist global proxy config (\(track.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }
}
