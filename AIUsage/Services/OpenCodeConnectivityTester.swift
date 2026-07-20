import Foundation
import QuotaBackend

// MARK: - OpenCode Connectivity Tester
// OpenCode 节点的连通性探测：按协议向上游发送一条最小化（1 token）请求，
// 返回与 Claude/Codex 节点同构的 ProxyConnectivityTestState（状态码/耗时/明细报文）。
// 管理页卡片与节点编辑器共用，避免两处维护协议分支。

enum OpenCodeConnectivityTester {

    /// 执行一次连通性测试。要求节点已填 baseURL 且模型列表非空。
    static func test(node: OpenCodeNode) async -> ProxyConnectivityTestState {
        guard let model = node.effectiveDefaultModel,
              let url = endpointURL(baseURL: node.baseURL, protocolType: node.protocolType) else {
            return ProxyConnectivityTestState(
                isTesting: false,
                lastSucceeded: false,
                message: AppSettings.shared.t(
                    "Fill in the base URL and at least one model first.",
                    "请先填写 Base URL 和至少一个模型。"
                ),
                statusCode: nil,
                latencyMs: nil,
                testedAt: Date()
            )
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !node.apiKey.isEmpty {
            if node.protocolType == .anthropic {
                request.setValue(node.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(node.apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: testBody(model: model, protocolType: node.protocolType)
        )

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            if let statusCode, (200..<300).contains(statusCode) {
                return ProxyConnectivityTestState(
                    isTesting: false,
                    lastSucceeded: true,
                    message: nil,
                    statusCode: statusCode,
                    latencyMs: elapsed,
                    testedAt: Date()
                )
            }
            let bodyText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ProxyConnectivityTestState(
                isTesting: false,
                lastSucceeded: false,
                message: String(bodyText.prefix(1500)),
                statusCode: statusCode,
                latencyMs: elapsed,
                testedAt: Date()
            )
        } catch {
            return ProxyConnectivityTestState(
                isTesting: false,
                lastSucceeded: false,
                message: SensitiveDataRedactor.redactedMessage(for: error),
                statusCode: nil,
                latencyMs: nil,
                testedAt: Date()
            )
        }
    }

    /// 测试端点：base 末尾已含 /v1 则直接拼协议路径，否则补 /v1（与 OpenCode SDK 拼接语义一致）。
    static func endpointURL(baseURL: String, protocolType: OpenCodeProtocol) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.lowercased().hasSuffix("/v1")
            ? protocolType.requestPath
            : "/v1" + protocolType.requestPath
        return URL(string: trimmed + path)
    }

    /// 各协议最小可行的 1-token 探测请求体。
    static func testBody(model: String, protocolType: OpenCodeProtocol) -> [String: Any] {
        switch protocolType {
        case .openAICompatible:
            return [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
                "stream": false,
            ]
        case .anthropic:
            return [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
            ]
        case .openAIResponses:
            // Responses API 要求 max_output_tokens ≥ 16。
            return [
                "model": model,
                "input": "ping",
                "max_output_tokens": 16,
                "stream": false,
            ]
        }
    }
}
