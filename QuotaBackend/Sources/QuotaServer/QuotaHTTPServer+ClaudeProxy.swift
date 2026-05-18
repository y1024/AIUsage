import Foundation
import Network
import os.log
import QuotaBackend

extension QuotaHTTPServer {
    private static let filesAPIBeta = "files-api-2025-04-14"

    struct ParsedMultipartFileUpload {
        let filename: String
        let mimeType: String?
        let data: Data
    }

    func proxyErrorHTTPResponse(
        proxy: ClaudeProxyService,
        error: Error,
        headers: [String: String]
    ) async -> HTTPResponse {
        let errorResult = await proxy.buildErrorResult(error: error)
        var responseHeaders = headers
        if let requestID = errorResult.response.requestID, !requestID.isEmpty {
            responseHeaders["request-id"] = requestID
        }
        return jsonResponse(
            encodable: errorResult.response,
            status: errorResult.statusCode,
            headers: responseHeaders
        )
    }

    // MARK: - Claude Proxy Handlers

    func handleEventLoggingEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
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

    func handleMessagesEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
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
                cacheCreationTokens: response.usage.cacheCreationInputTokens ?? 0,
                cacheReadTokens: response.usage.cacheReadInputTokens ?? 0
            )
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            let upstreamModel = await proxy.mapModel(claudeRequest.model)
            let errorResult = await proxy.buildErrorResult(error: error)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode
            )
            httpLog.error("  ✗ Proxy error: \(error.localizedDescription)")
            var responseHeaders = headers
            if let requestID = errorResult.response.requestID, !requestID.isEmpty {
                responseHeaders["request-id"] = requestID
            }
            return jsonResponse(
                encodable: errorResult.response,
                status: errorResult.statusCode,
                headers: responseHeaders
            )
        }
    }

    func handleCountTokensEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        // Authenticate: OpenAI Convert mode uses proxyService, Passthrough mode uses proxyConfig key
        if let proxy = proxyService {
            guard await proxy.authenticate(headers: request.headers) else {
                return claudeErrorResponse(
                    type: "authentication_error",
                    message: "Invalid API key",
                    status: 401,
                    headers: headers
                )
            }
        } else if let config = proxyConfig, let expectedKey = config.expectedClientKey, !expectedKey.isEmpty {
            let clientKey = request.headers["x-api-key"]
                ?? request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
            if clientKey != expectedKey {
                return claudeErrorResponse(
                    type: "authentication_error",
                    message: "Invalid API key",
                    status: 401,
                    headers: headers
                )
            }
        }

        guard let tokenRequest = try? JSONDecoder().decode(ClaudeTokenCountRequest.self, from: request.body) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Failed to parse token count request body",
                status: 400,
                headers: headers
            )
        }

        httpLog.debug("→ POST /v1/messages/count_tokens (model: \(tokenRequest.model))")

        if let proxy = proxyService {
            do {
                let response = try await proxy.handleCountTokens(request: tokenRequest)
                return jsonResponse(encodable: response, headers: headers)
            } catch {
                return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
            }
        }

        // Passthrough mode fallback: local heuristic estimate (upstream does not support count_tokens)
        let estimated = estimateTokenCount(request: tokenRequest)
        return jsonResponse(encodable: ClaudeTokenCountResponse(inputTokens: estimated), headers: headers)
    }

    /// Local heuristic token estimate for passthrough mode where upstream
    /// does not support `/v1/messages/count_tokens`.
    /// Uses character-count / 4 approximation; not tokenizer-exact.
    /// Algorithm mirrors `ClaudeProxyService.handleCountTokens`.
    private func estimateTokenCount(request: ClaudeTokenCountRequest) -> Int {
        var totalChars = 0

        if let system = request.system {
            totalChars += system.count
        }
        if let systemBlocks = request.systemBlocks {
            for block in systemBlocks {
                totalChars += block.text?.count ?? 0
                totalChars += block.cacheControl == nil ? 0 : 20
            }
        }

        for message in request.messages {
            switch message.content {
            case .text(let text):
                totalChars += text.count
            case .blocks(let blocks):
                for block in blocks {
                    switch block {
                    case .text(let textBlock):
                        totalChars += textBlock.text.count
                    case .toolUse(let toolUse):
                        totalChars += toolUse.name.count
                        totalChars += 50
                    case .toolResult(let result):
                        totalChars += result.content?.count ?? 0
                        if let contentBlocks = result.contentBlocks {
                            for contentBlock in contentBlocks {
                                switch contentBlock {
                                case .image:
                                    totalChars += 4000
                                case .document:
                                    totalChars += 8000
                                case .thinking(let thinking):
                                    totalChars += thinking.thinking.count
                                case .redactedThinking:
                                    totalChars += 2000
                                case .text, .toolUse, .toolResult, .unknown:
                                    break
                                }
                            }
                        }
                    case .image:
                        totalChars += 4000
                    case .document:
                        totalChars += 8000
                    case .thinking(let thinking):
                        totalChars += thinking.thinking.count
                    case .redactedThinking:
                        totalChars += 2000
                    case .unknown:
                        totalChars += 100
                    }
                }
            }
        }

        if let tools = request.tools {
            for tool in tools {
                totalChars += tool.name.count
                totalChars += tool.description?.count ?? 0
                totalChars += 100
            }
        }

        return max(1, totalChars / 4)
    }

    func handleListFilesEndpoint(
        request: HTTPRequest,
        queryItems: [String: String],
        headers: [String: String]
    ) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        if queryItems["before_id"] != nil {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "`before_id` is not supported by this OpenAI bridge. Use `after_id` for forward pagination.",
                status: 400,
                headers: headers
            )
        }

        let limit: Int?
        if let rawLimit = queryItems["limit"], !rawLimit.isEmpty {
            guard let parsedLimit = Int(rawLimit) else {
                return claudeErrorResponse(
                    type: "invalid_request_error",
                    message: "`limit` must be an integer.",
                    status: 400,
                    headers: headers
                )
            }
            limit = parsedLimit
        } else {
            limit = nil
        }

        do {
            let response = try await proxy.listFiles(limit: limit, afterID: queryItems["after_id"])
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func handleCreateFileEndpoint(request: HTTPRequest, headers: [String: String]) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        guard let upload = parseClaudeFilesMultipartUpload(
            body: request.body,
            contentTypeHeader: request.headers["content-type"]
        ) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Claude Files upload expects multipart/form-data with a single `file` part.",
                status: 400,
                headers: headers
            )
        }

        do {
            let response = try await proxy.createFile(
                filename: upload.filename,
                mimeType: upload.mimeType,
                data: upload.data
            )
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func handleFileSubresourceEndpoint(
        request: HTTPRequest,
        path: String,
        headers: [String: String]
    ) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        let filePath = String(path.dropFirst("/v1/files/".count))
        if filePath.hasSuffix("/content") {
            let fileID = String(filePath.dropLast("/content".count))
            do {
                let response = try await proxy.retrieveFileContent(fileID: fileID)
                var responseHeaders = headers
                responseHeaders["Content-Type"] = response.contentType ?? "application/octet-stream"
                responseHeaders["Content-Length"] = "\(response.data.count)"
                if let contentDisposition = response.contentDisposition {
                    responseHeaders["Content-Disposition"] = contentDisposition
                }
                return HTTPResponse(status: 200, headers: responseHeaders, bodyData: response.data)
            } catch {
                return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
            }
        }

        do {
            let response = try await proxy.retrieveFile(fileID: filePath)
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func handleDeleteFileEndpoint(
        request: HTTPRequest,
        path: String,
        headers: [String: String]
    ) async -> HTTPResponse {
        guard let proxy = proxyService else {
            return claudeErrorResponse(
                type: "api_error",
                message: "Claude proxy is not enabled",
                status: 503,
                headers: headers
            )
        }

        guard await proxy.authenticate(headers: request.headers) else {
            return claudeErrorResponse(
                type: "authentication_error",
                message: "Invalid API key",
                status: 401,
                headers: headers
            )
        }

        if let validationError = validateFilesAPIHeaders(requestHeaders: request.headers, responseHeaders: headers) {
            return validationError
        }

        let fileID = String(path.dropFirst("/v1/files/".count))

        do {
            let response = try await proxy.deleteFile(fileID: fileID)
            return jsonResponse(encodable: response, headers: headers)
        } catch {
            return await proxyErrorHTTPResponse(proxy: proxy, error: error, headers: headers)
        }
    }

    func validateFilesAPIHeaders(
        requestHeaders: [String: String],
        responseHeaders: [String: String]
    ) -> HTTPResponse? {
        let betas = parseAnthropicBetas(from: requestHeaders["anthropic-beta"])
        guard betas.contains(Self.filesAPIBeta) else {
            return claudeErrorResponse(
                type: "invalid_request_error",
                message: "Files API requires anthropic-beta: \(Self.filesAPIBeta)",
                status: 400,
                headers: responseHeaders
            )
        }
        return nil
    }

    func parseAnthropicBetas(from rawValue: String?) -> Set<String> {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        return Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    func parseClaudeFilesMultipartUpload(
        body: Data,
        contentTypeHeader: String?
    ) -> ParsedMultipartFileUpload? {
        guard let boundary = extractMultipartBoundary(from: contentTypeHeader) else {
            return nil
        }

        let openingBoundary = Data("--\(boundary)\r\n".utf8)
        guard body.starts(with: openingBoundary) else {
            return nil
        }

        let headerStart = openingBoundary.count
        let headerSeparator = Data([13, 10, 13, 10])
        guard let headerRange = body.range(of: headerSeparator, in: headerStart..<body.count) else {
            return nil
        }

        let headerData = Data(body[headerStart..<headerRange.lowerBound])
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        var partHeaders: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            partHeaders[key] = value
        }

        guard let disposition = partHeaders["content-disposition"] else {
            return nil
        }
        let parameters = parseContentDispositionParameters(disposition)
        guard parameters["name"] == "file" else {
            return nil
        }

        let filename = parameters["filename"] ?? "upload.bin"
        let contentStart = headerRange.upperBound
        let closingBoundary = Data("\r\n--\(boundary)".utf8)
        guard let closingRange = body.range(of: closingBoundary, in: contentStart..<body.count) else {
            return nil
        }

        return ParsedMultipartFileUpload(
            filename: filename,
            mimeType: partHeaders["content-type"],
            data: Data(body[contentStart..<closingRange.lowerBound])
        )
    }

    func extractMultipartBoundary(from contentTypeHeader: String?) -> String? {
        guard let contentTypeHeader else { return nil }
        for segment in contentTypeHeader.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            let rawBoundary = trimmed.dropFirst("boundary=".count)
            return rawBoundary.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    func parseContentDispositionParameters(_ headerValue: String) -> [String: String] {
        var parameters: [String: String] = [:]
        for component in headerValue.split(separator: ";").dropFirst() {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            parameters[parts[0].lowercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return parameters
    }

    func handleStreamingProxy(_ connection: NWConnection, request: HTTPRequest) async {
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
            let upstreamModel = await proxy.mapModel(claudeRequest.model)

            let encoder = JSONEncoder()
            let messageID = "msg_\(UUID().uuidString.prefix(24))"
            var outputTokens = 0
            var reportedOutputTokens: Int?
            var reportedInputTokens: Int?
            var reportedCacheCreation: Int?
            var reportedCacheRead: Int?
            var hasAnyContentBlock = false
            var canonicalMapper = CanonicalOpenAIUpstreamStreamMapper()
            let canonicalBuilder = CanonicalClaudeStreamBuilder()

            func sendClaudeEvent(_ event: ClaudeStreamEvent) async throws {
                let eventName: String
                let json: String

                func encodeEventJSON<T: Encodable>(_ payload: T) throws -> String {
                    let data = try encoder.encode(payload)
                    guard let json = String(data: data, encoding: .utf8) else {
                        throw NSError(
                            domain: "QuotaHTTPServer",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to encode Claude SSE payload"]
                        )
                    }
                    return json
                }

                switch event {
                case .messageStart(let payload):
                    eventName = "message_start"
                    json = try encodeEventJSON(payload)

                case .contentBlockStart(let payload):
                    hasAnyContentBlock = true
                    eventName = "content_block_start"
                    json = try encodeEventJSON(payload)

                case .contentBlockDelta(let payload):
                    hasAnyContentBlock = true
                    eventName = "content_block_delta"
                    json = try encodeEventJSON(payload)

                case .contentBlockStop(let payload):
                    hasAnyContentBlock = true
                    eventName = "content_block_stop"
                    json = try encodeEventJSON(payload)

                case .messageDelta(let payload):
                    eventName = "message_delta"
                    json = try encodeEventJSON(payload)

                case .messageStop:
                    eventName = "message_stop"
                    json = "{\"type\":\"message_stop\"}"

                case .ping:
                    eventName = "ping"
                    json = "{\"type\":\"ping\"}"
                }
                await streamer.sendSSEEvent(event: eventName, data: json)
            }

            func sendEmptyTextLifecycleIfNeeded() async throws {
                guard !hasAnyContentBlock else { return }
                try await sendClaudeEvent(.contentBlockStart(ClaudeContentBlockStartEvent(
                    index: 0,
                    contentBlock: .text(ClaudeTextBlock(text: ""))
                )))
                try await sendClaudeEvent(.contentBlockStop(ClaudeContentBlockStopEvent(index: 0)))
            }

            try await proxy.sendStreamingClaudeRequest(claudeRequest) { upstreamEvent in
                let canonicalEvents = canonicalMapper.map(upstreamEvent).map { event -> CanonicalStreamEvent in
                    guard case .messageStarted(let start) = event else { return event }
                    return .messageStarted(CanonicalStreamMessageStarted(
                        role: start.role,
                        messageID: messageID,
                        model: claudeRequest.model,
                        rawExtensions: start.rawExtensions
                    ))
                }

                for canonicalEvent in canonicalEvents {
                    if case .contentPartDelta(let delta) = canonicalEvent,
                       let textDelta = delta.textDelta,
                       !textDelta.isEmpty {
                        outputTokens += max(1, textDelta.count / 4)
                    }

                    if case .messageDelta(let delta) = canonicalEvent, let usage = delta.usage {
                        reportedInputTokens = usage.inputTokens ?? reportedInputTokens
                        reportedCacheCreation = usage.cacheCreationInputTokens ?? reportedCacheCreation
                        reportedCacheRead = usage.cacheReadInputTokens ?? reportedCacheRead
                    }

                    let claudeEvents = canonicalBuilder.build(event: canonicalEvent)
                    for claudeEvent in claudeEvents {
                        if case .messageDelta(let payload) = claudeEvent {
                            try await sendEmptyTextLifecycleIfNeeded()
                            reportedOutputTokens = payload.usage.outputTokens
                        }
                        try await sendClaudeEvent(claudeEvent)
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let finalOutputTokens = max(1, reportedOutputTokens ?? outputTokens)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: upstreamModel,
                success: true,
                responseTimeMs: elapsed,
                inputTokens: reportedInputTokens ?? 0,
                outputTokens: finalOutputTokens,
                cacheCreationTokens: reportedCacheCreation ?? 0,
                cacheReadTokens: reportedCacheRead ?? 0
            )

        } catch {
            httpLog.error("  ✗ Streaming proxy error: \(error.localizedDescription)")
            let errorResult = await proxy.buildErrorResult(error: error)
            let errMsg = """
            {"type":"error","error":{"type":\(escapeJSON(errorResult.response.error.type)),"message":\(escapeJSON(errorResult.response.error.message))}\(errorResult.response.requestID.map { ",\"request_id\":\(escapeJSON($0))" } ?? "")}
            """
            await streamer.sendSSEEvent(event: "error", data: errMsg)

            let elapsed = Date().timeIntervalSince(streamStartTime) * 1000
            let errUpstreamModel = await proxy.mapModel(claudeRequest.model)
            emitRequestLog(
                claudeModel: claudeRequest.model,
                upstreamModel: errUpstreamModel,
                success: false,
                responseTimeMs: elapsed,
                errorMessage: errorResult.response.error.message,
                errorType: errorResult.response.error.type,
                statusCode: errorResult.statusCode
            )
        }

        await streamer.finish()
    }

    func emitRequestLog(
        claudeModel: String,
        upstreamModel: String,
        success: Bool,
        responseTimeMs: Double,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        errorMessage: String? = nil,
        errorType: String? = nil,
        statusCode: Int? = nil
    ) {
        var parts = [
            "\"type\":\"proxy_request_log\"",
            "\"claude_model\":\(escapeJSON(claudeModel))",
            "\"upstream_model\":\(escapeJSON(upstreamModel))",
            "\"success\":\(success)",
            "\"response_time_ms\":\(Int(responseTimeMs))",
            "\"input_tokens\":\(inputTokens)",
            "\"output_tokens\":\(outputTokens)",
            "\"cache_creation_tokens\":\(cacheCreationTokens)",
            "\"cache_read_tokens\":\(cacheReadTokens)",
            "\"cache_tokens\":\(cacheCreationTokens + cacheReadTokens)"
        ]
        if let err = errorMessage {
            parts.append("\"error\":\(escapeJSON(err))")
        }
        if let errType = errorType {
            parts.append("\"error_type\":\(escapeJSON(errType))")
        }
        if let code = statusCode {
            parts.append("\"status_code\":\(code)")
        }
        // stdout is parsed by the macOS host app for structured log ingestion
        print("PROXY_LOG:{\(parts.joined(separator: ","))}")
    }
}
