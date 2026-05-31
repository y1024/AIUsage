import Foundation
import SystemConfiguration

// MARK: - System Proxy Detector
// 检测 macOS 系统级 HTTP/HTTPS/SOCKS 代理是否开启。
//
// 背景: codex(reqwest) 会读取系统代理，但忽略系统代理的「跳过列表」(即使其中已含
//       127.0.0.1/localhost)，从而把发往本地回环 (127.0.0.1:port) 的请求也丢给系统
//       代理；本地代理无法被系统代理 CONNECT，于是返回 502。开启时需提示用户设置
//       no_proxy 跳过本地回环。
// 数据来源: SCDynamicStoreCopyProxies(nil)（与「系统设置 > 网络 > 代理」一致）。

enum SystemProxyDetector {

    /// 系统代理快照（仅记录已启用的端点，用于 UI 提示）。
    struct Snapshot: Equatable {
        let httpProxy: String?
        let httpsProxy: String?
        let socksProxy: String?

        static let empty = Snapshot(httpProxy: nil, httpsProxy: nil, socksProxy: nil)

        /// 是否有任意一种系统代理处于开启状态。
        var isAnyEnabled: Bool {
            httpProxy != nil || httpsProxy != nil || socksProxy != nil
        }

        /// 简短展示串，如 "HTTP 127.0.0.1:24473"，供 UI 直接显示。
        var summary: String? {
            if let httpProxy { return "HTTP \(httpProxy)" }
            if let httpsProxy { return "HTTPS \(httpsProxy)" }
            if let socksProxy { return "SOCKS \(socksProxy)" }
            return nil
        }
    }

    /// 读取当前系统代理配置。
    static func current() -> Snapshot {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [CFString: Any] else {
            return .empty
        }
        return Snapshot(
            httpProxy: endpoint(
                in: proxies,
                enableKey: kSCPropNetProxiesHTTPEnable,
                hostKey: kSCPropNetProxiesHTTPProxy,
                portKey: kSCPropNetProxiesHTTPPort
            ),
            httpsProxy: endpoint(
                in: proxies,
                enableKey: kSCPropNetProxiesHTTPSEnable,
                hostKey: kSCPropNetProxiesHTTPSProxy,
                portKey: kSCPropNetProxiesHTTPSPort
            ),
            socksProxy: endpoint(
                in: proxies,
                enableKey: kSCPropNetProxiesSOCKSEnable,
                hostKey: kSCPropNetProxiesSOCKSProxy,
                portKey: kSCPropNetProxiesSOCKSPort
            )
        )
    }

    // MARK: - Internal Helpers

    /// 当对应代理开启且有主机时，返回 "host:port"（无端口则只返回 host）。
    private static func endpoint(
        in proxies: [CFString: Any],
        enableKey: CFString,
        hostKey: CFString,
        portKey: CFString
    ) -> String? {
        guard (proxies[enableKey] as? Int) == 1,
              let host = (proxies[hostKey] as? String)?.nilIfBlank else {
            return nil
        }
        if let port = proxies[portKey] as? Int, port > 0 {
            return "\(host):\(port)"
        }
        return host
    }
}
