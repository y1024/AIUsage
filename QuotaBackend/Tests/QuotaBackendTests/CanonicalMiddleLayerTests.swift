import Foundation
import XCTest
@testable import QuotaBackend

final class CanonicalMiddleLayerTests: XCTestCase {

    func testCanonicalClaudeRequestMappingPreservesToolConfigAndRichItems() throws {
        let mapper = CanonicalRequestMapper()
        let request = ClaudeMessageRequest(
            model: "claude-sonnet-4-5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .text(ClaudeTextBlock(text: "Read this doc")),
                    .document(ClaudeDocumentBlock(
                        source: [
                            "type": AnyCodable("file"),
                            "file_id": AnyCodable("file_123")
                        ],
                        title: "Spec"
                    ))
                ])),
                ClaudeMessage(role: "assistant", content: .blocks([
                    .thinking(ClaudeThinkingBlock(thinking: "Need tool", signature: "sig_1")),
                    .toolUse(ClaudeToolUseBlock(
                        id: "toolu_1",
                        name: "lookup",
                        input: ["query": AnyCodable("quota")]
                    ))
                ])),
                ClaudeMessage(role: "user", content: .blocks([
                    .toolResult(ClaudeToolResultBlock(
                        toolUseId: "toolu_1",
                        contentBlocks: [
                            .text(ClaudeTextBlock(text: "Found it"))
                        ]
                    ))
                ]))
            ],
            systemBlocks: [
                ClaudeSystemBlock(
                    type: "text",
                    text: "You are precise.",
                    cacheControl: ["type": AnyCodable("ephemeral")]
                )
            ],
            maxTokens: 2048,
            stream: true,
            tools: [
                ClaudeTool(
                    name: "lookup",
                    description: "Lookup docs",
                    inputSchema: ["type": AnyCodable("object")],
                    eagerInputStreaming: true
                )
            ],
            toolChoice: ClaudeToolChoice(
                type: "tool",
                name: "lookup",
                disableParallelToolUse: true
            ),
            metadata: ClaudeMetadata(userId: "user_123")
        )

        let canonical = try mapper.mapClaude(request)

        XCTAssertEqual(canonical.modelHint, "claude-sonnet-4-5")
        XCTAssertEqual(canonical.system.count, 1)
        guard case .text(let systemText) = try XCTUnwrap(canonical.system.first) else {
            return XCTFail("Expected canonical system text part")
        }
        XCTAssertEqual(systemText.text, "You are precise.")
        XCTAssertEqual(systemText.rawExtensions.first?.key, "cache_control")
        XCTAssertEqual(canonical.metadata["user_id"]?.value as? String, "user_123")

        XCTAssertEqual(canonical.tools.count, 1)
        XCTAssertEqual(canonical.tools.first?.name, "lookup")
        XCTAssertEqual(canonical.tools.first?.flags.eagerInputStreaming, true)

        XCTAssertEqual(canonical.toolConfig?.parallelCallsAllowed, false)
        guard case .specific(let toolName)? = canonical.toolConfig?.choice else {
            return XCTFail("Expected specific tool choice")
        }
        XCTAssertEqual(toolName, "lookup")

        XCTAssertEqual(canonical.items.count, 4)

        guard case .message(let userMessage) = canonical.items[0] else {
            return XCTFail("Expected first canonical item to be a user message")
        }
        XCTAssertEqual(userMessage.role.value, "user")
        XCTAssertEqual(userMessage.parts.count, 2)
        guard case .document(let document) = userMessage.parts[1] else {
            return XCTFail("Expected document content part")
        }
        guard case .fileID(let fileID) = document.source else {
            return XCTFail("Expected file-backed document source")
        }
        XCTAssertEqual(fileID, "file_123")

        guard case .reasoning(let reasoning) = canonical.items[1] else {
            return XCTFail("Expected reasoning item")
        }
        XCTAssertEqual(reasoning.fullText, "Need tool")
        XCTAssertEqual(reasoning.signature, "sig_1")

        guard case .toolCall(let toolCall) = canonical.items[2] else {
            return XCTFail("Expected tool call item")
        }
        XCTAssertEqual(toolCall.id, "toolu_1")
        XCTAssertEqual(toolCall.name, "lookup")
        XCTAssertTrue(toolCall.inputJSON.contains("\"query\""))
        XCTAssertFalse(toolCall.partial)

        guard case .toolResult(let toolResult) = canonical.items[3] else {
            return XCTFail("Expected tool result item")
        }
        XCTAssertEqual(toolResult.toolCallID, "toolu_1")
        XCTAssertEqual(toolResult.rawTextFallback, "Found it")
        guard case .text(let toolResultText)? = toolResult.parts.first else {
            return XCTFail("Expected text tool result part")
        }
        XCTAssertEqual(toolResultText.text, "Found it")
    }

    func testCanonicalOpenAIChatRequestMappingSeparatesSystemAndToolMessages() throws {
        let mapper = CanonicalRequestMapper()
        let request = OpenAIChatCompletionRequest(
            model: "gpt-4.1",
            messages: [
                OpenAIChatMessage(role: "system", content: .text("You are strict.")),
                OpenAIChatMessage(role: "user", content: .parts([
                    .text(OpenAITextPart(text: "Summarize this")),
                    .inputFile(OpenAIFilePart(fileId: "file_42", filename: "notes.txt"))
                ])),
                OpenAIChatMessage(
                    role: "assistant",
                    content: .text("I'll call a tool."),
                    toolCalls: [
                        OpenAIToolCall(
                            id: "call_1",
                            function: OpenAIFunctionCall(
                                name: "lookup",
                                arguments: "{\"query\":\"quota\"}"
                            )
                        )
                    ]
                ),
                OpenAIChatMessage(
                    role: "tool",
                    content: .text("done"),
                    toolCallId: "call_1"
                )
            ],
            stream: true,
            tools: [
                OpenAITool(function: OpenAIFunction(
                    name: "lookup",
                    description: "Lookup docs",
                    parameters: ["type": AnyCodable("object")]
                ))
            ],
            toolChoice: .function("lookup"),
            parallelToolCalls: false
        )

        let canonical = try mapper.mapOpenAIChatCompletions(request)

        XCTAssertEqual(canonical.system.count, 1)
        guard case .text(let systemText) = try XCTUnwrap(canonical.system.first) else {
            return XCTFail("Expected system text part")
        }
        XCTAssertEqual(systemText.text, "You are strict.")

        XCTAssertEqual(canonical.tools.count, 1)
        XCTAssertEqual(canonical.tools.first?.name, "lookup")
        XCTAssertEqual(canonical.toolConfig?.parallelCallsAllowed, false)
        guard case .specific(let toolName)? = canonical.toolConfig?.choice else {
            return XCTFail("Expected specific chat tool choice")
        }
        XCTAssertEqual(toolName, "lookup")

        XCTAssertEqual(canonical.items.count, 4)

        guard case .message(let userMessage) = canonical.items[0] else {
            return XCTFail("Expected user message item")
        }
        XCTAssertEqual(userMessage.role.value, "user")
        XCTAssertEqual(userMessage.parts.count, 2)
        guard case .fileRef(let fileRef) = userMessage.parts[1] else {
            return XCTFail("Expected file reference in user message")
        }
        XCTAssertEqual(fileRef.fileID, "file_42")
        XCTAssertEqual(fileRef.filename, "notes.txt")

        guard case .message(let assistantMessage) = canonical.items[1] else {
            return XCTFail("Expected assistant message item")
        }
        XCTAssertEqual(assistantMessage.role.value, "assistant")
        guard case .text(let assistantText)? = assistantMessage.parts.first else {
            return XCTFail("Expected assistant text part")
        }
        XCTAssertEqual(assistantText.text, "I'll call a tool.")

        guard case .toolCall(let toolCall) = canonical.items[2] else {
            return XCTFail("Expected tool call item")
        }
        XCTAssertEqual(toolCall.id, "call_1")
        XCTAssertEqual(toolCall.name, "lookup")

        guard case .toolResult(let toolResult) = canonical.items[3] else {
            return XCTFail("Expected tool result item")
        }
        XCTAssertEqual(toolResult.toolCallID, "call_1")
        XCTAssertEqual(toolResult.rawTextFallback, "done")
    }

    func testCanonicalOpenAIResponsesRequestPreservesStoreAndPartialToolCall() throws {
        let mapper = CanonicalRequestMapper()
        let functionTool = OpenAIResponsesFunctionTool(
            name: "lookup",
            description: "Lookup docs",
            parameters: ["type": AnyCodable("object")],
            strict: true
        )
        let request = OpenAIResponsesRequest(
            model: "gpt-5",
            input: [
                .message(OpenAIResponsesInputMessage(
                    role: "user",
                    content: [.inputText(OpenAIResponsesInputText(text: "Find quota info"))]
                )),
                .functionCall(OpenAIResponsesFunctionCall(
                    callId: "call_1",
                    name: "lookup",
                    arguments: "{\"query\":\"quota\"}",
                    status: "in_progress"
                ))
            ],
            stream: true,
            store: true,
            tools: [
                .function(functionTool),
                .webSearch(OpenAIResponsesWebSearchTool(
                    type: "web_search",
                    filters: nil,
                    searchContextSize: "medium",
                    userLocation: nil
                ))
            ],
            toolChoice: .allowedTools(mode: "auto", tools: [.function(functionTool)]),
            parallelToolCalls: true
        )

        let canonical = try mapper.mapOpenAIResponses(request)

        XCTAssertEqual(canonical.rawExtensions.count, 1)
        XCTAssertEqual(canonical.rawExtensions.first?.vendor, "openai_responses")
        XCTAssertEqual(canonical.rawExtensions.first?.key, "store")
        XCTAssertEqual(canonical.rawExtensions.first?.value.value as? Bool, true)

        XCTAssertEqual(canonical.tools.count, 2)
        XCTAssertEqual(canonical.tools[0].name, "lookup")
        XCTAssertEqual(canonical.tools[0].flags.strict, true)
        XCTAssertEqual(canonical.tools[1].vendorType, "web_search")

        XCTAssertEqual(canonical.toolConfig?.parallelCallsAllowed, true)
        guard case .allowed(let names)? = canonical.toolConfig?.choice else {
            return XCTFail("Expected allowed-tools configuration")
        }
        XCTAssertEqual(names, ["lookup"])

        XCTAssertEqual(canonical.items.count, 2)
        guard case .toolCall(let toolCall) = canonical.items[1] else {
            return XCTFail("Expected second item to be the in-progress function call")
        }
        XCTAssertEqual(toolCall.id, "call_1")
        XCTAssertEqual(toolCall.status.value, "in_progress")
        XCTAssertTrue(toolCall.partial)
    }

    func testCanonicalOpenAIResponsesResponseMapsReasoningHostedToolAndPauseTurn() throws {
        let mapper = CanonicalResponseMapper()
        let response = OpenAIResponsesResponse(
            id: "resp_1",
            object: "response",
            createdAt: 1_710_000_000,
            model: "gpt-5",
            output: [
                .reasoning(OpenAIResponsesReasoningItem(
                    id: "rs_1",
                    summary: [OpenAIResponsesSummaryText(text: "Need to inspect the app state.")],
                    content: [OpenAIResponsesReasoningText(text: "A hosted computer tool is still running.")],
                    encryptedContent: "enc_reasoning",
                    status: "in_progress"
                )),
                .computerCall(OpenAIResponsesComputerCall(
                    id: "computer_1",
                    type: "computer_call",
                    callId: "computer_call_1",
                    status: "in_progress",
                    action: ["type": AnyCodable("click")],
                    actions: nil,
                    pendingSafetyChecks: nil,
                    createdBy: "assistant"
                ))
            ],
            status: "incomplete",
            usage: OpenAIResponsesUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12)
        )

        let canonical = try mapper.mapOpenAIResponses(response)

        XCTAssertEqual(canonical.stop.reason.value, "pause_turn")
        XCTAssertEqual(canonical.usage?.totalTokens, 12)
        XCTAssertEqual(canonical.items.count, 2)

        guard case .reasoning(let reasoning) = canonical.items[0] else {
            return XCTFail("Expected reasoning item")
        }
        XCTAssertEqual(reasoning.summaryText, "Need to inspect the app state.")
        XCTAssertEqual(reasoning.fullText, "A hosted computer tool is still running.")
        XCTAssertEqual(reasoning.encryptedContent, "enc_reasoning")

        guard case .hostedToolEvent(let event) = canonical.items[1] else {
            return XCTFail("Expected hosted tool event")
        }
        XCTAssertEqual(event.vendorType, "computer_call")
        XCTAssertEqual(event.callID, "computer_call_1")
        XCTAssertEqual(event.status.value, "in_progress")
        let payload = try XCTUnwrap(event.payload?.value as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "computer_call")
    }

    func testCanonicalOpenAIUpstreamStreamMapperSynthesizesLifecycle() {
        var mapper = CanonicalOpenAIUpstreamStreamMapper()
        var events: [CanonicalStreamEvent] = []

        events += mapper.map(.reasoningSummaryDelta("Need tool."))
        events += mapper.map(.toolCallStarted(index: 0, id: "call_1", name: "lookup"))
        events += mapper.map(.toolCallArgumentsDelta(index: 0, argumentsDelta: "{\"query\":\"quota\"}"))
        events += mapper.map(.textDelta("Done."))
        events += mapper.map(.completed(
            finishReason: "length",
            usage: OpenAIUsage(promptTokens: 12, completionTokens: 5, totalTokens: 17)
        ))

        XCTAssertEqual(events.count, 12)

        guard case .messageStarted(let messageStart) = events[0] else {
            return XCTFail("Expected synthesized message start")
        }
        XCTAssertEqual(messageStart.role.value, "assistant")

        guard case .contentPartStarted(let reasoningStart) = events[1] else {
            return XCTFail("Expected reasoning part start")
        }
        XCTAssertEqual(reasoningStart.kind.value, "reasoning")

        guard case .contentPartDelta(let reasoningDelta) = events[2] else {
            return XCTFail("Expected reasoning delta")
        }
        XCTAssertEqual(reasoningDelta.textDelta, "Need tool.")

        guard case .contentPartStopped(let reasoningStop) = events[3] else {
            return XCTFail("Expected reasoning stop before tool start")
        }
        XCTAssertEqual(reasoningStop.index, 0)

        guard case .contentPartStarted(let toolStart) = events[4] else {
            return XCTFail("Expected tool part start")
        }
        XCTAssertEqual(toolStart.kind.value, "tool_call")
        XCTAssertEqual(toolStart.toolCallID, "call_1")
        XCTAssertEqual(toolStart.toolName, "lookup")

        guard case .contentPartDelta(let toolDelta) = events[5] else {
            return XCTFail("Expected tool arguments delta")
        }
        XCTAssertEqual(toolDelta.jsonDelta, "{\"query\":\"quota\"}")

        guard case .contentPartStarted(let textStart) = events[6] else {
            return XCTFail("Expected text part start")
        }
        XCTAssertEqual(textStart.kind.value, "text")

        guard case .contentPartDelta(let textDelta) = events[7] else {
            return XCTFail("Expected text delta")
        }
        XCTAssertEqual(textDelta.textDelta, "Done.")

        guard case .contentPartStopped(let textStop) = events[8] else {
            return XCTFail("Expected text stop")
        }
        XCTAssertEqual(textStop.index, 2)

        guard case .contentPartStopped(let toolStop) = events[9] else {
            return XCTFail("Expected tool stop")
        }
        XCTAssertEqual(toolStop.index, 1)

        guard case .messageDelta(let messageDelta) = events[10] else {
            return XCTFail("Expected message delta")
        }
        XCTAssertEqual(messageDelta.stop?.reason.value, "max_tokens")
        XCTAssertEqual(messageDelta.usage?.totalTokens, 17)

        guard case .messageStopped = events[11] else {
            return XCTFail("Expected message stopped event")
        }
    }

    func testCanonicalOpenAIUpstreamStreamMapperBuffersToolArgumentsUntilMetadataArrives() {
        var mapper = CanonicalOpenAIUpstreamStreamMapper()

        let bufferedOnly = mapper.map(.toolCallArgumentsDelta(index: 0, argumentsDelta: "{\"query\":\"quota\"}"))
        XCTAssertEqual(bufferedOnly.count, 1)
        guard case .messageStarted = bufferedOnly[0] else {
            return XCTFail("Expected only synthesized message start before tool metadata arrives")
        }

        let resolved = mapper.map(.toolCallStarted(index: 0, id: "call_1", name: "lookup"))
        XCTAssertEqual(resolved.count, 2)

        guard case .contentPartStarted(let toolStart) = resolved[0] else {
            return XCTFail("Expected tool start after metadata arrives")
        }
        XCTAssertEqual(toolStart.toolCallID, "call_1")
        XCTAssertEqual(toolStart.toolName, "lookup")

        guard case .contentPartDelta(let toolDelta) = resolved[1] else {
            return XCTFail("Expected buffered tool delta to flush after tool start")
        }
        XCTAssertEqual(toolDelta.jsonDelta, "{\"query\":\"quota\"}")
    }

    func testCanonicalClaudeStreamMapperPreservesIndicesAndStopReason() {
        let mapper = CanonicalClaudeStreamMapper()
        let events =
            mapper.map(.messageStart(ClaudeMessageStartEvent(message: ClaudeMessageStart(
                id: "msg_1",
                type: "message",
                role: "assistant",
                model: "claude-sonnet-4-5"
            )))) +
            mapper.map(.contentBlockStart(ClaudeContentBlockStartEvent(
                index: 0,
                contentBlock: .text(ClaudeTextBlock(text: ""))
            ))) +
            mapper.map(.contentBlockDelta(ClaudeContentBlockDeltaEvent(
                index: 0,
                delta: .text(ClaudeTextDelta(type: "text_delta", text: "Hello"))
            ))) +
            mapper.map(.contentBlockStop(ClaudeContentBlockStopEvent(index: 0))) +
            mapper.map(.messageDelta(ClaudeMessageDeltaEvent(
                delta: ClaudeMessageDeltaContent(stopReason: "pause_turn", stopSequence: nil),
                usage: ClaudeUsageDelta(outputTokens: 7)
            ))) +
            mapper.map(.messageStop)

        XCTAssertEqual(events.count, 6)

        guard case .messageStarted(let messageStart) = events[0] else {
            return XCTFail("Expected message start")
        }
        XCTAssertEqual(messageStart.role.value, "assistant")
        XCTAssertEqual(messageStart.messageID, "msg_1")

        guard case .contentPartStarted(let contentStart) = events[1] else {
            return XCTFail("Expected content block start")
        }
        XCTAssertEqual(contentStart.index, 0)
        XCTAssertEqual(contentStart.kind.value, "text")

        guard case .contentPartDelta(let contentDelta) = events[2] else {
            return XCTFail("Expected content delta")
        }
        XCTAssertEqual(contentDelta.index, 0)
        XCTAssertEqual(contentDelta.textDelta, "Hello")

        guard case .messageDelta(let messageDelta) = events[4] else {
            return XCTFail("Expected message delta")
        }
        XCTAssertEqual(messageDelta.stop?.reason.value, "pause_turn")
        XCTAssertEqual(messageDelta.usage?.outputTokens, 7)

        guard case .messageStopped = events[5] else {
            return XCTFail("Expected message stopped event")
        }
    }

    func testCanonicalChatBuilderMatchesClaudeDirectConverter() throws {
        let mapper = CanonicalRequestMapper()
        let builder = CanonicalOpenAIRequestBuilder()
        let directConverter = ClaudeToOpenAIConverter()
        let imageSource = ClaudeImageSource(
            type: "base64",
            mediaType: "image/png",
            data: "AAAA"
        )
        let request = ClaudeMessageRequest(
            model: "claude-sonnet-4-5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .text(ClaudeTextBlock(text: "Summarize this file")),
                    .document(ClaudeDocumentBlock(
                        source: [
                            "type": AnyCodable("file"),
                            "file_id": AnyCodable("file_123")
                        ],
                        title: "report.pdf"
                    ))
                ])),
                ClaudeMessage(role: "assistant", content: .blocks([
                    .text(ClaudeTextBlock(text: "Let me inspect that")),
                    .toolUse(ClaudeToolUseBlock(
                        id: "toolu_123",
                        name: "lookup",
                        input: ["topic": AnyCodable("quota")]
                    ))
                ])),
                ClaudeMessage(role: "user", content: .blocks([
                    .toolResult(ClaudeToolResultBlock(
                        toolUseId: "toolu_123",
                        contentBlocks: [
                            .text(ClaudeTextBlock(text: "Here is the chart")),
                            .image(ClaudeImageBlock(source: imageSource))
                        ]
                    ))
                ]))
            ],
            system: "You are precise.",
            maxTokens: 1024,
            stream: true,
            tools: [
                ClaudeTool(
                    name: "lookup",
                    description: "Lookup docs",
                    inputSchema: ["type": AnyCodable("object")]
                )
            ],
            toolChoice: ClaudeToolChoice(
                type: "tool",
                name: "lookup",
                disableParallelToolUse: true
            )
        )

        let canonical = try mapper.mapClaude(request)
        let built = try builder.buildChatCompletionRequest(from: canonical, modelOverride: "gpt-4o-mini")
        let direct = try directConverter.convert(request: request, upstreamModel: "gpt-4o-mini")

        XCTAssertTrue(built.lossyNotes.isEmpty)
        XCTAssertEqual(
            try normalizedJSONString(from: built.payload, droppingKeys: ["prompt_cache_key"]),
            try normalizedJSONString(from: direct)
        )
    }

    func testCanonicalResponsesBuilderMatchesCurrentResponsesWireShape() async throws {
        let mapper = CanonicalRequestMapper()
        let builder = CanonicalOpenAIRequestBuilder()
        let directConverter = ClaudeToOpenAIConverter()
        let imageSource = ClaudeImageSource(
            type: "base64",
            mediaType: "image/png",
            data: "AAAA"
        )
        let request = ClaudeMessageRequest(
            model: "claude-sonnet-4-5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .text(ClaudeTextBlock(text: "Summarize this file")),
                    .document(ClaudeDocumentBlock(
                        source: [
                            "type": AnyCodable("file"),
                            "file_id": AnyCodable("file_123")
                        ],
                        title: "report.pdf"
                    ))
                ])),
                ClaudeMessage(role: "assistant", content: .blocks([
                    .text(ClaudeTextBlock(text: "Let me inspect that")),
                    .toolUse(ClaudeToolUseBlock(
                        id: "toolu_123",
                        name: "lookup",
                        input: ["topic": AnyCodable("quota")]
                    ))
                ])),
                ClaudeMessage(role: "user", content: .blocks([
                    .toolResult(ClaudeToolResultBlock(
                        toolUseId: "toolu_123",
                        contentBlocks: [
                            .text(ClaudeTextBlock(text: "Here is the chart")),
                            .image(ClaudeImageBlock(source: imageSource))
                        ]
                    ))
                ]))
            ],
            system: "You are precise.",
            maxTokens: 1024,
            stream: true,
            tools: [
                ClaudeTool(
                    name: "lookup",
                    description: "Lookup docs",
                    inputSchema: ["type": AnyCodable("object")]
                )
            ],
            toolChoice: ClaudeToolChoice(
                type: "tool",
                name: "lookup",
                disableParallelToolUse: true
            )
        )

        let canonical = try mapper.mapClaude(request)
        let built = try builder.buildResponsesRequest(from: canonical, modelOverride: "gpt-4o-mini")
        let directChatRequest = try directConverter.convert(request: request, upstreamModel: "gpt-4o-mini")

        let upstreamPort = try findFreePort()
        let upstream = MockHTTPServer(port: upstreamPort) { _ in
            MockHTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: [
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_shadow\",\"object\":\"response\",\"created_at\":1710000000,\"model\":\"gpt-4o-mini\",\"status\":\"completed\",\"output\":[{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"input_tokens\":12,\"output_tokens\":2,\"total_tokens\":14}}}\n\n"
                ]
            )
        }
        try await upstream.start()
        defer { upstream.stop() }

        let client = OpenAICompatibleClient(configuration: ClaudeProxyConfiguration(
            enabled: true,
            upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
            openAIUpstreamAPI: .responses,
            upstreamAPIKey: "upstream-key"
        ))

        try await client.streamResponses(request: built.payload) { _ in }

        let requests = await upstream.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(built.lossyNotes.isEmpty)
        XCTAssertEqual(
            try normalizedJSONString(from: built.payload),
            try normalizedJSONString(from: try XCTUnwrap(requests.first).body)
        )
    }

    func testCanonicalBuilderRecordsLossyDocumentDowngrade() throws {
        let mapper = CanonicalRequestMapper()
        let builder = CanonicalOpenAIRequestBuilder()
        let request = ClaudeMessageRequest(
            model: "claude-sonnet-4-5",
            messages: [
                ClaudeMessage(role: "user", content: .blocks([
                    .document(ClaudeDocumentBlock(
                        source: [
                            "type": AnyCodable("url"),
                            "url": AnyCodable("https://example.com/spec")
                        ],
                        title: "Spec"
                    ))
                ]))
            ],
            maxTokens: 512
        )

        let canonical = try mapper.mapClaude(request)
        let built = try builder.buildChatCompletionRequest(from: canonical, modelOverride: "gpt-4o-mini")

        XCTAssertEqual(built.lossyNotes.count, 1)
        XCTAssertEqual(built.lossyNotes.first?.code, "chat_document_url_degraded")
        guard let firstMessage = built.payload.messages.first else {
            return XCTFail("Expected degraded chat message")
        }
        guard case .text(let text) = firstMessage.content else {
            return XCTFail("Expected degraded document to become text content")
        }
        XCTAssertTrue(text.contains("[Claude document degraded during OpenAI proxy conversion]"))
    }

    func testCanonicalClaudeResponseBuilderMatchesDirectOpenAIToClaudeConverter() throws {
        let mapper = CanonicalResponseMapper()
        let builder = CanonicalClaudeResponseBuilder()
        let directConverter = OpenAIToClaudeConverter()
        let response = OpenAIChatCompletionResponse(
            id: "chatcmpl_canonical_1",
            created: 1_710_000_000,
            model: "gpt-4o-mini",
            choices: [
                OpenAIChoice(
                    index: 0,
                    message: OpenAIChatMessage(
                        role: "assistant",
                        content: .parts([
                            .text(OpenAITextPart(text: "Please inspect this file.")),
                            .inputFile(OpenAIFilePart(fileId: "file_123", filename: "report.pdf"))
                        ]),
                        toolCalls: [
                            OpenAIToolCall(
                                id: "call_1",
                                function: OpenAIFunctionCall(
                                    name: "lookup",
                                    arguments: #"{"topic":"quota"}"#
                                )
                            )
                        ]
                    ),
                    finishReason: "tool_calls"
                )
            ],
            usage: OpenAIUsage(promptTokens: 10, completionTokens: 4, totalTokens: 14)
        )

        let canonical = try mapper.mapOpenAIChatCompletions(response)
        let built = try builder.buildMessageResponse(from: canonical, originalModel: "claude-sonnet-4-5")
        let direct = try directConverter.convert(response: response, originalModel: "claude-sonnet-4-5")

        XCTAssertTrue(built.lossyNotes.isEmpty)
        XCTAssertEqual(try normalizedJSONString(from: built.payload), try normalizedJSONString(from: direct))
    }

    func testCanonicalClaudeStreamBuilderMapsToolLifecycle() {
        let builder = CanonicalClaudeStreamBuilder()
        let events: [CanonicalStreamEvent] = [
            .messageStarted(CanonicalStreamMessageStarted(
                role: .assistant,
                messageID: "msg_1",
                model: "claude-sonnet-4-5"
            )),
            .contentPartStarted(CanonicalStreamContentPartStarted(
                index: 0,
                kind: .toolCall,
                toolCallID: "toolu_1",
                toolName: "lookup"
            )),
            .contentPartDelta(CanonicalStreamContentPartDelta(
                index: 0,
                kind: .toolCall,
                jsonDelta: #"{"topic":"quota"}"#
            )),
            .contentPartStopped(CanonicalStreamContentPartStopped(index: 0)),
            .messageDelta(CanonicalStreamMessageDelta(
                stop: CanonicalStop(reason: .toolUse),
                usage: CanonicalUsage(outputTokens: 4)
            )),
            .messageStopped
        ]

        let claudeEvents = events.flatMap(builder.build)
        XCTAssertEqual(claudeEvents.count, 6)

        guard case .messageStart(let messageStart) = claudeEvents[0] else {
            return XCTFail("Expected message_start")
        }
        XCTAssertEqual(messageStart.message.id, "msg_1")
        XCTAssertEqual(messageStart.message.model, "claude-sonnet-4-5")
        XCTAssertTrue(messageStart.message.content.isEmpty)
        XCTAssertNil(messageStart.message.stopReason)
        XCTAssertNil(messageStart.message.stopSequence)
        XCTAssertEqual(messageStart.message.usage.inputTokens, 0)
        XCTAssertEqual(messageStart.message.usage.outputTokens, 0)

        guard case .contentBlockStart(let blockStart) = claudeEvents[1] else {
            return XCTFail("Expected tool content block start")
        }
        XCTAssertEqual(blockStart.index, 0)
        guard case .toolUse(let toolUseBlock) = blockStart.contentBlock else {
            return XCTFail("Expected tool_use block")
        }
        XCTAssertEqual(toolUseBlock.id, "toolu_1")
        XCTAssertEqual(toolUseBlock.name, "lookup")

        guard case .contentBlockDelta(let deltaEvent) = claudeEvents[2] else {
            return XCTFail("Expected input_json_delta")
        }
        guard case .inputJson(let inputJsonDelta) = deltaEvent.delta else {
            return XCTFail("Expected Claude input_json_delta")
        }
        XCTAssertEqual(inputJsonDelta.partialJson, #"{"topic":"quota"}"#)

        guard case .messageDelta(let messageDelta) = claudeEvents[4] else {
            return XCTFail("Expected message_delta")
        }
        XCTAssertEqual(messageDelta.delta.stopReason, "tool_use")
        XCTAssertEqual(messageDelta.usage.outputTokens, 4)

        guard case .messageStop = claudeEvents[5] else {
            return XCTFail("Expected message_stop")
        }
    }
}

private func normalizedJSONString<T: Encodable>(from value: T, droppingKeys: Set<String> = []) throws -> String {
    let encoded = try JSONEncoder().encode(value)
    return try normalizedJSONString(from: encoded, droppingKeys: droppingKeys)
}

private func normalizedJSONString(from data: Data, droppingKeys: Set<String> = []) throws -> String {
    var object = try JSONSerialization.jsonObject(with: data)
    if !droppingKeys.isEmpty, var dict = object as? [String: Any] {
        for key in droppingKeys { dict.removeValue(forKey: key) }
        object = dict
    }
    let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: normalized, encoding: .utf8) ?? ""
}
