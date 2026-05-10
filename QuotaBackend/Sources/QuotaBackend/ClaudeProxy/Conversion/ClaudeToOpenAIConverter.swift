import Foundation

// MARK: - Claude to OpenAI Converter

// Reference converter retained as a regression baseline for tests.
// Production request building now flows through the canonical layer.
public struct ClaudeToOpenAIConverter {

    public init() {}

    // MARK: - Request Conversion

    public func convert(
        request: ClaudeMessageRequest,
        upstreamModel: String
    ) throws -> OpenAIChatCompletionRequest {
        var openAIMessages: [OpenAIChatMessage] = []

        // Add system message if present
        if let system = request.system, !system.isEmpty {
            openAIMessages.append(OpenAIChatMessage(
                role: "system",
                content: .text(system)
            ))
        }

        // Convert Claude messages to OpenAI messages
        for claudeMsg in request.messages {
            let convertedMessages = try convertMessage(claudeMsg)
            openAIMessages.append(contentsOf: convertedMessages)
        }

        // Convert tools if present
        let openAITools = request.tools?.map { convertTool($0) }

        // Convert tool choice
        let openAIToolChoice = request.toolChoice.map { convertToolChoice($0) }

        return OpenAIChatCompletionRequest(
            model: upstreamModel,
            messages: openAIMessages,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens,
            stop: request.stopSequences,
            stream: request.stream,
            tools: openAITools,
            toolChoice: openAIToolChoice,
            parallelToolCalls: mapParallelToolCalls(from: request.toolChoice)
        )
    }

    // MARK: - Message Conversion

    private func convertMessage(_ message: ClaudeMessage) throws -> [OpenAIChatMessage] {
        switch message.content {
        case .text(let text):
            return [OpenAIChatMessage(
                role: message.role,
                content: .text(text)
            )]

        case .blocks(let blocks):
            return try convertBlocksMessage(role: message.role, blocks: blocks)
        }
    }

    private func convertBlocksMessage(role: String, blocks: [ClaudeContentBlock]) throws -> [OpenAIChatMessage] {
        // Check if this is an assistant message with tool calls
        let toolUseBlocks = blocks.compactMap { block -> ClaudeToolUseBlock? in
            if case .toolUse(let toolUse) = block {
                return toolUse
            }
            return nil
        }

        if !toolUseBlocks.isEmpty && role == "assistant" {
            // Convert to assistant message with tool calls
            let toolCalls = try toolUseBlocks.map { try convertToolUseToToolCall($0) }
            return [OpenAIChatMessage(
                role: "assistant",
                content: try makeRegularContent(from: blocks),
                toolCalls: toolCalls
            )]
        }

        // Check if this is a user message with tool results
        if role == "user" && blocks.contains(where: {
            if case .toolResult = $0 { return true }
            return false
        }) {
            return try convertUserBlocksMessage(blocks)
        }

        guard let message = try makeRegularMessage(role: role, from: blocks) else {
            return []
        }

        return [message]
    }

    private func convertContentBlock(_ block: ClaudeContentBlock) throws -> OpenAIContentPart? {
        switch block {
        case .text(let textBlock):
            return .text(OpenAITextPart(text: textBlock.text))

        case .image(let imageBlock):
            if imageBlock.source.type == "url", let url = imageBlock.source.url {
                return .imageUrl(OpenAIImageUrlPart(
                    imageUrl: OpenAIImageUrl(url: url)
                ))
            }
            guard let mediaType = imageBlock.source.mediaType,
                  let data = imageBlock.source.data else {
                return nil
            }
            let dataURL = "data:\(mediaType);base64,\(data)"
            return .imageUrl(OpenAIImageUrlPart(
                imageUrl: OpenAIImageUrl(url: dataURL)
            ))

        case .document(let documentBlock):
            return convertDocumentBlock(documentBlock)

        case .toolUse, .toolResult, .thinking, .redactedThinking, .unknown:
            return nil
        }
    }

    // MARK: - Tool Conversion

    private func convertTool(_ tool: ClaudeTool) -> OpenAITool {
        OpenAITool(
            type: "function",
            function: OpenAIFunction(
                name: tool.name,
                description: tool.description,
                parameters: tool.inputSchema
            )
        )
    }

    private func convertToolChoice(_ choice: ClaudeToolChoice) -> OpenAIToolChoice {
        switch choice.type {
        case "none":
            return .none
        case "auto":
            return .auto
        case "any":
            return .required
        case "tool":
            if let name = choice.name {
                return .function(name)
            }
            return .auto
        default:
            return .auto
        }
    }

    private func convertToolUseToToolCall(_ toolUse: ClaudeToolUseBlock) throws -> OpenAIToolCall {
        let argumentsData = try JSONSerialization.data(withJSONObject: toolUse.input.mapValues(\.foundationValue))
        let argumentsString = String(data: argumentsData, encoding: .utf8) ?? "{}"

        return OpenAIToolCall(
            id: toolUse.id,
            type: "function",
            function: OpenAIFunctionCall(
                name: toolUse.name,
                arguments: argumentsString
            )
        )
    }

    private func convertUserBlocksMessage(_ blocks: [ClaudeContentBlock]) throws -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = []
        var pendingRegularBlocks: [ClaudeContentBlock] = []

        func flushPendingRegularBlocks() throws {
            guard let message = try makeRegularMessage(role: "user", from: pendingRegularBlocks) else {
                pendingRegularBlocks.removeAll()
                return
            }
            messages.append(message)
            pendingRegularBlocks.removeAll()
        }

        for block in blocks {
            if case .toolResult(let result) = block {
                try flushPendingRegularBlocks()
                messages.append(OpenAIChatMessage(
                    role: "tool",
                    content: try makeToolResultContent(from: result),
                    toolCallId: result.toolUseId
                ))
            } else {
                pendingRegularBlocks.append(block)
            }
        }

        try flushPendingRegularBlocks()
        return messages
    }

    private func makeRegularMessage(
        role: String,
        from blocks: [ClaudeContentBlock]
    ) throws -> OpenAIChatMessage? {
        guard let content = try makeRegularContent(from: blocks) else {
            return nil
        }

        return OpenAIChatMessage(role: role, content: content)
    }

    private func makeRegularContent(from blocks: [ClaudeContentBlock]) throws -> OpenAIMessageContent? {
        let parts = try blocks.compactMap { try convertContentBlock($0) }
        guard !parts.isEmpty else { return nil }

        if parts.count == 1, case .text(let textPart) = parts[0] {
            return .text(textPart.text)
        }

        return .parts(parts)
    }

    private func makeToolResultContent(from result: ClaudeToolResultBlock) throws -> OpenAIMessageContent {
        guard let contentBlocks = result.contentBlocks else {
            return .text(result.content ?? "")
        }

        let parts = try contentBlocks.compactMap { try convertContentBlock($0) }
        guard !parts.isEmpty else {
            return .text(result.content ?? "")
        }

        let containsNonTextPart = parts.contains { part in
            if case .text = part {
                return false
            }
            return true
        }

        if !containsNonTextPart {
            let joinedText = parts.compactMap { part -> String? in
                guard case .text(let textPart) = part else { return nil }
                return textPart.text
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            return .text(joinedText.isEmpty ? (result.content ?? "") : joinedText)
        }

        return .parts(parts)
    }

    private func convertDocumentBlock(_ block: ClaudeDocumentBlock) -> OpenAIContentPart? {
        guard let sourceType = block.source["type"]?.value as? String else {
            return documentFallbackTextPart(from: block, sourceType: nil)
        }

        switch sourceType {
        case "file":
            guard let fileId = block.source["file_id"]?.value as? String else {
                return documentFallbackTextPart(
                    from: block,
                    sourceType: sourceType,
                    detail: "missing file_id"
                )
            }
            return .inputFile(OpenAIFilePart(fileId: fileId, filename: block.title))
        case "text":
            if let text = extractDocumentInlineText(from: block.source) {
                return .text(OpenAITextPart(text: renderInlineDocumentText(from: block, body: text)))
            }
            return documentFallbackTextPart(
                from: block,
                sourceType: sourceType,
                detail: "missing inline text payload"
            )
        case "content":
            if let text = extractDocumentContentText(from: block.source["content"]?.value) {
                return .text(OpenAITextPart(text: renderInlineDocumentText(from: block, body: text)))
            }
            return documentFallbackTextPart(
                from: block,
                sourceType: sourceType,
                detail: "missing content blocks"
            )
        case "url":
            let url = block.source["url"]?.value as? String
            return documentFallbackTextPart(from: block, sourceType: sourceType, detail: url)
        case "base64":
            let mediaType = block.source["media_type"]?.value as? String
            return documentFallbackTextPart(from: block, sourceType: sourceType, detail: mediaType)
        default:
            return documentFallbackTextPart(from: block, sourceType: sourceType)
        }
    }

    private func extractDocumentInlineText(from source: [String: AnyCodable]) -> String? {
        if let text = source["text"]?.value as? String, !text.isEmpty {
            return text
        }
        if let data = source["data"]?.value as? String, !data.isEmpty {
            return data
        }
        return nil
    }

    private func extractDocumentContentText(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.isEmpty ? nil : text
        case let dictionary as [String: AnyCodable]:
            if let type = dictionary["type"]?.value as? String,
               type == "text",
               let text = dictionary["text"]?.value as? String,
               !text.isEmpty {
                return text
            }
            if let nested = dictionary["content"]?.value {
                return extractDocumentContentText(from: nested)
            }
            return nil
        case let array as [AnyCodable]:
            let text = array.compactMap { extractDocumentContentText(from: $0.value) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    private func renderInlineDocumentText(from block: ClaudeDocumentBlock, body: String) -> String {
        var lines: [String] = []
        if let title = block.title, !title.isEmpty {
            lines.append("Document title: \(title)")
        }
        if let context = block.context, !context.isEmpty {
            lines.append("Document context: \(context)")
        }
        lines.append("Document content:")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private func documentFallbackTextPart(
        from block: ClaudeDocumentBlock,
        sourceType: String?,
        detail: String? = nil
    ) -> OpenAIContentPart {
        var segments = ["[Claude document degraded during OpenAI proxy conversion]"]
        segments.append("source.type=\(sourceType ?? "unknown")")
        if let title = block.title, !title.isEmpty {
            segments.append("title=\(title)")
        }
        if let context = block.context, !context.isEmpty {
            segments.append("context=\(context)")
        }
        if let detail, !detail.isEmpty {
            segments.append("detail=\(detail)")
        }
        return .text(OpenAITextPart(text: segments.joined(separator: "\n")))
    }

    private func mapParallelToolCalls(from choice: ClaudeToolChoice?) -> Bool? {
        guard let disableParallelToolUse = choice?.disableParallelToolUse else {
            return nil
        }

        return !disableParallelToolUse
    }
}
