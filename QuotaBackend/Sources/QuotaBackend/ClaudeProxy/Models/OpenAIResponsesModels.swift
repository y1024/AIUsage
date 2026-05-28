import Foundation

// MARK: - Responses API Request Models

public struct OpenAIResponsesRequest: Codable, Sendable {
    public let model: String
    public let input: [OpenAIResponsesInputItem]
    public let temperature: Double?
    public let topP: Double?
    public let maxOutputTokens: Int?
    public let stream: Bool?
    public let store: Bool?
    public let tools: [OpenAIResponsesTool]?
    public let toolChoice: OpenAIResponsesToolChoice?
    public let parallelToolCalls: Bool?

    enum CodingKeys: String, CodingKey {
        case model, input, temperature, stream, store, tools
        case topP = "top_p"
        case maxOutputTokens = "max_output_tokens"
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
    }

    public init(
        model: String,
        input: [OpenAIResponsesInputItem],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        stream: Bool? = nil,
        store: Bool? = false,
        tools: [OpenAIResponsesTool]? = nil,
        toolChoice: OpenAIResponsesToolChoice? = nil,
        parallelToolCalls: Bool? = nil
    ) {
        self.model = model
        self.input = input
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.stream = stream
        self.store = store
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
    }
}

public enum OpenAIResponsesAssistantPhase: String, Codable, Sendable {
    case commentary
    case finalAnswer = "final_answer"
}

public enum OpenAIResponsesInputItem: Codable, Sendable {
    case message(OpenAIResponsesInputMessage)
    case functionCall(OpenAIResponsesFunctionCall)
    case functionCallOutput(OpenAIResponsesFunctionCallOutput)
    case reasoning(OpenAIResponsesReasoningItem)
    case compaction(OpenAIResponsesCompactionItem)
    case computerCall(OpenAIResponsesComputerCall)
    case computerCallOutput(OpenAIResponsesComputerCallOutput)
    case toolSearchCall(OpenAIResponsesToolSearchCall)
    case toolSearchOutput(OpenAIResponsesToolSearchOutput)
    case localShellCall(OpenAIResponsesLocalShellCall)
    case localShellCallOutput(OpenAIResponsesLocalShellCallOutput)
    case shellCall(OpenAIResponsesShellCall)
    case shellCallOutput(OpenAIResponsesShellCallOutput)
    case applyPatchCall(OpenAIResponsesApplyPatchCall)
    case applyPatchCallOutput(OpenAIResponsesApplyPatchCallOutput)
    case mcpListTools(OpenAIResponsesMCPListTools)
    case mcpApprovalRequest(OpenAIResponsesMCPApprovalRequest)
    case mcpApprovalResponse(OpenAIResponsesMCPApprovalResponse)
    case mcpCall(OpenAIResponsesMCPCall)
    case customToolCall(OpenAIResponsesCustomToolCall)
    case customToolCallOutput(OpenAIResponsesCustomToolCallOutput)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "message":
            self = .message(try OpenAIResponsesInputMessage(from: decoder))
        case "function_call":
            self = .functionCall(try OpenAIResponsesFunctionCall(from: decoder))
        case "function_call_output":
            self = .functionCallOutput(try OpenAIResponsesFunctionCallOutput(from: decoder))
        case "reasoning":
            self = .reasoning(try OpenAIResponsesReasoningItem(from: decoder))
        case "compaction":
            self = .compaction(try OpenAIResponsesCompactionItem(from: decoder))
        case "computer_call":
            self = .computerCall(try OpenAIResponsesComputerCall(from: decoder))
        case "computer_call_output":
            self = .computerCallOutput(try OpenAIResponsesComputerCallOutput(from: decoder))
        case "tool_search_call":
            self = .toolSearchCall(try OpenAIResponsesToolSearchCall(from: decoder))
        case "tool_search_output":
            self = .toolSearchOutput(try OpenAIResponsesToolSearchOutput(from: decoder))
        case "local_shell_call":
            self = .localShellCall(try OpenAIResponsesLocalShellCall(from: decoder))
        case "local_shell_call_output":
            self = .localShellCallOutput(try OpenAIResponsesLocalShellCallOutput(from: decoder))
        case "shell_call":
            self = .shellCall(try OpenAIResponsesShellCall(from: decoder))
        case "shell_call_output":
            self = .shellCallOutput(try OpenAIResponsesShellCallOutput(from: decoder))
        case "apply_patch_call":
            self = .applyPatchCall(try OpenAIResponsesApplyPatchCall(from: decoder))
        case "apply_patch_call_output":
            self = .applyPatchCallOutput(try OpenAIResponsesApplyPatchCallOutput(from: decoder))
        case "mcp_list_tools":
            self = .mcpListTools(try OpenAIResponsesMCPListTools(from: decoder))
        case "mcp_approval_request":
            self = .mcpApprovalRequest(try OpenAIResponsesMCPApprovalRequest(from: decoder))
        case "mcp_approval_response":
            self = .mcpApprovalResponse(try OpenAIResponsesMCPApprovalResponse(from: decoder))
        case "mcp_call":
            self = .mcpCall(try OpenAIResponsesMCPCall(from: decoder))
        case "custom_tool_call":
            self = .customToolCall(try OpenAIResponsesCustomToolCall(from: decoder))
        case "custom_tool_call_output":
            self = .customToolCallOutput(try OpenAIResponsesCustomToolCallOutput(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported Responses input item type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let message):
            try message.encode(to: encoder)
        case .functionCall(let functionCall):
            try functionCall.encode(to: encoder)
        case .functionCallOutput(let output):
            try output.encode(to: encoder)
        case .reasoning(let reasoning):
            try reasoning.encode(to: encoder)
        case .compaction(let compaction):
            try compaction.encode(to: encoder)
        case .computerCall(let computerCall):
            try computerCall.encode(to: encoder)
        case .computerCallOutput(let computerCallOutput):
            try computerCallOutput.encode(to: encoder)
        case .toolSearchCall(let toolSearchCall):
            try toolSearchCall.encode(to: encoder)
        case .toolSearchOutput(let toolSearchOutput):
            try toolSearchOutput.encode(to: encoder)
        case .localShellCall(let localShellCall):
            try localShellCall.encode(to: encoder)
        case .localShellCallOutput(let localShellCallOutput):
            try localShellCallOutput.encode(to: encoder)
        case .shellCall(let shellCall):
            try shellCall.encode(to: encoder)
        case .shellCallOutput(let shellCallOutput):
            try shellCallOutput.encode(to: encoder)
        case .applyPatchCall(let applyPatchCall):
            try applyPatchCall.encode(to: encoder)
        case .applyPatchCallOutput(let applyPatchCallOutput):
            try applyPatchCallOutput.encode(to: encoder)
        case .mcpListTools(let mcpListTools):
            try mcpListTools.encode(to: encoder)
        case .mcpApprovalRequest(let mcpApprovalRequest):
            try mcpApprovalRequest.encode(to: encoder)
        case .mcpApprovalResponse(let mcpApprovalResponse):
            try mcpApprovalResponse.encode(to: encoder)
        case .mcpCall(let mcpCall):
            try mcpCall.encode(to: encoder)
        case .customToolCall(let customToolCall):
            try customToolCall.encode(to: encoder)
        case .customToolCallOutput(let customToolCallOutput):
            try customToolCallOutput.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesInputMessage: Codable, Sendable {
    public let type: String
    public let role: String
    public let content: [OpenAIResponsesInputContent]
    public let phase: OpenAIResponsesAssistantPhase?

    public init(
        role: String,
        content: [OpenAIResponsesInputContent],
        phase: OpenAIResponsesAssistantPhase? = nil
    ) {
        self.type = "message"
        self.role = role
        self.content = content
        self.phase = phase
    }
}

public enum OpenAIResponsesInputContent: Codable, Sendable {
    case inputText(OpenAIResponsesInputText)
    case inputImage(OpenAIResponsesInputImage)
    case inputFile(OpenAIResponsesInputFile)
    case outputText(OpenAIResponsesOutputText)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "input_text":
            self = .inputText(try OpenAIResponsesInputText(from: decoder))
        case "input_image":
            self = .inputImage(try OpenAIResponsesInputImage(from: decoder))
        case "input_file":
            self = .inputFile(try OpenAIResponsesInputFile(from: decoder))
        case "output_text":
            self = .outputText(try OpenAIResponsesOutputText(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported Responses input content type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .inputText(let text):
            try text.encode(to: encoder)
        case .inputImage(let image):
            try image.encode(to: encoder)
        case .inputFile(let file):
            try file.encode(to: encoder)
        case .outputText(let text):
            try text.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesInputText: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "input_text"
        self.text = text
    }
}

public struct OpenAIResponsesInputImage: Codable, Sendable {
    public let type: String
    public let imageURL: String?
    public let fileId: String?
    public let detail: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case type, detail, status
        case imageURL = "image_url"
        case fileId = "file_id"
    }

    public init(imageURL: String? = nil, fileId: String? = nil, detail: String? = nil, status: String? = nil) {
        self.type = "input_image"
        self.imageURL = imageURL
        self.fileId = fileId
        self.detail = detail
        self.status = status
    }
}

public struct OpenAIResponsesInputFile: Codable, Sendable {
    public let type: String
    public let detail: String?
    public let fileData: String?
    public let fileId: String?
    public let fileURL: String?
    public let filename: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case type, detail, filename, status
        case fileData = "file_data"
        case fileId = "file_id"
        case fileURL = "file_url"
    }

    public init(
        detail: String? = nil,
        fileData: String? = nil,
        fileId: String? = nil,
        fileURL: String? = nil,
        filename: String? = nil,
        status: String? = nil
    ) {
        self.type = "input_file"
        self.detail = detail
        self.fileData = fileData
        self.fileId = fileId
        self.fileURL = fileURL
        self.filename = filename
        self.status = status
    }
}

public struct OpenAIResponsesFunctionCall: Codable, Sendable {
    public let type: String
    public let id: String?
    public let callId: String
    public let name: String
    public let arguments: String
    public let status: String?
    public let createdBy: String?
    public let namespace: String?

    enum CodingKeys: String, CodingKey {
        case type, id, name, arguments, status, namespace
        case callId = "call_id"
        case createdBy = "created_by"
    }

    public init(
        id: String? = nil,
        callId: String,
        name: String,
        arguments: String,
        status: String? = nil,
        createdBy: String? = nil,
        namespace: String? = nil
    ) {
        self.type = "function_call"
        self.id = id
        self.callId = callId
        self.name = name
        self.arguments = arguments
        self.status = status
        self.createdBy = createdBy
        self.namespace = namespace
    }
}

public enum OpenAIResponsesFunctionCallOutputPayload: Codable, Sendable {
    case text(String)
    case content([OpenAIResponsesInputContent])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .content(try container.decode([OpenAIResponsesInputContent].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .content(let content):
            try container.encode(content)
        }
    }
}

public struct OpenAIResponsesFunctionCallOutput: Codable, Sendable {
    public let type: String
    public let id: String?
    public let callId: String
    public let output: OpenAIResponsesFunctionCallOutputPayload
    public let status: String?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case type, id, output, status
        case callId = "call_id"
        case createdBy = "created_by"
    }

    public init(
        id: String? = nil,
        callId: String,
        output: OpenAIResponsesFunctionCallOutputPayload,
        status: String? = nil,
        createdBy: String? = nil
    ) {
        self.type = "function_call_output"
        self.id = id
        self.callId = callId
        self.output = output
        self.status = status
        self.createdBy = createdBy
    }
}

public enum OpenAIResponsesTool: Codable, Sendable {
    case function(OpenAIResponsesFunctionTool)
    case fileSearch(OpenAIResponsesFileSearchTool)
    case computerUsePreview(OpenAIResponsesComputerUsePreviewTool)
    case webSearch(OpenAIResponsesWebSearchTool)
    case mcp(OpenAIResponsesMCPTool)
    case codeInterpreter(OpenAIResponsesCodeInterpreterTool)
    case imageGeneration(OpenAIResponsesImageGenerationTool)
    case localShell(OpenAIResponsesLocalShellTool)
    case shell(OpenAIResponsesShellTool)
    case custom(OpenAIResponsesCustomTool)
    case applyPatch(OpenAIResponsesApplyPatchTool)
    case other(OpenAIResponsesUnknownToolDefinition)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "function":
            self = .function(try OpenAIResponsesFunctionTool(from: decoder))
        case "file_search":
            self = .fileSearch(try OpenAIResponsesFileSearchTool(from: decoder))
        case "computer_use_preview":
            self = .computerUsePreview(try OpenAIResponsesComputerUsePreviewTool(from: decoder))
        case "web_search", "web_search_2025_08_26", "web_search_preview", "web_search_preview_2025_03_11":
            self = .webSearch(try OpenAIResponsesWebSearchTool(from: decoder))
        case "mcp":
            self = .mcp(try OpenAIResponsesMCPTool(from: decoder))
        case "code_interpreter":
            self = .codeInterpreter(try OpenAIResponsesCodeInterpreterTool(from: decoder))
        case "image_generation":
            self = .imageGeneration(try OpenAIResponsesImageGenerationTool(from: decoder))
        case "local_shell":
            self = .localShell(try OpenAIResponsesLocalShellTool(from: decoder))
        case "shell":
            self = .shell(try OpenAIResponsesShellTool(from: decoder))
        case "custom":
            self = .custom(try OpenAIResponsesCustomTool(from: decoder))
        case "apply_patch":
            self = .applyPatch(try OpenAIResponsesApplyPatchTool(from: decoder))
        default:
            self = .other(try OpenAIResponsesUnknownToolDefinition(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .function(let function):
            try function.encode(to: encoder)
        case .fileSearch(let fileSearch):
            try fileSearch.encode(to: encoder)
        case .computerUsePreview(let computerUsePreview):
            try computerUsePreview.encode(to: encoder)
        case .webSearch(let webSearch):
            try webSearch.encode(to: encoder)
        case .mcp(let mcp):
            try mcp.encode(to: encoder)
        case .codeInterpreter(let codeInterpreter):
            try codeInterpreter.encode(to: encoder)
        case .imageGeneration(let imageGeneration):
            try imageGeneration.encode(to: encoder)
        case .localShell(let localShell):
            try localShell.encode(to: encoder)
        case .shell(let shell):
            try shell.encode(to: encoder)
        case .custom(let custom):
            try custom.encode(to: encoder)
        case .applyPatch(let applyPatch):
            try applyPatch.encode(to: encoder)
        case .other(let other):
            try other.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesFunctionTool: Codable, Sendable {
    public let type: String
    public let name: String
    public let description: String?
    public let parameters: [String: AnyCodable]?
    public let strict: Bool?
    public let deferLoading: Bool?

    enum CodingKeys: String, CodingKey {
        case type, name, description, parameters, strict
        case deferLoading = "defer_loading"
    }

    public init(
        name: String,
        description: String?,
        parameters: [String: AnyCodable]?,
        strict: Bool? = false,
        deferLoading: Bool? = nil
    ) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
        self.deferLoading = deferLoading
    }
}

public struct OpenAIResponsesFileSearchTool: Codable, Sendable {
    public let type: String
    public let vectorStoreIds: [String]
    public let filters: AnyCodable?
    public let maxNumResults: Int?
    public let rankingOptions: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case type, filters
        case vectorStoreIds = "vector_store_ids"
        case maxNumResults = "max_num_results"
        case rankingOptions = "ranking_options"
    }
}

public struct OpenAIResponsesComputerUsePreviewTool: Codable, Sendable {
    public let type: String
    public let displayHeight: Int
    public let displayWidth: Int
    public let environment: String

    enum CodingKeys: String, CodingKey {
        case type, environment
        case displayHeight = "display_height"
        case displayWidth = "display_width"
    }
}

public struct OpenAIResponsesWebSearchFilters: Codable, Sendable {
    public let allowedDomains: [String]?

    enum CodingKeys: String, CodingKey {
        case allowedDomains = "allowed_domains"
    }
}

public struct OpenAIResponsesUserLocation: Codable, Sendable {
    public let type: String?
    public let city: String?
    public let country: String?
    public let region: String?
    public let timezone: String?
}

public struct OpenAIResponsesWebSearchTool: Codable, Sendable {
    public let type: String
    public let filters: OpenAIResponsesWebSearchFilters?
    public let searchContextSize: String?
    public let userLocation: OpenAIResponsesUserLocation?

    enum CodingKeys: String, CodingKey {
        case type, filters
        case searchContextSize = "search_context_size"
        case userLocation = "user_location"
    }
}

public struct OpenAIResponsesMCPToolFilter: Codable, Sendable {
    public let readOnly: Bool?
    public let toolNames: [String]?

    enum CodingKeys: String, CodingKey {
        case readOnly = "read_only"
        case toolNames = "tool_names"
    }
}

public enum OpenAIResponsesMCPAllowedTools: Codable, Sendable {
    case toolNames([String])
    case filter(OpenAIResponsesMCPToolFilter)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let toolNames = try? container.decode([String].self) {
            self = .toolNames(toolNames)
        } else {
            self = .filter(try container.decode(OpenAIResponsesMCPToolFilter.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .toolNames(let toolNames):
            try container.encode(toolNames)
        case .filter(let filter):
            try container.encode(filter)
        }
    }
}

public struct OpenAIResponsesMCPRequireApprovalFilter: Codable, Sendable {
    public let always: OpenAIResponsesMCPToolFilter?
    public let never: OpenAIResponsesMCPToolFilter?
}

public enum OpenAIResponsesMCPRequireApproval: Codable, Sendable {
    case policy(String)
    case filters(OpenAIResponsesMCPRequireApprovalFilter)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let policy = try? container.decode(String.self) {
            self = .policy(policy)
        } else {
            self = .filters(try container.decode(OpenAIResponsesMCPRequireApprovalFilter.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .policy(let policy):
            try container.encode(policy)
        case .filters(let filters):
            try container.encode(filters)
        }
    }
}

public struct OpenAIResponsesMCPTool: Codable, Sendable {
    public let type: String
    public let serverLabel: String
    public let allowedTools: OpenAIResponsesMCPAllowedTools?
    public let authorization: String?
    public let connectorId: String?
    public let headers: [String: String]?
    public let requireApproval: OpenAIResponsesMCPRequireApproval?
    public let serverDescription: String?
    public let serverURL: String?

    enum CodingKeys: String, CodingKey {
        case type, authorization, headers
        case serverLabel = "server_label"
        case allowedTools = "allowed_tools"
        case connectorId = "connector_id"
        case requireApproval = "require_approval"
        case serverDescription = "server_description"
        case serverURL = "server_url"
    }
}

public struct OpenAIResponsesContainerNetworkPolicyDisabled: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesContainerNetworkPolicyAllowlist: Codable, Sendable {
    public let type: String
    public let allowedDomains: [String]
    public let domainSecrets: [[String: AnyCodable]]?

    enum CodingKeys: String, CodingKey {
        case type
        case allowedDomains = "allowed_domains"
        case domainSecrets = "domain_secrets"
    }
}

public enum OpenAIResponsesContainerNetworkPolicy: Codable, Sendable {
    case disabled(OpenAIResponsesContainerNetworkPolicyDisabled)
    case allowlist(OpenAIResponsesContainerNetworkPolicyAllowlist)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "disabled":
            self = .disabled(try OpenAIResponsesContainerNetworkPolicyDisabled(from: decoder))
        case "allowlist":
            self = .allowlist(try OpenAIResponsesContainerNetworkPolicyAllowlist(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported container network policy type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .disabled(let disabled):
            try disabled.encode(to: encoder)
        case .allowlist(let allowlist):
            try allowlist.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesCodeInterpreterAutoContainer: Codable, Sendable {
    public let type: String
    public let fileIds: [String]?
    public let memoryLimit: String?
    public let networkPolicy: OpenAIResponsesContainerNetworkPolicy?

    enum CodingKeys: String, CodingKey {
        case type
        case fileIds = "file_ids"
        case memoryLimit = "memory_limit"
        case networkPolicy = "network_policy"
    }
}

public enum OpenAIResponsesCodeInterpreterContainer: Codable, Sendable {
    case containerId(String)
    case auto(OpenAIResponsesCodeInterpreterAutoContainer)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let containerId = try? container.decode(String.self) {
            self = .containerId(containerId)
        } else {
            self = .auto(try container.decode(OpenAIResponsesCodeInterpreterAutoContainer.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .containerId(let containerId):
            try container.encode(containerId)
        case .auto(let auto):
            try container.encode(auto)
        }
    }
}

public struct OpenAIResponsesCodeInterpreterTool: Codable, Sendable {
    public let type: String
    public let container: OpenAIResponsesCodeInterpreterContainer
}

public struct OpenAIResponsesImageGenerationTool: Codable, Sendable {
    public let type: String
    public let background: String?
    public let inputFidelity: String?
    public let inputImageMask: String?
    public let model: String?
    public let moderation: String?
    public let outputCompression: Int?
    public let outputFormat: String?
    public let partialImages: Int?
    public let quality: String?
    public let size: String?

    enum CodingKeys: String, CodingKey {
        case type, background, model, moderation, quality, size
        case inputFidelity = "input_fidelity"
        case inputImageMask = "input_image_mask"
        case outputCompression = "output_compression"
        case outputFormat = "output_format"
        case partialImages = "partial_images"
    }
}

public struct OpenAIResponsesLocalShellTool: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesLocalSkill: Codable, Sendable {
    public let description: String
    public let name: String
    public let path: String
}

public struct OpenAIResponsesShellLocalEnvironment: Codable, Sendable {
    public let type: String
    public let skills: [OpenAIResponsesLocalSkill]?
}

public struct OpenAIResponsesShellContainerReference: Codable, Sendable {
    public let type: String
    public let containerId: String

    enum CodingKeys: String, CodingKey {
        case type
        case containerId = "container_id"
    }
}

public struct OpenAIResponsesShellContainerAuto: Codable, Sendable {
    public let type: String
    public let fileIds: [String]?
    public let memoryLimit: String?
    public let networkPolicy: OpenAIResponsesContainerNetworkPolicy?

    enum CodingKeys: String, CodingKey {
        case type
        case fileIds = "file_ids"
        case memoryLimit = "memory_limit"
        case networkPolicy = "network_policy"
    }
}

public enum OpenAIResponsesShellToolEnvironment: Codable, Sendable {
    case local(OpenAIResponsesShellLocalEnvironment)
    case containerReference(OpenAIResponsesShellContainerReference)
    case containerAuto(OpenAIResponsesShellContainerAuto)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "local":
            self = .local(try OpenAIResponsesShellLocalEnvironment(from: decoder))
        case "container_reference":
            self = .containerReference(try OpenAIResponsesShellContainerReference(from: decoder))
        case "container_auto":
            self = .containerAuto(try OpenAIResponsesShellContainerAuto(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported shell environment type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .local(let local):
            try local.encode(to: encoder)
        case .containerReference(let containerReference):
            try containerReference.encode(to: encoder)
        case .containerAuto(let containerAuto):
            try containerAuto.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesShellTool: Codable, Sendable {
    public let type: String
    public let environment: OpenAIResponsesShellToolEnvironment?
}

public struct OpenAIResponsesCustomToolTextFormat: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesCustomToolGrammarFormat: Codable, Sendable {
    public let type: String
    public let definition: String
    public let syntax: String
}

public enum OpenAIResponsesCustomToolFormat: Codable, Sendable {
    case text(OpenAIResponsesCustomToolTextFormat)
    case grammar(OpenAIResponsesCustomToolGrammarFormat)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try OpenAIResponsesCustomToolTextFormat(from: decoder))
        case "grammar":
            self = .grammar(try OpenAIResponsesCustomToolGrammarFormat(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported custom tool format type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            try text.encode(to: encoder)
        case .grammar(let grammar):
            try grammar.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesCustomTool: Codable, Sendable {
    public let type: String
    public let name: String
    public let description: String?
    public let format: OpenAIResponsesCustomToolFormat?
}

public struct OpenAIResponsesApplyPatchTool: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesUnknownToolDefinition: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesSummaryText: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "summary_text"
        self.text = text
    }
}

public struct OpenAIResponsesReasoningText: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "reasoning_text"
        self.text = text
    }
}

public struct OpenAIResponsesReasoningItem: Codable, Sendable {
    public let id: String
    public let type: String
    public let summary: [OpenAIResponsesSummaryText]
    public let content: [OpenAIResponsesReasoningText]?
    public let encryptedContent: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id, type, summary, content, status
        case encryptedContent = "encrypted_content"
    }

    public init(
        id: String,
        summary: [OpenAIResponsesSummaryText],
        content: [OpenAIResponsesReasoningText]? = nil,
        encryptedContent: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.type = "reasoning"
        self.summary = summary
        self.content = content
        self.encryptedContent = encryptedContent
        self.status = status
    }
}

public struct OpenAIResponsesCompactionItem: Codable, Sendable {
    public let type: String
    public let encryptedContent: String
    public let id: String?

    enum CodingKeys: String, CodingKey {
        case type, id
        case encryptedContent = "encrypted_content"
    }

    public init(encryptedContent: String, id: String? = nil) {
        self.type = "compaction"
        self.encryptedContent = encryptedContent
        self.id = id
    }
}

public struct OpenAIResponsesFileSearchResult: Codable, Sendable {
    public let attributes: [String: AnyCodable]?
    public let fileId: String?
    public let filename: String?
    public let score: Double?
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case attributes, filename, score, text
        case fileId = "file_id"
    }
}

public struct OpenAIResponsesFileSearchCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let queries: [String]?
    public let status: String?
    public let results: [OpenAIResponsesFileSearchResult]?
}

public struct OpenAIResponsesWebSearchSource: Codable, Sendable {
    public let type: String
    public let url: String
}

public struct OpenAIResponsesWebSearchAction: Codable, Sendable {
    public let type: String
    public let query: String?
    public let queries: [String]?
    public let sources: [OpenAIResponsesWebSearchSource]?
    public let url: String?
    public let pattern: String?
}

public struct OpenAIResponsesWebSearchCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let status: String?
    public let action: OpenAIResponsesWebSearchAction?
}

public struct OpenAIResponsesComputerCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String?
    public let status: String?
    public let action: [String: AnyCodable]?
    public let actions: [[String: AnyCodable]]?
    public let pendingSafetyChecks: [[String: AnyCodable]]?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, action, actions
        case callId = "call_id"
        case pendingSafetyChecks = "pending_safety_checks"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesComputerScreenshot: Codable, Sendable {
    public let type: String
    public let fileId: String?
    public let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case type
        case fileId = "file_id"
        case imageURL = "image_url"
    }
}

public struct OpenAIResponsesComputerCallOutput: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let output: OpenAIResponsesComputerScreenshot
    public let status: String?
    public let acknowledgedSafetyChecks: [[String: AnyCodable]]?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, output, status
        case callId = "call_id"
        case acknowledgedSafetyChecks = "acknowledged_safety_checks"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesImageGenerationCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let status: String
    public let result: String
}

public enum OpenAIResponsesCodeInterpreterOutput: Codable, Sendable {
    case logs(OpenAIResponsesCodeInterpreterLogsOutput)
    case image(OpenAIResponsesCodeInterpreterImageOutput)
    case other(OpenAIResponsesUnknownToolPayload)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "logs":
            self = .logs(try OpenAIResponsesCodeInterpreterLogsOutput(from: decoder))
        case "image":
            self = .image(try OpenAIResponsesCodeInterpreterImageOutput(from: decoder))
        default:
            self = .other(try OpenAIResponsesUnknownToolPayload(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .logs(let logs):
            try logs.encode(to: encoder)
        case .image(let image):
            try image.encode(to: encoder)
        case .other(let other):
            try other.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesCodeInterpreterLogsOutput: Codable, Sendable {
    public let type: String
    public let logs: String
}

public struct OpenAIResponsesCodeInterpreterImageOutput: Codable, Sendable {
    public let type: String
    public let url: String
}

public struct OpenAIResponsesCodeInterpreterCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let status: String
    public let code: String?
    public let containerId: String?
    public let outputs: [OpenAIResponsesCodeInterpreterOutput]?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, code, outputs
        case containerId = "container_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesToolSearchCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let arguments: AnyCodable?
    public let callId: String
    public let execution: String
    public let status: String
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, arguments, execution, status
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesToolSearchOutput: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let execution: String
    public let status: String
    public let tools: [OpenAIResponsesTool]
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, execution, status, tools
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesLocalShellAction: Codable, Sendable {
    public let type: String
    public let command: [String]
    public let env: [String: String]?
    public let timeoutMs: Double?
    public let user: String?
    public let workingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case type, command, env, user
        case timeoutMs = "timeout_ms"
        case workingDirectory = "working_directory"
    }
}

public struct OpenAIResponsesLocalShellCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let status: String
    public let action: OpenAIResponsesLocalShellAction
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, action
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesLocalShellCallOutput: Codable, Sendable {
    public let id: String
    public let type: String
    public let output: String
    public let status: String?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, output, status
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesShellCallAction: Codable, Sendable {
    public let commands: [String]
    public let maxOutputLength: Int?
    public let timeoutMs: Int?

    enum CodingKeys: String, CodingKey {
        case commands
        case maxOutputLength = "max_output_length"
        case timeoutMs = "timeout_ms"
    }
}

public struct OpenAIResponsesShellEnvironment: Codable, Sendable {
    public let type: String
    public let containerId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case containerId = "container_id"
    }
}

public struct OpenAIResponsesShellCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let action: OpenAIResponsesShellCallAction
    public let callId: String
    public let environment: OpenAIResponsesShellEnvironment
    public let status: String
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, action, environment, status
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public enum OpenAIResponsesShellOutcome: Codable, Sendable {
    case timeout(OpenAIResponsesUnknownToolPayload)
    case exit(OpenAIResponsesShellExitOutcome)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "timeout":
            self = .timeout(try OpenAIResponsesUnknownToolPayload(from: decoder))
        case "exit":
            self = .exit(try OpenAIResponsesShellExitOutcome(from: decoder))
        default:
            self = .timeout(try OpenAIResponsesUnknownToolPayload(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .timeout(let payload):
            try payload.encode(to: encoder)
        case .exit(let outcome):
            try outcome.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesShellExitOutcome: Codable, Sendable {
    public let type: String
    public let exitCode: Int

    enum CodingKeys: String, CodingKey {
        case type
        case exitCode = "exit_code"
    }
}

public struct OpenAIResponsesShellOutputChunk: Codable, Sendable {
    public let outcome: OpenAIResponsesShellOutcome
    public let stderr: String?
    public let stdout: String?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case outcome, stderr, stdout
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesShellCallOutput: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let maxOutputLength: Int?
    public let output: [OpenAIResponsesShellOutputChunk]
    public let status: String
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, output, status
        case callId = "call_id"
        case maxOutputLength = "max_output_length"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesApplyPatchOperation: Codable, Sendable {
    public let type: String
    public let path: String
    public let diff: String?
}

public struct OpenAIResponsesApplyPatchCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let status: String
    public let operation: OpenAIResponsesApplyPatchOperation
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, operation
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesApplyPatchCallOutput: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let status: String
    public let createdBy: String?
    public let output: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, output
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesMCPListTools: Codable, Sendable {
    public let id: String
    public let type: String
    public let serverLabel: String
    public let tools: [OpenAIResponsesTool]
    public let error: String?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, tools, error
        case serverLabel = "server_label"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesMCPApprovalRequest: Codable, Sendable {
    public let id: String
    public let type: String
    public let arguments: String
    public let name: String
    public let serverLabel: String

    enum CodingKeys: String, CodingKey {
        case id, type, arguments, name
        case serverLabel = "server_label"
    }
}

public struct OpenAIResponsesMCPApprovalResponse: Codable, Sendable {
    public let id: String
    public let type: String
    public let approvalRequestId: String
    public let approve: Bool
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, type, approve, reason
        case approvalRequestId = "approval_request_id"
    }
}

public struct OpenAIResponsesMCPCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let arguments: String
    public let name: String
    public let serverLabel: String
    public let approvalRequestId: String?
    public let error: String?
    public let output: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id, type, arguments, name, error, output, status
        case serverLabel = "server_label"
        case approvalRequestId = "approval_request_id"
    }
}

public struct OpenAIResponsesCustomToolCall: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let input: String
    public let name: String
    public let status: String
    public let createdBy: String?
    public let namespace: String?

    enum CodingKeys: String, CodingKey {
        case id, type, input, name, status, namespace
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesCustomToolCallOutput: Codable, Sendable {
    public let id: String
    public let type: String
    public let callId: String
    public let output: OpenAIResponsesFunctionCallOutputPayload
    public let status: String?
    public let createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, type, output, status
        case callId = "call_id"
        case createdBy = "created_by"
    }
}

public struct OpenAIResponsesUnknownToolPayload: Codable, Sendable {
    public let type: String
}

public enum OpenAIResponsesToolChoice: Codable, Sendable {
    case none
    case auto
    case required
    case function(String)
    case allowedTools(mode: String, tools: [OpenAIResponsesTool])
    case hostedTool(String)
    case mcp(serverLabel: String, name: String?)
    case custom(String)
    case applyPatch
    case shell
    case other(OpenAIResponsesUnknownToolChoice)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            switch value {
            case "none":
                self = .none
            case "auto":
                self = .auto
            case "required":
                self = .required
            default:
                self = .auto
            }
            return
        }

        let object = try container.decode(OpenAIResponsesToolChoiceObject.self)
        switch object.type {
        case "function":
            if let name = object.name {
                self = .function(name)
            } else {
                self = .other(OpenAIResponsesUnknownToolChoice(
                    type: object.type,
                    name: object.name,
                    mode: object.mode,
                    tools: object.tools,
                    serverLabel: object.serverLabel
                ))
            }
        case "allowed_tools":
            self = .allowedTools(mode: object.mode ?? "auto", tools: object.tools ?? [])
        case "mcp":
            if let serverLabel = object.serverLabel {
                self = .mcp(serverLabel: serverLabel, name: object.name)
            } else {
                self = .other(OpenAIResponsesUnknownToolChoice(
                    type: object.type,
                    name: object.name,
                    mode: object.mode,
                    tools: object.tools,
                    serverLabel: object.serverLabel
                ))
            }
        case "custom":
            if let name = object.name {
                self = .custom(name)
            } else {
                self = .other(OpenAIResponsesUnknownToolChoice(
                    type: object.type,
                    name: object.name,
                    mode: object.mode,
                    tools: object.tools,
                    serverLabel: object.serverLabel
                ))
            }
        case "apply_patch":
            self = .applyPatch
        case "shell":
            self = .shell
        case "file_search", "web_search_preview", "web_search_preview_2025_03_11", "computer_use_preview", "image_generation", "code_interpreter":
            self = .hostedTool(object.type)
        default:
            self = .other(OpenAIResponsesUnknownToolChoice(
                type: object.type,
                name: object.name,
                mode: object.mode,
                tools: object.tools,
                serverLabel: object.serverLabel
            ))
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
            try container.encode(OpenAIResponsesToolChoiceObject(type: "function", name: name))
        case .allowedTools(let mode, let tools):
            try container.encode(OpenAIResponsesToolChoiceObject(type: "allowed_tools", mode: mode, tools: tools))
        case .hostedTool(let type):
            try container.encode(OpenAIResponsesToolChoiceObject(type: type))
        case .mcp(let serverLabel, let name):
            try container.encode(OpenAIResponsesToolChoiceObject(type: "mcp", name: name, serverLabel: serverLabel))
        case .custom(let name):
            try container.encode(OpenAIResponsesToolChoiceObject(type: "custom", name: name))
        case .applyPatch:
            try container.encode(OpenAIResponsesToolChoiceObject(type: "apply_patch"))
        case .shell:
            try container.encode(OpenAIResponsesToolChoiceObject(type: "shell"))
        case .other(let other):
            try container.encode(other)
        }
    }
}

private struct OpenAIResponsesToolChoiceObject: Codable, Sendable {
    let type: String
    let name: String?
    let mode: String?
    let tools: [OpenAIResponsesTool]?
    let serverLabel: String?

    enum CodingKeys: String, CodingKey {
        case type, name, mode, tools
        case serverLabel = "server_label"
    }

    init(
        type: String,
        name: String? = nil,
        mode: String? = nil,
        tools: [OpenAIResponsesTool]? = nil,
        serverLabel: String? = nil
    ) {
        self.type = type
        self.name = name
        self.mode = mode
        self.tools = tools
        self.serverLabel = serverLabel
    }
}

public struct OpenAIResponsesUnknownToolChoice: Codable, Sendable {
    public let type: String
    public let name: String?
    public let mode: String?
    public let tools: [OpenAIResponsesTool]?
    public let serverLabel: String?

    enum CodingKeys: String, CodingKey {
        case type, name, mode, tools
        case serverLabel = "server_label"
    }
}

// MARK: - Responses API Response Models

public struct OpenAIResponsesResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let createdAt: Int
    public let model: String
    public let output: [OpenAIResponsesOutputItem]
    public let status: String?
    public let usage: OpenAIResponsesUsage?

    enum CodingKeys: String, CodingKey {
        case id, object, model, output, status, usage
        case createdAt = "created_at"
    }
}

public enum OpenAIResponsesOutputItem: Codable, Sendable {
    case message(OpenAIResponsesOutputMessage)
    case functionCall(OpenAIResponsesFunctionCall)
    case functionCallOutput(OpenAIResponsesFunctionCallOutput)
    case reasoning(OpenAIResponsesReasoningItem)
    case compaction(OpenAIResponsesCompactionItem)
    case fileSearchCall(OpenAIResponsesFileSearchCall)
    case webSearchCall(OpenAIResponsesWebSearchCall)
    case computerCall(OpenAIResponsesComputerCall)
    case computerCallOutput(OpenAIResponsesComputerCallOutput)
    case imageGenerationCall(OpenAIResponsesImageGenerationCall)
    case codeInterpreterCall(OpenAIResponsesCodeInterpreterCall)
    case toolSearchCall(OpenAIResponsesToolSearchCall)
    case toolSearchOutput(OpenAIResponsesToolSearchOutput)
    case localShellCall(OpenAIResponsesLocalShellCall)
    case localShellCallOutput(OpenAIResponsesLocalShellCallOutput)
    case shellCall(OpenAIResponsesShellCall)
    case shellCallOutput(OpenAIResponsesShellCallOutput)
    case applyPatchCall(OpenAIResponsesApplyPatchCall)
    case applyPatchCallOutput(OpenAIResponsesApplyPatchCallOutput)
    case mcpListTools(OpenAIResponsesMCPListTools)
    case mcpApprovalRequest(OpenAIResponsesMCPApprovalRequest)
    case mcpApprovalResponse(OpenAIResponsesMCPApprovalResponse)
    case mcpCall(OpenAIResponsesMCPCall)
    case customToolCall(OpenAIResponsesCustomToolCall)
    case customToolCallOutput(OpenAIResponsesCustomToolCallOutput)
    case other(OpenAIResponsesUnknownOutputItem)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "message":
            self = .message(try OpenAIResponsesOutputMessage(from: decoder))
        case "function_call":
            self = .functionCall(try OpenAIResponsesFunctionCall(from: decoder))
        case "function_call_output":
            self = .functionCallOutput(try OpenAIResponsesFunctionCallOutput(from: decoder))
        case "reasoning":
            self = .reasoning(try OpenAIResponsesReasoningItem(from: decoder))
        case "compaction":
            self = .compaction(try OpenAIResponsesCompactionItem(from: decoder))
        case "file_search_call":
            self = .fileSearchCall(try OpenAIResponsesFileSearchCall(from: decoder))
        case "web_search_call":
            self = .webSearchCall(try OpenAIResponsesWebSearchCall(from: decoder))
        case "computer_call":
            self = .computerCall(try OpenAIResponsesComputerCall(from: decoder))
        case "computer_call_output":
            self = .computerCallOutput(try OpenAIResponsesComputerCallOutput(from: decoder))
        case "image_generation_call":
            self = .imageGenerationCall(try OpenAIResponsesImageGenerationCall(from: decoder))
        case "code_interpreter_call":
            self = .codeInterpreterCall(try OpenAIResponsesCodeInterpreterCall(from: decoder))
        case "tool_search_call":
            self = .toolSearchCall(try OpenAIResponsesToolSearchCall(from: decoder))
        case "tool_search_output":
            self = .toolSearchOutput(try OpenAIResponsesToolSearchOutput(from: decoder))
        case "local_shell_call":
            self = .localShellCall(try OpenAIResponsesLocalShellCall(from: decoder))
        case "local_shell_call_output":
            self = .localShellCallOutput(try OpenAIResponsesLocalShellCallOutput(from: decoder))
        case "shell_call":
            self = .shellCall(try OpenAIResponsesShellCall(from: decoder))
        case "shell_call_output":
            self = .shellCallOutput(try OpenAIResponsesShellCallOutput(from: decoder))
        case "apply_patch_call":
            self = .applyPatchCall(try OpenAIResponsesApplyPatchCall(from: decoder))
        case "apply_patch_call_output":
            self = .applyPatchCallOutput(try OpenAIResponsesApplyPatchCallOutput(from: decoder))
        case "mcp_list_tools":
            self = .mcpListTools(try OpenAIResponsesMCPListTools(from: decoder))
        case "mcp_approval_request":
            self = .mcpApprovalRequest(try OpenAIResponsesMCPApprovalRequest(from: decoder))
        case "mcp_approval_response":
            self = .mcpApprovalResponse(try OpenAIResponsesMCPApprovalResponse(from: decoder))
        case "mcp_call":
            self = .mcpCall(try OpenAIResponsesMCPCall(from: decoder))
        case "custom_tool_call":
            self = .customToolCall(try OpenAIResponsesCustomToolCall(from: decoder))
        case "custom_tool_call_output":
            self = .customToolCallOutput(try OpenAIResponsesCustomToolCallOutput(from: decoder))
        default:
            self = .other(try OpenAIResponsesUnknownOutputItem(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let message):
            try message.encode(to: encoder)
        case .functionCall(let functionCall):
            try functionCall.encode(to: encoder)
        case .functionCallOutput(let functionCallOutput):
            try functionCallOutput.encode(to: encoder)
        case .reasoning(let reasoning):
            try reasoning.encode(to: encoder)
        case .compaction(let compaction):
            try compaction.encode(to: encoder)
        case .fileSearchCall(let fileSearchCall):
            try fileSearchCall.encode(to: encoder)
        case .webSearchCall(let webSearchCall):
            try webSearchCall.encode(to: encoder)
        case .computerCall(let computerCall):
            try computerCall.encode(to: encoder)
        case .computerCallOutput(let computerCallOutput):
            try computerCallOutput.encode(to: encoder)
        case .imageGenerationCall(let imageGenerationCall):
            try imageGenerationCall.encode(to: encoder)
        case .codeInterpreterCall(let codeInterpreterCall):
            try codeInterpreterCall.encode(to: encoder)
        case .toolSearchCall(let toolSearchCall):
            try toolSearchCall.encode(to: encoder)
        case .toolSearchOutput(let toolSearchOutput):
            try toolSearchOutput.encode(to: encoder)
        case .localShellCall(let localShellCall):
            try localShellCall.encode(to: encoder)
        case .localShellCallOutput(let localShellCallOutput):
            try localShellCallOutput.encode(to: encoder)
        case .shellCall(let shellCall):
            try shellCall.encode(to: encoder)
        case .shellCallOutput(let shellCallOutput):
            try shellCallOutput.encode(to: encoder)
        case .applyPatchCall(let applyPatchCall):
            try applyPatchCall.encode(to: encoder)
        case .applyPatchCallOutput(let applyPatchCallOutput):
            try applyPatchCallOutput.encode(to: encoder)
        case .mcpListTools(let mcpListTools):
            try mcpListTools.encode(to: encoder)
        case .mcpApprovalRequest(let mcpApprovalRequest):
            try mcpApprovalRequest.encode(to: encoder)
        case .mcpApprovalResponse(let mcpApprovalResponse):
            try mcpApprovalResponse.encode(to: encoder)
        case .mcpCall(let mcpCall):
            try mcpCall.encode(to: encoder)
        case .customToolCall(let customToolCall):
            try customToolCall.encode(to: encoder)
        case .customToolCallOutput(let customToolCallOutput):
            try customToolCallOutput.encode(to: encoder)
        case .other(let other):
            try other.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesOutputMessage: Codable, Sendable {
    public let id: String?
    public let type: String
    public let role: String
    public let status: String?
    public let content: [OpenAIResponsesOutputContent]
    public let phase: OpenAIResponsesAssistantPhase?
}

public enum OpenAIResponsesOutputContent: Codable, Sendable {
    case outputText(OpenAIResponsesOutputText)
    case refusal(OpenAIResponsesOutputRefusal)
    case other(OpenAIResponsesUnknownOutputContent)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "output_text":
            self = .outputText(try OpenAIResponsesOutputText(from: decoder))
        case "refusal":
            self = .refusal(try OpenAIResponsesOutputRefusal(from: decoder))
        default:
            self = .other(try OpenAIResponsesUnknownOutputContent(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .outputText(let text):
            try text.encode(to: encoder)
        case .refusal(let refusal):
            try refusal.encode(to: encoder)
        case .other(let other):
            try other.encode(to: encoder)
        }
    }
}

public struct OpenAIResponsesOutputText: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "output_text"
        self.text = text
    }
}

public struct OpenAIResponsesOutputRefusal: Codable, Sendable {
    public let type: String
    public let refusal: String?
}

public struct OpenAIResponsesUnknownOutputContent: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesUnknownOutputItem: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesUsage: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public var inputTokensDetails: InputTokensDetails?

    public struct InputTokensDetails: Codable, Sendable {
        public let cachedTokens: Int?
        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case inputTokensDetails = "input_tokens_details"
    }

    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

// MARK: - Responses Streaming Models

public struct OpenAIResponsesStreamEnvelope: Codable, Sendable {
    public let type: String
}

public struct OpenAIResponsesOutputItemAddedEvent: Codable, Sendable {
    public let type: String
    public let outputIndex: Int
    public let item: OpenAIResponsesOutputItem

    enum CodingKeys: String, CodingKey {
        case type, item
        case outputIndex = "output_index"
    }
}

public struct OpenAIResponsesOutputItemDoneEvent: Codable, Sendable {
    public let type: String
    public let outputIndex: Int
    public let item: OpenAIResponsesOutputItem

    enum CodingKeys: String, CodingKey {
        case type, item
        case outputIndex = "output_index"
    }
}

public struct OpenAIResponsesOutputTextDeltaEvent: Codable, Sendable {
    public let type: String
    public let itemId: String
    public let outputIndex: Int
    public let contentIndex: Int
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case type, delta
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
    }
}

public struct OpenAIResponsesReasoningSummaryTextDeltaEvent: Codable, Sendable {
    public let type: String
    public let itemId: String?
    public let outputIndex: Int
    public let summaryIndex: Int?
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case type, delta
        case itemId = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
    }
}

public struct OpenAIResponsesFunctionCallArgumentsDeltaEvent: Codable, Sendable {
    public let type: String
    public let itemId: String?
    public let outputIndex: Int
    public let delta: String

    enum CodingKeys: String, CodingKey {
        case type, delta
        case itemId = "item_id"
        case outputIndex = "output_index"
    }
}

public struct OpenAIResponsesFunctionCallArgumentsDoneEvent: Codable, Sendable {
    public let type: String
    public let itemId: String?
    public let outputIndex: Int
    public let arguments: String?
    public let name: String?
    public let item: OpenAIResponsesFunctionCall?

    enum CodingKeys: String, CodingKey {
        case type, arguments, name, item
        case itemId = "item_id"
        case outputIndex = "output_index"
    }
}

public struct OpenAIResponsesCompletedEvent: Codable, Sendable {
    public let type: String
    public let response: OpenAIResponsesResponse
}

// MARK: - Normalized Streaming Events

public enum OpenAIUpstreamStreamEvent: Sendable {
    case textDelta(String)
    case reasoningSummaryDelta(String)
    case toolCallStarted(index: Int, id: String, name: String)
    case toolCallArgumentsDelta(index: Int, argumentsDelta: String)
    case completed(finishReason: String?, usage: OpenAIUsage?)
}
