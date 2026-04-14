import Foundation
import Network
import os.log
import QuotaBackend

private let httpLog = Logger(subsystem: "com.aiusage.quotaserver", category: "HTTP")

private enum QuotaHTTPServerError: LocalizedError {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid server port \(port). Use a value from 1 through 65535."
        }
    }
}

// MARK: - Lightweight HTTP Server
// Uses Network.framework (no external dependencies) to serve the same JSON API
// as the original Node.js backend.

public final class QuotaHTTPServer: @unchecked Sendable {
    let host: String
    let port: Int
    let engine = ProviderEngine()
    var proxyService: ClaudeProxyService?
    var proxyConfig: ClaudeProxyConfiguration?

    var isPassthrough: Bool { proxyConfig?.mode == .anthropicPassthrough }

    public init(host: String, port: Int, proxyConfig: ClaudeProxyConfiguration? = nil) {
        self.host = host
        self.port = port
        self.proxyConfig = proxyConfig
        if let config = proxyConfig, config.enabled, config.mode == .openaiConvert {
            self.proxyService = try? ClaudeProxyService(configuration: config)
        }
    }

    public func run() async throws {
        guard (1...65_535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw QuotaHTTPServerError.invalidPort(port)
        }
        let nwHost = NWEndpoint.Host(host)

        // Create IPv4 listener with explicit local endpoint
        let params4 = NWParameters.tcp
        params4.requiredLocalEndpoint = NWEndpoint.hostPort(host: nwHost, port: nwPort)
        let listener4 = try NWListener(using: params4)
        listener4.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }
        listener4.start(queue: .global())

        // Attempt IPv6 dual-stack (best-effort, may fail if IPv4 already covers it)
        var ipv6Active = false
        do {
            let params6 = NWParameters.tcp
            params6.requiredLocalEndpoint = NWEndpoint.hostPort(host: "::1", port: nwPort)
            let listener6 = try NWListener(using: params6)
            listener6.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.handleConnection(connection) }
            }
            listener6.stateUpdateHandler = { state in
                if case .failed(_) = state {
                    // IPv6 bind failed — IPv4 on 0.0.0.0 typically already covers dual-stack
                }
            }
            listener6.start(queue: .global())
            ipv6Active = true
        } catch {
            // Silently ignore — IPv4 on 0.0.0.0 handles most cases
        }

        httpLog.info("QuotaServer listening on \(host):\(port)\(ipv6Active ? " (IPv4 + IPv6)" : " (IPv4)")")
        httpLog.info("Endpoints:")
        httpLog.info("  GET /api/dashboard")
        httpLog.info("  GET /api/provider/:id")
        httpLog.info("  GET /api/providers")
        httpLog.info("  GET /api/health")
        httpLog.info("  GET /health")
        if proxyService != nil {
            httpLog.info("  POST /v1/messages (Claude Proxy - OpenAI Convert)")
            httpLog.info("  POST /v1/messages/count_tokens (Claude Proxy)")
        }
        if isPassthrough {
            httpLog.info("  POST /v1/messages (Anthropic Passthrough)")
        }

        // Keep alive until IPv4 listener fails
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            listener4.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    httpLog.error("Listener failed: \(error.localizedDescription)")
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global())
        guard let requestData = await receiveData(connection) else {
            connection.cancel()
            return
        }

        let request = parseHTTPRequest(requestData)
        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path

        if request.method == "POST",
           cleanPath == "/v1/messages" || cleanPath.hasPrefix("/v1/messages/") {
            if isPassthrough {
                await handlePassthroughProxy(connection, request: request)
                return
            }
            if proxyService != nil {
                let isStreaming: Bool
                if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
                    isStreaming = json["stream"] as? Bool ?? false
                } else {
                    isStreaming = false
                }
                if isStreaming {
                    await handleStreamingProxy(connection, request: request)
                    return
                }
            }
        }

        let response = await routeRequest(request)
        await sendResponse(connection, response: response)
        connection.cancel()
    }

    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let queryItems = parseQueryItems(request.path)
        let corsHeaders = [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type"
        ]

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: corsHeaders, body: "")
        }

        switch (request.method, path) {
        case ("GET", "/health"), ("GET", "/api/health"):
            let generatedAt = SharedFormatters.iso8601String(from: Date())
            return jsonResponse(
                [
                    "ok": true,
                    "generatedAt": generatedAt,
                    "status": "ok",
                    "time": generatedAt
                ],
                headers: corsHeaders
            )

        // MARK: - Claude Proxy Endpoints

        case ("POST", "/v1/messages"):
            return await handleMessagesEndpoint(request: request, headers: corsHeaders)

        case ("POST", "/v1/messages/count_tokens"):
            return await handleCountTokensEndpoint(request: request, headers: corsHeaders)

        case ("POST", "/api/event_logging/batch"):
            if isPassthrough {
                return await forwardPassthrough(request: request, path: "/api/event_logging/batch")
            }
            return await handleEventLoggingEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/api/providers"):
            let providers = ProviderRegistry.allProviders().map { ["id": $0.id, "displayName": $0.displayName, "description": $0.description] }
            return jsonResponse(providers, headers: corsHeaders)

        case ("GET", "/api/dashboard"):
            httpLog.debug("→ GET /api/dashboard")
            let ids = queryItems["ids"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let snapshot = await engine.fetchAll(ids: ids)
            return jsonResponse(encodable: snapshot, headers: corsHeaders)

        case ("GET", _) where path.hasPrefix("/api/provider/"):
            let providerId = String(path.dropFirst("/api/provider/".count))
            httpLog.debug("→ GET /api/provider/\(providerId)")
            guard let result = await engine.fetchSingle(id: providerId) else {
                return jsonResponse(["error": "Provider '\(providerId)' not found"], status: 404, headers: corsHeaders)
            }
            return jsonResponse(encodable: result, headers: corsHeaders)

        default:
            return jsonResponse(["error": "Not found"], status: 404, headers: corsHeaders)
        }
    }

    // MARK: - Claude Proxy Handlers

    private func handleEventLoggingEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        httpLog.debug("→ POST /api/event_logging/batch")

        let batchId = UUID().uuidString
        var processedCount = 0

        // Parse request body
        if let loggingRequest = try? JSONDecoder().decode(EventLoggingBatchRequest.self, from: request.body) {
            let events = loggingRequest.events ?? []
            processedCount = events.count

            // Log first 5 events
            let previewCount = min(5, events.count)
            for (index, event) in events.prefix(previewCount).enumerated() {
                let eventType = event.eventType ?? "unknown"
                httpLog.debug("  Event \(index + 1): \(eventType)")
            }

            if events.count > previewCount {
                httpLog.debug("  ... and \(events.count - previewCount) more events")
            }
        }

        // Always return success (telemetry endpoint should never fail)
        let response = EventLoggingBatchResponse(
            success: true,
            batchId: batchId,
            processedCount: processedCount,
            message: "Batch received and logged"
        )

        return jsonResponse(encodable: response, headers: headers)
    }

    private func handleMessagesEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        // Authenticate
        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        // Parse request
        guard let claudeRequest = try? JSONDecoder().decode(ClaudeMessageRequest.self, from: request.body) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse request body",
                status: 400,
                headers: headers
            )
        }

        httpLog.debug("→ POST /v1/messages (model: \(claudeRequest.model), stream: \(claudeRequest.stream ?? false))")

        let startTime = Date()
        do {
            let response = try await proxy.handleMessages(request: claudeRequest)
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                inputTokens: response.usage.inputTokens,
                outputTokens: response.usage.outputTokens,
                cacheTokens: (response.usage.cacheCreationInputTokens ?? 0) + (response.usage.cacheReadInputTokens ?? 0)
            )
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: error.localizedDescription
            )
            httpLog.error("  ✗ Proxy error: \(error.localizedDescription)")
            let errorResponse = await proxy.buildErrorResponse(error: error)
            return jsonResponse(encodable: errorResponse, status: 500, headers: headers)
        }
    }

    private func handleCountTokensEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        // Authenticate
        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        // Parse request
        guard let tokenRequest = try? JSONDecoder().decode(ClaudeTokenCountRequest.self, from: request.body) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse token count request body",
                status: 400,
                headers: headers
            )
        }

        httpLog.debug("→ POST /v1/messages/count_tokens (model: \(tokenRequest.model))")

        do {
            let response = try await proxy.handleCountTokens(request: tokenRequest)
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            let errorResponse = await proxy.buildErrorResponse(error: error)
            return jsonResponse(encodable: errorResponse, status: 500, headers: headers)
        }
    }

    // MARK: - Anthropic Passthrough Proxy

    private func handlePassthroughProxy(_ connection: NWConnection, request: HTTPRequest) async {
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
            ? config.upstreamBaseURL + cleanPath.dropFirst() + queryPart
            : config.upstreamBaseURL + cleanPath + queryPart

        httpLog.debug("→ PASSTHROUGH \(request.method) \(request.path, privacy: .public) → \(upstreamURL, privacy: .private)")

        guard let url = URL(string: upstreamURL) else {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Invalid upstream URL\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
            return
        }

        var upstreamReq = URLRequest(url: url)
        upstreamReq.httpMethod = request.method
        upstreamReq.httpBody = request.body

        for (key, value) in request.headers {
            let lk = key.lowercased()
            if lk == "host" || lk == "content-length" { continue }
            upstreamReq.setValue(value, forHTTPHeaderField: key)
        }
        if !config.upstreamAPIKey.isEmpty {
            upstreamReq.setValue(config.upstreamAPIKey, forHTTPHeaderField: "x-api-key")
        }
        upstreamReq.setValue("application/json", forHTTPHeaderField: "content-type")

        let isStreaming: Bool
        let requestModel: String
        if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            isStreaming = json["stream"] as? Bool ?? false
            requestModel = json["model"] as? String ?? "unknown"
        } else {
            isStreaming = false
            requestModel = "unknown"
        }

        if isStreaming {
            await handlePassthroughStreaming(connection, upstreamRequest: upstreamReq, requestModel: requestModel, startTime: startTime)
        } else {
            await handlePassthroughNonStreaming(connection, upstreamRequest: upstreamReq, requestModel: requestModel, startTime: startTime)
        }
    }

    private func handlePassthroughNonStreaming(_ connection: NWConnection, upstreamRequest: URLRequest, requestModel: String, startTime: Date) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            let responseStr = String(data: data, encoding: .utf8) ?? ""
            var respHeaders: [String: String] = ["Content-Type": "application/json"]
            httpResp?.allHeaderFields.forEach { key, value in
                if let k = key as? String, let v = value as? String {
                    let lk = k.lowercased()
                    if lk != "content-length" && lk != "transfer-encoding" {
                        respHeaders[k] = v
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let usage = json["usage"] as? [String: Any] {
                emitPassthroughLog(model: requestModel, usage: usage, responseTimeMs: Int(elapsed), success: statusCode < 400)
            }

            let resp = HTTPResponse(status: statusCode, headers: respHeaders, body: responseStr)
            await sendResponse(connection, response: resp)
            connection.cancel()
        } catch {
            let resp = HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Upstream error: \(error.localizedDescription)\"}")
            await sendResponse(connection, response: resp)
            connection.cancel()
        }
    }

    private func handlePassthroughStreaming(_ connection: NWConnection, upstreamRequest: URLRequest, requestModel: String, startTime: Date) async {
        let streamer = StreamingResponse(connection: connection)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: upstreamRequest)
            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 502

            await streamer.sendHeaders(status: statusCode, headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive"
            ])

            var totalInputTokens = 0
            var totalOutputTokens = 0
            var cacheCreationTokens = 0
            var cacheReadTokens = 0

            for try await line in bytes.lines {
                await streamer.sendChunk(line + "\n")

                if line.hasPrefix("data: "), let jsonStart = line.firstIndex(of: Character("{")) {
                    let jsonStr = String(line[jsonStart...])
                    if let eventData = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any] {
                        if let usage = eventData["usage"] as? [String: Any] {
                            if let v = usage["input_tokens"] as? Int { totalInputTokens = v }
                            if let v = usage["output_tokens"] as? Int { totalOutputTokens = v }
                            if let v = usage["cache_creation_input_tokens"] as? Int { cacheCreationTokens = v }
                            if let v = usage["cache_read_input_tokens"] as? Int { cacheReadTokens = v }
                        }
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let usageDict: [String: Any] = [
                "input_tokens": totalInputTokens,
                "output_tokens": totalOutputTokens,
                "cache_creation_input_tokens": cacheCreationTokens,
                "cache_read_input_tokens": cacheReadTokens
            ]
            emitPassthroughLog(model: requestModel, usage: usageDict, responseTimeMs: Int(elapsed), success: statusCode < 400)

            streamer.close()
        } catch {
            await streamer.sendChunk("event: error\ndata: {\"error\":\"\(error.localizedDescription)\"}\n\n")
            streamer.close()
        }
    }

    private func forwardPassthrough(request: HTTPRequest, path: String) async -> HTTPResponse {
        guard let config = proxyConfig else {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"Not configured\"}")
        }

        let upstreamURL = config.upstreamBaseURL.hasSuffix("/")
            ? config.upstreamBaseURL + path.dropFirst()
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
                body: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return HTTPResponse(status: 502, headers: [:], body: "{\"error\":\"\(error.localizedDescription)\"}")
        }
    }

    private func emitPassthroughLog(model: String, usage: [String: Any], responseTimeMs: Int, success: Bool) {
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheTokens = cacheCreation + cacheRead

        let log: [String: Any] = [
            "type": "proxy_request_log",
            "claude_model": model,
            "upstream_model": model,
            "success": success,
            "response_time_ms": responseTimeMs,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "cache_tokens": cacheTokens,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: log),
           let jsonStr = String(data: data, encoding: .utf8) {
            print("PROXY_LOG:\(jsonStr)")
        }
    }

    private func handleStreamingProxy(_ connection: NWConnection, request: HTTPRequest) async {
        guard let proxy = proxyService else {
            let response = claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        // Authenticate
        guard await proxy.authenticate(headers: request.headers) else {
            let response = claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        // Parse request
        guard let claudeRequest = try? JSONDecoder().decode(ClaudeMessageRequest.self, from: request.body) else {
            let response = claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse request body",
                status: 400,
                headers: [:]
            )
            await sendResponse(connection, response: response)
            connection.cancel()
            return
        }

        httpLog.debug("→ POST /v1/messages (streaming, model: \(claudeRequest.model))")

        let streamStartTime = Date()
        let streamer = StreamingResponse(connection: connection)

        // Send SSE headers
        await streamer.sendHeaders(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*"
        ])

        do {
            // Map model
            let upstreamModel = await proxy.mapModel(claudeRequest.model)

            // Convert request
            let converter = ClaudeToOpenAIConverter()
            let openAIRequest = try converter.convert(
                request: claudeRequest,
                upstreamModel: upstreamModel
            )

            // Get upstream client and send streaming request
            let (bytes, _) = try await proxy.sendStreamingRequest(openAIRequest: openAIRequest)

            let encoder = JSONEncoder()

            // Send message_start event
            let messageStart = ClaudeMessageStartEvent(
                message: ClaudeMessageStart(
                    id: "msg_\(UUID().uuidString.prefix(24))",
                    type: "message",
                    role: "assistant",
                    model: claudeRequest.model
                )
            )
            if let data = try? encoder.encode(messageStart),
               let json = String(data: data, encoding: .utf8) {
                await streamer.sendSSEEvent(event: "message_start", data: json)
            }

            // Send content_block_start for text
            let blockStart = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
            await streamer.sendSSEEvent(event: "content_block_start", data: blockStart)

            // Process upstream SSE chunks
            var currentLine = ""
            var outputTokens = 0
            var stopReason = "end_turn"

            for try await byte in bytes {
                let char = Character(UnicodeScalar(byte))
                if char == "\n" {
                    if currentLine.hasPrefix("data: ") {
                        let dataStr = String(currentLine.dropFirst(6))
                        if dataStr.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                            break
                        }

                        // Parse OpenAI chunk
                        if let chunkData = dataStr.data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: chunkData),
                           let choice = chunk.choices.first {

                            // Handle text content delta
                            if let content = choice.delta.content, !content.isEmpty {
                                outputTokens += content.count / 4
                                let delta = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(escapeJSON(content))}}"
                                await streamer.sendSSEEvent(event: "content_block_delta", data: delta)
                            }

                            // Handle tool calls
                            if let toolCalls = choice.delta.toolCalls {
                                for toolCall in toolCalls {
                                    if let id = toolCall.id, let name = toolCall.function?.name {
                                        stopReason = "tool_use"
                                        let toolStart = "{\"type\":\"content_block_start\",\"index\":\(toolCall.index),\"content_block\":{\"type\":\"tool_use\",\"id\":\(escapeJSON(id)),\"name\":\(escapeJSON(name)),\"input\":{}}}"
                                        await streamer.sendSSEEvent(event: "content_block_start", data: toolStart)
                                    }
                                    if let args = toolCall.function?.arguments, !args.isEmpty {
                                        let toolDelta = "{\"type\":\"content_block_delta\",\"index\":\(toolCall.index),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(escapeJSON(args))}}"
                                        await streamer.sendSSEEvent(event: "content_block_delta", data: toolDelta)
                                    }
                                }
                            }

                            // Handle finish reason
                            if let finish = choice.finishReason {
                                switch finish {
                                case "tool_calls": stopReason = "tool_use"
                                case "stop": stopReason = "end_turn"
                                case "length": stopReason = "max_tokens"
                                default: break
                                }
                            }
                        }
                    }
                    currentLine = ""
                } else {
                    currentLine.append(char)
                }
            }

            // Send content_block_stop
            let blockStop = "{\"type\":\"content_block_stop\",\"index\":0}"
            await streamer.sendSSEEvent(event: "content_block_stop", data: blockStop)

            // Send message_delta
            let messageDelta = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":\(max(1, outputTokens))}}"
            await streamer.sendSSEEvent(event: "message_delta", data: messageDelta)

            // Send message_stop
            await streamer.sendSSEEvent(event: "message_stop", data: "{\"type\":\"message_stop\"}")

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                outputTokens: max(1, outputTokens)
            )

        } catch {
            httpLog.error("  ✗ Streaming proxy error: \(error.localizedDescription)")
            let errMsg = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\(escapeJSON(error.localizedDescription))}}"
            await streamer.sendSSEEvent(event: "error", data: errMsg)

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let errUpstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: errUpstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: error.localizedDescription
            )
        }

        streamer.close()
    }

    private func emitRequestLog(
        claudeModel: String,
        upstreamModel: String,
        success: Bool,
        responseTimeMs: Double,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheTokens: Int = 0,
        errorMessage: String? = nil
    ) {
        var parts = [
            "\"type\":\"proxy_request_log\"",
            "\"claude_model\":\(escapeJSON(claudeModel))",
            "\"upstream_model\":\(escapeJSON(upstreamModel))",
            "\"success\":\(success)",
            "\"response_time_ms\":\(Int(responseTimeMs))",
            "\"input_tokens\":\(inputTokens)",
            "\"output_tokens\":\(outputTokens)",
            "\"cache_tokens\":\(cacheTokens)"
        ]
        if let err = errorMessage {
            parts.append("\"error\":\(escapeJSON(err))")
        }
        print("PROXY_LOG:{\(parts.joined(separator: ","))}")
    }

    private func claudeErrorResponse(type: String, message: String, status: Int, headers: [String: String]) -> HTTPResponse {
        let errorJSON = """
        {"type":"error","error":{"type":"\(type)","message":"\(message)"}}
        """
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(errorJSON.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: errorJSON)
    }

    private func escapeJSON(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let json = String(data: data, encoding: .utf8),
              json.count > 2 else {
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        // Strip outer [ and ] to get the quoted string
        let start = json.index(after: json.startIndex)
        let end = json.index(before: json.endIndex)
        return String(json[start..<end])
    }

    // MARK: - HTTP Helpers

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var bodyString: String {
            String(data: body, encoding: .utf8) ?? ""
        }
    }

    private struct HTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    // MARK: - Streaming Response

    private actor StreamingResponse {
        let connection: NWConnection
        private var headersSent = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        func sendHeaders(status: Int, headers: [String: String]) async {
            guard !headersSent else { return }
            headersSent = true

            let statusText = httpStatusText(status)
            var headerLines = "HTTP/1.1 \(status) \(statusText)\r\n"
            for (key, value) in headers {
                headerLines += "\(key): \(value)\r\n"
            }
            headerLines += "\r\n"

            guard let data = headerLines.data(using: .utf8) else { return }
            await sendData(data)
        }

        func sendSSEEvent(event: String?, data: String) async {
            var message = ""
            if let event {
                message += "event: \(event)\n"
            }
            message += "data: \(data)\n\n"

            guard let eventData = message.data(using: .utf8) else { return }
            await sendData(eventData)
        }

        func sendChunk(_ text: String) async {
            guard let data = text.data(using: .utf8) else { return }
            await sendData(data)
        }

        nonisolated func close() {
            connection.cancel()
        }

        private func sendData(_ data: Data) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: data, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
        }

        private func httpStatusText(_ code: Int) -> String {
            [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error"][code] ?? "OK"
        }
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            if index > 0, let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body
        let bodyLines = lines.dropFirst(bodyStartIndex)
        let bodyText = bodyLines.joined(separator: "\r\n")
        let bodyData = bodyText.data(using: .utf8) ?? Data()

        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    private func parseQueryItems(_ path: String) -> [String: String] {
        guard let questionMark = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: questionMark)...])
        var result: [String: String] = [:]

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : ""
            result[key] = value
        }

        return result
    }

    private func jsonResponse(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let body: String
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            body = str
        } else {
            body = "{}"
        }
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(body.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: body)
    }

    private func jsonResponse<T: Encodable>(encodable: T, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let body: String
        if let data = try? encoder.encode(encodable), let str = String(data: data, encoding: .utf8) {
            body = str
        } else {
            body = "{}"
        }
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(body.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: body)
    }

    private func receiveData(_ connection: NWConnection) async -> Data? {
        // Support larger payloads (up to 10MB) with chunked reading
        let maxSize = 10 * 1024 * 1024 // 10MB
        var accumulated = Data()

        while accumulated.count < maxSize {
            guard let chunk = await receiveChunk(connection) else {
                break
            }
            accumulated.append(chunk)

            // Check if we have a complete HTTP request (headers + body)
            if let text = String(data: accumulated, encoding: .utf8),
               text.contains("\r\n\r\n") {
                // Check Content-Length to see if we have the full body
                if let contentLength = extractContentLength(from: text) {
                    guard let headerEnd = text.range(of: "\r\n\r\n") else {
                        continue
                    }
                    let headerEndOffset = text.distance(from: text.startIndex, to: headerEnd.upperBound)
                    let bodySize = accumulated.count - headerEndOffset
                    if bodySize >= contentLength {
                        break
                    }
                } else {
                    // No Content-Length, assume complete
                    break
                }
            }
        }

        return accumulated.isEmpty ? nil : accumulated
    }

    private func receiveChunk(_ connection: NWConnection) async -> Data? {
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: data)
            }
        }
    }

    private func extractContentLength(from text: String) -> Int? {
        let lines = text.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    private func sendResponse(_ connection: NWConnection, response: HTTPResponse) async {
        let statusText = httpStatusText(response.status)
        var headerLines = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        for (key, value) in response.headers {
            headerLines += "\(key): \(value)\r\n"
        }
        headerLines += "\r\n"
        let full = (headerLines + response.body).data(using: .utf8) ?? Data()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: full, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func httpStatusText(_ code: Int) -> String {
        [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"][code] ?? "OK"
    }
}

// MARK: - CLI Argument Parsing

func parseArgs() -> [String: String] {
    var result: [String: String] = [:]
    let args = CommandLine.arguments.dropFirst()
    var i = args.startIndex
    while i < args.endIndex {
        let arg = args[i]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            let nextIdx = args.index(after: i)
            if nextIdx < args.endIndex && !args[nextIdx].hasPrefix("--") {
                result[key] = args[nextIdx]
                i = args.index(after: nextIdx)
                continue
            }
        }
        i = args.index(after: i)
    }
    return result
}
