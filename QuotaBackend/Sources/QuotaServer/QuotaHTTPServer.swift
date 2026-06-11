import Foundation
import Network
import os.log
import QuotaBackend

let httpLog = Logger(subsystem: "com.aiusage.quotaserver", category: "HTTP")

enum QuotaHTTPServerError: LocalizedError {
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
    // JSONDecoder/JSONEncoder 的 decode/encode 线程安全（配置不可变时），
    // 静态复用避免每请求/每事件重复创建高成本对象。
    static let requestDecoder = JSONDecoder()
    static let responseEncoder = JSONEncoder()

    static let corsHeaders = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, x-api-key, authorization, anthropic-version, anthropic-beta"
    ]

    /// 仅探测请求体顶层 `stream` 标志的轻量解码目标，
    /// 避免为路由判断对大 body 做 JSONSerialization 全量建图。
    struct StreamFlagProbe: Decodable {
        let stream: Bool?
    }

    let host: String
    let port: Int
    let engine = ProviderEngine()
    var proxyService: ClaudeProxyService?
    var proxyConfig: ClaudeProxyConfiguration?
    var codexProxyService: CodexProxyService?
    var codexConfig: CodexProxyConfiguration?
    var httpsConfig: HTTPSConfig?
    private let lifecycleQueue = DispatchQueue(label: "com.aiusage.quotaserver.lifecycle")
    private var ipv4Listener: NWListener?
    private var ipv6Listener: NWListener?
    private var httpsListener: NWListener?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    var isPassthrough: Bool { proxyConfig?.mode == .anthropicPassthrough }

    public init(
        host: String,
        port: Int,
        proxyConfig: ClaudeProxyConfiguration? = nil,
        codexConfig: CodexProxyConfiguration? = nil,
        httpsConfig: HTTPSConfig? = nil
    ) {
        self.host = host
        self.port = port
        self.proxyConfig = proxyConfig
        self.codexConfig = codexConfig
        self.httpsConfig = httpsConfig
        if let config = proxyConfig, config.enabled, config.mode == .openaiConvert {
            self.proxyService = try? ClaudeProxyService(configuration: config)
        }
        if let codexConfig, codexConfig.enabled, codexConfig.mode == .openaiConvert {
            self.codexProxyService = try? CodexProxyService(configuration: codexConfig)
        }
    }

    deinit {
        stop()
    }

    public func start() async throws {
        let isRunning = lifecycleQueue.sync { ipv4Listener != nil }
        if isRunning {
            return
        }

        guard (1...65_535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw QuotaHTTPServerError.invalidPort(port)
        }
        let nwHost = NWEndpoint.Host(host)

        let listener4 = try await startIPv4Listener(host: nwHost, port: nwPort)
        let (listener6, ipv6Active) = startIPv6Listener(port: nwPort)

        var tlsListener: NWListener?
        if let httpsConfig {
            do {
                tlsListener = try await startHTTPSListener(config: httpsConfig, host: nwHost)
            } catch {
                httpLog.error("HTTPS listener failed to start: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        lifecycleQueue.sync {
            ipv4Listener = listener4
            ipv6Listener = listener6
            httpsListener = tlsListener
        }

        logStartup(ipv6Active: ipv6Active, httpsPort: tlsListener != nil ? httpsConfig?.port : nil)
    }

    public func stop() {
        let state = lifecycleQueue.sync { () -> (NWListener?, NWListener?, NWListener?, CheckedContinuation<Void, Never>?) in
            let currentState = (ipv4Listener, ipv6Listener, httpsListener, stopContinuation)
            ipv4Listener = nil
            ipv6Listener = nil
            httpsListener = nil
            stopContinuation = nil
            return currentState
        }

        state.0?.cancel()
        state.1?.cancel()
        state.2?.cancel()
        state.3?.resume()
    }

    public func run() async throws {
        try await start()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResumeImmediately = lifecycleQueue.sync { () -> Bool in
                if ipv4Listener == nil {
                    return true
                }
                stopContinuation = cont
                return false
            }
            if shouldResumeImmediately {
                cont.resume()
            }
        }
    }

    private func startIPv4Listener(host: NWEndpoint.Host, port: NWEndpoint.Port) async throws -> NWListener {
        final class ListenerStartState: @unchecked Sendable {
            private let lock = NSLock()
            private var hasResolved = false

            func resolve(
                continuation: CheckedContinuation<Void, Error>,
                result: Result<Void, Error>
            ) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResolved else { return }
                hasResolved = true
                continuation.resume(with: result)
            }
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startState = ListenerStartState()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    startState.resolve(continuation: continuation, result: .success(()))
                case .failed(let error):
                    startState.resolve(continuation: continuation, result: .failure(error))
                    self?.handlePrimaryListenerExit(error: error)
                case .cancelled:
                    startState.resolve(continuation: continuation, result: .failure(CancellationError()))
                    self?.handlePrimaryListenerExit(error: nil)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        return listener
    }

    private func startIPv6Listener(port: NWEndpoint.Port) -> (NWListener?, Bool) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "::1", port: port)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.handleConnection(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    httpLog.debug("IPv6 listener unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
            listener.start(queue: .global())
            return (listener, true)
        } catch {
            return (nil, false)
        }
    }

    private func handlePrimaryListenerExit(error: Error?) {
        if let error {
            httpLog.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        }

        let continuation = lifecycleQueue.sync { () -> CheckedContinuation<Void, Never>? in
            ipv4Listener = nil
            ipv6Listener = nil
            let waiter = stopContinuation
            stopContinuation = nil
            return waiter
        }
        continuation?.resume()
    }

    private func logStartup(ipv6Active: Bool, httpsPort: Int? = nil) {
        var proto = ipv6Active ? "(IPv4 + IPv6)" : "(IPv4)"
        if let httpsPort { proto += " + HTTPS:\(httpsPort)" }
        httpLog.info("QuotaServer listening on \(self.host):\(self.port) \(proto)")
        httpLog.info("Endpoints:")
        httpLog.info("  GET /api/dashboard")
        httpLog.info("  GET /api/provider/:id")
        httpLog.info("  GET /api/providers")
        httpLog.info("  GET /api/health")
        httpLog.info("  GET /health")
        if self.proxyService != nil {
            httpLog.info("  POST /v1/messages (Claude Proxy - OpenAI Convert)")
            httpLog.info("  POST /v1/messages/count_tokens (Claude Proxy)")
            httpLog.info("  GET /v1/files (Claude Proxy)")
            httpLog.info("  POST /v1/files (Claude Proxy)")
            httpLog.info("  GET /v1/files/:id (Claude Proxy)")
            httpLog.info("  DELETE /v1/files/:id (Claude Proxy)")
        }
        if self.isPassthrough {
            httpLog.info("  POST /v1/messages (Anthropic Passthrough)")
        }
        if self.codexProxyService != nil {
            httpLog.info("  POST /v1/responses (Codex Proxy - OpenAI Convert)")
        }
    }

    // MARK: - Connection Handling

    func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global())
        guard let requestData = await receiveData(connection) else {
            connection.cancel()
            return
        }

        let request = parseHTTPRequest(requestData)
        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path

        if request.method == "POST",
           cleanPath == "/v1/messages" || cleanPath.hasPrefix("/v1/messages/") {
            if isPassthrough && cleanPath != "/v1/messages/count_tokens" {
                await handlePassthroughProxy(connection, request: request)
                return
            }
            if proxyService != nil, cleanPath == "/v1/messages" {
                // 单次解码：一次拿到 stream 标志与完整请求，流式/非流式 handler 直接复用，
                // 不再「JSONSerialization 全量建图读 stream + handler 再 JSONDecoder 解一遍」。
                if let claudeRequest = try? Self.requestDecoder.decode(ClaudeMessageRequest.self, from: request.body) {
                    if claudeRequest.stream == true {
                        await handleStreamingProxy(connection, request: request, claudeRequest: claudeRequest)
                    } else {
                        let response = await handleMessagesEndpoint(
                            request: request,
                            claudeRequest: claudeRequest,
                            headers: Self.corsHeaders
                        )
                        await sendResponse(connection, response: response)
                        connection.cancel()
                    }
                    return
                }
                // 解码失败：交由通用路由按非流式流程返回 400。
            }
        }

        if request.method == "POST", cleanPath == "/v1/responses", codexProxyService != nil {
            let isStreaming = (try? Self.requestDecoder.decode(StreamFlagProbe.self, from: request.body))?.stream ?? false
            if isStreaming {
                await handleCodexStreamingProxy(connection, request: request)
                return
            }
        }

        let response = await routeRequest(request)
        await sendResponse(connection, response: response)
        connection.cancel()
    }

    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let queryItems = parseQueryItems(request.path)
        let corsHeaders = Self.corsHeaders

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: corsHeaders, body: "")
        }

        switch (request.method, path) {
        case ("GET", "/health"), ("GET", "/api/health"):
            let generatedAt = SharedFormatters.iso8601String(from: Date())
            return jsonResponse(
                [
                    "ok": true,
                    "generatedAt": generatedAt
                ],
                headers: corsHeaders
            )

        // MARK: - Claude Proxy Endpoints

        case ("POST", "/v1/messages"):
            return await handleMessagesEndpoint(request: request, headers: corsHeaders)

        // MARK: - Codex Proxy Endpoint

        case ("POST", "/v1/responses"):
            return await handleCodexResponsesEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/v1/models") where codexProxyService != nil:
            return await handleCodexModelsEndpoint(request: request, headers: corsHeaders)

        case ("POST", "/v1/messages/count_tokens"):
            return await handleCountTokensEndpoint(request: request, headers: corsHeaders)

        case ("GET", "/v1/files"):
            return await handleListFilesEndpoint(request: request, queryItems: queryItems, headers: corsHeaders)

        case ("POST", "/v1/files"):
            return await handleCreateFileEndpoint(request: request, headers: corsHeaders)

        case ("GET", _) where path.hasPrefix("/v1/files/"):
            return await handleFileSubresourceEndpoint(request: request, path: path, headers: corsHeaders)

        case ("DELETE", _) where path.hasPrefix("/v1/files/"):
            return await handleDeleteFileEndpoint(request: request, path: path, headers: corsHeaders)

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

    // MARK: - Error Helpers

    func claudeErrorResponse(type: String, message: String, status: Int, headers: [String: String]) -> HTTPResponse {
        let errorJSON = "{\"type\":\"error\",\"error\":{\"type\":\(escapeJSON(type)),\"message\":\(escapeJSON(message))}}"
        var h = headers
        h["Content-Type"] = "application/json"
        h["Content-Length"] = "\(errorJSON.utf8.count)"
        return HTTPResponse(status: status, headers: h, body: errorJSON)
    }

    func escapeJSON(_ string: String) -> String {
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

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var bodyString: String {
            String(data: body, encoding: .utf8) ?? ""
        }
    }

    struct HTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: Data

        init(status: Int, headers: [String: String], body: String) {
            self.status = status
            self.headers = headers
            self.body = Data(body.utf8)
        }

        init(status: Int, headers: [String: String], bodyData: Data) {
            self.status = status
            self.headers = headers
            self.body = bodyData
        }
    }

    // MARK: - Streaming Response

    actor StreamingResponse {
        let connection: NWConnection
        private var headersSent = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        func sendHeaders(status: Int, headers: [String: String]) async {
            guard !headersSent else { return }
            headersSent = true

            let statusText = httpStatusText(status)
            var h = headers
            h["Transfer-Encoding"] = "chunked"

            var headerLines = "HTTP/1.1 \(status) \(statusText)\r\n"
            for (key, value) in h {
                headerLines += "\(key): \(value)\r\n"
            }
            headerLines += "\r\n"

            guard let data = headerLines.data(using: .utf8) else { return }
            await sendRaw(data)
        }

        func sendSSEEvent(event: String?, data: String) async {
            var message = ""
            if let event {
                message += "event: \(event)\n"
            }
            message += "data: \(data)\n\n"

            guard let eventData = message.data(using: .utf8) else { return }
            await sendChunkedFrame(eventData)
        }

        func sendChunk(_ text: String) async {
            guard let data = text.data(using: .utf8) else { return }
            await sendChunkedFrame(data)
        }

        func sendDataChunk(_ data: Data) async {
            guard !data.isEmpty else { return }
            await sendChunkedFrame(data)
        }

        func finish() async {
            let terminator = Data("0\r\n\r\n".utf8)
            await sendRaw(terminator)

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
            connection.cancel()
        }

        nonisolated func close() {
            connection.cancel()
        }

        private func sendChunkedFrame(_ body: Data) async {
            let sizeHex = String(body.count, radix: 16)
            var frame = Data("\(sizeHex)\r\n".utf8)
            frame.append(body)
            frame.append(Data("\r\n".utf8))
            await sendRaw(frame)
        }

        private func sendRaw(_ data: Data) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: data, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
        }

        private func httpStatusText(_ code: Int) -> String {
            [
                200: "OK",
                204: "No Content",
                400: "Bad Request",
                401: "Unauthorized",
                404: "Not Found",
                500: "Internal Server Error",
                501: "Not Implemented",
                503: "Service Unavailable",
            ][code] ?? "OK"
        }
    }

    func parseHTTPRequest(_ data: Data) -> HTTPRequest {
        let headerSeparator = Data([13, 10, 13, 10])
        let headerRange = data.range(of: headerSeparator)
        let headerData = headerRange.map { Data(data[..<($0.lowerBound)]) } ?? data
        let bodyData = headerRange.map { Data(data[$0.upperBound...]) } ?? Data()
        let text = String(data: headerData, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        // Parse headers
        var headers: [String: String] = [:]
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                break
            }
            if index > 0, let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

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

    // JSON 响应统一紧凑输出（不 prettyPrinted）：代理热路径上的响应体不必为可读性
    // 膨胀约 30% 的体积与编码成本；调试时可用 jq 等工具格式化。
    func jsonResponse(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let body: String
        if let data = try? JSONSerialization.data(withJSONObject: object),
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

    func jsonResponse<T: Encodable>(encodable: T, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let body: String
        if let data = try? Self.responseEncoder.encode(encodable), let str = String(data: data, encoding: .utf8) {
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
        let headerSeparator = Data([13, 10, 13, 10])
        var accumulated = Data()

        while accumulated.count < maxSize {
            guard let chunk = await receiveChunk(connection) else {
                break
            }
            accumulated.append(chunk)

            // Check if we have a complete HTTP request (headers + body)
            if let headerRange = accumulated.range(of: headerSeparator) {
                let headerText = String(data: accumulated[..<headerRange.lowerBound], encoding: .utf8) ?? ""
                if let contentLength = extractContentLength(from: headerText) {
                    let bodySize = accumulated.count - headerRange.upperBound
                    if bodySize >= contentLength {
                        break
                    }
                } else {
                    // No Content-Length, assume complete once headers are fully received.
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

    func sendResponse(_ connection: NWConnection, response: HTTPResponse) async {
        let statusText = httpStatusText(response.status)
        var headerLines = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        for (key, value) in response.headers {
            headerLines += "\(key): \(value)\r\n"
        }
        headerLines += "\r\n"
        var full = Data(headerLines.utf8)
        full.append(response.body)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: full, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func httpStatusText(_ code: Int) -> String {
        [
            200: "OK",
            204: "No Content",
            400: "Bad Request",
            401: "Unauthorized",
            404: "Not Found",
            500: "Internal Server Error",
            501: "Not Implemented",
            503: "Service Unavailable",
        ][code] ?? "OK"
    }
}
