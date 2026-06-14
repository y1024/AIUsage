# 调用分析（MCP / Skill / 工具）技术设计

> 对应 issue [#23](https://github.com/sylearn/AIUsage/issues/23)。
> 分支：`feature/call-analytics`。
> 本文是实现的唯一事实源：数据口径、解析规则、文件级改动清单、分阶段范围都以此为准。
> 文中所有 schema / 字段均为在本机真实日志上实测得到（Claude Code、Codex、OpenCode 1.2.x）。
>
> **状态（2026-06）**：Phase 1 已实现并落地。本文已对齐实际实现（类型/文件名/刷新接入），
> 并补入两条实测新结论：① Codex 自 2025/12 起原生支持 Skills，但**无离散调用事件**，只能靠
> 读取 `SKILL.md` 启发式计数；② 排行同分项采用「次数降序→名称升序」稳定排序。下文凡与早期
> 规划不同处均以「实现」为准（旧规划名保留在括注中以便对照 git 历史）。

## 1. 背景与结论

issue #23 请求新增「MCP 工具调用 / Skill 调用 / 规则（Rules）命中」的次数与分析能力，类似 cc-switch 的 Usage Dashboard，但聚焦调用频次而非 token 费用，且**只解析本地 session 历史、不额外埋点**。

调研结论（实测三家本地日志）：

- **MCP 调用 + Skill 调用 + 工具调用 = 数据可得**，是高价值主线。MCP 在三家都以可解析的结构记录；`mcp__<server>__<tool>` / Codex `invocation.{server,tool}` 让「按 server / 按 tool」拆分天然成立。
- **Skill 三家都有，但口径不同**：Claude 是离散 `Skill` 工具（强信号）；OpenCode 是 `part.tool=="skill"`（强信号）；**Codex 自 2025/12 起原生支持 Skills**（`$skill-installer`，存 `~/.codex/skills`，SKILL.md 开放标准），但会话日志里**没有 skill 专属事件**（实测事件类型仅 `response_item`/`event_msg`/`function_call`/`mcp_tool_call_end`/`custom_tool_call` 等），技能靠「渐进式披露 → 用到才读全文」体现为 `exec_command` 读取 `skills/<name>/SKILL.md`，故 Codex skill 为**启发式弱信号**（每个读取命令计一次，行内去重，排除 `.system`）。
- **「规则命中」在原理上取不到**。规则（CLAUDE.md / AGENTS.md / `.cursor/rules`）是注入到上下文的静态内容，不是离散调用事件，日志里无任何 per-rule 触发信号。本设计**不实现「命中次数」**，改为「技能/MCP 清单 + 零调用检测」（见 §7）。
- **「平均耗时」口径不统一**：OpenCode（`state.time`）与 Codex MCP（`invocation.duration`）有精确耗时，Claude **无逐工具计时**。耗时定义为「可选指标，仅在数据源提供时展示」，归入 Phase 2。
- 现有用量统计栈（`CostSummary` / `StatsDataAdapter`）是 token/模型中心的，**无法承载调用计数**；调用分析需要独立的解析层、聚合模型与视图，但 UI 接入与刷新管线可大量复用。

分三阶段：

| 阶段 | 范围 | 状态 |
|------|------|------|
| Phase 1 | 三家的 MCP / Skill / 工具调用次数 + Top-N 排行 + 每日趋势 + 零调用检测 | ✅ 已实现 |
| Phase 2 | 成功率、耗时（仅有数据的源）、Claude subagent 分组、按 server 钻取 | 设计见 §10 |
| Phase 3（可选） | 导出（JSON/CSV）、与用量统计页的交叉联动 | 仅列方向 |

## 2. 数据源事实（实测）

### 2.1 可得性总览

| 维度 | Claude Code | Codex | OpenCode |
|------|-------------|-------|----------|
| 数据源 | `~/.claude/projects/**/*.jsonl` | `~/.codex/sessions/**/*.jsonl`（+ `archived_sessions`） | `opencode.db` 的 `part` 表 |
| 工具调用 | ✅ `message.content[].name` | ✅ `function_call.name` | ✅ `part.tool` |
| MCP 调用 | ✅ `mcp__<server>__<tool>` | ✅ `mcp_tool_call_end.invocation.{server,tool}` | ✅ `part.tool`（mcp 前缀） |
| Skill 调用 | ✅ `Skill` 工具，名在 `input.skill` | 🔶 原生支持但无离散事件 → 启发式：`exec_command` 读取 `skills/<name>/SKILL.md` | ✅ `part.tool == "skill"`，名在 `state.input.name` |
| 成功/状态 | ⚠️ 配对 `tool_result.is_error` | ✅ `function_call_output` / MCP `result.Ok\|Err` | ✅ `part.state.status` |
| 耗时 | ❌ 无逐工具计时 | ✅ MCP `invocation.duration`；普通工具需由事件时间戳推算 | ✅ `part.state.time.{start,end}` |
| 现状 | ✅ 已实现独立轻量扫描器（`ClaudeCallEventSource`） | ✅ 独立扫描器（`CodexCallEventSource`），含 skill 启发式 | ✅ 独立 `part` 查询（`OpenCodeCallEventSource`） |

### 2.2 Claude Code（`~/.claude/projects/**/*.jsonl`）

每行一条事件，`type` 取值：`assistant` / `user` / `system` / `attachment` / `file-history-snapshot` 等。工具调用在 assistant 行：

```jsonc
// type == "assistant"
{
  "type": "assistant",
  "timestamp": "2026-06-13T...Z",
  "sessionId": "....",
  "message": {
    "model": "claude-...",
    "content": [
      { "type": "thinking", ... },
      { "type": "tool_use", "id": "toolu_...", "name": "Bash", "input": { ... } },
      { "type": "tool_use", "id": "toolu_...", "name": "mcp__context7__query-docs", "input": { ... } },
      { "type": "tool_use", "id": "toolu_...", "name": "Skill", "input": { "skill": "smart-search", "args": "..." } }
    ]
  }
}
```

提取规则：
- **工具名**：`message.content[] | select(.type=="tool_use") | .name`。
- **MCP**：名形如 `mcp__<server>__<tool>`，按 `__` 切分得 server 与 tool（tool 内可能再含 `_`，按前两段切分，第三段起拼回）。
- **Skill**：`name == "Skill"`，技能名取 `input.skill`（实测值：`run` / `smart-search` / `opencli-autofix`）。
- **成功率**（Phase 2）：下一条 `type=="user"` 行的 `content[] | select(.type=="tool_result")`，按 `tool_use_id` 配对，`is_error`（实测分布：false 365 / null 355 / true 64；null 视为「未知/成功」）。
- **耗时**：无。Claude jsonl 不记录逐工具时长。
- **subagent**：路径含 `subagents/` 目录的文件标记为 subagent 来源，可作 Phase 2 分组维度。

实测样本（本机 88 个文件）的工具分布（节选）：`Bash 390 / Read 202 / Edit 63 / WebSearch 16 / mcp__ccd_directory__request_directory 4 / mcp__context7__* 2 / Skill 3 …`。**MCP/Skill 绝对量很低**——这正是「僵尸技能/低频 MCP」检测的价值所在。

> 背景：0.8.0（commit `907b4ff`）曾删除 Claude 的 jsonl 扫描管线（`+Scanning`/`+FileParsing`/`+Discovery` 等）。本功能**已新建一个只为调用分析服务**的轻量扫描器（`ClaudeCallEventSource` + `CallAnalyticsLineReader`），与已删的用量管线无关、只取 `tool_use`。目录发现沿用历史逻辑：`CLAUDE_CONFIG_DIR`（逗号分隔）→ 否则 `~/.config/claude/projects` 与 `~/.claude/projects`，递归收集 `*.jsonl`。

### 2.3 Codex（`~/.codex/sessions/**/*.jsonl`）

每行 `type` ∈ `event_msg` / `response_item` / `session_meta` / `turn_context`。两类有用记录：

普通函数/工具调用（`response_item`）：

```jsonc
{ "type": "response_item",
  "payload": { "type": "function_call", "name": "exec_command", "call_id": "...", "arguments": "..." } }
{ "type": "response_item",
  "payload": { "type": "function_call_output", "call_id": "...", "output": "..." } }
```

MCP 调用（`event_msg`，结构最完整，**自带 server/tool/duration/result**）：

```jsonc
{ "type": "mcp_tool_call_end",
  "call_id": "call_...",
  "invocation": { "server": "codebase-memory-mcp", "tool": "list_projects", "arguments": {} },
  "duration": { "secs": 0, "nanos": 16286375 },
  "result": { "Ok": { "content": [ ... ] } } }   // 失败为 { "Err": ... }
```

提取规则：
- **工具名**：`response_item.payload(type=="function_call").name`（实测：`exec_command 328 / js 18 / web_search_exa 16 / get_code_snippet 15 …`）。
- **MCP**：`mcp_tool_call_end.invocation.{server,tool}`；`result.Ok`=成功、`result.Err`=失败；`duration` = `secs + nanos/1e9`。
- **成功率**：普通工具看 `function_call_output`（无显式 success 字段，可用「有 output 即完成」近似，或 Phase 2 解析 exit 信息）；MCP 看 `result.Ok|Err`。
- **耗时**：MCP 直接有 `duration`；普通工具需由 call 与 output 的行时间戳差推算（Phase 2）。
- **Skill（启发式）**：Codex 自 2025/12 原生支持 Skills（`~/.codex/skills`，SKILL.md 开放标准；参考 [OpenAI Codex Skills 文档](https://developers.openai.com/codex/skills)）。但**会话日志无 skill 专属事件**——实测顶层事件类型只有 `response_item`/`event_msg`/`function_call`/`mcp_tool_call_end`/`custom_tool_call` 等，搜 `*skill*` 事件零命中，`turn_context` 也不列激活技能。技能采用「渐进式披露：用到才读全文」，体现为 `exec_command` 读取 `skills/<name>/SKILL.md`。故识别规则：在 `function_call` 行内匹配 `skills/<name>/SKILL.md`，取父目录名为技能名，**每个读取命令计一次**（行内 `Set` 去重），排除 `.system` 系统技能与含 glob/非法字符的名。`function_call_output`（文件内容输出行）不含闭合的 `"function_call"` 串，天然不被命中，避免文件内容造成的重复计数。属**弱信号、可能有少量噪声**。
- 复用：`CodexCostProvider+Discovery.swift` 已实现 `~/.codex/sessions` + `archived_sessions`（或 `$CODEX_HOME`）的发现与增量扫描，扩展时**复用同一遍文件扫描**，避免二次遍历。

### 2.4 OpenCode（`opencode.db` 的 `part` 表）

数据目录解析顺序与 OpenCode `Global.Path.data` 对齐：`$XDG_DATA_HOME/opencode` → `~/.local/share/opencode` → `~/Library/Application Support/opencode`（已在 `OpenCodeCostProvider+Discovery.swift` 实现，直接复用）。

现有解析只读 `message` 表（token/cost）。调用数据在 **`part` 表**（同一个 db）：

```sql
-- part 表的 data(JSON) 中 type 分布（实测）：text / step-start / step-finish / tool / reasoning
SELECT data FROM part;
```

工具 part 示例：

```jsonc
{ "type": "tool", "tool": "glob", "callID": "call_95501845",
  "state": { "status": "completed", "time": { "start": 1767339068099, "end": 1767339068373 } } }
// skill：{ "type":"tool", "tool":"skill", "state": { "status":"completed", "input": { "name": "<技能名>" } } }
```

提取规则：
- **工具名**：`part.data(type=="tool").tool`（实测：`webfetch 56 / read 33 / bash 32 / write 9 / glob 8 / edit 7 / skill 1 / question 1`）。
- **MCP**：tool 名带 mcp 前缀（OpenCode 的 MCP 工具命名）；按前缀识别归类。
- **Skill**：`tool == "skill"`，技能名取 `state.input.name`。
- **成功率**：`state.status`（completed / error 等）。
- **耗时**：`state.time.end - state.time.start`（毫秒）。
- **时间桶**：part 自身无独立 created；可 join `message.time_created`（part 属于某 message）或用 part 所在 message 的时间。
- 复用：`OpenCodeCostProvider+Database.swift` 已封装「复制 db/-wal/-shm 到临时目录只读打开」，加一条 `SELECT data FROM part` 即可。

## 3. 数据可得性逐项裁决

| 子需求 | 裁决 | 落地说明 |
|--------|------|----------|
| MCP 调用次数 / 按 server·tool 排行 | ✅ Phase 1 | 三家全可取，最高价值 |
| Skill 调用统计 | ✅ Phase 1 | Claude / OpenCode 强信号；Codex 启发式（读 SKILL.md） |
| 工具调用总览 | ✅ Phase 1（顺带） | 解析时一并得到 |
| 零调用检测（僵尸 skill / MCP） | ✅ Phase 1 | 已装清单（§7）与已用集合求差；**可清理仅限用户自建技能** |
| 成功率 | ⚠️ Phase 2 | Codex/OpenCode 好取；Claude 需配对 tool_result |
| 平均耗时 | ⚠️ Phase 2 | 仅 OpenCode / Codex-MCP；Claude 无 → 标注「无数据」 |
| 规则命中次数 | ❌ 不实现 | 原理无信号；改为「规则清单/状态」可选展示 |
| 按 agent 分组 | ⚠️ Phase 2 | 仅 Claude subagent 维度较可靠 |

## 4. 规范化中间模型（实现）

所有源归一化到统一**聚合条目**，集中在 `QuotaBackend/.../CallAnalytics/CallAnalyticsModels.swift`。
与早期规划不同：Phase 1 直接产出「按 日×来源×类别×名称(×server) 聚合好的计数条目」，
成功率/耗时（`success`/`durationMs`）留到 Phase 2 再加字段，当前模型不含它们。

```swift
public enum CallKind: String, Codable, Sendable, CaseIterable {
    case mcp        // mcp__server__tool / invocation
    case skill      // Skill 工具 / SKILL.md 读取
    case builtin    // Read/Edit/Bash/Glob/...
    case webSearch  // WebSearch / WebFetch（单列更直观）
    case other
}

public enum CallSourceKind: String, Codable, Sendable, CaseIterable {
    case claude, codex, opencode   // 含 displayName
}

/// 一条按「日 × 来源 × 类别 × 名称(× MCP server)」聚合后的调用计数。
public struct CallAnalyticsEntry: Codable, Sendable, Hashable {
    public let source: CallSourceKind
    public let kind: CallKind
    public let name: String      // MCP=server/tool，Skill=技能名，其它=工具名
    public let server: String?   // 仅 MCP
    public let dayKey: String    // yyyy-MM-dd（本地时区）
    public var count: Int
}
```

聚合在 `CallEventAccumulator`（`CallAnalyticsSupport.swift`）内完成：以
`(source, kind, name, server, dayKey)` 为键累加 `count`，最终 `entries()` 吐出 `[CallAnalyticsEntry]`。
快照 `CallAnalyticsSnapshot`（schema v2）额外携带 `installedSkills` / `installedMCPServers`（均为带来源的 `[InstalledItem]`，零调用按应用用）、
每源 `sources: [CallSourceStatus]`（区分「无数据/未安装」与「采集失败」）、`windowDays`、`schemaVersion`、`generatedAt`。

> 旧规划里的 `ToolCallEvent`（逐事件）/ `CallAnalyticsBucket` / `CallAggKey` 已不复存在——
> 聚合直接发生在采集累加器里，省一层中间事件，模型更精简。

归一化要点：
- MCP 展示名统一为 `server/tool`；`server` 单独留字段便于「按 server 折叠」（见 `CallAnalyticsNaming`）。
- Claude `mcp__a__b__c` → server=`a`，tool=`b__c`（仅切前两段）。
- 计数永远 +1；成功率/耗时（Phase 2）将按「有数据才计入分母」，避免 Claude 的 nil 拉低可信度。

## 5. 解析层设计（实现）

三个采集源各是一个 `struct`（非协议），统一暴露 `collect(cutoff:) -> (entries:[CallAnalyticsEntry], status:CallSourceStatus)`，
由 `CallAnalyticsEngine`（`public actor`）串行调度。早期规划的 `CallEventSource` 协议未采用——
三家实现差异大（jsonl 流式 vs SQLite 查询），统一签名后协议抽象收益有限，直接用具名结构更直观。

| 实现（结构） | 文件 | 数据来源 / 复用 |
|------|------|------|
| `ClaudeCallEventSource` | `QuotaBackend/.../CallAnalytics/ClaudeCallEventSource.swift` | 自建轻量 jsonl 扫描；目录发现：`CLAUDE_CONFIG_DIR`→`~/.config/claude/projects`/`~/.claude/projects`，递归 `*.jsonl` |
| `CodexCallEventSource` | `QuotaBackend/.../CallAnalytics/CodexCallEventSource.swift` | `~/.codex/sessions`+`archived_sessions`（或 `$CODEX_HOME`）；含 MCP + skill 启发式 |
| `OpenCodeCallEventSource` | `QuotaBackend/.../CallAnalytics/OpenCodeCallEventSource.swift` | `opencode.db` 临时只读快照，查 `part` 表 |

公共支撑在 `CallAnalyticsSupport.swift`：`CallAnalyticsClock`（日期/dayKey）、`CallAnalyticsLineReader`（流式按行 + 子串预筛 + maxLineBytes 上限）、`CallAnalyticsJSON`（字节级取字段，避免大行整体反序列化）、`CallEventAccumulator`（聚合）、`CallAnalyticsNaming`（MCP 名归一化）。

性能策略（已落地）：
- 全程 `actor`（`CallAnalyticsEngine`）化、后台执行；解析结果合并成快照后才回主线程。
- 时间窗裁剪：`windowDays>0` 时按文件 `mtime` / 库时间跳过窗口外文件（`cutoff`）。
- 流式按行解析，避免一次性载入大文件；先做廉价子串预筛（`tool_use` / `function_call` / `mcp_tool_call_end`）再 JSON 解析；Claude 单行给 4MB、Codex 给 256KB 缓冲上限。
- OpenCode 复制 db/-wal/-shm 到临时目录只读打开，`SELECT data FROM part`。

> 注：早期规划的「`(path,size,mtime)` 指纹增量缓存」Phase 1 未实现——当前是窗口内全量重扫 + 整份快照落盘缓存（§6）。文件量大时再按 §11 引入增量。

## 6. 聚合、存储与刷新接入（实现）

- **聚合**：三源各自在 `CallEventAccumulator` 内聚合为 `[CallAnalyticsEntry]`，`CallAnalyticsEngine.computeSnapshot(windowDays:)` 合并成 `CallAnalyticsSnapshot`。
- **存储**：调用分析**无成本冻结需求**（不像代理用量要逐条冻结价格），因此**不做永久归档**，整份快照落盘缓存到 `~/.config/aiusage/cache/call-analytics-v<schema>.json`（ISO8601 编码，schema 不匹配则丢弃重建）。冷启动先读缓存即时显示，再后台刷新。
- **刷新接入**：实现为**独立的** `@MainActor` 单例 `CallAnalyticsStore.shared`（`AIUsage/ViewModels/CallAnalyticsStore.swift`），不挂在 `ProviderRefreshCoordinator` 上——语义不同（调用计数 vs token/成本）、刷新时机不同（按窗口切换/手动）。它持有 `@Published snapshot` / `@Published isRefreshing`，`refreshIfNeeded(windowDays:)`（首进或窗口变化）与 `refresh(windowDays:)`（强制）调度 `CallAnalyticsEngine.shared` 后回主线程发布并落盘。

## 7. 零调用检测（清单源，按来源归属，实现）

「已用集合」来自 §2 聚合；「已装清单」由 `CallAnalyticsInventory` 枚举本地安装项，**按来源（Claude/Codex/OpenCode）归属**，与「已用」求差得到「装了但从未调用」。清单项为 `InstalledItem{source, name}`，同名项装在多家则各算一条：

| 来源 | Skill 目录 | MCP 配置（格式） |
|------|-----------|------------------|
| Claude | `~/.claude/skills` 下 `*/SKILL.md` | `~/.claude.json`（JSON，含 `projects.*.mcpServers`） |
| Codex | `~/.codex/skills` 下 `*/SKILL.md` | `~/.codex/config.toml`（**TOML**：`[mcp_servers.NAME...]` 取首段 NAME） |
| OpenCode | `~/.config/opencode/skills` 下 `*/SKILL.md` | `~/.config/opencode/opencode.json(c)` 的 `mcp`/`mcpServers` 块 |

- **按应用口径（关键）**：零调用卡与上方 KPI **同口径、跟随顶部「来源」筛选**。选某应用 → 只看该应用自己装的技能/MCP，且必须被该应用调用过才算「已用」，否则即该应用的僵尸；选「全部」→ 取三家并集、任一工具用过即「已用」。修复了此前「KPI 跟随筛选、卡片写死全部来源」导致的数字不一致。
- **只覆盖三家 CLI**：不扫 `~/.cursor`（技能/MCP）——Cursor 自身用量不在这些日志里，否则其条目永远显示为僵尸、误导。`CallSourceKind` 也只有 claude/codex/opencode 三档。
- **可清理 = 仅用户自建技能**：内置（`~/.cursor/skills-cursor`）和插件缓存（`~/.claude/plugins/cache` 等）里的捆绑子技能由工具/插件托管，用户无法单独清理，故**不计入清单**——但其**调用仍由各事件源正常统计**，用过照样进排行、在「已用」里显示绿色（实测本机插件缓存约 38 个捆绑技能）。
- 零调用卡 `skillStatuses()` / `serverStatuses()` 取「该 scope 已装清单 ∪ 该 scope 实际用过的名」，已用绿色、未用（仅用户技能）橙色虚线标为可清理；排序「已用在前→次数降序→名称升序」。
- 清单探测做成「尽力而为」：找不到某来源就跳过，不阻塞主统计。

## 8. UI 设计

### 8.1 导航接入（仅改 3 处）

```swift
// AIUsage/Models/AppSettings.swift —— AppSection 加一枚
enum AppSection: String, Hashable {
    case dashboard, providers, costTracking
    case callAnalytics            // 新增
    case proxyManagement, codexProxyManagement, opencodeManagement, inbox, settings
}
```

- `AIUsage/Views/SidebarNavigation.swift`：在 `primary` 数组加一条 `SidebarNavItem(section: .callAnalytics, titleEn: "Call Analytics", titleZh: "调用分析", localizationKey: "nav.call_analytics", icon: .system("puzzlepiece.extension"), tint: .purple, isHideable: true)`。`isHideable: true` 让它自动出现在「设置 → 侧边栏」隐藏开关里（复用 #22 机制）。
- `AIUsage/Views/ContentView.swift`：`switch` 加 `case .callAnalytics: CallAnalyticsView()`。

### 8.2 页面结构（复用现有组件）

```
CallAnalyticsView（CallAnalyticsView.swift + CallAnalyticsDerived.swift 派生层）
├─ 控制区            来源(all/claude/codex/opencode) × 维度 lens(MCP/技能/工具) × 窗口(7/30/90/全部)
├─ KPI 条            总调用 / MCP 调用 / Skill 调用 / 活跃 server / 僵尸技能
├─ 每日趋势          按日总调用横向条（自定义，非热力图；复用 LazyVGrid 模式）
├─ Top-N 排行        CallAnalyticsView+Rankings.swift：lens 分段 + 自定义 Capsule 条形 + 来源圆点
└─ 零调用卡          CallAnalyticsView+ZeroCall.swift：技能/MCP 两组芯片（已用绿 / 可清理橙），FlowLayout 自适应
```

派生层 `CallAnalyticsDerived`（`AIUsage/Views/CallAnalyticsDerived.swift`）：把快照按来源 scope 过滤后产出 KPI、`ranking(for:lens)`（MCP 按 server 折叠）、`dailyCounts`、`skillStatuses()`/`serverStatuses()`。排行同分用 `rankOrder`（次数降序→名称升序）稳定排序，避免字典遍历顺序导致位次抖动。

UI 实现选择：
- **每日趋势用自定义横向条**，未复用 `LocalTokenUsageHeatmap`（计数信号稀疏，热力图意义不大）。
- **Top-N 用自定义 `Capsule` 进度条**，不引入 Swift Charts `BarMark`（轻、可控；当前 App 仅饼图用到 Charts）。
- **零调用芯片用自研 `FlowLayout`（`Layout` 协议，macOS 13+）**：芯片按内容宽度排布、自动换行，长名整行完整显示；取代等宽 `LazyVGrid(.adaptive)`（后者固定列宽会把长 MCP 名截断，拉宽窗口也无解）。
- 复用：`summaryStrip/summaryCell`（`ProxyStatsView+Summary.swift`）、`ViewThatFits` 弹性布局（#20）。

## 9. 文件级改动清单（实测落地）

新增（QuotaBackend，`Sources/QuotaBackend/CallAnalytics/`）：
- `CallAnalyticsModels.swift`（`CallKind` / `CallSourceKind` / `CallAnalyticsEntry` / `CallSourceStatus` / `CallAnalyticsSnapshot`）
- `CallAnalyticsSupport.swift`（`CallAnalyticsClock` / `CallAnalyticsLineReader` / `CallAnalyticsJSON` / `CallEventAccumulator` / `CallAnalyticsNaming`）
- `ClaudeCallEventSource.swift`
- `CodexCallEventSource.swift`（含 MCP + skill 启发式）
- `OpenCodeCallEventSource.swift`
- `CallAnalyticsInventory.swift`（零调用清单探测；早期名 `InstalledInventory`）
- `CallAnalyticsEngine.swift`（`public actor` 编排，早期规划未单列此文件）

新增（App）：
- `AIUsage/ViewModels/CallAnalyticsStore.swift`（`@MainActor` 单例：快照 + 刷新 + 缓存读写）
- `AIUsage/Views/CallAnalyticsView.swift`（主视图）
- `AIUsage/Views/CallAnalyticsView+Rankings.swift`（早期名 `+TopN`）
- `AIUsage/Views/CallAnalyticsView+ZeroCall.swift`（含自研 `FlowLayout`）
- `AIUsage/Views/CallAnalyticsDerived.swift`（派生层：KPI/排行/趋势/零调用，早期规划未单列）

修改：
- `AIUsage/Models/AppSettings.swift`（`AppSection` 加 `callAnalytics`）
- `AIUsage/Views/SidebarNavigation.swift`（加导航项）
- `AIUsage/Views/ContentView.swift`（switch 加 case）
- `AIUsage.xcodeproj/project.pbxproj`（登记上述 App 端新文件；QuotaBackend 走 SPM 自动纳入，无需登记）

> 与早期规划差异：未改 `ProviderRefreshCoordinator`（改用独立 `CallAnalyticsStore`，见 §6）；多出 `CallAnalyticsEngine` / `CallAnalyticsDerived` / `CallAnalyticsSupport` 三个文件以保持单一职责、控制单文件规模。

## 10. 分阶段范围

- **Phase 1（MVP）✅ 已实现**：三家 MCP/Skill/工具计数（Codex skill 启发式）+ Top-N 排行（稳定排序）+ 每日趋势 + 零调用检测（可清理仅限用户技能）；不做规则命中、不做耗时、不做成功率。
- **Phase 2（规划）**：成功率（三家）、耗时（OpenCode + Codex-MCP，Claude 标注无数据）、Claude subagent 分组、按 server 钻取详情、可选「跨工具同名技能合并」、可选「(path,size,mtime) 增量缓存」。
- **Phase 3（可选）**：导出 JSON/CSV；与用量统计页交叉联动（如某 MCP 的调用次数 vs token）。

## 11. 性能与风险

| 项 | 说明 | 对策 |
|----|------|------|
| 文件量大 | Codex 数百会话、Claude 数十文件，全量扫描会卡 | 后台 actor + 子串预筛 + maxLineBytes 上限 + 窗口裁剪（增量指纹缓存待 Phase 2） |
| Claude 解析重建 | 0.8.0 曾删，已新建独立轻量扫描器 | 只取 tool_use，不碰 token；与用量栈解耦 |
| 耗时口径不一 | Claude 无计时 | Phase 2 定义为可选指标，缺失显式标注 |
| 信号稀疏 | MCP/Skill 绝对量低 | UI 偏「洞察/清理建议」，弱化趋势热闹度 |
| Codex 技能弱信号 | 无离散事件，靠读 SKILL.md 推断 | 行内去重 + 排除 `.system`/glob；UI 可注明为估算 |
| 仅覆盖三家 CLI | Cursor 自身用量不在这些日志 | 文档与 UI 注明数据范围 |

## 12. 决策记录（Phase 1 已定）

1. **规则命中** → ✅ 不做命中次数，改为「技能/MCP 清单 + 零调用检测」（原理无 per-rule 信号）。
2. **耗时** → Phase 1 不展示，归 Phase 2（仅 OpenCode/Codex-MCP 有数据，Claude 标注无）。
3. **内置工具** → 保留，单列「工具」lens（与 MCP / 技能并列），不混入 MCP/技能榜。
4. **时间范围** → 提供窗口选择器（7/30/90/全部），`windowDays` 驱动解析裁剪。
5. **Codex 技能（实现后新增决策）** → 启发式按读取 `SKILL.md` 计数（无离散事件，弱信号）；实测确认无更精确信号，不再深挖。
6. **零调用「可清理」范围（实现后新增决策）** → 仅用户自建技能；插件/内置捆绑技能仍计调用但不算可清理候选。
7. **零调用按来源归属（实现后新增决策）** → 清单升级为带来源的 `InstalledItem`，零调用卡跟随顶部筛选、与 KPI 同口径（修数字不一致）；技能/MCP 按目录与配置归属到 Claude/Codex/OpenCode（补扫 OpenCode 技能目录、Codex 的 TOML MCP），不再扫 `~/.cursor`（非三家 CLI，避免永久误报僵尸）。schema 升 v2 自动失效旧缓存。

## 13. 已知限制与噪声

- **Codex 技能为弱信号**：靠读 `SKILL.md` 推断，无法区分「真激活」与「只是查看 SKILL.md」；同一技能多次读取会多次计数。Claude/OpenCode 是强信号（离散事件）。
- **同名技能跨工具不合并**：同名技能在 Claude/Codex/OpenCode 各自计数，排行里按名聚合时会合并三家计数（来源圆点区分），但「来源不同的同名异技能」无法区分。Phase 2 评估归一化。
- **OpenCode MCP server 归属**：工具名形如 `<server>_<tool>`，优先用 opencode.json 里已装 server 名做最长前缀匹配（兼容 server 名含 `_`/`-`），匹配不到才回退「首个下划线切分」。极少数未配置且含下划线的 server 名仍可能切错（弱信号）。
- **仅覆盖三家 CLI**：Cursor/IDE 自身的技能与 MCP 调用不在这些日志里，不纳入统计。
- **无增量缓存**：当前窗口内全量重扫；文件极多时刷新偏慢，按 §11 再引入指纹增量。
