import Foundation
import os.log

private let upstreamLog = Logger(subsystem: "com.aiusage.quotaserver", category: "Upstream")

// MARK: - OpenAI-Compatible HTTP Client

public actor OpenAICompatibleClient {
    private let configuration: ClaudeProxyConfiguration
    private let session: URLSession

    public init(configuration: ClaudeProxyConfiguration) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfig.timeoutIntervalForResource = configuration.requestTimeout * 2
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Non-Streaming Request

    public func sendChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> OpenAIChatCompletionResponse {
        let nonStreamRequest = OpenAIChatCompletionRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stop,
            stream: false,
            tools: request.tools,
            toolChoice: request.toolChoice
        )

        let url = try buildURL(path: "/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.upstreamAPIKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in configuration.customHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let body = try JSONEncoder().encode(nonStreamRequest)
        urlRequest.httpBody = body
        upstreamLog.debug("Upstream: \(url.absoluteString, privacy: .private) model=\(nonStreamRequest.model)")

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode == 200 {
            if let result = try? JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data) {
                return result
            }
            if let body = String(data: data, encoding: .utf8), body.contains("data: ") {
                return try assembleFromSSE(body: body)
            }
            let body = String(data: data, encoding: .utf8) ?? "Unable to read response"
            throw UpstreamError.decodingFailed("Failed to decode upstream response. Body: \(body)")
        }

        let errorBody = String(data: data, encoding: .utf8) ?? ""
        upstreamLog.warning("Upstream \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")

        let isMaxTokensError = errorBody.contains("max_tokens") || errorBody.contains("model output limit")
        if isMaxTokensError {
            let retryRequest = OpenAIChatCompletionRequest(
                model: request.model,
                messages: request.messages,
                temperature: request.temperature,
                topP: request.topP,
                maxTokens: nil,
                stop: request.stop,
                stream: false,
                tools: request.tools,
                toolChoice: request.toolChoice
            )
            upstreamLog.info("Retrying without max_tokens")
            var retryURLRequest = urlRequest
            retryURLRequest.httpBody = try JSONEncoder().encode(retryRequest)

            let (retryData, retryResponse) = try await session.data(for: retryURLRequest)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw UpstreamError.invalidResponse("Not an HTTP response on retry")
            }
            if retryHTTP.statusCode == 200 {
                if let result = try? JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: retryData) {
                    return result
                }
                if let retryBody = String(data: retryData, encoding: .utf8), retryBody.contains("data: ") {
                    return try assembleFromSSE(body: retryBody)
                }
            }
            let retryError = String(data: retryData, encoding: .utf8) ?? ""
            throw UpstreamError.httpError(statusCode: retryHTTP.statusCode, message: retryError)
        }

        throw UpstreamError.httpError(statusCode: httpResponse.statusCode, message: errorBody)
    }

    private func fallbackViaStreaming(
        request: OpenAIChatCompletionRequest
    ) async throws -> OpenAIChatCompletionResponse {
        let streamReq = OpenAIChatCompletionRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stop,
            stream: true,
            tools: request.tools,
            toolChoice: request.toolChoice
        )

        let url = try buildURL(path: "/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.upstreamAPIKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in configuration.customHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONEncoder().encode(streamReq)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await byte in bytes {
                errorBody.append(Character(UnicodeScalar(byte)))
                if errorBody.count > 2048 { break }
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpstreamError.httpError(
                statusCode: code,
                message: "Streaming fallback failed (\(code)): \(errorBody)"
            )
        }

        var assembledContent = ""
        var finishReason: String? = "length"
        var responseId = ""
        var model = ""
        var created = 0
        var pendingToolCalls: [Int: (id: String, name: String, args: String)] = [:]
        var currentLine = ""

        for try await byte in bytes {
            let char = Character(UnicodeScalar(byte))
            if char == "\n" {
                let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data: ") {
                    let payload = String(trimmed.dropFirst(6))
                    if payload == "[DONE]" { break }

                    if let chunkData = payload.data(using: .utf8),
                       let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: chunkData),
                       let choice = chunk.choices.first {
                        if responseId.isEmpty { responseId = chunk.id }
                        if model.isEmpty { model = chunk.model }
                        if created == 0 { created = chunk.created }
                        if let content = choice.delta.content { assembledContent += content }
                        if let deltaTools = choice.delta.toolCalls {
                            for tc in deltaTools {
                                var entry = pendingToolCalls[tc.index] ?? (id: "", name: "", args: "")
                                if let id = tc.id { entry.id = id }
                                if let name = tc.function?.name { entry.name = name }
                                if let args = tc.function?.arguments { entry.args += args }
                                pendingToolCalls[tc.index] = entry
                            }
                        }
                        if let fr = choice.finishReason { finishReason = fr }
                    }
                }
                currentLine = ""
            } else {
                currentLine.append(char)
            }
        }

        var toolCalls: [OpenAIToolCall] = []
        for (_, entry) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
            toolCalls.append(OpenAIToolCall(
                id: entry.id, type: "function",
                function: OpenAIFunctionCall(name: entry.name, arguments: entry.args)
            ))
        }

        let message = OpenAIChatMessage(
            role: "assistant",
            content: assembledContent.isEmpty ? nil : .text(assembledContent),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
        let estimatedTokens = max(1, assembledContent.count / 4)

        return OpenAIChatCompletionResponse(
            id: responseId.isEmpty ? "chatcmpl-\(UUID().uuidString.prefix(12))" : responseId,
            object: "chat.completion",
            created: created == 0 ? Int(Date().timeIntervalSince1970) : created,
            model: model.isEmpty ? request.model : model,
            choices: [OpenAIChoice(index: 0, message: message, finishReason: finishReason)],
            usage: OpenAIUsage(promptTokens: 0, completionTokens: estimatedTokens, totalTokens: estimatedTokens)
        )
    }

    private func assembleFromSSE(body: String) throws -> OpenAIChatCompletionResponse {
        let decoder = JSONDecoder()
        var assembledContent = ""
        var finishReason: String? = nil
        var responseId = ""
        var model = ""
        var created = 0
        var toolCalls: [OpenAIToolCall] = []
        var pendingToolCalls: [Int: (id: String, name: String, args: String)] = [:]

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }
            let payload = String(trimmed.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: chunkData),
                  let choice = chunk.choices.first else { continue }

            if responseId.isEmpty { responseId = chunk.id }
            if model.isEmpty { model = chunk.model }
            if created == 0 { created = chunk.created }

            if let content = choice.delta.content {
                assembledContent += content
            }
            if let deltaTools = choice.delta.toolCalls {
                for tc in deltaTools {
                    var entry = pendingToolCalls[tc.index] ?? (id: "", name: "", args: "")
                    if let id = tc.id { entry.id = id }
                    if let name = tc.function?.name { entry.name = name }
                    if let args = tc.function?.arguments { entry.args += args }
                    pendingToolCalls[tc.index] = entry
                }
            }
            if let fr = choice.finishReason {
                finishReason = fr
            }
        }

        for (_, entry) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
            toolCalls.append(OpenAIToolCall(
                id: entry.id,
                type: "function",
                function: OpenAIFunctionCall(name: entry.name, arguments: entry.args)
            ))
        }

        let message = OpenAIChatMessage(
            role: "assistant",
            content: assembledContent.isEmpty ? nil : .text(assembledContent),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )

        let estimatedTokens = max(1, assembledContent.count / 4)

        return OpenAIChatCompletionResponse(
            id: responseId,
            object: "chat.completion",
            created: created,
            model: model,
            choices: [OpenAIChoice(index: 0, message: message, finishReason: finishReason)],
            usage: OpenAIUsage(
                promptTokens: 0,
                completionTokens: estimatedTokens,
                totalTokens: estimatedTokens
            )
        )
    }

    // MARK: - Streaming Request

    public func sendStreamingChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let url = try buildURL(path: "/chat/completions")

        func makeURLRequest(for req: OpenAIChatCompletionRequest) throws -> URLRequest {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("Bearer \(configuration.upstreamAPIKey)", forHTTPHeaderField: "Authorization")
            for (key, value) in configuration.customHeaders {
                r.setValue(value, forHTTPHeaderField: key)
            }
            r.httpBody = try JSONEncoder().encode(req)
            return r
        }

        let urlRequest = try makeURLRequest(for: request)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpstreamError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode == 200 {
            return (bytes, httpResponse)
        }

        var errorBody = ""
        for try await byte in bytes {
            errorBody.append(Character(UnicodeScalar(byte)))
            if errorBody.count > 4096 { break }
        }
        upstreamLog.warning("Upstream streaming \(httpResponse.statusCode): \(String(errorBody.prefix(500)), privacy: .private)")

        let isMaxTokensError = errorBody.contains("max_tokens") || errorBody.contains("model output limit")
        if isMaxTokensError {
            upstreamLog.info("Retrying streaming without max_tokens")
            let retryReq = OpenAIChatCompletionRequest(
                model: request.model, messages: request.messages,
                temperature: request.temperature, topP: request.topP,
                maxTokens: nil, stop: request.stop, stream: true,
                tools: request.tools, toolChoice: request.toolChoice
            )
            let retryURLRequest = try makeURLRequest(for: retryReq)
            let (retryBytes, retryResp) = try await session.bytes(for: retryURLRequest)
            guard let retryHTTP = retryResp as? HTTPURLResponse, retryHTTP.statusCode == 200 else {
                throw UpstreamError.httpError(
                    statusCode: (retryResp as? HTTPURLResponse)?.statusCode ?? 0,
                    message: "Retry without max_tokens also failed"
                )
            }
            return (retryBytes, retryHTTP)
        }

        throw UpstreamError.httpError(
            statusCode: httpResponse.statusCode,
            message: errorBody.isEmpty ? "Upstream returned status \(httpResponse.statusCode)" : errorBody
        )
    }

    // MARK: - Helpers

    private func buildURL(path: String) throws -> URL {
        var baseURL = configuration.upstreamBaseURL
        if baseURL.hasSuffix("/") {
            baseURL = String(baseURL.dropLast())
        }
        // Remove trailing /v1 if present since we add path ourselves
        if baseURL.hasSuffix("/v1") {
            // Keep as is, append path
        } else if !baseURL.contains("/v1") {
            baseURL += "/v1"
        }

        guard let url = URL(string: baseURL + path) else {
            throw UpstreamError.invalidURL(baseURL + path)
        }
        return url
    }
}

// MARK: - Upstream Errors

public enum UpstreamError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, message: String)
    case decodingFailed(String)
    case streamingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid upstream URL: \(url)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .httpError(let code, let msg):
            return "Upstream HTTP \(code): \(msg)"
        case .decodingFailed(let msg):
            return "Decoding failed: \(msg)"
        case .streamingFailed(let msg):
            return "Streaming failed: \(msg)"
        }
    }
}
