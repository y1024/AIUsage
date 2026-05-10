import Foundation

public struct CanonicalOpenAIRequestBuilder {
    public init() {}

    public func buildChatCompletionRequest(
        from request: CanonicalRequest,
        modelOverride: String? = nil
    ) throws -> CanonicalBuildResult<OpenAIChatCompletionRequest> {
        var lossyNotes: [CanonicalLossyNote] = []
        var messages: [OpenAIChatMessage] = []

        if let systemContent = try makeChatMessageContent(
            from: request.system,
            itemIndex: nil,
            path: "system",
            lossyNotes: &lossyNotes
        ) {
            messages.append(OpenAIChatMessage(role: "system", content: systemContent))
        }

        var pendingReasoningText: String?
        var index = 0
        while index < request.items.count {
            switch request.items[index] {
            case .message(let message):
                let currentIndex = index
                if case .assistant = message.role {
                    let (nextIndex, toolCalls) = try collectFollowingAssistantToolCalls(
                        in: request.items,
                        start: index + 1,
                        lossyNotes: &lossyNotes
                    )
                    let content = try makeChatMessageContent(
                        from: message.parts,
                        itemIndex: currentIndex,
                        path: "items[\(currentIndex)].message.parts",
                        lossyNotes: &lossyNotes
                    )
                    let reasoning = pendingReasoningText
                    pendingReasoningText = nil
                    if content != nil || !toolCalls.isEmpty || reasoning != nil {
                        messages.append(OpenAIChatMessage(
                            role: message.role.value,
                            content: content,
                            name: message.name,
                            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                            reasoningContent: reasoning
                        ))
                    }
                    index = nextIndex
                    continue
                }

                if case .tool = message.role {
                    appendLossyNote(
                        to: &lossyNotes,
                        code: "chat_tool_role_message_unsupported",
                        message: "Canonical message(role: tool) cannot be losslessly reconstructed without a tool call id; skipping in chat builder.",
                        itemIndex: currentIndex,
                        path: "items[\(currentIndex)]"
                    )
                    index += 1
                    continue
                }

                let content = try makeChatMessageContent(
                    from: message.parts,
                    itemIndex: currentIndex,
                    path: "items[\(currentIndex)].message.parts",
                    lossyNotes: &lossyNotes
                )
                if let content {
                    messages.append(OpenAIChatMessage(
                        role: message.role.value,
                        content: content,
                        name: message.name
                    ))
                } else {
                    appendLossyNote(
                        to: &lossyNotes,
                        code: "chat_empty_message_skipped",
                        message: "Canonical message had no representable OpenAI chat content and was skipped.",
                        itemIndex: currentIndex,
                        path: "items[\(currentIndex)]"
                    )
                }
                index += 1

            case .reasoning(let reasoning):
                let reasoningText = reasoning.fullText ?? reasoning.summaryText
                if let text = reasoningText, !text.isEmpty {
                    pendingReasoningText = text
                }
                let (nextIndex, toolCalls) = try collectFollowingAssistantToolCalls(
                    in: request.items,
                    start: index + 1,
                    lossyNotes: &lossyNotes
                )
                if !toolCalls.isEmpty {
                    messages.append(OpenAIChatMessage(
                        role: "assistant",
                        content: nil,
                        toolCalls: toolCalls,
                        reasoningContent: pendingReasoningText
                    ))
                    pendingReasoningText = nil
                    index = nextIndex
                } else {
                    index += 1
                }

            case .toolCall:
                let (nextIndex, toolCalls) = try collectConsecutiveToolCalls(
                    in: request.items,
                    start: index,
                    lossyNotes: &lossyNotes
                )
                messages.append(OpenAIChatMessage(role: "assistant", content: nil, toolCalls: toolCalls))
                index = nextIndex

            case .toolResult(let result):
                messages.append(OpenAIChatMessage(
                    role: "tool",
                    content: try makeChatToolResultContent(
                        from: result,
                        itemIndex: index,
                        lossyNotes: &lossyNotes
                    ),
                    toolCallId: result.toolCallID
                ))
                index += 1

            case .compaction:
                appendLossyNote(
                    to: &lossyNotes,
                    code: "chat_compaction_item_skipped",
                    message: "Canonical compaction items are not representable in chat/completions input and were skipped.",
                    itemIndex: index,
                    path: "items[\(index)]"
                )
                index += 1

            case .hostedToolEvent:
                appendLossyNote(
                    to: &lossyNotes,
                    code: "chat_hosted_tool_event_skipped",
                    message: "Canonical hosted tool events are not representable in chat/completions input and were skipped.",
                    itemIndex: index,
                    path: "items[\(index)]"
                )
                index += 1
            }
        }

        if let trailingReasoning = pendingReasoningText {
            messages.append(OpenAIChatMessage(
                role: "assistant",
                reasoningContent: trailingReasoning
            ))
            pendingReasoningText = nil
        }

        let payload = OpenAIChatCompletionRequest(
            model: modelOverride ?? request.modelHint,
            messages: messages,
            temperature: request.generationConfig.temperature,
            topP: request.generationConfig.topP,
            maxTokens: request.generationConfig.maxOutputTokens,
            stop: request.generationConfig.stopSequences.isEmpty ? nil : request.generationConfig.stopSequences,
            stream: request.generationConfig.stream,
            tools: buildChatTools(from: request.tools, lossyNotes: &lossyNotes),
            toolChoice: buildChatToolChoice(from: request.toolConfig?.choice, lossyNotes: &lossyNotes),
            parallelToolCalls: request.toolConfig?.parallelCallsAllowed
        )
        return CanonicalBuildResult(payload: payload, lossyNotes: lossyNotes)
    }

    public func buildResponsesRequest(
        from request: CanonicalRequest,
        modelOverride: String? = nil
    ) throws -> CanonicalBuildResult<OpenAIResponsesRequest> {
        var lossyNotes: [CanonicalLossyNote] = []
        var input: [OpenAIResponsesInputItem] = []

        let systemContent = makeResponsesInputContent(
            from: request.system,
            role: "system",
            itemIndex: nil,
            path: "system",
            lossyNotes: &lossyNotes
        )
        if !systemContent.isEmpty {
            input.append(.message(OpenAIResponsesInputMessage(role: "system", content: systemContent)))
        }

        for (itemIndex, item) in request.items.enumerated() {
            switch item {
            case .message(let message):
                let content = makeResponsesInputContent(
                    from: message.parts,
                    role: message.role.value,
                    itemIndex: itemIndex,
                    path: "items[\(itemIndex)].message.parts",
                    lossyNotes: &lossyNotes
                )
                guard !content.isEmpty else {
                    appendLossyNote(
                        to: &lossyNotes,
                        code: "responses_empty_message_skipped",
                        message: "Canonical message had no representable Responses input content and was skipped.",
                        itemIndex: itemIndex,
                        path: "items[\(itemIndex)]"
                    )
                    continue
                }
                input.append(.message(OpenAIResponsesInputMessage(
                    role: message.role.value,
                    content: content,
                    phase: inferredResponsesAssistantPhase(
                        for: message,
                        itemIndex: itemIndex,
                        in: request.items
                    )
                )))

            case .toolCall(let toolCall):
                input.append(.functionCall(OpenAIResponsesFunctionCall(
                    callId: toolCall.id,
                    name: toolCall.name,
                    arguments: toolCall.inputJSON,
                    status: responsesStatus(from: toolCall.status, partial: toolCall.partial)
                )))

            case .toolResult(let toolResult):
                input.append(.functionCallOutput(OpenAIResponsesFunctionCallOutput(
                    callId: toolResult.toolCallID,
                    output: makeResponsesFunctionCallOutputPayload(
                        from: toolResult,
                        itemIndex: itemIndex,
                        lossyNotes: &lossyNotes
                    )
                )))

            case .reasoning(let reasoning):
                input.append(.reasoning(OpenAIResponsesReasoningItem(
                    id: "canonical_reasoning_\(itemIndex)",
                    summary: reasoning.summaryText.map { [OpenAIResponsesSummaryText(text: $0)] } ?? [],
                    content: reasoning.fullText.map { [OpenAIResponsesReasoningText(text: $0)] },
                    encryptedContent: reasoning.encryptedContent,
                    status: reasoning.redacted == true ? "completed" : nil
                )))

            case .compaction(let compaction):
                guard let encryptedContent = compaction.encryptedContent else {
                    appendLossyNote(
                        to: &lossyNotes,
                        code: "responses_compaction_missing_encrypted_content",
                        message: "Canonical compaction item is missing encrypted content and was skipped.",
                        itemIndex: itemIndex,
                        path: "items[\(itemIndex)]"
                    )
                    continue
                }
                input.append(.compaction(OpenAIResponsesCompactionItem(
                    encryptedContent: encryptedContent,
                    id: compaction.id
                )))

            case .hostedToolEvent(let event):
                if let builtItem = try buildResponsesHostedToolInputItem(
                    from: event,
                    itemIndex: itemIndex,
                    lossyNotes: &lossyNotes
                ) {
                    input.append(builtItem)
                }
            }
        }

        let tools = try buildResponsesTools(from: request.tools, lossyNotes: &lossyNotes)
        let payload = OpenAIResponsesRequest(
            model: modelOverride ?? request.modelHint,
            input: input,
            temperature: request.generationConfig.temperature,
            topP: request.generationConfig.topP,
            maxOutputTokens: request.generationConfig.maxOutputTokens,
            stream: request.generationConfig.stream,
            store: extractResponsesStore(from: request.rawExtensions),
            tools: tools.isEmpty ? nil : tools,
            toolChoice: try buildResponsesToolChoice(
                from: request.toolConfig?.choice,
                tools: tools,
                lossyNotes: &lossyNotes
            ),
            parallelToolCalls: request.toolConfig?.parallelCallsAllowed
        )
        return CanonicalBuildResult(payload: payload, lossyNotes: lossyNotes)
    }
}

private func collectFollowingAssistantToolCalls(
    in items: [CanonicalConversationItem],
    start: Int,
    lossyNotes: inout [CanonicalLossyNote]
) throws -> (Int, [OpenAIToolCall]) {
    var index = start
    while index < items.count, case .reasoning = items[index] {
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_reasoning_item_skipped",
            message: "Canonical reasoning items cannot be directly represented in chat/completions input and were skipped.",
            itemIndex: index,
            path: "items[\(index)]"
        )
        index += 1
    }

    let (nextIndex, toolCalls) = try collectConsecutiveToolCalls(
        in: items,
        start: index,
        lossyNotes: &lossyNotes
    )
    return (nextIndex, toolCalls)
}

private func collectConsecutiveToolCalls(
    in items: [CanonicalConversationItem],
    start: Int,
    lossyNotes: inout [CanonicalLossyNote]
) throws -> (Int, [OpenAIToolCall]) {
    var index = start
    var toolCalls: [OpenAIToolCall] = []

    while index < items.count {
        switch items[index] {
        case .toolCall(let toolCall):
            toolCalls.append(OpenAIToolCall(
                id: toolCall.id,
                function: OpenAIFunctionCall(name: toolCall.name, arguments: toolCall.inputJSON)
            ))
            index += 1

        case .reasoning:
            appendLossyNote(
                to: &lossyNotes,
                code: "chat_reasoning_item_skipped",
                message: "Canonical reasoning items cannot be directly represented in chat/completions input and were skipped.",
                itemIndex: index,
                path: "items[\(index)]"
            )
            index += 1

        default:
            return (index, toolCalls)
        }
    }

    return (index, toolCalls)
}

private func makeChatMessageContent(
    from parts: [CanonicalContentPart],
    itemIndex: Int?,
    path: String,
    lossyNotes: inout [CanonicalLossyNote]
) throws -> OpenAIMessageContent? {
    let convertedParts = try parts.compactMap { part in
        try makeChatContentPart(
            from: part,
            itemIndex: itemIndex,
            path: path,
            lossyNotes: &lossyNotes
        )
    }

    guard !convertedParts.isEmpty else { return nil }
    if convertedParts.count == 1, case .text(let text) = convertedParts[0] {
        return .text(text.text)
    }
    return .parts(convertedParts)
}

private func makeChatToolResultContent(
    from result: CanonicalToolResult,
    itemIndex: Int?,
    lossyNotes: inout [CanonicalLossyNote]
) throws -> OpenAIMessageContent {
    let convertedParts = try result.parts.compactMap { part in
        try makeChatContentPart(
            from: part,
            itemIndex: itemIndex,
            path: "items[\(itemIndex ?? -1)].toolResult.parts",
            lossyNotes: &lossyNotes
        )
    }

    guard !convertedParts.isEmpty else {
        return .text(result.rawTextFallback ?? "")
    }

    let containsNonTextPart = convertedParts.contains { part in
        if case .text = part { return false }
        return true
    }

    if !containsNonTextPart {
        let joinedText = convertedParts.compactMap { part -> String? in
            guard case .text(let textPart) = part else { return nil }
            return textPart.text
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        return .text(joinedText.isEmpty ? (result.rawTextFallback ?? "") : joinedText)
    }

    return .parts(convertedParts)
}

private func makeChatContentPart(
    from part: CanonicalContentPart,
    itemIndex: Int?,
    path: String,
    lossyNotes: inout [CanonicalLossyNote]
) throws -> OpenAIContentPart? {
    switch part {
    case .text(let text):
        return .text(OpenAITextPart(text: text.text))

    case .image(let image):
        switch image.source {
        case .base64:
            guard let mediaType = image.mediaType else {
                appendLossyNote(
                    to: &lossyNotes,
                    code: "chat_image_missing_media_type",
                    message: "Base64 image was skipped because mediaType is missing.",
                    itemIndex: itemIndex,
                    path: path
                )
                return nil
            }
            return .imageUrl(OpenAIImageUrlPart(
                imageUrl: OpenAIImageUrl(url: "data:\(mediaType);base64,\(image.data)", detail: image.detail)
            ))
        case .url:
            return .imageUrl(OpenAIImageUrlPart(
                imageUrl: OpenAIImageUrl(url: image.data, detail: image.detail)
            ))
        case .fileID:
            appendLossyNote(
                to: &lossyNotes,
                code: "chat_image_file_id_degraded",
                message: "File-backed images are not directly representable in chat/completions content and were skipped.",
                itemIndex: itemIndex,
                path: path
            )
            return nil
        case .unknown(let raw):
            appendLossyNote(
                to: &lossyNotes,
                code: "chat_image_unknown_source_skipped",
                message: "Unsupported canonical image source `\(raw)` was skipped in chat/completions builder.",
                itemIndex: itemIndex,
                path: path
            )
            return nil
        }

    case .document(let document):
        return makeChatDocumentPart(from: document, itemIndex: itemIndex, path: path, lossyNotes: &lossyNotes)

    case .fileRef(let fileRef):
        return .inputFile(OpenAIFilePart(fileId: fileRef.fileID, filename: fileRef.filename))

    case .reasoningText:
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_reasoning_text_part_skipped",
            message: "Reasoning text parts are not emitted into chat/completions content and were skipped.",
            itemIndex: itemIndex,
            path: path
        )
        return nil

    case .refusal:
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_refusal_part_skipped",
            message: "Refusal parts are not directly representable in chat/completions input and were skipped.",
            itemIndex: itemIndex,
            path: path
        )
        return nil

    case .unknown(let unknown):
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_unknown_part_skipped",
            message: "Unknown canonical content part `\(unknown.type)` was skipped in chat/completions builder.",
            itemIndex: itemIndex,
            path: path
        )
        return nil
    }
}

private func makeChatDocumentPart(
    from document: CanonicalDocumentPart,
    itemIndex: Int?,
    path: String,
    lossyNotes: inout [CanonicalLossyNote]
) -> OpenAIContentPart {
    switch document.source {
    case .fileID(let fileID):
        return .inputFile(OpenAIFilePart(fileId: fileID, filename: document.title))

    case .inlineText(let text):
        return .text(OpenAITextPart(text: renderCanonicalInlineDocumentText(document: document, body: text)))

    case .contentParts(let parts):
        if let text = extractCanonicalDocumentContentText(parts), !text.isEmpty {
            return .text(OpenAITextPart(text: renderCanonicalInlineDocumentText(document: document, body: text)))
        }
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_document_content_degraded",
            message: "Document content parts could not be flattened into text and were degraded to explicit text.",
            itemIndex: itemIndex,
            path: path
        )
        return .text(OpenAITextPart(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "content",
            detail: "missing content blocks"
        )))

    case .url(let url):
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_document_url_degraded",
            message: "URL-backed documents were degraded to explicit text in chat/completions builder.",
            itemIndex: itemIndex,
            path: path
        )
        return .text(OpenAITextPart(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "url",
            detail: url
        )))

    case .base64(_, let mediaType):
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_document_base64_degraded",
            message: "Base64-backed documents were degraded to explicit text in chat/completions builder.",
            itemIndex: itemIndex,
            path: path
        )
        return .text(OpenAITextPart(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "base64",
            detail: mediaType
        )))

    case .unknown:
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_document_unknown_degraded",
            message: "Unknown document source was degraded to explicit text in chat/completions builder.",
            itemIndex: itemIndex,
            path: path
        )
        return .text(OpenAITextPart(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "unknown"
        )))
    }
}

private func buildChatTools(
    from tools: [CanonicalToolDefinition],
    lossyNotes: inout [CanonicalLossyNote]
) -> [OpenAITool]? {
    let builtTools = tools.compactMap { tool -> OpenAITool? in
        switch tool.kind {
        case .function:
            guard let name = tool.name else {
                appendLossyNote(
                    to: &lossyNotes,
                    code: "chat_function_tool_missing_name",
                    message: "Function tool without a name was skipped in chat/completions builder."
                )
                return nil
            }
            return OpenAITool(function: OpenAIFunction(
                name: name,
                description: tool.description,
                parameters: tool.inputSchema
            ))

        case .hosted, .custom, .unknown:
            appendLossyNote(
                to: &lossyNotes,
                code: "chat_non_function_tool_skipped",
                message: "Only function tools can be emitted to chat/completions; non-function canonical tool was skipped."
            )
            return nil
        }
    }

    return builtTools.isEmpty ? nil : builtTools
}

private func buildChatToolChoice(
    from choice: CanonicalToolChoice?,
    lossyNotes: inout [CanonicalLossyNote]
) -> OpenAIToolChoice? {
    guard let choice else { return nil }

    switch choice {
    case .none:
        return OpenAIToolChoice.none
    case .auto:
        return .auto
    case .required:
        return .required
    case .specific(let name):
        return .function(name)
    case .allowed(let names):
        if let first = names.first, names.count == 1 {
            appendLossyNote(
                to: &lossyNotes,
                code: "chat_allowed_tools_collapsed_to_function",
                message: "allowed_tools with a single function was collapsed to chat/completions function tool_choice."
            )
            return .function(first)
        }
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_allowed_tools_degraded_to_required",
            message: "allowed_tools is not representable in chat/completions and was degraded to `required`."
        )
        return .required
    case .hosted, .custom, .unknown:
        appendLossyNote(
            to: &lossyNotes,
            code: "chat_tool_choice_degraded_to_auto",
            message: "Unsupported canonical tool choice was degraded to chat/completions `auto`."
        )
        return .auto
    }
}

private func makeResponsesInputContent(
    from parts: [CanonicalContentPart],
    role: String,
    itemIndex: Int?,
    path: String,
    lossyNotes: inout [CanonicalLossyNote]
) -> [OpenAIResponsesInputContent] {
    parts.compactMap { part in
        makeResponsesInputContentPart(
            from: part,
            role: role,
            itemIndex: itemIndex,
            path: path,
            lossyNotes: &lossyNotes
        )
    }
}

private func makeResponsesInputContentPart(
    from part: CanonicalContentPart,
    role: String,
    itemIndex: Int?,
    path: String,
    lossyNotes: inout [CanonicalLossyNote]
) -> OpenAIResponsesInputContent? {
    let isAssistant = role == "assistant"

    switch part {
    case .text(let text):
        if isAssistant {
            return .outputText(OpenAIResponsesOutputText(text: text.text))
        }
        return .inputText(OpenAIResponsesInputText(text: text.text))

    case .image(let image):
        switch image.source {
        case .base64:
            guard let mediaType = image.mediaType else {
                appendLossyNote(
                    to: &lossyNotes,
                    code: "responses_image_missing_media_type",
                    message: "Base64 image was skipped because mediaType is missing.",
                    itemIndex: itemIndex,
                    path: path
                )
                return nil
            }
            return .inputImage(OpenAIResponsesInputImage(
                imageURL: "data:\(mediaType);base64,\(image.data)",
                detail: image.detail
            ))
        case .url:
            return .inputImage(OpenAIResponsesInputImage(
                imageURL: image.data,
                detail: image.detail
            ))
        case .fileID:
            return .inputImage(OpenAIResponsesInputImage(
                fileId: image.data,
                detail: image.detail
            ))
        case .unknown(let raw):
            appendLossyNote(
                to: &lossyNotes,
                code: "responses_image_unknown_source_skipped",
                message: "Unsupported canonical image source `\(raw)` was skipped in Responses builder.",
                itemIndex: itemIndex,
                path: path
            )
            return nil
        }

    case .document(let document):
        return makeResponsesDocumentPart(
            from: document,
            itemIndex: itemIndex,
            path: path,
            lossyNotes: &lossyNotes
        )

    case .fileRef(let fileRef):
        return .inputFile(OpenAIResponsesInputFile(
            fileId: fileRef.fileID,
            filename: fileRef.filename
        ))

    case .reasoningText:
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_reasoning_text_part_skipped",
            message: "Reasoning text parts are not emitted into Responses input content and were skipped.",
            itemIndex: itemIndex,
            path: path
        )
        return nil

    case .refusal(let refusal):
        if isAssistant {
            return .outputText(OpenAIResponsesOutputText(text: refusal.text))
        }
        return .inputText(OpenAIResponsesInputText(text: refusal.text))

    case .unknown(let unknown):
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_unknown_part_skipped",
            message: "Unknown canonical content part `\(unknown.type)` was skipped in Responses builder.",
            itemIndex: itemIndex,
            path: path
        )
        return nil
    }
}

private func makeResponsesDocumentPart(
    from document: CanonicalDocumentPart,
    itemIndex: Int?,
    path: String,
    lossyNotes: inout [CanonicalLossyNote]
) -> OpenAIResponsesInputContent {
    switch document.source {
    case .fileID(let fileID):
        return .inputFile(OpenAIResponsesInputFile(
            fileId: fileID,
            filename: document.title
        ))

    case .inlineText(let text):
        return .inputText(OpenAIResponsesInputText(text: renderCanonicalInlineDocumentText(document: document, body: text)))

    case .contentParts(let parts):
        if let text = extractCanonicalDocumentContentText(parts), !text.isEmpty {
            return .inputText(OpenAIResponsesInputText(text: renderCanonicalInlineDocumentText(document: document, body: text)))
        }
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_document_content_degraded",
            message: "Document content parts could not be flattened into text and were degraded to explicit text.",
            itemIndex: itemIndex,
            path: path
        )
        return .inputText(OpenAIResponsesInputText(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "content",
            detail: "missing content blocks"
        )))

    case .url(let url):
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_document_url_degraded",
            message: "URL-backed documents were degraded to explicit text in Responses builder.",
            itemIndex: itemIndex,
            path: path
        )
        return .inputText(OpenAIResponsesInputText(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "url",
            detail: url
        )))

    case .base64(_, let mediaType):
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_document_base64_degraded",
            message: "Base64-backed documents were degraded to explicit text in Responses builder.",
            itemIndex: itemIndex,
            path: path
        )
        return .inputText(OpenAIResponsesInputText(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "base64",
            detail: mediaType
        )))

    case .unknown:
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_document_unknown_degraded",
            message: "Unknown document source was degraded to explicit text in Responses builder.",
            itemIndex: itemIndex,
            path: path
        )
        return .inputText(OpenAIResponsesInputText(text: renderCanonicalDocumentFallbackText(
            document: document,
            sourceType: "unknown"
        )))
    }
}

private func makeResponsesFunctionCallOutputPayload(
    from result: CanonicalToolResult,
    itemIndex: Int?,
    lossyNotes: inout [CanonicalLossyNote]
) -> OpenAIResponsesFunctionCallOutputPayload {
    let content = makeResponsesInputContent(
        from: result.parts,
        role: "tool",
        itemIndex: itemIndex,
        path: "items[\(itemIndex ?? -1)].toolResult.parts",
        lossyNotes: &lossyNotes
    )

    guard !content.isEmpty else {
        return .text(result.rawTextFallback ?? "")
    }

    let containsNonTextPart = content.contains { part in
        if case .inputText = part { return false }
        return true
    }

    if !containsNonTextPart {
        let joinedText = content.compactMap { part -> String? in
            guard case .inputText(let text) = part else { return nil }
            return text.text
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        return .text(joinedText.isEmpty ? (result.rawTextFallback ?? "") : joinedText)
    }

    return .content(content)
}

private func buildResponsesTools(
    from tools: [CanonicalToolDefinition],
    lossyNotes: inout [CanonicalLossyNote]
) throws -> [OpenAIResponsesTool] {
    try tools.compactMap { tool in
        if let rawTool = try decodeResponsesToolDefinitionFromRawExtension(tool) {
            return rawTool
        }

        switch tool.kind {
        case .function:
            guard let name = tool.name else {
                appendLossyNote(
                    to: &lossyNotes,
                    code: "responses_function_tool_missing_name",
                    message: "Function tool without a name was skipped in Responses builder."
                )
                return nil
            }
            return .function(OpenAIResponsesFunctionTool(
                name: name,
                description: tool.description,
                parameters: tool.inputSchema,
                strict: tool.flags.strict ?? false
            ))

        case .custom:
            guard let name = tool.name else {
                appendLossyNote(
                    to: &lossyNotes,
                    code: "responses_custom_tool_missing_name",
                    message: "Custom tool without a name was skipped in Responses builder."
                )
                return nil
            }
            return .custom(OpenAIResponsesCustomTool(
                type: "custom",
                name: name,
                description: tool.description,
                format: nil
            ))

        case .hosted:
            switch tool.vendorType {
            case "web_search", "web_search_preview", "web_search_preview_2025_03_11", "web_search_2025_08_26":
                return .webSearch(OpenAIResponsesWebSearchTool(
                    type: tool.vendorType ?? "web_search",
                    filters: nil,
                    searchContextSize: nil,
                    userLocation: nil
                ))
            case "local_shell":
                return .localShell(OpenAIResponsesLocalShellTool(type: "local_shell"))
            case "shell":
                return .shell(OpenAIResponsesShellTool(type: "shell", environment: nil))
            case "apply_patch":
                return .applyPatch(OpenAIResponsesApplyPatchTool(type: "apply_patch"))
            case "image_generation":
                return .imageGeneration(OpenAIResponsesImageGenerationTool(
                    type: "image_generation",
                    background: nil,
                    inputFidelity: nil,
                    inputImageMask: nil,
                    model: nil,
                    moderation: nil,
                    outputCompression: nil,
                    outputFormat: nil,
                    partialImages: nil,
                    quality: nil,
                    size: nil
                ))
            default:
                appendLossyNote(
                    to: &lossyNotes,
                    code: "responses_hosted_tool_skipped",
                    message: "Hosted tool `\(tool.vendorType ?? "unknown")` could not be reconstructed from canonical data and was skipped."
                )
                return nil
            }

        case .unknown(let raw):
            appendLossyNote(
                to: &lossyNotes,
                code: "responses_unknown_tool_skipped",
                message: "Unknown canonical tool kind `\(raw)` was skipped in Responses builder."
            )
            return nil
        }
    }
}

private func buildResponsesToolChoice(
    from choice: CanonicalToolChoice?,
    tools: [OpenAIResponsesTool],
    lossyNotes: inout [CanonicalLossyNote]
) throws -> OpenAIResponsesToolChoice? {
    guard let choice else { return nil }

    switch choice {
    case .none:
        return OpenAIResponsesToolChoice.none
    case .auto:
        return .auto
    case .required:
        return .required
    case .specific(let name):
        return .function(name)
    case .allowed(let names):
        let allowedTools = tools.filter { tool in
            if case .function(let function) = tool {
                return names.contains(function.name)
            }
            return false
        }
        if allowedTools.count == names.count, !allowedTools.isEmpty {
            return .allowedTools(mode: "auto", tools: allowedTools)
        }
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_allowed_tools_degraded",
            message: "allowed_tools could not be fully reconstructed and was degraded to `required`."
        )
        return .required
    case .hosted(let type):
        return .hostedTool(type)
    case .custom(let name):
        return .custom(name)
    case .unknown(let raw):
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_unknown_tool_choice_skipped",
            message: "Unknown canonical tool choice `\(raw)` was omitted in Responses builder."
        )
        return nil
    }
}

private func buildResponsesHostedToolInputItem(
    from event: CanonicalHostedToolEvent,
    itemIndex: Int,
    lossyNotes: inout [CanonicalLossyNote]
) throws -> OpenAIResponsesInputItem? {
    switch event.vendorType {
    case "computer_call":
        return try decodeInputItem(event.payload, as: OpenAIResponsesComputerCall.self).map(OpenAIResponsesInputItem.computerCall)
    case "computer_call_output":
        return try decodeInputItem(event.payload, as: OpenAIResponsesComputerCallOutput.self).map(OpenAIResponsesInputItem.computerCallOutput)
    case "tool_search_call":
        return try decodeInputItem(event.payload, as: OpenAIResponsesToolSearchCall.self).map(OpenAIResponsesInputItem.toolSearchCall)
    case "tool_search_output":
        return try decodeInputItem(event.payload, as: OpenAIResponsesToolSearchOutput.self).map(OpenAIResponsesInputItem.toolSearchOutput)
    case "local_shell_call":
        return try decodeInputItem(event.payload, as: OpenAIResponsesLocalShellCall.self).map(OpenAIResponsesInputItem.localShellCall)
    case "local_shell_call_output":
        return try decodeInputItem(event.payload, as: OpenAIResponsesLocalShellCallOutput.self).map(OpenAIResponsesInputItem.localShellCallOutput)
    case "shell_call":
        return try decodeInputItem(event.payload, as: OpenAIResponsesShellCall.self).map(OpenAIResponsesInputItem.shellCall)
    case "shell_call_output":
        return try decodeInputItem(event.payload, as: OpenAIResponsesShellCallOutput.self).map(OpenAIResponsesInputItem.shellCallOutput)
    case "apply_patch_call":
        return try decodeInputItem(event.payload, as: OpenAIResponsesApplyPatchCall.self).map(OpenAIResponsesInputItem.applyPatchCall)
    case "apply_patch_call_output":
        return try decodeInputItem(event.payload, as: OpenAIResponsesApplyPatchCallOutput.self).map(OpenAIResponsesInputItem.applyPatchCallOutput)
    case "mcp_list_tools":
        return try decodeInputItem(event.payload, as: OpenAIResponsesMCPListTools.self).map(OpenAIResponsesInputItem.mcpListTools)
    case "mcp_approval_request":
        return try decodeInputItem(event.payload, as: OpenAIResponsesMCPApprovalRequest.self).map(OpenAIResponsesInputItem.mcpApprovalRequest)
    case "mcp_approval_response":
        return try decodeInputItem(event.payload, as: OpenAIResponsesMCPApprovalResponse.self).map(OpenAIResponsesInputItem.mcpApprovalResponse)
    case "mcp_call":
        return try decodeInputItem(event.payload, as: OpenAIResponsesMCPCall.self).map(OpenAIResponsesInputItem.mcpCall)
    case "custom_tool_call":
        return try decodeInputItem(event.payload, as: OpenAIResponsesCustomToolCall.self).map(OpenAIResponsesInputItem.customToolCall)
    case "custom_tool_call_output":
        return try decodeInputItem(event.payload, as: OpenAIResponsesCustomToolCallOutput.self).map(OpenAIResponsesInputItem.customToolCallOutput)
    default:
        appendLossyNote(
            to: &lossyNotes,
            code: "responses_hosted_tool_event_skipped",
            message: "Hosted tool event `\(event.vendorType)` is not representable as a Responses input item and was skipped.",
            itemIndex: itemIndex,
            path: "items[\(itemIndex)]"
        )
        return nil
    }
}

private func responsesAssistantPhase(from phase: CanonicalPhase?) -> OpenAIResponsesAssistantPhase? {
    switch phase {
    case .commentary:
        return .commentary
    case .finalAnswer:
        return .finalAnswer
    case .unknown, .none:
        return nil
    }
}

private func inferredResponsesAssistantPhase(
    for message: CanonicalMessage,
    itemIndex: Int,
    in items: [CanonicalConversationItem]
) -> OpenAIResponsesAssistantPhase? {
    if let phase = responsesAssistantPhase(from: message.phase) {
        return phase
    }

    guard case .assistant = message.role else {
        return nil
    }

    var scanIndex = itemIndex + 1
    while scanIndex < items.count, case .reasoning = items[scanIndex] {
        scanIndex += 1
    }

    if scanIndex < items.count, case .toolCall = items[scanIndex] {
        return .commentary
    }

    return .finalAnswer
}

private func responsesStatus(from status: CanonicalItemStatus, partial: Bool) -> String? {
    switch status {
    case .completed where !partial:
        return nil
    case .unknown:
        return partial ? "in_progress" : nil
    default:
        return status.value
    }
}

private func extractResponsesStore(from extensions: [CanonicalVendorExtension]) -> Bool? {
    extensions.first(where: { $0.vendor == "openai_responses" && $0.key == "store" })?.value.value as? Bool ?? false
}

private func decodeResponsesToolDefinitionFromRawExtension(
    _ tool: CanonicalToolDefinition
) throws -> OpenAIResponsesTool? {
    guard let payload = tool.rawExtensions.first(where: {
        $0.vendor == "openai_responses" && $0.key == "tool_definition"
    })?.value else {
        return nil
    }
    return try decodeFromAnyCodable(payload, as: OpenAIResponsesTool.self)
}

private func decodeInputItem<T: Decodable>(
    _ payload: AnyCodable?,
    as type: T.Type
) throws -> T? {
    guard let payload else { return nil }
    return try decodeFromAnyCodable(payload, as: type)
}

private func decodeFromAnyCodable<T: Decodable>(
    _ payload: AnyCodable,
    as type: T.Type
) throws -> T {
    let unwrapped = payload.foundationValue
    guard JSONSerialization.isValidJSONObject(unwrapped) else {
        throw CanonicalMappingError.invalidJSONObject("Canonical raw extension decode")
    }
    let data = try JSONSerialization.data(withJSONObject: unwrapped)
    return try JSONDecoder().decode(type, from: data)
}

private func extractCanonicalDocumentContentText(_ parts: [CanonicalContentPart]) -> String? {
    let text = parts.compactMap { part -> String? in
        switch part {
        case .text(let text):
            return text.text
        case .document(let document):
            switch document.source {
            case .inlineText(let inlineText):
                return inlineText
            case .contentParts(let nested):
                return extractCanonicalDocumentContentText(nested)
            default:
                return nil
            }
        default:
            return nil
        }
    }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
    return text.isEmpty ? nil : text
}

private func renderCanonicalInlineDocumentText(
    document: CanonicalDocumentPart,
    body: String
) -> String {
    var lines: [String] = []
    if let title = document.title, !title.isEmpty {
        lines.append("Document title: \(title)")
    }
    if let context = document.context, !context.isEmpty {
        lines.append("Document context: \(context)")
    }
    lines.append("Document content:")
    lines.append(body)
    return lines.joined(separator: "\n")
}

private func renderCanonicalDocumentFallbackText(
    document: CanonicalDocumentPart,
    sourceType: String,
    detail: String? = nil
) -> String {
    var segments = ["[Claude document degraded during OpenAI proxy conversion]"]
    segments.append("source.type=\(sourceType)")
    if let title = document.title, !title.isEmpty {
        segments.append("title=\(title)")
    }
    if let context = document.context, !context.isEmpty {
        segments.append("context=\(context)")
    }
    if let detail, !detail.isEmpty {
        segments.append("detail=\(detail)")
    }
    return segments.joined(separator: "\n")
}

private func appendLossyNote(
    to notes: inout [CanonicalLossyNote],
    code: String,
    message: String,
    severity: CanonicalLossySeverity = .warning,
    itemIndex: Int? = nil,
    path: String? = nil
) {
    notes.append(CanonicalLossyNote(
        code: code,
        message: message,
        severity: severity,
        itemIndex: itemIndex,
        path: path
    ))
}
