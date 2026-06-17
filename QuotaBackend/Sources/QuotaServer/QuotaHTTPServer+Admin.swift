import Foundation
import os.log

// MARK: - Global Proxy Admin Endpoint
// 仅在全局统一代理模式下启用（启动环境注入 GLOBAL_PROXY_ADMIN_KEY）。宿主 App 通过本端点
// 把「当前激活节点的上游」原子推给常驻代理进程，实现无重启 / 无端口变化 / 不重写 CLI 配置的热切换。
//
// 安全: 必须携带 `Authorization: Bearer <admin key>`，且 key 为本次启动随机生成、仅宿主 App 持有；
//       绑定地址恒为本机回环。仅替换上游（base_url/key/model），client key 始终沿用启动时的固定值。

extension QuotaHTTPServer {
    /// admin 热切换请求体：宿主 App 下发的「当前激活节点上游」。
    struct CodexUpstreamUpdate: Decodable {
        let nodeId: String
        let baseURL: String
        let apiKey: String
        let model: String?
        let maxOutputTokens: Int?
    }

    func handleCodexUpstreamAdmin(request: HTTPRequest, headers: [String: String]) -> HTTPResponse {
        guard let adminKey = globalProxyAdminKey, !adminKey.isEmpty else {
            // 非全局模式：不暴露该端点，对外表现为 404，避免泄露其存在。
            return jsonResponse(["error": "Not found"], status: 404, headers: headers)
        }

        guard let provided = bearerToken(from: request.headers), provided == adminKey else {
            return jsonResponse(["error": "Unauthorized"], status: 401, headers: headers)
        }

        guard let update = try? Self.requestDecoder.decode(CodexUpstreamUpdate.self, from: request.body),
              !update.baseURL.isEmpty, !update.apiKey.isEmpty else {
            return jsonResponse(["error": "Invalid upstream payload"], status: 400, headers: headers)
        }

        guard applyCodexUpstream(update) else {
            return jsonResponse(["error": "Failed to apply upstream"], status: 422, headers: headers)
        }

        httpLog.info("Global proxy hot-swapped Codex upstream → node \(update.nodeId, privacy: .public)")
        return jsonResponse(["ok": true, "activeNodeId": update.nodeId], headers: headers)
    }

    /// 从入站头解析 Bearer token（headers 键已小写化）。
    private func bearerToken(from requestHeaders: [String: String]) -> String? {
        guard let auth = requestHeaders["authorization"] else { return nil }
        let prefix = "Bearer "
        guard auth.hasPrefix(prefix) else { return nil }
        let token = String(auth.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
