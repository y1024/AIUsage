import Foundation

// MARK: - Call Analytics Models
// 「调用分析」的统一数据模型：把 Claude Code / Codex / OpenCode 三家本地会话日志里的
// 工具调用、MCP 调用、Skill 调用归一化为同一套结构，供 UI 做 Top-N / 热力图 / 零调用检测。
// 数据来源（只读、零埋点）：
//   • Claude: ~/.claude/projects/**/*.jsonl 的 assistant.message.content[].tool_use
//   • Codex:  ~/.codex/sessions/**/*.jsonl 的 function_call / mcp_tool_call_end
//   • OpenCode: opencode.db 的 part 表（type==tool）
// 设计见 docs/CALL_ANALYTICS_DESIGN.md。

/// 调用类别。MCP 与 Skill 是本功能的高价值主线；内置工具量大价值低，单列便于 UI 折叠。
public enum CallKind: String, Codable, Sendable, CaseIterable {
    case mcp
    case skill
    case builtin
    case webSearch
    case other
}

/// 数据来源（哪个 CLI）。
public enum CallSourceKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case opencode

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

/// 一条按「日 × 来源 × 类别 × 名称(× MCP server)」聚合后的调用计数。
public struct CallAnalyticsEntry: Codable, Sendable, Hashable {
    public let source: CallSourceKind
    public let kind: CallKind
    /// 展示名：MCP=`server/tool`，Skill=技能名，其它=工具名。
    public let name: String
    /// 仅 MCP 有值，便于「按 server 折叠」。
    public let server: String?
    public let dayKey: String        // yyyy-MM-dd（本地时区）
    public var count: Int

    public init(source: CallSourceKind, kind: CallKind, name: String, server: String?, dayKey: String, count: Int) {
        self.source = source
        self.kind = kind
        self.name = name
        self.server = server
        self.dayKey = dayKey
        self.count = count
    }
}

/// 一条「本地已安装/已配置」的清单项，带来源归属，用于按应用做零调用检测。
/// 同名项在不同来源各算一条（如同一技能装在 Claude/Codex/OpenCode 三处 → 三条）。
public struct InstalledItem: Codable, Sendable, Hashable {
    public let source: CallSourceKind
    public let name: String

    public init(source: CallSourceKind, name: String) {
        self.source = source
        self.name = name
    }
}

/// 单个来源的采集状态，供 UI 区分「无数据」与「采集失败」。
public struct CallSourceStatus: Codable, Sendable {
    public let source: CallSourceKind
    /// 数据目录/文件是否存在（未安装该 CLI 时为 false）。
    public let available: Bool
    public let eventCount: Int
    public let filesScanned: Int
    /// 采集失败时的错误码（如 db_open_failed）；成功为 nil。
    public let errorCode: String?

    public init(source: CallSourceKind, available: Bool, eventCount: Int, filesScanned: Int, errorCode: String?) {
        self.source = source
        self.available = available
        self.eventCount = eventCount
        self.filesScanned = filesScanned
        self.errorCode = errorCode
    }
}

/// 调用分析快照（可缓存落盘、可整份重建，无成本冻结需求）。
public struct CallAnalyticsSnapshot: Codable, Sendable {
    // v2：installedSkills / installedMCPServers 从 [String] 升级为带来源的 [InstalledItem]，
    // 支持按应用做零调用检测。版本号变更会令旧缓存自动失效、整份重建。
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let generatedAt: Date
    /// 解析窗口（天）。0 表示全部历史。
    public let windowDays: Int
    public let entries: [CallAnalyticsEntry]
    /// 本地已安装的 skill（带来源，用于按应用做零调用检测）。
    public let installedSkills: [InstalledItem]
    /// 本地已配置的 MCP server（带来源，用于按应用做零调用检测）。
    public let installedMCPServers: [InstalledItem]
    public let sources: [CallSourceStatus]

    public init(
        schemaVersion: Int = CallAnalyticsSnapshot.currentSchemaVersion,
        generatedAt: Date,
        windowDays: Int,
        entries: [CallAnalyticsEntry],
        installedSkills: [InstalledItem],
        installedMCPServers: [InstalledItem],
        sources: [CallSourceStatus]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.windowDays = windowDays
        self.entries = entries
        self.installedSkills = installedSkills
        self.installedMCPServers = installedMCPServers
        self.sources = sources
    }

    public static let empty = CallAnalyticsSnapshot(
        generatedAt: .distantPast,
        windowDays: 0,
        entries: [],
        installedSkills: [],
        installedMCPServers: [],
        sources: []
    )

    public var isEmpty: Bool { entries.isEmpty }
    public var totalCalls: Int { entries.reduce(0) { $0 + $1.count } }
}
