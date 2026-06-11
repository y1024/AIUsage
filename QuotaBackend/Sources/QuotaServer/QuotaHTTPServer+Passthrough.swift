import Foundation
import Network
import os.log
import QuotaBackend

extension QuotaHTTPServer {
    // MARK: - Anthropic Passthrough Proxy

    func handlePassthroughProxy(_ connection: NWConnection, request: HTTPRequest) async {
        guard let config = proxyConfig else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Passthrough not configured\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        if let expectedKey = config.expectedClientKey, !expectedKey.isEmpty {
            let clientKey = request.headers["x-api-key"] ?? request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
            if clientKey != expectedKey {
                let resp = claudeErrorResponse(type: "authentication_error", message: "Invalid API key", status: 401, headers: [:])
                await sendResponse(connection, response: resp)
                connection.cancel()
                return
            }
        }

        let startTime = Date()
        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let queryPart = request.path.contains("?") ? "?" + request.path.split(separator: "?").dropFirst().joined(separator: "?") : ""
        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + String(cleanPath.dropFirst()) + queryPart
            : config.upstreamBaseURL + cleanPath + queryPart

        httpLog.debug("→ PASSTHROUGH \(request.method) \(request.path, privacy: .public) → \(upstreamURL, privacy: .private)")

        guard let url = URL(string: upstreamURL) else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid upstream URL\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        var mutableBody = request.body
        var mutableHeaders = request.headers
        if let interceptor = config.interceptor {
            let _ = interceptor.intercept(
                path: cleanPath,
                headers: &mutableHeaders,
                body: &mutableBody
            )
        }

        // Parse request metadata, apply model alias mapping, and inject
        // missing thinking blocks before building the upstream request.
        var isStreaming = false
        var requestModel = "unknown"
        var upstreamModel = "unknown"
        if var json = try? JSONSerialization.jsonObject(with: mutableBody) as? [String: Any] {
            isStreaming = json["stream"] as? Bool ?? false
            requestModel = json["model"] as? String ?? "unknown"
            upstreamModel = requestModel
            var bodyModified = false

            if config.enableModelAliasMapping, requestModel != "unknown" {
                let mapped = config.mapToUpstreamModel(requestModel)
                if mapped != requestModel {
                    upstreamModel = mapped
                    json["model"] = mapped
                    bodyModified = true
                }
            }

            let hoisted = hoistSystemMessages(in: &json)
            if hoisted > 0 {
                bodyModified = true
                httpLog.debug("Hoisted \(hoisted) system message(s) from messages[] to top-level system")
            }

            if thinkingIsActive(in: json),
               let messages = json["messages"] as? [[String: Any]] {
                let result = injectMissingThinkingBlocks(messages)
                if result.injected > 0 {
                    json["messages"] = result.messages
                    bodyModified = true
                    httpLog.debug("Injected empty thinking blocks into \(result.injected) assistant message(s)")
                }
            }

            if bodyModified, let rewritten = try? JSONSerialization.data(withJSONObject: json) {
                mutableBody = rewritten
            }
        }

        var upstreamReq = URLRequest(url: url)
        upstreamReq.httpMethod = request.method
        upstreamReq.httpBody = mutableBody

        let suppressedRequestHeaders: Set<String> = [
            "host", "content-length",
            "accept-encoding",
        ]

        for (key, value) in mutableHeaders {
            let lk = key.lowercased()
            if suppressedRequestHeaders.contains(lk) { continue }
            if lk == "authorization" && !config.upstreamAPIKey.isEmpty { continue }
            upstreamReq.setValue(value, forHTTPHeaderField: key)
        }
        if !config.upstreamAPIKey.isEmpty {
            upstreamReq.setValue(config.upstreamAPIKey, forHTTPHeaderField: "x-api-key")
        }
        if mutableHeaders["content-type"] == nil {
            upstreamReq.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        if isStreaming {
            await handlePassthroughStreaming(connection, upstreamRequest: upstreamReq, requestModel: requestModel, upstreamModel: upstreamModel, startTime: startTime)
        } else {
            await handlePassthroughNonStreaming(connection, upstreamRequest: upstreamReq, requestModel: requestModel, upstreamModel: upstreamModel, startTime: startTime)
        }
    }

    private static let suppressedResponseHeaders: Set<String> = [
        "content-length", "transfer-encoding", "content-encoding",
    ]

    func handlePassthroughNonStreaming(_ connection: NWConnection, upstreamRequest: URLRequest, requestModel: String, upstreamModel: String, startTime: Date) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            var respHeaders: [String: String] = ["Content-Type": "application/json"]
            httpResp?.allHeaderFields.forEach { key, value in
                if let k = key as? String, let v = value as? String {
                    let lk = k.lowercased()
                    if !Self.suppressedResponseHeaders.contains(lk) {
                        respHeaders[k] = v
                    }
                }
            }
            respHeaders["Content-Length"] = "\(data.count)"

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let isSuccess = statusCode < 400
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            var usage = json?["usage"] as? [String: Any] ?? [:]

            if isSuccess {
                // 与流式路径一致的宽容化 + 兜底：上游漏发 usage 时用请求体字符数估算 input、
                // 用响应 content 字符数估算 output。input 兜底要先排除「全命中缓存
                // 导致 input_tokens 真值就是 0」的情况——有 cache 字段就别动 input。
                let normalizedInput = Self.coerceInt(usage["input_tokens"]) ?? 0
                let normalizedOutput = Self.coerceInt(usage["output_tokens"]) ?? 0
                let normalizedCacheRead = Self.coerceInt(usage["cache_read_input_tokens"]) ?? 0
                let normalizedCacheWrite = Self.coerceInt(usage["cache_creation_input_tokens"]) ?? 0

                if normalizedInput == 0, normalizedCacheRead == 0, normalizedCacheWrite == 0 {
                    usage["input_tokens"] = Self.estimateAnthropicInputTokens(fromRequestBody: upstreamRequest.httpBody)
                } else {
                    usage["input_tokens"] = normalizedInput
                }
                if normalizedOutput == 0 {
                    let chars = Self.estimateAnthropicOutputChars(fromResponseJSON: json)
                    usage["output_tokens"] = chars > 0 ? max(1, chars / 4) : 0
                } else {
                    usage["output_tokens"] = normalizedOutput
                }
                usage["cache_read_input_tokens"] = normalizedCacheRead
                usage["cache_creation_input_tokens"] = normalizedCacheWrite
            }

            var errorType: String?
            var errorMessage: String?
            if !isSuccess {
                if let errorObj = json?["error"] as? [String: Any] {
                    errorType = errorObj["type"] as? String
                    errorMessage = errorObj["message"] as? String
                }
                if errorType == nil {
                    errorType = passthroughErrorType(forHTTPStatus: statusCode)
                }
                if errorMessage == nil {
                    errorMessage = json?["message"] as? String ?? "HTTP \(statusCode)"
                }
            }

            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: usage,
                responseTimeMs: Int(elapsed),
                success: isSuccess,
                errorType: errorType,
                errorMessage: errorMessage,
                statusCode: !isSuccess ? statusCode : nil
            )

            let resp = HTTPResponse(status: statusCode, headers: respHeaders, bodyData: data)
            await sendResponse(connection, response: resp)
            connection.cancel()
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: [:],
                responseTimeMs: Int(elapsed),
                success: false,
                errorType: "network_error",
                errorMessage: error.localizedDescription,
                statusCode: nil
            )
            let escaped = escapeJSON("Upstream error: \(error.localizedDescription)")
            let resp = HTTPResponse(status: 502, headers: ["Content-Type": "application/json"], body: "{\"error\":\(escaped)}")
            await sendResponse(connection, response: resp)
            connection.cancel()
        }
    }

    private static let suppressedStreamingResponseHeaders: Set<String> = [
        "content-length", "transfer-encoding", "connection", "content-encoding",
    ]

    func handlePassthroughStreaming(_ connection: NWConnection, upstreamRequest: URLRequest, requestModel: String, upstreamModel: String, startTime: Date) async {
        let streamer = StreamingResponse(connection: connection)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            var respHeaders: [String: String] = [
                "Cache-Control": "no-cache",
                "Connection": "close",
            ]
            httpResp?.allHeaderFields.forEach { key, value in
                guard let k = key as? String, let v = value as? String else { return }
                let lk = k.lowercased()
                if !Self.suppressedStreamingResponseHeaders.contains(lk) {
                    respHeaders[k] = v
                }
            }
            if respHeaders["Content-Type"] == nil && respHeaders["content-type"] == nil {
                respHeaders["Content-Type"] = "text/event-stream"
            }
            await streamer.sendHeaders(status: statusCode, headers: respHeaders)

            var totalInputTokens = 0
            var totalOutputTokens = 0
            var cacheCreationTokens = 0
            var cacheReadTokens = 0
            // 兜底估算：当上游漏发 usage（Kimi Coding/Anthropic-compat 在中断或不带缓存的
            // 短回合里很常见）时，用「请求体字符数」估 input、用「累计 delta 字符数」估 output，
            // 避免明细行恒显 0/0。估算用 chars/4 的传统启发式，仅当上游真实数据缺失时才介入。
            var assistantDeltaChars = 0
            var lineBuffer = Data()

            func processUsageLine(_ line: String) {
                // W3C SSE 规范里 `data:` 后面的空格是可选的；Kimi Coding 的 Anthropic-compat
                // 端点固定发的就是 `data:{...}`（无空格），原先 hasPrefix("data: ") 直接全部丢弃，
                // 导致 passthrough 路径下 Kimi 的 usage 一次都抓不到，明细行恒显 0/0。
                // 现在统一通过定位第一个 `{` 来抠 JSON，兼容有空格 / 没空格两种格式。
                guard line.hasPrefix("data:"), let jsonStart = line.firstIndex(of: Character("{")) else {
                    return
                }
                // 廉价子串预过滤：只有可能携带 usage 或参与 output 兜底估算
                // （content_block_delta）的事件才值得做 JSON 解析；
                // ping / content_block_start / message_stop 等高频帧直接跳过。
                guard line.contains("\"usage\"") || line.contains("content_block_delta") else {
                    return
                }
                let jsonStr = String(line[jsonStart...])
                guard let eventData = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any] else {
                    return
                }

                // 累计输出 delta（content_block_delta.delta.{text|partial_json|thinking}），
                // 用作上游漏发 message_delta.usage 时的 output 兜底估算。
                if let type = eventData["type"] as? String, type == "content_block_delta",
                   let delta = eventData["delta"] as? [String: Any] {
                    if let text = delta["text"] as? String { assistantDeltaChars += text.count }
                    if let partial = delta["partial_json"] as? String { assistantDeltaChars += partial.count }
                    if let thinking = delta["thinking"] as? String { assistantDeltaChars += thinking.count }
                }

                let usage: [String: Any]
                if let u = eventData["usage"] as? [String: Any] {
                    usage = u
                } else if let message = eventData["message"] as? [String: Any],
                          let u = message["usage"] as? [String: Any] {
                    usage = u
                } else {
                    return
                }

                if let v = Self.coerceInt(usage["input_tokens"]), v > 0 { totalInputTokens = v }
                if let v = Self.coerceInt(usage["output_tokens"]), v > 0 { totalOutputTokens = v }
                if let v = Self.coerceInt(usage["cache_creation_input_tokens"]), v > 0 { cacheCreationTokens = v }
                if let v = Self.coerceInt(usage["cache_read_input_tokens"]), v > 0 { cacheReadTokens = v }
            }

            for try await byte in bytes {
                lineBuffer.append(byte)

                if byte == 0x0A {
                    var trimmed = lineBuffer
                    if trimmed.last == 0x0A { trimmed.removeLast() }
                    if trimmed.last == 0x0D { trimmed.removeLast() }
                    let line = String(decoding: trimmed, as: UTF8.self)
                    processUsageLine(line)

                    await streamer.sendDataChunk(lineBuffer)
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            }

            if !lineBuffer.isEmpty {
                let trailingLine = String(decoding: lineBuffer, as: UTF8.self)
                processUsageLine(trailingLine)
                await streamer.sendDataChunk(lineBuffer)
            }

            // 上游真没给就用估算补上，至少让明细行不再恒 0/0。
            // - input：只有在「连 cache 字段都没拿到」时才估算，否则可能是「全命中缓存
            //   导致 input_tokens 真值就是 0」（Anthropic 语义），不能被估算覆盖成几 K。
            // - output：上游没给且本地累计的 content delta 也为空时才填 0；
            //   只要有 delta 文本就用 chars/4 当下界。
            if totalInputTokens == 0, cacheReadTokens == 0, cacheCreationTokens == 0 {
                totalInputTokens = Self.estimateAnthropicInputTokens(fromRequestBody: upstreamRequest.httpBody)
            }
            if totalOutputTokens == 0, assistantDeltaChars > 0 {
                totalOutputTokens = max(1, assistantDeltaChars / 4)
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let isSuccess = statusCode < 400
            let usageDict: [String: Any] = [
                "input_tokens": totalInputTokens,
                "output_tokens": totalOutputTokens,
                "cache_creation_input_tokens": cacheCreationTokens,
                "cache_read_input_tokens": cacheReadTokens
            ]
            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: usageDict,
                responseTimeMs: Int(elapsed),
                success: isSuccess,
                errorType: !isSuccess ? passthroughErrorType(forHTTPStatus: statusCode) : nil,
                errorMessage: !isSuccess ? "HTTP \(statusCode)" : nil,
                statusCode: !isSuccess ? statusCode : nil
            )

            await streamer.finish()
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            emitPassthroughLog(
                model: requestModel,
                upstreamModel: upstreamModel,
                usage: [:],
                responseTimeMs: Int(elapsed),
                success: false,
                errorType: "network_error",
                errorMessage: error.localizedDescription,
                statusCode: nil
            )
            let escaped = escapeJSON(error.localizedDescription)
            await streamer.sendChunk("event: error\ndata: {\"error\":\(escaped)}\n\n")
            await streamer.finish()
        }
    }

    func forwardPassthrough(request: HTTPRequest, path: String) async -> HTTPResponse {
        guard let config = proxyConfig else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Not configured\"}")
        }

        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + String(path.dropFirst())
            : config.upstreamBaseURL + path

        guard let url = URL(string: upstreamURL) else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid URL\"}")
        }

        var upstreamReq = URLRequest(url: url)
        upstreamReq.httpMethod = request.method
        upstreamReq.httpBody = request.body
        for (key, value) in request.headers {
            let lk = key.lowercased()
            if lk == "host" || lk == "content-length" { continue }
            if lk == "authorization" && !config.upstreamAPIKey.isEmpty { continue }
            upstreamReq.setValue(value, forHTTPHeaderField: key)
        }
        if !config.upstreamAPIKey.isEmpty {
            upstreamReq.setValue(config.upstreamAPIKey, forHTTPHeaderField: "x-api-key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: upstreamReq)
            let httpResp = response as? HTTPURLResponse
            return HTTPResponse(
                status: httpResp?.statusCode ?? 502,
                headers: ["Content-Type": "application/json"],
                bodyData: data
            )
        } catch {
            let escaped = escapeJSON(error.localizedDescription)
            return HTTPResponse(status: 502, headers: ["Content-Type": "application/json"], body: "{\"error\":\(escaped)}")
        }
    }

    func emitPassthroughLog(
        model: String,
        upstreamModel: String? = nil,
        usage: [String: Any],
        responseTimeMs: Int,
        success: Bool,
        errorType: String? = nil,
        errorMessage: String? = nil,
        statusCode: Int? = nil
    ) {
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

        var log: [String: Any] = [
            "type": "proxy_request_log",
            "claude_model": model,
            "upstream_model": upstreamModel ?? model,
            "success": success,
            "response_time_ms": responseTimeMs,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cache_creation_tokens": cacheCreation,
            "cache_read_tokens": cacheRead,
            "cache_tokens": cacheCreation + cacheRead,
        ]
        if let errorType { log["error_type"] = errorType }
        if let errorMessage { log["error"] = errorMessage }
        if let statusCode { log["status_code"] = statusCode }

        if let data = try? JSONSerialization.data(withJSONObject: log),
           let jsonStr = String(data: data, encoding: .utf8) {
            // stdout is parsed by the macOS host app for structured log ingestion
            print("PROXY_LOG:\(jsonStr)")
        }
    }

    func passthroughErrorType(forHTTPStatus statusCode: Int) -> String {
        switch statusCode {
        case 400: return "invalid_request_error"
        case 401: return "authentication_error"
        case 402: return "billing_error"
        case 403: return "permission_error"
        case 404: return "not_found_error"
        case 413: return "request_too_large"
        case 429: return "rate_limit_error"
        case 504: return "timeout_error"
        case 529: return "overloaded_error"
        case 400..<500: return "invalid_request_error"
        default: return "api_error"
        }
    }

    // MARK: - Lean System Prompt Normalization

    /// Claude Code 2.1.154+ ("Lean System Prompt Now Default") emits
    /// `role: "system"` entries inside the `messages[]` array. The Anthropic
    /// spec only allows `system` as a top-level field — strict upstreams
    /// (DeepSeek `/anthropic`, SuCloud, etc.) reject anything other than
    /// `user`/`assistant` in messages with a 400. This hoists those entries
    /// into the top-level `system` field (as text blocks, preserving
    /// `cache_control`) and removes them from `messages`. Returns the number
    /// of system messages hoisted.
    func hoistSystemMessages(in json: inout [String: Any]) -> Int {
        guard let messages = json["messages"] as? [[String: Any]] else { return 0 }

        var hoistedBlocks: [[String: Any]] = []
        var remaining: [[String: Any]] = []
        var systemCount = 0
        for message in messages {
            if (message["role"] as? String) == "system" {
                systemCount += 1
                hoistedBlocks.append(contentsOf: systemTextBlocks(from: message["content"]))
            } else {
                remaining.append(message)
            }
        }

        // Always strip system entries from messages — leaving even an empty or
        // non-text one behind still trips the strict upstream's 400.
        guard systemCount > 0 else { return 0 }

        // Only rewrite the top-level system when there is actual text to carry
        // over; normalize the existing value to text blocks and append the
        // hoisted blocks after it to preserve ordering.
        if !hoistedBlocks.isEmpty {
            var merged: [[String: Any]] = []
            if let existing = json["system"] as? String, !existing.isEmpty {
                merged.append(["type": "text", "text": existing])
            } else if let existing = json["system"] as? [[String: Any]] {
                merged.append(contentsOf: existing)
            }
            merged.append(contentsOf: hoistedBlocks)
            json["system"] = merged
        }

        json["messages"] = remaining
        return systemCount
    }

    /// Extracts Anthropic-compatible text blocks from a system message's
    /// content, which may be a plain string or an array of content blocks.
    /// Only text blocks are kept (system supports text only); `cache_control`
    /// is preserved so prompt-cache breakpoints survive the hoist.
    private func systemTextBlocks(from content: Any?) -> [[String: Any]] {
        if let text = content as? String {
            return text.isEmpty ? [] : [["type": "text", "text": text]]
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block in
                guard (block["type"] as? String) == "text" else { return nil }
                var out: [String: Any] = ["type": "text", "text": block["text"] as? String ?? ""]
                if let cacheControl = block["cache_control"] {
                    out["cache_control"] = cacheControl
                }
                return out
            }
        }
        return []
    }

    // MARK: - DeepSeek Thinking Block Injection

    /// Returns true when the request's `thinking` parameter is active
    /// (enabled / adaptive / budget-based). Disabled and absent both
    /// return false — we only inject blocks when the caller already
    /// opted into thinking mode.
    private func thinkingIsActive(in json: [String: Any]) -> Bool {
        guard let thinking = json["thinking"] as? [String: Any],
              let type = thinking["type"] as? String else {
            return false
        }
        return type != "disabled"
    }

    /// DeepSeek (and compatible gateways like SuCloud) require every
    /// assistant message that contains `tool_use` to also carry a
    /// `thinking` content block — otherwise the API returns 400.
    /// Claude Code strips thinking blocks from conversation history,
    /// so we re-inject an empty placeholder where needed.
    private func injectMissingThinkingBlocks(
        _ messages: [[String: Any]]
    ) -> (messages: [[String: Any]], injected: Int) {
        var result: [[String: Any]] = []
        var injected = 0

        for var message in messages {
            guard (message["role"] as? String) == "assistant",
                  var content = message["content"] as? [[String: Any]] else {
                result.append(message)
                continue
            }

            let hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
            let hasThinking = content.contains {
                let t = $0["type"] as? String
                return t == "thinking" || t == "redacted_thinking"
            }

            if hasToolUse && !hasThinking {
                content.insert(["type": "thinking", "thinking": ""], at: 0)
                message["content"] = content
                injected += 1
            }

            result.append(message)
        }

        return (result, injected)
    }

    // MARK: - Usage Coercion & Estimation Fallbacks

    /// 把 `Any?` 形态的 token 字段安全转回 Int。
    /// 不少「Anthropic 兼容」上游（包括 Kimi Coding 在内）会把 token 数写成
    /// 浮点或字符串，直接 `as? Int` 失败就丢字段；用一组兜底转换把这种 case 拉回来。
    static func coerceInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        if let s = value as? String, let d = Double(s) { return Int(d) }
        return nil
    }

    /// 用请求体里的 `system + messages + tools` 字符数粗估 input tokens。
    /// 仅用于上游漏发 `usage.input_tokens` 的兜底，避免明细行显示 0/0。
    /// 字符数除以 4 是经典启发式，准度有限但是个有意义的下界。
    static func estimateAnthropicInputTokens(fromRequestBody body: Data?) -> Int {
        guard let body, !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return 0
        }
        var chars = 0
        if let system = json["system"] as? String {
            chars += system.count
        } else if let systemBlocks = json["system"] as? [[String: Any]] {
            for block in systemBlocks {
                if let t = block["text"] as? String { chars += t.count }
            }
        }
        if let messages = json["messages"] as? [[String: Any]] {
            for message in messages {
                chars += countAnthropicContentChars(message["content"])
            }
        }
        if let tools = json["tools"] as? [[String: Any]] {
            for tool in tools {
                if let name = tool["name"] as? String { chars += name.count }
                if let desc = tool["description"] as? String { chars += desc.count }
                // tool input schema 经常比较大，给个估算下限免得低估太狠
                chars += 100
            }
        }
        return chars > 0 ? max(1, chars / 4) : 0
    }

    /// 非流式响应里，把 assistant content 的字符数加起来做 output 估算。
    static func estimateAnthropicOutputChars(fromResponseJSON json: [String: Any]?) -> Int {
        guard let json,
              let content = json["content"] as? [[String: Any]] else { return 0 }
        var chars = 0
        for block in content {
            if let text = block["text"] as? String { chars += text.count }
            if let thinking = block["thinking"] as? String { chars += thinking.count }
            if let input = block["input"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: input) {
                chars += data.count
            }
        }
        return chars
    }

    private static func countAnthropicContentChars(_ content: Any?) -> Int {
        if let text = content as? String { return text.count }
        guard let blocks = content as? [[String: Any]] else { return 0 }
        var chars = 0
        for block in blocks {
            if let t = block["text"] as? String { chars += t.count }
            if let c = block["content"] as? String { chars += c.count }
            if let nested = block["content"] as? [[String: Any]] {
                for inner in nested {
                    if let t = inner["text"] as? String { chars += t.count }
                }
            }
            if let input = block["input"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: input) {
                chars += data.count
            }
        }
        return chars
    }
}
