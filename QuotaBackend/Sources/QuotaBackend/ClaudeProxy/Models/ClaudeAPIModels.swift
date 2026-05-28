import Foundation

// MARK: - Claude API Request Models

public struct ClaudeMessageRequest: Codable, Sendable {
    public let model: String
    public let messages: [ClaudeMessage]
    public let system: String?
    public let systemBlocks: [ClaudeSystemBlock]?
    public let maxTokens: Int
    public let temperature: Double?
    public let topP: Double?
    public let topK: Int?
    public let stopSequences: [String]?
    public let stream: Bool?
    public let tools: [ClaudeTool]?
    public let toolChoice: ClaudeToolChoice?
    public let metadata: ClaudeMetadata?
    public let thinking: ClaudeThinkingConfig?
    public let outputConfig: ClaudeOutputConfig?

    enum CodingKeys: String, CodingKey {
        case model, messages, system, temperature, tools, metadata, stream, thinking
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case stopSequences = "stop_sequences"
        case toolChoice = "tool_choice"
        case outputConfig = "output_config"
    }

    public init(
        model: String,
        messages: [ClaudeMessage],
        system: String? = nil,
        systemBlocks: [ClaudeSystemBlock]? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        stopSequences: [String]? = nil,
        stream: Bool? = nil,
        tools: [ClaudeTool]? = nil,
        toolChoice: ClaudeToolChoice? = nil,
        metadata: ClaudeMetadata? = nil,
        thinking: ClaudeThinkingConfig? = nil,
        outputConfig: ClaudeOutputConfig? = nil
    ) {
        self.model = model
        self.messages = messages
        self.system = system ?? systemBlocks?.compactMap(\.text).joined(separator: "\n")
        self.systemBlocks = systemBlocks
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.stopSequences = stopSequences
        self.stream = stream
        self.tools = tools
        self.toolChoice = toolChoice
        self.metadata = metadata
        self.thinking = thinking
        self.outputConfig = outputConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        messages = try container.decode([ClaudeMessage].self, forKey: .messages)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK)
        stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences)
        stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
        tools = try container.decodeIfPresent([ClaudeTool].self, forKey: .tools)
        toolChoice = try container.decodeIfPresent(ClaudeToolChoice.self, forKey: .toolChoice)
        metadata = try container.decodeIfPresent(ClaudeMetadata.self, forKey: .metadata)
        thinking = try container.decodeIfPresent(ClaudeThinkingConfig.self, forKey: .thinking)
        outputConfig = try container.decodeIfPresent(ClaudeOutputConfig.self, forKey: .outputConfig)

        if let text = try? container.decodeIfPresent(String.self, forKey: .system) {
            system = text
            systemBlocks = nil
        } else if let blocks = try? container.decodeIfPresent([SystemBlock].self, forKey: .system) {
            systemBlocks = blocks.map { ClaudeSystemBlock(type: $0.type, text: $0.text, cacheControl: $0.cacheControl) }
            system = blocks.compactMap { $0.text }.joined(separator: "\n")
        } else {
            system = nil
            systemBlocks = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        if let systemBlocks, !systemBlocks.isEmpty {
            try container.encode(systemBlocks, forKey: .system)
        } else {
            try container.encodeIfPresent(system, forKey: .system)
        }
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(topP, forKey: .topP)
        try container.encodeIfPresent(topK, forKey: .topK)
        try container.encodeIfPresent(stopSequences, forKey: .stopSequences)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
    }

    private struct SystemBlock: Codable {
        let type: String?
        let text: String?
        let cacheControl: [String: AnyCodable]?

        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }
    }
}

public struct ClaudeSystemBlock: Codable, Sendable {
    public let type: String?
    public let text: String?
    public let cacheControl: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    public init(type: String?, text: String?, cacheControl: [String: AnyCodable]? = nil) {
        self.type = type
        self.text = text
        self.cacheControl = cacheControl
    }
}

public struct ClaudeMessage: Codable, Sendable {
    public let role: String
    public let content: ClaudeContent

    public init(role: String, content: ClaudeContent) {
        self.role = role
        self.content = content
    }
}

public enum ClaudeContent: Codable, Sendable {
    case text(String)
    case blocks([ClaudeContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let blocks = try? container.decode([ClaudeContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Content must be string or array of blocks"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

public enum ClaudeContentBlock: Codable, Sendable {
    case text(ClaudeTextBlock)
    case image(ClaudeImageBlock)
    case document(ClaudeDocumentBlock)
    case toolUse(ClaudeToolUseBlock)
    case toolResult(ClaudeToolResultBlock)
    case thinking(ClaudeThinkingBlock)
    case redactedThinking(ClaudeRedactedThinkingBlock)
    case unknown(ClaudeUnknownContentBlock)

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try ClaudeTextBlock(from: decoder))
        case "image":
            self = .image(try ClaudeImageBlock(from: decoder))
        case "document":
            self = .document(try ClaudeDocumentBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ClaudeToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try ClaudeToolResultBlock(from: decoder))
        case "thinking":
            self = .thinking(try ClaudeThinkingBlock(from: decoder))
        case "redacted_thinking":
            self = .redactedThinking(try ClaudeRedactedThinkingBlock(from: decoder))
        default:
            self = .unknown(try ClaudeUnknownContentBlock(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .image(let block):
            try block.encode(to: encoder)
        case .document(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        case .thinking(let block):
            try block.encode(to: encoder)
        case .redactedThinking(let block):
            try block.encode(to: encoder)
        case .unknown(let block):
            try block.encode(to: encoder)
        }
    }
}

public struct ClaudeTextBlock: Codable, Sendable {
    public let type: String
    public let text: String
    public let cacheControl: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }

    public init(text: String, cacheControl: [String: AnyCodable]? = nil) {
        self.type = "text"
        self.text = text
        self.cacheControl = cacheControl
    }
}

public struct ClaudeImageBlock: Codable, Sendable {
    public let type: String
    public let source: ClaudeImageSource

    enum CodingKeys: String, CodingKey {
        case type, source
    }

    public init(source: ClaudeImageSource) {
        self.type = "image"
        self.source = source
    }
}

public struct ClaudeImageSource: Codable, Sendable {
    public let type: String
    public let mediaType: String?
    public let data: String?
    public let url: String?

    enum CodingKeys: String, CodingKey {
        case type, data, url
        case mediaType = "media_type"
    }

    public init(type: String = "base64", mediaType: String, data: String) {
        self.type = type
        self.mediaType = mediaType
        self.data = data
        self.url = nil
    }

    public init(url: String) {
        self.type = "url"
        self.url = url
        self.mediaType = nil
        self.data = nil
    }
}

public struct ClaudeDocumentBlock: Codable, Sendable {
    public let type: String
    public let source: [String: AnyCodable]
    public let title: String?
    public let context: String?
    public let citations: AnyCodable?
    public let cacheControl: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case type, source, title, context, citations
        case cacheControl = "cache_control"
    }

    public init(
        source: [String: AnyCodable],
        title: String? = nil,
        context: String? = nil,
        citations: AnyCodable? = nil,
        cacheControl: [String: AnyCodable]? = nil
    ) {
        self.type = "document"
        self.source = source
        self.title = title
        self.context = context
        self.citations = citations
        self.cacheControl = cacheControl
    }
}

public struct ClaudeToolUseBlock: Codable, Sendable {
    public let type: String
    public let id: String
    public let name: String
    public let input: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case type, id, name, input
    }

    public init(id: String, name: String, input: [String: AnyCodable]) {
        self.type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ClaudeToolResultBlock: Codable, Sendable {
    public let type: String
    public let toolUseId: String
    public let content: String?
    public let contentBlocks: [ClaudeContentBlock]?
    public let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }

    public init(toolUseId: String, content: String?, isError: Bool? = nil) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
        self.contentBlocks = nil
        self.isError = isError
    }

    public init(toolUseId: String, contentBlocks: [ClaudeContentBlock], isError: Bool? = nil) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.contentBlocks = contentBlocks
        self.content = contentBlocks.compactMap { block -> String? in
            if case .text(let textBlock) = block {
                return textBlock.text
            }
            return nil
        }.joined(separator: "\n")
        self.isError = isError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        toolUseId = try container.decode(String.self, forKey: .toolUseId)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)

        if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            content = text
            contentBlocks = nil
        } else if let blocks = try? container.decodeIfPresent([ClaudeContentBlock].self, forKey: .content) {
            contentBlocks = blocks
            content = blocks.compactMap { block -> String? in
                if case .text(let textBlock) = block {
                    return textBlock.text
                }
                return nil
            }.joined(separator: "\n")
        } else {
            content = nil
            contentBlocks = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(toolUseId, forKey: .toolUseId)
        try container.encodeIfPresent(isError, forKey: .isError)
        if let contentBlocks {
            try container.encode(contentBlocks, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }
    }
}

public struct ClaudeTool: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: [String: AnyCodable]
    public let eagerInputStreaming: Bool?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case eagerInputStreaming = "eager_input_streaming"
    }

    public init(
        name: String,
        description: String?,
        inputSchema: [String: AnyCodable],
        eagerInputStreaming: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.eagerInputStreaming = eagerInputStreaming
    }
}

public struct ClaudeToolChoice: Codable, Sendable {
    public let type: String
    public let name: String?
    public let disableParallelToolUse: Bool?

    enum CodingKeys: String, CodingKey {
        case type, name
        case disableParallelToolUse = "disable_parallel_tool_use"
    }

    public init(type: String, name: String? = nil, disableParallelToolUse: Bool? = nil) {
        self.type = type
        self.name = name
        self.disableParallelToolUse = disableParallelToolUse
    }
}

public struct ClaudeThinkingBlock: Codable, Sendable {
    public let type: String
    public let thinking: String
    public let signature: String?

    public init(thinking: String, signature: String? = nil) {
        self.type = "thinking"
        self.thinking = thinking
        self.signature = signature
    }
}

public struct ClaudeRedactedThinkingBlock: Codable, Sendable {
    public let type: String
    public let data: String

    public init(data: String) {
        self.type = "redacted_thinking"
        self.data = data
    }
}

public struct ClaudeUnknownContentBlock: Codable, Sendable {
    public let type: String
    public let payload: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(type: String, payload: [String: AnyCodable]) {
        self.type = type
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode([String: AnyCodable].self)
        self.payload = payload
        self.type = payload["type"]?.value as? String ?? "unknown"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
}

public struct ClaudeMetadata: Codable, Sendable {
    public let userId: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }

    public init(userId: String?) {
        self.userId = userId
    }
}

// MARK: - Claude Extended Thinking & Output Config

public struct ClaudeThinkingConfig: Codable, Sendable {
    public let type: String
    public let budgetTokens: Int?
    public let display: String?

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
        case display
    }

    public init(type: String, budgetTokens: Int? = nil, display: String? = nil) {
        self.type = type
        self.budgetTokens = budgetTokens
        self.display = display
    }
}

public struct ClaudeOutputConfig: Codable, Sendable {
    public let effort: String?
    public let format: ClaudeOutputFormat?

    public init(effort: String? = nil, format: ClaudeOutputFormat? = nil) {
        self.effort = effort
        self.format = format
    }
}

public struct ClaudeOutputFormat: Codable, Sendable {
    public let type: String
    public let schema: [String: AnyCodable]?

    public init(type: String, schema: [String: AnyCodable]? = nil) {
        self.type = type
        self.schema = schema
    }
}

// MARK: - Claude API Response Models

public struct ClaudeMessageResponse: Codable, Sendable {
    public let id: String
    public let type: String
    public let role: String
    public let content: [ClaudeContentBlock]
    public let model: String
    public let stopReason: String?
    public let stopSequence: String?
    public let usage: ClaudeUsage

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model, usage
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }

    public init(
        id: String,
        type: String = "message",
        role: String,
        content: [ClaudeContentBlock],
        model: String,
        stopReason: String?,
        stopSequence: String?,
        usage: ClaudeUsage
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.usage = usage
    }
}

public struct ClaudeUsage: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

// MARK: - Claude Token Count Request/Response

public struct ClaudeTokenCountRequest: Codable, Sendable {
    public let model: String
    public let messages: [ClaudeMessage]
    public let system: String?
    public let systemBlocks: [ClaudeSystemBlock]?
    public let tools: [ClaudeTool]?

    public init(
        model: String,
        messages: [ClaudeMessage],
        system: String?,
        systemBlocks: [ClaudeSystemBlock]? = nil,
        tools: [ClaudeTool]?
    ) {
        self.model = model
        self.messages = messages
        self.system = system ?? systemBlocks?.compactMap(\.text).joined(separator: "\n")
        self.systemBlocks = systemBlocks
        self.tools = tools
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, system, tools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        messages = try container.decode([ClaudeMessage].self, forKey: .messages)
        tools = try container.decodeIfPresent([ClaudeTool].self, forKey: .tools)

        if let text = try? container.decodeIfPresent(String.self, forKey: .system) {
            system = text
            systemBlocks = nil
        } else if let blocks = try? container.decodeIfPresent([ClaudeSystemBlock].self, forKey: .system) {
            systemBlocks = blocks
            system = blocks.compactMap { $0.text }.joined(separator: "\n")
        } else {
            system = nil
            systemBlocks = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        if let systemBlocks, !systemBlocks.isEmpty {
            try container.encode(systemBlocks, forKey: .system)
        } else {
            try container.encodeIfPresent(system, forKey: .system)
        }
        try container.encodeIfPresent(tools, forKey: .tools)
    }
}

/// Response for `POST /v1/messages/count_tokens`.
///
/// When produced by AIUsage's Claude proxy, `input_tokens` is a **heuristic** estimate (character-based),
/// not a tokenizer-accurate count; clients should treat it as approximate for display or rough limits only.
public struct ClaudeTokenCountResponse: Codable, Sendable {
    public let inputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
    }

    public init(inputTokens: Int) {
        self.inputTokens = inputTokens
    }
}

// MARK: - Claude Files API Models

public struct ClaudeFileScope: Codable, Sendable {
    public let type: String
    public let id: String?

    public init(type: String, id: String? = nil) {
        self.type = type
        self.id = id
    }
}

public struct ClaudeFileObject: Codable, Sendable {
    public let id: String
    public let type: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let createdAt: String
    public let downloadable: Bool
    public let scope: ClaudeFileScope?

    enum CodingKeys: String, CodingKey {
        case id, type, filename, downloadable, scope
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        type: String = "file",
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        createdAt: String,
        downloadable: Bool,
        scope: ClaudeFileScope? = nil
    ) {
        self.id = id
        self.type = type
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.downloadable = downloadable
        self.scope = scope
    }
}

public struct ClaudeFilesListResponse: Codable, Sendable {
    public let data: [ClaudeFileObject]
    public let hasMore: Bool
    public let firstId: String?
    public let lastId: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case firstId = "first_id"
        case lastId = "last_id"
    }

    public init(data: [ClaudeFileObject], hasMore: Bool, firstId: String?, lastId: String?) {
        self.data = data
        self.hasMore = hasMore
        self.firstId = firstId
        self.lastId = lastId
    }
}

public struct ClaudeDeletedFileResponse: Codable, Sendable {
    public let id: String
    public let type: String
    public let deleted: Bool

    public init(id: String, type: String = "file", deleted: Bool) {
        self.id = id
        self.type = type
        self.deleted = deleted
    }
}

// MARK: - Claude Error Response

public struct ClaudeErrorResponse: Codable, Sendable {
    public let type: String
    public let error: ClaudeError
    public let requestID: String?

    enum CodingKeys: String, CodingKey {
        case type, error
        case requestID = "request_id"
    }

    public init(type: String = "error", error: ClaudeError, requestID: String? = nil) {
        self.type = type
        self.error = error
        self.requestID = requestID
    }
}

public struct ClaudeError: Codable, Sendable {
    public let type: String
    public let message: String

    public init(type: String, message: String) {
        self.type = type
        self.message = message
    }
}
