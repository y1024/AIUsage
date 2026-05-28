import Foundation

public enum CanonicalMappingError: Error, LocalizedError {
    case noChoicesInResponse
    case invalidJSONObject(String)

    public var errorDescription: String? {
        switch self {
        case .noChoicesInResponse:
            return "Expected at least one choice in the upstream response."
        case .invalidJSONObject(let context):
            return "Failed to serialize JSON object while mapping canonical model: \(context)"
        }
    }
}

public struct CanonicalRequestMapper {
    public init() {}

    public func mapClaude(_ request: ClaudeMessageRequest) throws -> CanonicalRequest {
        var systemParts: [CanonicalContentPart] = []
        if let systemBlocks = request.systemBlocks, !systemBlocks.isEmpty {
            systemParts.append(contentsOf: mapClaudeSystemBlocks(systemBlocks))
        } else if let system = request.system, !system.isEmpty {
            systemParts.append(.text(CanonicalTextPart(text: system)))
        }

        var items: [CanonicalConversationItem] = []
        for message in request.messages {
            items.append(contentsOf: try mapClaudeMessage(message))
        }

        var metadata: CanonicalJSONMap = [:]
        if let userId = request.metadata?.userId {
            metadata["user_id"] = AnyCodable(userId)
        }

        return CanonicalRequest(
            modelHint: request.model,
            system: systemParts,
            items: items,
            tools: request.tools?.map(mapClaudeTool) ?? [],
            toolConfig: mapClaudeToolConfig(request.toolChoice),
            generationConfig: CanonicalGenerationConfig(
                maxOutputTokens: request.maxTokens,
                temperature: request.temperature,
                topP: request.topP,
                topK: request.topK,
                stopSequences: request.stopSequences ?? [],
                stream: request.stream
            ),
            metadata: metadata
        )
    }

    public func mapOpenAIChatCompletions(_ request: OpenAIChatCompletionRequest) throws -> CanonicalRequest {
        let mapped = try mapOpenAIChatMessages(request.messages)

        return CanonicalRequest(
            modelHint: request.model,
            system: mapped.system,
            items: mapped.items,
            tools: request.tools?.map(mapOpenAIChatTool) ?? [],
            toolConfig: mapOpenAIChatToolConfig(request.toolChoice, parallelToolCalls: request.parallelToolCalls),
            generationConfig: CanonicalGenerationConfig(
                maxOutputTokens: request.maxTokens,
                temperature: request.temperature,
                topP: request.topP,
                stopSequences: request.stop ?? [],
                stream: request.stream
            ),
            metadata: [:]
        )
    }

    public func mapOpenAIResponses(_ request: OpenAIResponsesRequest) throws -> CanonicalRequest {
        var systemParts: [CanonicalContentPart] = []
        var items: [CanonicalConversationItem] = []

        for inputItem in request.input {
            switch inputItem {
            case .message(let message):
                let role = canonicalRole(from: message.role)
                let mappedMessage = CanonicalMessage(
                    role: role,
                    phase: message.phase.map(canonicalPhase(from:)),
                    parts: mapResponsesInputContent(message.content)
                )
                if case .system = role {
                    systemParts.append(contentsOf: mappedMessage.parts)
                } else {
                    items.append(.message(mappedMessage))
                }

            case .functionCall(let functionCall):
                items.append(.toolCall(mapResponsesFunctionCall(functionCall)))

            case .functionCallOutput(let output):
                items.append(.toolResult(mapResponsesFunctionCallOutput(output)))

            case .reasoning(let reasoning):
                items.append(.reasoning(mapResponsesReasoning(reasoning)))

            case .compaction(let compaction):
                items.append(.compaction(CanonicalCompactionItem(
                    id: compaction.id,
                    encryptedContent: compaction.encryptedContent
                )))

            case .computerCall(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .computerCallOutput(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .toolSearchCall(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .toolSearchOutput(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .localShellCall(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .localShellCallOutput(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: nil, status: event.status, payload: event)))
            case .shellCall(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .shellCallOutput(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .applyPatchCall(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .applyPatchCallOutput(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .mcpListTools(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: nil, status: nil, payload: event)))
            case .mcpApprovalRequest(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: nil, payload: event)))
            case .mcpApprovalResponse(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.approvalRequestId, status: nil, payload: event)))
            case .mcpCall(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: event.status, payload: event)))
            case .customToolCall(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            case .customToolCallOutput(let event):
                items.append(.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event)))
            }
        }

        return CanonicalRequest(
            modelHint: request.model,
            system: systemParts,
            items: items,
            tools: request.tools?.map(mapOpenAIResponsesTool) ?? [],
            toolConfig: mapOpenAIResponsesToolConfig(request.toolChoice, parallelToolCalls: request.parallelToolCalls),
            generationConfig: CanonicalGenerationConfig(
                maxOutputTokens: request.maxOutputTokens,
                temperature: request.temperature,
                topP: request.topP,
                stream: request.stream
            ),
            metadata: [:],
            rawExtensions: request.store.map { [CanonicalVendorExtension(vendor: "openai_responses", key: "store", value: AnyCodable($0))] } ?? []
        )
    }
}

public struct CanonicalResponseMapper {
    public init() {}

    public func mapClaude(_ response: ClaudeMessageResponse) throws -> CanonicalResponse {
        let items = try mapClaudeBlocks(response.content, role: canonicalRole(from: response.role))
        return CanonicalResponse(
            id: response.id,
            model: response.model,
            items: items,
            stop: CanonicalStop(
                reason: canonicalStopReason(fromClaude: response.stopReason),
                sequence: response.stopSequence
            ),
            usage: CanonicalUsage(
                inputTokens: response.usage.inputTokens,
                outputTokens: response.usage.outputTokens,
                totalTokens: nil,
                cacheCreationInputTokens: response.usage.cacheCreationInputTokens,
                cacheReadInputTokens: response.usage.cacheReadInputTokens
            )
        )
    }

    public func mapOpenAIChatCompletions(_ response: OpenAIChatCompletionResponse) throws -> CanonicalResponse {
        guard let firstChoice = response.choices.first else {
            throw CanonicalMappingError.noChoicesInResponse
        }

        let mapped = try mapOpenAIChatMessages([firstChoice.message])
        return CanonicalResponse(
            id: response.id,
            model: response.model,
            items: mapped.items,
            stop: CanonicalStop(reason: canonicalStopReason(fromOpenAI: firstChoice.finishReason)),
            usage: response.usage.map { u in
                CanonicalUsage(
                    inputTokens: u.effectiveInputTokens,
                    outputTokens: u.completionTokens,
                    totalTokens: u.totalTokens,
                    cacheCreationInputTokens: nil,
                    cacheReadInputTokens: u.effectiveCachedTokens
                )
            }
        )
    }

    public func mapOpenAIResponses(_ response: OpenAIResponsesResponse) throws -> CanonicalResponse {
        let items = try response.output.flatMap(mapResponsesOutputItem)
        return CanonicalResponse(
            id: response.id,
            model: response.model,
            items: items,
            stop: CanonicalStop(reason: canonicalStopReason(fromResponses: response)),
            usage: response.usage.map { u in
                let cached = u.inputTokensDetails?.cachedTokens
                return CanonicalUsage(
                    inputTokens: cached.map { max(u.inputTokens - $0, 0) } ?? u.inputTokens,
                    outputTokens: u.outputTokens,
                    totalTokens: u.totalTokens,
                    cacheReadInputTokens: cached
                )
            }
        )
    }
}

// MARK: - Claude Mapping Helpers

private func mapClaudeSystemBlocks(_ blocks: [ClaudeSystemBlock]) -> [CanonicalContentPart] {
    blocks.compactMap { block in
        guard let text = block.text else { return nil }
        var extensions: [CanonicalVendorExtension] = []
        if let cacheControl = block.cacheControl {
            extensions.append(CanonicalVendorExtension(
                vendor: "claude",
                key: "cache_control",
                value: AnyCodable(cacheControl.mapValues(\.value))
            ))
        }
        return .text(CanonicalTextPart(text: text, rawExtensions: extensions))
    }
}

private func mapClaudeMessage(_ message: ClaudeMessage) throws -> [CanonicalConversationItem] {
    switch message.content {
    case .text(let text):
        return [.message(CanonicalMessage(
            role: canonicalRole(from: message.role),
            parts: [.text(CanonicalTextPart(text: text))]
        ))]
    case .blocks(let blocks):
        return try mapClaudeBlocks(blocks, role: canonicalRole(from: message.role))
    }
}

private func mapClaudeBlocks(
    _ blocks: [ClaudeContentBlock],
    role: CanonicalRole
) throws -> [CanonicalConversationItem] {
    var items: [CanonicalConversationItem] = []
    var pendingParts: [CanonicalContentPart] = []

    func flushMessageIfNeeded() {
        guard !pendingParts.isEmpty else { return }
        items.append(.message(CanonicalMessage(role: role, parts: pendingParts)))
        pendingParts.removeAll()
    }

    for block in blocks {
        switch block {
        case .text(let text):
            var extensions: [CanonicalVendorExtension] = []
            if let cc = text.cacheControl {
                extensions.append(CanonicalVendorExtension(
                    vendor: "claude",
                    key: "cache_control",
                    value: AnyCodable(cc.mapValues(\.value))
                ))
            }
            pendingParts.append(.text(CanonicalTextPart(text: text.text, rawExtensions: extensions)))
        case .image(let image):
            if image.source.type == "url", let url = image.source.url {
                pendingParts.append(.image(CanonicalImagePart(
                    source: .url,
                    data: url,
                    mediaType: image.source.mediaType
                )))
            } else {
                pendingParts.append(.image(CanonicalImagePart(
                    source: canonicalImageSource(from: image.source.type),
                    data: image.source.data ?? "",
                    mediaType: image.source.mediaType
                )))
            }
        case .document(let document):
            pendingParts.append(.document(mapClaudeDocument(document)))
        case .unknown(let unknown):
            pendingParts.append(.unknown(CanonicalUnknownPart(
                type: unknown.type,
                payload: AnyCodable(unknown.payload.mapValues(\.value))
            )))
        case .toolUse(let toolUse):
            flushMessageIfNeeded()
            items.append(.toolCall(try CanonicalToolCall(
                id: toolUse.id,
                name: toolUse.name,
                inputJSON: canonicalJSONString(from: toolUse.input.mapValues(\.foundationValue), context: "Claude tool_use")
            )))
        case .toolResult(let toolResult):
            flushMessageIfNeeded()
            items.append(.toolResult(try mapClaudeToolResult(toolResult)))
        case .thinking(let thinking):
            flushMessageIfNeeded()
            items.append(.reasoning(CanonicalReasoningItem(
                fullText: thinking.thinking,
                signature: thinking.signature
            )))
        case .redactedThinking(let redacted):
            flushMessageIfNeeded()
            items.append(.reasoning(CanonicalReasoningItem(
                redacted: true,
                rawExtensions: [
                    CanonicalVendorExtension(vendor: "claude", key: "redacted_data", value: AnyCodable(redacted.data))
                ]
            )))
        }
    }

    flushMessageIfNeeded()
    return items
}

private func mapClaudeDocument(_ document: ClaudeDocumentBlock) -> CanonicalDocumentPart {
    let sourceType = document.source["type"]?.value as? String
    let source: CanonicalDocumentSource

    switch sourceType {
    case "file":
        source = .fileID(document.source["file_id"]?.value as? String ?? "")
    case "text":
        source = .inlineText(document.source["text"]?.value as? String ?? "")
    case "url":
        source = .url(document.source["url"]?.value as? String ?? "")
    case "base64":
        source = .base64(
            data: document.source["data"]?.value as? String ?? "",
            mediaType: document.source["media_type"]?.value as? String
        )
    default:
        source = .unknown(AnyCodable(document.source.mapValues(\.value)))
    }

    return CanonicalDocumentPart(
        source: source,
        title: document.title,
        context: document.context,
        citations: document.citations,
        rawExtensions: document.cacheControl.map {
            [
                CanonicalVendorExtension(
                    vendor: "claude",
                    key: "cache_control",
                    value: AnyCodable($0.mapValues(\.value))
                )
            ]
        } ?? []
    )
}

private func mapClaudeTool(_ tool: ClaudeTool) -> CanonicalToolDefinition {
    CanonicalToolDefinition(
        kind: .function,
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
        execution: .client,
        vendorType: "claude_function",
        flags: CanonicalToolDefinitionFlags(
            eagerInputStreaming: tool.eagerInputStreaming
        )
    )
}

private func mapClaudeToolConfig(_ choice: ClaudeToolChoice?) -> CanonicalToolConfig? {
    guard let choice else { return nil }
    let canonicalChoice: CanonicalToolChoice
    switch choice.type {
    case "none":
        canonicalChoice = .none
    case "auto":
        canonicalChoice = .auto
    case "any":
        canonicalChoice = .required
    case "tool":
        canonicalChoice = choice.name.map(CanonicalToolChoice.specific) ?? .required
    default:
        canonicalChoice = .unknown(choice.type)
    }

    return CanonicalToolConfig(
        choice: canonicalChoice,
        parallelCallsAllowed: choice.disableParallelToolUse.map(!)
    )
}

private func mapClaudeToolResult(_ result: ClaudeToolResultBlock) throws -> CanonicalToolResult {
    let parts: [CanonicalContentPart]
    if let contentBlocks = result.contentBlocks {
        parts = contentBlocks.compactMap { block in
            switch block {
            case .text(let text):
                return .text(CanonicalTextPart(text: text.text))
            case .image(let image):
                if image.source.type == "url", let url = image.source.url {
                    return .image(CanonicalImagePart(
                        source: .url,
                        data: url,
                        mediaType: image.source.mediaType
                    ))
                }
                return .image(CanonicalImagePart(
                    source: canonicalImageSource(from: image.source.type),
                    data: image.source.data ?? "",
                    mediaType: image.source.mediaType
                ))
            case .document(let document):
                return .document(mapClaudeDocument(document))
            case .thinking(let thinking):
                return .reasoningText(CanonicalReasoningTextPart(text: thinking.thinking))
            case .redactedThinking(let redacted):
                return .unknown(CanonicalUnknownPart(
                    type: redacted.type,
                    payload: AnyCodable(["data": redacted.data])
                ))
            case .unknown(let unknown):
                return .unknown(CanonicalUnknownPart(
                    type: unknown.type,
                    payload: AnyCodable(unknown.payload.mapValues(\.value))
                ))
            case .toolUse(let toolUse):
                return .unknown(CanonicalUnknownPart(
                    type: toolUse.type,
                    payload: AnyCodable([
                        "id": toolUse.id,
                        "name": toolUse.name,
                        "input": toolUse.input.mapValues(\.value)
                    ])
                ))
            case .toolResult(let nested):
                return .unknown(CanonicalUnknownPart(
                    type: nested.type,
                    payload: AnyCodable([
                        "tool_use_id": nested.toolUseId,
                        "content": nested.content ?? ""
                    ])
                ))
            }
        }
    } else {
        parts = result.content.map { [.text(CanonicalTextPart(text: $0))] } ?? []
    }

    return CanonicalToolResult(
        toolCallID: result.toolUseId,
        isError: result.isError,
        parts: parts,
        rawTextFallback: result.content
    )
}

// MARK: - OpenAI Chat Mapping Helpers

private func mapOpenAIChatMessages(
    _ messages: [OpenAIChatMessage]
) throws -> (system: [CanonicalContentPart], items: [CanonicalConversationItem]) {
    var systemParts: [CanonicalContentPart] = []
    var items: [CanonicalConversationItem] = []

    for message in messages {
        let role = canonicalRole(from: message.role)
        if case .system = role {
            systemParts.append(contentsOf: mapOpenAIMessageContent(message.content))
            continue
        }

        if case .tool = role {
            let parts = mapOpenAIMessageContent(message.content)
            items.append(.toolResult(CanonicalToolResult(
                toolCallID: message.toolCallId ?? "",
                parts: parts,
                rawTextFallback: flattenOpenAIMessageContent(message.content)
            )))
            continue
        }

        if case .assistant = role,
           let reasoning = message.reasoningContent, !reasoning.isEmpty {
            items.append(.reasoning(CanonicalReasoningItem(fullText: reasoning)))
        }

        let parts = mapOpenAIMessageContent(message.content)
        if !parts.isEmpty {
            items.append(.message(CanonicalMessage(role: role, parts: parts, name: message.name)))
        }

        if let toolCalls = message.toolCalls {
            for toolCall in toolCalls {
                items.append(.toolCall(CanonicalToolCall(
                    id: toolCall.id,
                    name: toolCall.function.name,
                    inputJSON: toolCall.function.arguments
                )))
            }
        }
    }

    return (systemParts, items)
}

private func mapOpenAIMessageContent(_ content: OpenAIMessageContent?) -> [CanonicalContentPart] {
    guard let content else { return [] }

    switch content {
    case .text(let text):
        return text.isEmpty ? [] : [.text(CanonicalTextPart(text: text))]
    case .parts(let parts):
        return parts.compactMap { part in
            switch part {
            case .text(let textPart):
                return .text(CanonicalTextPart(text: textPart.text))
            case .imageUrl(let imagePart):
                return .image(CanonicalImagePart(
                    source: .url,
                    data: imagePart.imageUrl.url,
                    detail: imagePart.imageUrl.detail
                ))
            case .inputFile(let filePart):
                return .fileRef(CanonicalFileReference(
                    fileID: filePart.fileId,
                    filename: filePart.filename
                ))
            case .unknown:
                return nil
            }
        }
    }
}

private func flattenOpenAIMessageContent(_ content: OpenAIMessageContent?) -> String? {
    let parts = mapOpenAIMessageContent(content)
    let textParts = parts.compactMap { part -> String? in
        if case .text(let text) = part {
            return text.text
        }
        return nil
    }
    return textParts.isEmpty ? nil : textParts.joined(separator: "\n")
}

private func mapOpenAIChatTool(_ tool: OpenAITool) -> CanonicalToolDefinition {
    CanonicalToolDefinition(
        kind: tool.type == "function" ? .function : .unknown(tool.type),
        name: tool.function.name,
        description: tool.function.description,
        inputSchema: tool.function.parameters,
        execution: .client,
        vendorType: tool.type
    )
}

private func mapOpenAIChatToolConfig(
    _ choice: OpenAIToolChoice?,
    parallelToolCalls: Bool?
) -> CanonicalToolConfig? {
    guard let choice else {
        if parallelToolCalls != nil {
            return CanonicalToolConfig(choice: nil, parallelCallsAllowed: parallelToolCalls)
        }
        return nil
    }

    let canonicalChoice: CanonicalToolChoice
    switch choice {
    case .none:
        canonicalChoice = .none
    case .auto:
        canonicalChoice = .auto
    case .required:
        canonicalChoice = .required
    case .function(let name):
        canonicalChoice = .specific(name)
    }

    return CanonicalToolConfig(choice: canonicalChoice, parallelCallsAllowed: parallelToolCalls)
}

// MARK: - OpenAI Responses Mapping Helpers

private func mapResponsesInputContent(_ content: [OpenAIResponsesInputContent]) -> [CanonicalContentPart] {
    content.map { item in
        switch item {
        case .inputText(let text):
            return .text(CanonicalTextPart(text: text.text))
        case .inputImage(let image):
            return .image(CanonicalImagePart(
                source: image.fileId != nil ? .fileID : .url,
                data: image.fileId ?? image.imageURL ?? "",
                detail: image.detail
            ))
        case .inputFile(let file):
            return .fileRef(CanonicalFileReference(
                fileID: file.fileId,
                filename: file.filename
            ))
        case .outputText(let text):
            return .text(CanonicalTextPart(text: text.text))
        }
    }
}

private func mapResponsesOutputMessage(_ message: OpenAIResponsesOutputMessage) -> CanonicalMessage {
    let parts = message.content.map { content -> CanonicalContentPart in
        switch content {
        case .outputText(let text):
            return .text(CanonicalTextPart(text: text.text))
        case .refusal(let refusal):
            return .refusal(CanonicalRefusalPart(text: refusal.refusal ?? ""))
        case .other(let other):
            return .unknown(CanonicalUnknownPart(type: other.type))
        }
    }
    return CanonicalMessage(
        role: canonicalRole(from: message.role),
        phase: message.phase.map(canonicalPhase(from:)),
        parts: parts
    )
}

private func mapResponsesFunctionCall(_ functionCall: OpenAIResponsesFunctionCall) -> CanonicalToolCall {
    let status = canonicalItemStatus(functionCall.status)
    return CanonicalToolCall(
        id: functionCall.callId,
        name: functionCall.name,
        inputJSON: functionCall.arguments,
        status: status,
        partial: status.value != CanonicalItemStatus.completed.value
    )
}

private func mapResponsesFunctionCallOutput(_ output: OpenAIResponsesFunctionCallOutput) -> CanonicalToolResult {
    switch output.output {
    case .text(let text):
        return CanonicalToolResult(
            toolCallID: output.callId,
            parts: text.isEmpty ? [] : [.text(CanonicalTextPart(text: text))],
            rawTextFallback: text
        )
    case .content(let content):
        return CanonicalToolResult(
            toolCallID: output.callId,
            parts: mapResponsesInputContent(content)
        )
    }
}

private func mapResponsesReasoning(_ reasoning: OpenAIResponsesReasoningItem) -> CanonicalReasoningItem {
    CanonicalReasoningItem(
        summaryText: reasoning.summary.map(\.text).joined(separator: "\n").nilIfEmpty,
        fullText: reasoning.content?.map(\.text).joined(separator: "\n").nilIfEmpty,
        encryptedContent: reasoning.encryptedContent
    )
}

private func mapResponsesOutputItem(_ item: OpenAIResponsesOutputItem) throws -> [CanonicalConversationItem] {
    switch item {
    case .message(let message):
        return [.message(mapResponsesOutputMessage(message))]
    case .functionCall(let functionCall):
        return [.toolCall(mapResponsesFunctionCall(functionCall))]
    case .functionCallOutput(let output):
        return [.toolResult(mapResponsesFunctionCallOutput(output))]
    case .reasoning(let reasoning):
        return [.reasoning(mapResponsesReasoning(reasoning))]
    case .compaction(let compaction):
        return [.compaction(CanonicalCompactionItem(
            id: compaction.id,
            encryptedContent: compaction.encryptedContent
        ))]
    case .fileSearchCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: event.status, payload: event))]
    case .webSearchCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: event.status, payload: event))]
    case .computerCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .computerCallOutput(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .imageGenerationCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: event.status, payload: event))]
    case .codeInterpreterCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: event.status, payload: event))]
    case .toolSearchCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .toolSearchOutput(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .localShellCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .localShellCallOutput(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: event.status, payload: event))]
    case .shellCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .shellCallOutput(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .applyPatchCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .applyPatchCallOutput(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .mcpListTools(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: nil, payload: event))]
    case .mcpApprovalRequest(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: nil, payload: event))]
    case .mcpApprovalResponse(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.approvalRequestId, status: nil, payload: event))]
    case .mcpCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.id, status: event.status, payload: event))]
    case .customToolCall(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .customToolCallOutput(let event):
        return [.hostedToolEvent(try mapHostedToolEvent(vendorType: event.type, callID: event.callId, status: event.status, payload: event))]
    case .other(let event):
        return [.hostedToolEvent(CanonicalHostedToolEvent(
            vendorType: event.type,
            payload: AnyCodable(["type": event.type])
        ))]
    }
}

private func mapOpenAIResponsesTool(_ tool: OpenAIResponsesTool) -> CanonicalToolDefinition {
    let rawExtensions = (try? anyCodable(from: tool)).map {
        [CanonicalVendorExtension(vendor: "openai_responses", key: "tool_definition", value: $0)]
    } ?? []

    switch tool {
    case .function(let function):
        return CanonicalToolDefinition(
            kind: .function,
            name: function.name,
            description: function.description,
            inputSchema: function.parameters,
            execution: .client,
            vendorType: function.type,
            flags: CanonicalToolDefinitionFlags(strict: function.strict),
            rawExtensions: rawExtensions
        )
    case .custom(let custom):
        return CanonicalToolDefinition(
            kind: .custom,
            name: custom.name,
            description: custom.description,
            inputSchema: nil,
            execution: .client,
            vendorType: custom.type,
            rawExtensions: rawExtensions
        )
    case .fileSearch(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .computerUsePreview(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .webSearch(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .mcp(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .codeInterpreter(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .imageGeneration(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .localShell(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .shell(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .applyPatch(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    case .other(let tool):
        return mapHostedResponsesToolDefinition(tool, rawExtensions: rawExtensions)
    }
}

private func mapHostedResponsesToolDefinition<T: Encodable>(
    _ tool: T,
    rawExtensions: [CanonicalVendorExtension]
) -> CanonicalToolDefinition {
    CanonicalToolDefinition(
        kind: .hosted,
        name: nil,
        description: nil,
        inputSchema: nil,
        execution: .hosted,
        vendorType: responsesToolType(tool),
        rawExtensions: rawExtensions
    )
}

private func responsesToolType<T: Encodable>(_ tool: T) -> String {
    if let payload = try? anyCodable(from: tool),
       let object = payload.value as? [String: Any],
       let type = object["type"] as? String {
        return type
    }
    return "unknown"
}

private func mapOpenAIResponsesToolConfig(
    _ choice: OpenAIResponsesToolChoice?,
    parallelToolCalls: Bool?
) -> CanonicalToolConfig? {
    guard let choice else {
        if parallelToolCalls != nil {
            return CanonicalToolConfig(choice: nil, parallelCallsAllowed: parallelToolCalls)
        }
        return nil
    }

    let canonicalChoice: CanonicalToolChoice
    switch choice {
    case .none:
        canonicalChoice = .none
    case .auto:
        canonicalChoice = .auto
    case .required:
        canonicalChoice = .required
    case .function(let name):
        canonicalChoice = .specific(name)
    case .allowedTools(_, let tools):
        let names = tools.compactMap { tool -> String? in
            if case .function(let function) = tool {
                return function.name
            }
            return nil
        }
        canonicalChoice = .allowed(names)
    case .hostedTool(let type):
        canonicalChoice = .hosted(type)
    case .mcp(let serverLabel, let name):
        canonicalChoice = .unknown("mcp:\(serverLabel):\(name ?? "")")
    case .custom(let name):
        canonicalChoice = .custom(name)
    case .applyPatch:
        canonicalChoice = .hosted("apply_patch")
    case .shell:
        canonicalChoice = .hosted("shell")
    case .other(let other):
        canonicalChoice = .unknown(other.type)
    }

    return CanonicalToolConfig(choice: canonicalChoice, parallelCallsAllowed: parallelToolCalls)
}

private func mapHostedToolEvent<T: Encodable>(
    vendorType: String,
    callID: String?,
    status: String?,
    payload: T
) throws -> CanonicalHostedToolEvent {
    CanonicalHostedToolEvent(
        vendorType: vendorType,
        callID: callID,
        status: canonicalItemStatus(status),
        payload: try anyCodable(from: payload)
    )
}

// MARK: - Stop / Status Helpers

private func canonicalRole(from raw: String) -> CanonicalRole {
    switch raw {
    case "system":
        return .system
    case "user":
        return .user
    case "assistant":
        return .assistant
    case "tool":
        return .tool
    case "developer":
        return .developer
    default:
        return .unknown(raw)
    }
}

private func canonicalPhase(from phase: OpenAIResponsesAssistantPhase) -> CanonicalPhase {
    switch phase {
    case .commentary:
        return .commentary
    case .finalAnswer:
        return .finalAnswer
    }
}

private func canonicalStopReason(fromClaude raw: String?) -> CanonicalStopReason {
    switch raw {
    case "end_turn", "stop", nil:
        return .endTurn
    case "tool_use":
        return .toolUse
    case "max_tokens":
        return .maxTokens
    case "pause_turn":
        return .pauseTurn
    case "refusal":
        return .refusal
    case "model_context_window_exceeded":
        return .modelContextWindowExceeded
    default:
        return .unknown(raw ?? "unknown")
    }
}

private func canonicalStopReason(fromOpenAI raw: String?) -> CanonicalStopReason {
    switch raw {
    case "stop", "end_turn", nil:
        return .endTurn
    case "tool_calls":
        return .toolUse
    case "length":
        return .maxTokens
    case "pause_turn":
        return .pauseTurn
    case "refusal", "content_filter":
        return .refusal
    case "model_context_window_exceeded":
        return .modelContextWindowExceeded
    default:
        return .unknown(raw ?? "unknown")
    }
}

private func canonicalStopReason(fromResponses response: OpenAIResponsesResponse) -> CanonicalStopReason {
    if responseRequiresPauseTurn(response) {
        return .pauseTurn
    }

    if response.status == "incomplete" {
        return .maxTokens
    }

    if response.output.contains(where: {
        if case .functionCall = $0 { return true }
        return false
    }) {
        return .toolUse
    }

    if response.status == "failed" {
        return .error
    }

    return .endTurn
}

private func responseRequiresPauseTurn(_ response: OpenAIResponsesResponse) -> Bool {
    guard let status = response.status?.lowercased(),
          status == "incomplete" || status == "in_progress" else {
        return false
    }

    return response.output.contains(where: hostedToolItemIsPending)
}

private func hostedToolItemIsPending(_ item: OpenAIResponsesOutputItem) -> Bool {
    switch item {
    case .fileSearchCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .webSearchCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .computerCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .imageGenerationCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .codeInterpreterCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .toolSearchCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .localShellCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .shellCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .applyPatchCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    case .mcpCall(let call):
        return hostedToolStatusRequiresPauseTurn(call.status)
    default:
        return false
    }
}

private func hostedToolStatusRequiresPauseTurn(_ status: String?) -> Bool {
    guard let normalized = status?.lowercased() else {
        return true
    }

    switch normalized {
    case "completed", "failed", "cancelled", "canceled":
        return false
    default:
        return true
    }
}

private func canonicalItemStatus(_ raw: String?) -> CanonicalItemStatus {
    switch raw?.lowercased() {
    case "in_progress":
        return .inProgress
    case "completed":
        return .completed
    case "incomplete":
        return .incomplete
    case "failed":
        return .failed
    case .none:
        return .unknown("unknown")
    default:
        return .unknown(raw ?? "unknown")
    }
}

// MARK: - Serialization Helpers

private func canonicalJSONString(from jsonObject: Any, context: String) throws -> String {
    guard JSONSerialization.isValidJSONObject(jsonObject) else {
        throw CanonicalMappingError.invalidJSONObject(context)
    }
    let data = try JSONSerialization.data(withJSONObject: jsonObject)
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func anyCodable<T: Encodable>(from value: T) throws -> AnyCodable {
    let data = try JSONEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    return AnyCodable(object)
}

private func canonicalImageSource(from raw: String) -> CanonicalImageSource {
    switch raw {
    case "base64":
        return .base64
    case "url":
        return .url
    case "file", "file_id":
        return .fileID
    default:
        return .unknown(raw)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
