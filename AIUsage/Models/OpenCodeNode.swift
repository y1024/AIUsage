import Foundation

// MARK: - OpenCode Node
// OpenCode 接入节点：一个 OpenAI 兼容上游（baseURL + API Key + 模型列表）。
// 激活时由 OpenCodeConfigManager 注入 ~/.config/opencode/opencode.json 的受管 provider 块。
// 直连模式: OpenCode 原生直连上游，无本地代理进程。
// 代理模式（路线 B）: 本地 QuotaServer(PROXY_TARGET=opencode) 透传 chat/completions，
//   opencode.json 指向 127.0.0.1:<proxyPort>，借此获得请求级日志（仅观测，不参与计费）。
// 持久化: ~/.config/aiusage/opencode-nodes.json（OpenCodeNodeStore）。

struct OpenCodeNode: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    /// 模型 ID 列表（顺序即展示顺序），至少一个。
    var models: [String]
    /// 顶层 `model` 指向的默认模型（必须在 models 中）。
    var defaultModel: String
    /// 受管 provider 的节点标识（进 opencode.db 的 providerID，统计按它归因到节点）。
    /// 首次保存时生成并保持稳定（改名不变，历史归因不断档）；旧档案缺省为 nil。
    var providerSlug: String?
    /// 写进每个模型 `limit.context` 的上下文窗口；0 = 不写，由 OpenCode 取默认。
    var contextLimit: Int
    /// 写进每个模型 `limit.output` 的输出上限；0 = 不写。
    var outputLimit: Int
    /// 代理模式：激活时启动本地透传代理并把 opencode.json 指向它（请求级日志）。
    var proxyEnabled: Bool
    /// 本地透传代理监听端口。
    var proxyPort: Int
    var createdAt: Date
    var lastUsedAt: Date?
    var sortOrder: Int

    static let defaultProxyPort = 4321

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        models: [String] = [],
        defaultModel: String = "",
        providerSlug: String? = nil,
        contextLimit: Int = 0,
        outputLimit: Int = 0,
        proxyEnabled: Bool = false,
        proxyPort: Int = OpenCodeNode.defaultProxyPort,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sortOrder: Int = Int.max
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.defaultModel = defaultModel
        self.providerSlug = providerSlug
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.proxyEnabled = proxyEnabled
        self.proxyPort = proxyPort
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
    }

    /// 兼容旧档案（无 proxyEnabled/proxyPort 字段）的解码。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        models = try c.decode([String].self, forKey: .models)
        defaultModel = try c.decode(String.self, forKey: .defaultModel)
        providerSlug = try c.decodeIfPresent(String.self, forKey: .providerSlug)
        contextLimit = try c.decode(Int.self, forKey: .contextLimit)
        outputLimit = try c.decode(Int.self, forKey: .outputLimit)
        proxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? Self.defaultProxyPort
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
    }

    /// 展示名：未命名时回退到 baseURL 的 host。
    var displayName: String {
        if let name = name.nilIfBlank { return name }
        if let host = URL(string: baseURL)?.host { return host }
        return AppSettings.shared.t("Untitled Node", "未命名节点")
    }

    /// 实际生效的默认模型：defaultModel 失配时回退到列表首个。
    var effectiveDefaultModel: String? {
        if models.contains(defaultModel) { return defaultModel }
        return models.first
    }

    /// 节点是否填齐了激活所需字段。
    var isComplete: Bool {
        baseURL.nilIfBlank != nil && effectiveDefaultModel != nil
    }

    /// 代理模式下写入 opencode.json 的本地 baseURL（OpenCode 在其后拼接 /chat/completions）。
    var proxyLocalBaseURL: String {
        "http://127.0.0.1:\(proxyPort)/v1"
    }

    // MARK: - Managed Provider Id

    /// 注入 opencode.json 的 provider 键，形如 `aiusage-deepseek`。
    /// opencode.db 的每条消息会带上它作为 providerID，统计页据此区分节点。
    var managedProviderId: String {
        "aiusage-" + (providerSlug?.nilIfBlank ?? String(id.prefix(6)).lowercased())
    }

    /// 从名称/host 生成 slug（小写 ASCII 字母数字 + 连字符），不可用时返回 nil。
    static func makeSlug(from source: String) -> String? {
        var slug = ""
        var previousWasHyphen = true // 抑制开头的连字符
        for character in source.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                slug.append("-")
                previousWasHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.nilIfBlank
    }

    /// 为本节点生成首选 slug：名称 → baseURL host → 短 id。
    func preferredSlug() -> String {
        if let slug = Self.makeSlug(from: name) { return slug }
        if let host = URL(string: baseURL)?.host, let slug = Self.makeSlug(from: host) { return slug }
        return String(id.prefix(6)).lowercased()
    }
}
