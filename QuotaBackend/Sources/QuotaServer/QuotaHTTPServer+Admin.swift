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

    /// Claude 轨热切换请求体：宿主 App 下发的「当前激活节点上游」（含模式与三模型映射）。
    struct ClaudeUpstreamUpdate: Decodable {
        let nodeId: String
        /// "passthrough"（Anthropic 透传）或 "convert"（OpenAI 兼容转换，默认）。
        let mode: String
        let baseURL: String
        let apiKey: String
        /// convert 模式上游 API："chat_completions" / "responses"。
        let apiMode: String?
        let bigModel: String
        let middleModel: String
        let smallModel: String
        let maxOutputTokens: Int?
        let enableModelAliasMapping: Bool?
        /// Science-only active node catalog. Optional keeps older app payloads
        /// and the normal Claude Code hot-switch contract compatible.
        let availableModels: [String]?
        let defaultModel: String?
        /// "science" or "desktop". Desktop requires Anthropic role-shaped
        /// route IDs even when the real upstream is Gemini/GPT/GLM.
        let catalogRouteStyle: String?
        /// Desktop hot-switch mode maps its three stable route IDs through the
        /// current node tiers. Full-catalog mode keeps exact upstream identity.
        let mapDesktopTierRoutes: Bool?
        /// Real upstream IDs whose catalog entries should offer a 1M variant.
        let catalogSupports1M: [String]?
        /// passthrough 模式下无条件改写入站 model 为该真实模型（OpenCode anthropic 接口用）。
        let forcedModel: String?
    }

    func handleClaudeUpstreamAdmin(request: HTTPRequest, headers: [String: String]) -> HTTPResponse {
        guard let adminKey = globalProxyAdminKey, !adminKey.isEmpty else {
            return jsonResponse(["error": "Not found"], status: 404, headers: headers)
        }

        guard let provided = bearerToken(from: request.headers), provided == adminKey else {
            return jsonResponse(["error": "Unauthorized"], status: 401, headers: headers)
        }

        guard let update = try? Self.requestDecoder.decode(ClaudeUpstreamUpdate.self, from: request.body),
              !update.baseURL.isEmpty, !update.apiKey.isEmpty else {
            return jsonResponse(["error": "Invalid upstream payload"], status: 400, headers: headers)
        }

        guard applyClaudeUpstream(update) else {
            return jsonResponse(["error": "Failed to apply upstream"], status: 422, headers: headers)
        }

        httpLog.info("Global proxy hot-swapped Claude upstream → node \(update.nodeId, privacy: .public)")
        return jsonResponse(["ok": true, "activeNodeId": update.nodeId], headers: headers)
    }

    func handleClaudeStatusAdmin(request: HTTPRequest, headers: [String: String]) -> HTTPResponse {
        guard let adminKey = globalProxyAdminKey, !adminKey.isEmpty else {
            return jsonResponse(["error": "Not found"], status: 404, headers: headers)
        }
        guard let provided = bearerToken(from: request.headers), provided == adminKey else {
            return jsonResponse(["error": "Unauthorized"], status: 401, headers: headers)
        }
        return jsonResponse([
            "ok": true,
            "activeNodeId": activeNodeId ?? "",
            "traffic": claudeTrafficSnapshot(),
        ], headers: headers)
    }

    /// OpenCode 轨（chat/completions 透传）热切换请求体：宿主 App 下发的「当前激活节点上游」。
    /// `model` 为该节点真实上游模型，CLI 端固定发虚拟模型名，由代理改写。
    struct OpenCodeUpstreamUpdate: Decodable {
        let nodeId: String
        let baseURL: String
        let apiKey: String
        let model: String?
    }

    func handleOpenCodeUpstreamAdmin(request: HTTPRequest, headers: [String: String]) -> HTTPResponse {
        guard let adminKey = globalProxyAdminKey, !adminKey.isEmpty else {
            return jsonResponse(["error": "Not found"], status: 404, headers: headers)
        }

        guard let provided = bearerToken(from: request.headers), provided == adminKey else {
            return jsonResponse(["error": "Unauthorized"], status: 401, headers: headers)
        }

        guard let update = try? Self.requestDecoder.decode(OpenCodeUpstreamUpdate.self, from: request.body),
              !update.baseURL.isEmpty else {
            return jsonResponse(["error": "Invalid upstream payload"], status: 400, headers: headers)
        }

        guard applyOpenCodeUpstream(update) else {
            return jsonResponse(["error": "Failed to apply upstream"], status: 422, headers: headers)
        }

        httpLog.info("Global proxy hot-swapped OpenCode upstream → node \(update.nodeId, privacy: .public)")
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
