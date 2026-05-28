import Foundation

// MARK: - OpenAI API Request Models

public struct OpenAIChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [OpenAIChatMessage]
    public let temperature: Double?
    public let topP: Double?
    public let maxTokens: Int?
    public let stop: [String]?
    public let stream: Bool?
    public let streamOptions: StreamOptions?
    public let tools: [OpenAITool]?
    public let toolChoice: OpenAIToolChoice?
    public let parallelToolCalls: Bool?
    /// OpenAI routing hint for prefix caching — requests with the same key
    /// are more likely to land on the same inference engine, improving cache hits.
    public let promptCacheKey: String?

    public struct StreamOptions: Codable, Sendable {
        public let includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        public init(includeUsage: Bool = true) { self.includeUsage = includeUsage }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stop, stream, tools
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case streamOptions = "stream_options"
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case promptCacheKey = "prompt_cache_key"
    }

    public init(
        model: String,
        messages: [OpenAIChatMessage],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stop: [String]? = nil,
        stream: Bool? = nil,
        streamOptions: StreamOptions? = nil,
        tools: [OpenAITool]? = nil,
        toolChoice: OpenAIToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        promptCacheKey: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stop = stop
        self.stream = stream
        self.streamOptions = streamOptions
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.promptCacheKey = promptCacheKey
    }
}

public struct OpenAIChatMessage: Codable, Sendable {
    public let role: String
    public let content: OpenAIMessageContent?
    public let name: String?
    public let toolCalls: [OpenAIToolCall]?
    public let toolCallId: String?
    /// DeepSeek reasoning_content field (chain-of-thought output)
    public let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }

    public init(
        role: String,
        content: OpenAIMessageContent? = nil,
        name: String? = nil,
        toolCalls: [OpenAIToolCall]? = nil,
        toolCallId: String? = nil,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.reasoningContent = reasoningContent
    }
}

public enum OpenAIMessageContent: Codable, Sendable {
    case text(String)
    case parts([OpenAIContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let parts = try? container.decode([OpenAIContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Content must be string or array of parts"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

public enum OpenAIContentPart: Codable, Sendable {
    case text(OpenAITextPart)
    case imageUrl(OpenAIImageUrlPart)
    case inputFile(OpenAIFilePart)
    case unknown(OpenAIUnknownContentPart)

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try OpenAITextPart(from: decoder))
        case "image_url":
            self = .imageUrl(try OpenAIImageUrlPart(from: decoder))
        case "input_file", "file":
            self = .inputFile(try OpenAIFilePart(from: decoder))
        default:
            self = .unknown(try OpenAIUnknownContentPart(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let part):
            try part.encode(to: encoder)
        case .imageUrl(let part):
            try part.encode(to: encoder)
        case .inputFile(let part):
            try OpenAIChatFilePartEnvelope(fileId: part.fileId, filename: part.filename).encode(to: encoder)
        case .unknown(let part):
            try part.encode(to: encoder)
        }
    }
}

public struct OpenAIUnknownContentPart: Codable, Sendable {
    public let type: String
    public let payload: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(type: String, payload: [String: AnyCodable] = [:]) {
        self.type = type
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: AnyCodable].self)
        self.payload = raw
        self.type = raw["type"]?.value as? String ?? "unknown"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
}

public struct OpenAITextPart: Codable, Sendable {
    public let type: String
    public let text: String

    enum CodingKeys: String, CodingKey {
        case type, text
    }

    public init(text: String) {
        self.type = "text"
        self.text = text
    }
}

public struct OpenAIImageUrlPart: Codable, Sendable {
    public let type: String
    public let imageUrl: OpenAIImageUrl

    enum CodingKeys: String, CodingKey {
        case type
        case imageUrl = "image_url"
    }

    public init(imageUrl: OpenAIImageUrl) {
        self.type = "image_url"
        self.imageUrl = imageUrl
    }
}

public struct OpenAIFilePart: Codable, Sendable {
    public let type: String
    public let fileId: String?
    public let filename: String?

    enum CodingKeys: String, CodingKey {
        case type, filename, file
        case fileId = "file_id"
    }

    enum NestedFileKeys: String, CodingKey {
        case filename
        case fileId = "file_id"
    }

    public init(type: String = "input_file", fileId: String? = nil, filename: String? = nil) {
        self.type = type
        self.fileId = fileId
        self.filename = filename
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        self.type = type
        if type == "file", container.contains(.file) {
            let fileContainer = try container.nestedContainer(keyedBy: NestedFileKeys.self, forKey: .file)
            self.fileId = try fileContainer.decodeIfPresent(String.self, forKey: .fileId)
            self.filename = try fileContainer.decodeIfPresent(String.self, forKey: .filename)
        } else {
            self.fileId = try container.decodeIfPresent(String.self, forKey: .fileId)
            self.filename = try container.decodeIfPresent(String.self, forKey: .filename)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        if type == "file" {
            var fileContainer = container.nestedContainer(keyedBy: NestedFileKeys.self, forKey: .file)
            try fileContainer.encodeIfPresent(fileId, forKey: .fileId)
            try fileContainer.encodeIfPresent(filename, forKey: .filename)
        } else {
            try container.encodeIfPresent(fileId, forKey: .fileId)
            try container.encodeIfPresent(filename, forKey: .filename)
        }
    }
}

private struct OpenAIChatFilePartEnvelope: Encodable {
    let type = "file"
    let file: OpenAIChatFileDescriptor

    init(fileId: String?, filename: String?) {
        self.file = OpenAIChatFileDescriptor(fileId: fileId, filename: filename)
    }
}

private struct OpenAIChatFileDescriptor: Encodable {
    let fileId: String?
    let filename: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case fileId = "file_id"
    }
}

public struct OpenAIImageUrl: Codable, Sendable {
    public let url: String
    public let detail: String?

    public init(url: String, detail: String? = nil) {
        self.url = url
        self.detail = detail
    }
}

public struct OpenAIToolCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let function: OpenAIFunctionCall

    public init(id: String, type: String = "function", function: OpenAIFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunctionCall: Codable, Sendable {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct OpenAITool: Codable, Sendable {
    public let type: String
    public let function: OpenAIFunction

    public init(type: String = "function", function: OpenAIFunction) {
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunction: Codable, Sendable {
    public let name: String
    public let description: String?
    public let parameters: [String: AnyCodable]?

    public init(name: String, description: String?, parameters: [String: AnyCodable]?) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum OpenAIToolChoice: Codable, Sendable {
    case none
    case auto
    case required
    case function(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            switch str {
            case "none": self = .none
            case "auto": self = .auto
            case "required": self = .required
            default: self = .auto
            }
        } else {
            let object = try container.decode(OpenAIToolChoiceObject.self)
            if object.type == "function", let name = object.function?.name {
                self = .function(name)
            } else {
                self = .auto
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode("none")
        case .auto:
            try container.encode("auto")
        case .required:
            try container.encode("required")
        case .function(let name):
            try container.encode(OpenAIToolChoiceObject(
                type: "function",
                function: OpenAIToolChoiceFunction(name: name)
            ))
        }
    }
}

private struct OpenAIToolChoiceObject: Codable, Sendable {
    let type: String
    let function: OpenAIToolChoiceFunction?
}

private struct OpenAIToolChoiceFunction: Codable, Sendable {
    let name: String
}

// MARK: - OpenAI API Response Models

public struct OpenAIChatCompletionResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [OpenAIChoice]
    public let usage: OpenAIUsage?

    public init(
        id: String,
        object: String = "chat.completion",
        created: Int,
        model: String,
        choices: [OpenAIChoice],
        usage: OpenAIUsage?
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

public struct OpenAIChoice: Codable, Sendable {
    public let index: Int
    public let message: OpenAIChatMessage
    public let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, message
        case finishReason = "finish_reason"
    }

    public init(index: Int, message: OpenAIChatMessage, finishReason: String?) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }
}

public struct OpenAIUsage: Codable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    /// DeepSeek: prompt_cache_hit_tokens (tokens served from context cache)
    public let promptCacheHitTokens: Int?
    /// DeepSeek: prompt_cache_miss_tokens (tokens not served from cache)
    public let promptCacheMissTokens: Int?
    /// OpenAI 2024-10+ and downstreams that mirror the official shape (e.g. OpenRouter, Kimi):
    /// prompt cache info is nested under `prompt_tokens_details.cached_tokens`.
    public let promptTokensDetails: PromptTokensDetails?

    public struct PromptTokensDetails: Codable, Sendable {
        public let cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }

        public init(cachedTokens: Int? = nil) {
            self.cachedTokens = cachedTokens
        }
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptCacheMissTokens = "prompt_cache_miss_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    public init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        promptCacheHitTokens: Int? = nil,
        promptCacheMissTokens: Int? = nil,
        promptTokensDetails: PromptTokensDetails? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptCacheHitTokens = promptCacheHitTokens
        self.promptCacheMissTokens = promptCacheMissTokens
        self.promptTokensDetails = promptTokensDetails
    }

    /// Tokens served from the prompt cache, normalized across vendor shapes.
    /// Returns nil when the upstream reports no cache signal at all (not 0,
    /// so downstream billing can distinguish "no cache" from "0 hits").
    public var effectiveCachedTokens: Int? {
        promptCacheHitTokens ?? promptTokensDetails?.cachedTokens
    }

    /// Uncached prompt size. Prefers an explicit miss field (DeepSeek);
    /// otherwise subtracts the cache-read portion from promptTokens so the
    /// hit portion is not billed at both input and cache-read prices.
    public var effectiveInputTokens: Int {
        if let miss = promptCacheMissTokens { return miss }
        return max(promptTokens - (effectiveCachedTokens ?? 0), 0)
    }
}

public struct OpenAIFileObject: Codable, Sendable {
    public let id: String
    public let object: String
    public let bytes: Int?
    public let createdAt: Int?
    public let filename: String?
    public let purpose: String?
    public let status: String?
    public let mimeType: String?
    public let deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, object, bytes, filename, purpose, status, deleted
        case createdAt = "created_at"
        case mimeType = "mime_type"
    }

    public init(
        id: String,
        object: String = "file",
        bytes: Int? = nil,
        createdAt: Int? = nil,
        filename: String? = nil,
        purpose: String? = nil,
        status: String? = nil,
        mimeType: String? = nil,
        deleted: Bool? = nil
    ) {
        self.id = id
        self.object = object
        self.bytes = bytes
        self.createdAt = createdAt
        self.filename = filename
        self.purpose = purpose
        self.status = status
        self.mimeType = mimeType
        self.deleted = deleted
    }
}

public struct OpenAIFileListResponse: Codable, Sendable {
    public let object: String
    public let data: [OpenAIFileObject]
    public let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case object, data
        case hasMore = "has_more"
    }

    public init(object: String = "list", data: [OpenAIFileObject], hasMore: Bool? = nil) {
        self.object = object
        self.data = data
        self.hasMore = hasMore
    }
}

public struct OpenAIDeletedFileResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let deleted: Bool

    public init(id: String, object: String = "file", deleted: Bool) {
        self.id = id
        self.object = object
        self.deleted = deleted
    }
}

public struct OpenAIFileContentResponse: Sendable {
    public let data: Data
    public let contentType: String?
    public let contentDisposition: String?

    public init(data: Data, contentType: String? = nil, contentDisposition: String? = nil) {
        self.data = data
        self.contentType = contentType
        self.contentDisposition = contentDisposition
    }
}

// MARK: - OpenAI Streaming Response Models

public struct OpenAIStreamChunk: Codable, Sendable {
    public let id: String
    public let object: String
    public let created: Int
    public let model: String
    public let choices: [OpenAIStreamChoice]
    public let usage: OpenAIUsage?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
    }

    public init(id: String, object: String = "chat.completion.chunk", created: Int, model: String, choices: [OpenAIStreamChoice], usage: OpenAIUsage? = nil) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decode(String.self, forKey: .object)
        created = try container.decode(Int.self, forKey: .created)
        model = try container.decode(String.self, forKey: .model)
        choices = try container.decode([OpenAIStreamChoice].self, forKey: .choices)
        // DeepSeek-v4 sends "usage": {} in intermediate chunks which cannot
        // be decoded into OpenAIUsage (required Int fields missing). Treat
        // any decode failure as nil so the chunk itself is not discarded.
        usage = try? container.decode(OpenAIUsage.self, forKey: .usage)
    }
}

public struct OpenAIStreamChoice: Codable, Sendable {
    public let index: Int
    public let delta: OpenAIDelta
    public let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }

    public init(index: Int, delta: OpenAIDelta, finishReason: String?) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
    }
}

public struct OpenAIDelta: Codable, Sendable {
    public let role: String?
    public let content: String?
    public let toolCalls: [OpenAIToolCallDelta]?
    /// DeepSeek reasoning_content field (chain-of-thought / thinking output)
    public let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case reasoningContent = "reasoning_content"
    }

    public init(role: String? = nil, content: String? = nil, toolCalls: [OpenAIToolCallDelta]? = nil, reasoningContent: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
    }
}

public struct OpenAIToolCallDelta: Codable, Sendable {
    public let index: Int
    public let id: String?
    public let type: String?
    public let function: OpenAIFunctionDelta?

    public init(index: Int, id: String?, type: String?, function: OpenAIFunctionDelta?) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunctionDelta: Codable, Sendable {
    public let name: String?
    public let arguments: String?

    public init(name: String?, arguments: String?) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - OpenAI Error Response

public struct OpenAIErrorResponse: Codable, Sendable {
    public let error: OpenAIError

    public init(error: OpenAIError) {
        self.error = error
    }
}

public struct OpenAIError: Codable, Sendable {
    public let message: String
    public let type: String?
    public let code: String?

    public init(message: String, type: String?, code: String?) {
        self.message = message
        self.type = type
        self.code = code
    }
}
