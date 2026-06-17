import Foundation
import os.log

// MARK: - Global Proxy Config (Codex track)
// 全局统一代理：给 Codex 轨一个「固定入口」——固定端口 + 固定 client key + 固定虚拟模型名，
// Codex CLI 一次性指向它即可。切换激活节点只在常驻代理进程内热替换上游（base_url/key/model），
// 进程不重启、端口不变、config.toml 不重写，因此正在运行的 CLI 无感。
//
// 数据来源/写入目标: ~/.config/aiusage/global-proxy-codex.json（含 client key，0600 权限）。
// 工作方式: isEnabled=true 时接管 config.toml 并拉起常驻代理；activeNodeId 指向某个 codexProxy 节点。

private let globalProxyLog = Logger(subsystem: "com.aiusage.desktop", category: "GlobalProxy")

struct GlobalProxyConfig: Codable, Equatable {
    /// 是否启用全局代理模式（启用时接管 config.toml、拉起常驻代理；停用时还原）。
    var isEnabled: Bool
    /// 常驻监听端口（固定，CLI 永远指向它）。
    var port: Int
    /// 对客户端固定不变的 client key（写入 config.toml 的 experimental_bearer_token）。
    var clientKey: String
    /// 写入 config.toml 顶层 model 的虚拟模型名（固定展示；实际请求模型由激活节点的真实模型覆盖）。
    var virtualModel: String
    /// 当前激活的参与节点 id（指向某个 codexProxy ProxyConfiguration）；nil 表示未选定。
    var activeNodeId: String?

    static let defaultPort = 4399
    static let defaultVirtualModel = "gpt-5-codex"

    static func makeDefault() -> GlobalProxyConfig {
        GlobalProxyConfig(
            isEnabled: false,
            port: defaultPort,
            clientKey: "aiusage-global-\(UUID().uuidString.prefix(8))",
            virtualModel: defaultVirtualModel,
            activeNodeId: nil
        )
    }

    /// client key 兜底：空则用稳定占位，避免 admin/CLI 鉴权两端空值不一致。
    var effectiveClientKey: String {
        let trimmed = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "aiusage-global-key" : trimmed
    }

    /// 写入 config.toml 的 base_url（含 /v1，Codex 在其后拼 /responses）。
    var cliBaseURL: String {
        "http://127.0.0.1:\(port)/v1"
    }
}

// MARK: - Persistence

/// GlobalProxyConfig 的文件持久化（与 OpenCodeNodeStore 等一致：~/.config/aiusage 下 0600 JSON）。
enum GlobalProxyStore {
    private static var configPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/aiusage/global-proxy-codex.json")
    }

    static func load() -> GlobalProxyConfig {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            return .makeDefault()
        }
        do {
            return try JSONDecoder().decode(GlobalProxyConfig.self, from: data)
        } catch {
            globalProxyLog.error("Failed to decode global proxy config, using default: \(String(describing: error), privacy: .public)")
            return .makeDefault()
        }
    }

    static func save(_ config: GlobalProxyConfig) {
        let path = configPath
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            globalProxyLog.error("Failed to persist global proxy config: \(String(describing: error), privacy: .public)")
        }
    }
}
