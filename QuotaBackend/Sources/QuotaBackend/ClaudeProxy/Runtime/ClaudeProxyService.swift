import Foundation

// MARK: - Claude Proxy Service

public struct ClaudeProxyErrorResult: Sendable {
    public let response: ClaudeErrorResponse
    public let statusCode: Int

    public init(response: ClaudeErrorResponse, statusCode: Int) {
        self.response = response
        self.statusCode = statusCode
    }
}

public actor ClaudeProxyService {
    private let configuration: ClaudeProxyConfiguration
    private let upstreamClient: OpenAICompatibleClient

    public init(configuration: ClaudeProxyConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        self.upstreamClient = OpenAICompatibleClient(configuration: configuration)
    }

    // MARK: - Authentication

    public func authenticate(headers: [String: String]) -> Bool {
        configuration.authenticatedSurface(headers: headers) != nil
    }

    // MARK: - Non-Streaming Messages

    public func handleMessages(
        request: ClaudeMessageRequest
    ) async throws -> ClaudeMessageResponse {
        let upstreamModel = configuration.mapToUpstreamModel(request.model)
        let canonicalRequest = cappedCanonicalRequest(
            try CanonicalRequestMapper().mapClaude(request)
        )

        switch configuration.openAIUpstreamAPI {
        case .chatCompletions:
            let buildResult = try CanonicalOpenAIRequestBuilder().buildChatCompletionRequest(
                from: canonicalRequest,
                modelOverride: upstreamModel
            )
            let openAIResponse = try await upstreamClient.sendChatCompletion(request: buildResult.payload)
            let canonicalResponse = try CanonicalResponseMapper().mapOpenAIChatCompletions(openAIResponse)
            return try CanonicalClaudeResponseBuilder().buildMessageResponse(
                from: canonicalResponse,
                originalModel: request.model
            ).payload

        case .responses:
            let buildResult = try CanonicalOpenAIRequestBuilder().buildResponsesRequest(
                from: canonicalRequest,
                modelOverride: upstreamModel
            )
            let openAIResponse = try await upstreamClient.sendResponses(request: buildResult.payload)
            let canonicalResponse = try CanonicalResponseMapper().mapOpenAIResponses(openAIResponse)
            return try CanonicalClaudeResponseBuilder().buildMessageResponse(
                from: canonicalResponse,
                originalModel: request.model
            ).payload
        }
    }

    // MARK: - Token Counting

    public func handleCountTokens(
        request: ClaudeTokenCountRequest
    ) async throws -> ClaudeTokenCountResponse {
        // Approximate token count only: not a real tokenizer; useful for rough budgeting.
        // Heuristic: total UTF-16 character count ÷ 4 (common rule-of-thumb; actual tokenization differs by model).
        var totalChars = 0

        // Count system message
        if let system = request.system {
            totalChars += system.count
        }
        if let systemBlocks = request.systemBlocks {
            for block in systemBlocks {
                totalChars += block.text?.count ?? 0
                totalChars += block.cacheControl == nil ? 0 : 20
            }
        }

        // Count messages
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
                        // Estimate tool input size
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

        // Count tools
        if let tools = request.tools {
            for tool in tools {
                totalChars += tool.name.count
                totalChars += tool.description?.count ?? 0
                totalChars += 100 // Estimate for schema
            }
        }

        // `input_tokens` in the JSON response is this heuristic estimate, not an exact count.
        // `totalChars / 4` is only a rough rule-of-thumb; real token counts differ by model and tokenizer.
        let estimatedTokens = max(1, totalChars / 4)

        return ClaudeTokenCountResponse(inputTokens: estimatedTokens)
    }

    // MARK: - Files API

    public func listFiles(limit: Int?, afterID: String?) async throws -> ClaudeFilesListResponse {
        let upstreamResponse = try await upstreamClient.listFiles(limit: limit, after: afterID)
        let mappedFiles = upstreamResponse.data.map(mapOpenAIFileToClaude)
        return ClaudeFilesListResponse(
            data: mappedFiles,
            hasMore: upstreamResponse.hasMore ?? false,
            firstId: mappedFiles.first?.id,
            lastId: mappedFiles.last?.id
        )
    }

    public func retrieveFile(fileID: String) async throws -> ClaudeFileObject {
        let upstreamFile = try await upstreamClient.retrieveFile(fileID: fileID)
        return mapOpenAIFileToClaude(upstreamFile)
    }

    public func createFile(filename: String, mimeType: String?, data: Data) async throws -> ClaudeFileObject {
        let upstreamFile = try await upstreamClient.uploadFile(
            filename: filename,
            mimeType: mimeType,
            data: data
        )
        return mapOpenAIFileToClaude(upstreamFile)
    }

    public func deleteFile(fileID: String) async throws -> ClaudeDeletedFileResponse {
        let upstreamResponse = try await upstreamClient.deleteFile(fileID: fileID)
        return ClaudeDeletedFileResponse(id: upstreamResponse.id, deleted: upstreamResponse.deleted)
    }

    public func retrieveFileContent(fileID: String) async throws -> OpenAIFileContentResponse {
        try await upstreamClient.retrieveFileContent(fileID: fileID)
    }

    // MARK: - Streaming Support

    public func mapModel(_ claudeModel: String) -> String {
        configuration.mapToUpstreamModel(claudeModel)
    }

    public func sendStreamingClaudeRequest(
        _ request: ClaudeMessageRequest,
        onEvent: @escaping (OpenAIUpstreamStreamEvent) async throws -> Void
    ) async throws {
        let upstreamModel = configuration.mapToUpstreamModel(request.model)
        let canonicalRequest = cappedCanonicalRequest(
            try CanonicalRequestMapper().mapClaude(request)
        )

        switch configuration.openAIUpstreamAPI {
        case .chatCompletions:
            let openAIRequest = try CanonicalOpenAIRequestBuilder()
                .buildChatCompletionRequest(
                    from: canonicalRequest,
                    modelOverride: upstreamModel
                )
                .payload
            try await upstreamClient.streamCompletion(request: openAIRequest, onEvent: onEvent)

        case .responses:
            let openAIRequest = try CanonicalOpenAIRequestBuilder()
                .buildResponsesRequest(
                    from: canonicalRequest,
                    modelOverride: upstreamModel
                )
                .payload
            try await upstreamClient.streamResponses(request: openAIRequest, onEvent: onEvent)
        }
    }

    private func mapOpenAIFileToClaude(_ file: OpenAIFileObject) -> ClaudeFileObject {
        let createdAtDate = file.createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(timeIntervalSince1970: 0)
        let filename = file.filename?.isEmpty == false ? file.filename! : file.id
        return ClaudeFileObject(
            id: file.id,
            filename: filename,
            mimeType: file.mimeType ?? inferMimeType(fromFilename: filename),
            sizeBytes: file.bytes ?? 0,
            createdAt: SharedFormatters.iso8601String(from: createdAtDate),
            downloadable: true
        )
    }

    private func inferMimeType(fromFilename filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "txt":
            return "text/plain"
        case "md":
            return "text/markdown"
        case "json":
            return "application/json"
        case "csv":
            return "text/csv"
        case "pdf":
            return "application/pdf"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "html":
            return "text/html"
        case "xml":
            return "application/xml"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
    }

    private func cappedCanonicalRequest(_ request: CanonicalRequest) -> CanonicalRequest {
        guard let cap = configuration.maxOutputTokens, cap > 0,
              let current = request.generationConfig.maxOutputTokens,
              current > cap else {
            return request
        }

        return CanonicalRequest(
            modelHint: request.modelHint,
            system: request.system,
            items: request.items,
            tools: request.tools,
            toolConfig: request.toolConfig,
            generationConfig: CanonicalGenerationConfig(
                maxOutputTokens: cap,
                temperature: request.generationConfig.temperature,
                topP: request.generationConfig.topP,
                topK: request.generationConfig.topK,
                stopSequences: request.generationConfig.stopSequences,
                stream: request.generationConfig.stream
            ),
            metadata: request.metadata,
            rawExtensions: request.rawExtensions
        )
    }

    // MARK: - Error Handling

    public func buildErrorResult(error: Error) -> ClaudeProxyErrorResult {
        let errorType: String
        let errorMessage: String
        let statusCode: Int
        let requestID: String?

        switch error {
        case let configError as ConfigurationError:
            errorType = "invalid_request_error"
            errorMessage = configError.localizedDescription
            statusCode = 400
            requestID = nil

        case let conversionError as ConversionError:
            errorType = "invalid_request_error"
            errorMessage = conversionError.localizedDescription
            statusCode = 400
            requestID = nil

        case let upstreamError as UpstreamError:
            switch upstreamError {
            case .httpError(let upstreamStatusCode, let upstreamMessage, let upstreamRequestID):
                errorType = claudeErrorType(forHTTPStatus: upstreamStatusCode)
                errorMessage = upstreamErrorMessage(
                    from: upstreamMessage,
                    statusCode: upstreamStatusCode
                )
                statusCode = upstreamStatusCode
                requestID = upstreamRequestID
            case .invalidURL(let url):
                errorType = "api_error"
                errorMessage = "Invalid upstream URL: \(url)"
                statusCode = 500
                requestID = nil
            case .invalidResponse(let message):
                errorType = "api_error"
                errorMessage = "Invalid response: \(message)"
                statusCode = 500
                requestID = nil
            case .decodingFailed(let message):
                errorType = "api_error"
                errorMessage = "Decoding failed: \(message)"
                statusCode = 500
                requestID = nil
            case .streamingFailed(let message):
                errorType = "api_error"
                errorMessage = "Streaming failed: \(message)"
                statusCode = 500
                requestID = nil
            }

        default:
            errorType = "api_error"
            errorMessage = error.localizedDescription
            statusCode = 500
            requestID = nil
        }

        return ClaudeProxyErrorResult(
            response: ClaudeErrorResponse(
                type: "error",
                error: ClaudeError(
                    type: errorType,
                    message: errorMessage
                ),
                requestID: requestID
            ),
            statusCode: statusCode
        )
    }

    public func buildErrorResponse(error: Error) -> ClaudeErrorResponse {
        buildErrorResult(error: error).response
    }

    private func claudeErrorType(forHTTPStatus statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return "invalid_request_error"
        case 401:
            return "authentication_error"
        case 402:
            return "billing_error"
        case 403:
            return "permission_error"
        case 404:
            return "not_found_error"
        case 413:
            return "request_too_large"
        case 429:
            return "rate_limit_error"
        case 504:
            return "timeout_error"
        case 529:
            return "overloaded_error"
        case 400..<500:
            return "invalid_request_error"
        default:
            return "api_error"
        }
    }

    private func upstreamErrorMessage(from rawMessage: String, statusCode: Int) -> String {
        if let data = rawMessage.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObject = object["error"] as? [String: Any],
               let message = errorObject["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let message = object["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let errorMessage = object["error"] as? String,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return errorMessage
            }
        }

        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        return "Upstream request failed with HTTP \(statusCode)."
    }
}
