# OpenCode 集成技术设计

> 对应 issue [#17](https://github.com/sylearn/AIUsage/issues/17)。
> 分支：`feature/opencode-provider`。
> 本文是实现的唯一事实源：数据口径、文件级改动清单、分阶段范围都以此为准。

## 1. 背景与结论

OpenCode 是终端 AI 编程工具（类似 Claude Code / Codex CLI）。issue #17 请求四项能力：代理、用量统计、菜单栏集成、多账户。

调研结论（实测 OpenCode 1.2.26 + 官方文档）：

- **用量统计无需代理**。OpenCode 自 v1.2.0 起把全部会话写入本地 SQLite（`~/.local/share/opencode/opencode.db`，WAL 模式，Drizzle 管理），每条 assistant 消息自带 token 明细与按 [models.dev](https://models.dev) 定价预计算的 `cost`。这比 Claude（必须走代理才有归档）和 Codex（非代理轨无成本）的数据条件更好。
- **翻译代理无存在必要**。OpenCode 原生支持任意 OpenAI 兼容上游（`opencode.json` 的 `provider` 块 + `baseURL`）。真正缺的是「节点管理 + 一键切换」，应做成配置切换器而非代理进程。
- **OpenCode Zen 无公开余额 API**（上游 issue #10448 开放中），配额型监控暂不可行。

因此分三阶段：

| 阶段 | 范围 | 状态 |
|------|------|------|
| Phase 1 | 用量统计 Provider + 仪表盘 / 菜单栏 / 统计页 / 设置集成 | 本文档主体 |
| Phase 2 | 多账户（auth.json 快照切换）+ 配置节点切换器（opencode.json 受管块） | 设计见 §7 |
| Phase 3（可选） | OpenAI 透传代理轨（请求级日志、与 Claude/Codex 同一节点池） | 设计要点见 §8 |

## 2. OpenCode 数据源事实

### 2.1 存储位置

| 路径 | 内容 |
|------|------|
| `~/.local/share/opencode/opencode.db`（+ `-wal` / `-shm`） | v1.2.0+ 唯一事实源。表：`project` / `session` / `message` / `part` / `account` 等 |
| `~/.local/share/opencode/storage/` | v1.2 之前的旧 JSON 存储；v1.2 启动时自动迁移进 db |
| `~/.local/share/opencode/auth.json` | 各 provider 凭据（Phase 2 用） |
| `~/.config/opencode/opencode.json`（或 `.jsonc`） | 全局配置（Phase 2 用） |

数据目录解析顺序（与 OpenCode 的 `Global.Path.data` 对齐）：

1. `$XDG_DATA_HOME/opencode`（若设置）
2. `~/.local/share/opencode`（CLI 默认，含 macOS）
3. `~/Library/Application Support/opencode`（桌面版 fallback）

**最低支持版本定为 v1.2.0**（SQLite 起点）。旧版 JSON 存储不做兼容——OpenCode 升级时自动迁移，无必要背包袱。找不到 `opencode.db` 即抛 `ProviderError("no_usage_data", …)`。

### 2.2 message 表 schema（实测 1.2.26）

```sql
CREATE TABLE `message` (
  `id` text PRIMARY KEY,            -- msg_xxx
  `session_id` text NOT NULL,
  `time_created` integer NOT NULL,  -- epoch 毫秒
  `time_updated` integer NOT NULL,
  `data` text NOT NULL              -- JSON
);
```

assistant 消息的 `data` JSON（仅列用到的字段）：

```json
{
  "role": "assistant",
  "providerID": "deepseek",
  "modelID": "deepseek-v4-pro",
  "cost": 0.0377087,
  "tokens": {
    "input": 15637, "output": 725, "reasoning": 479,
    "cache": { "read": 43520, "write": 0 }
  },
  "time": { "created": 1778062335799, "completed": 1778062360154 }
}
```

### 2.3 token / 成本口径

实测验证：`tokens.total = input + output + cache.read + cache.write`；`reasoning` 是 `output` 的子集，**不参与求和**。即 `input` 已是 non-cached input，与本项目「`input` 必须是非缓存输入」的计费口径天然一致（见 USAGE_AND_BILLING.md 总原则）。

映射：

| OpenCode 字段 | AIUsage 字段 |
|---|---|
| `tokens.input` | `inputTokens` |
| `tokens.output` | `outputTokens` |
| `tokens.cache.read` | `cacheReadTokens` |
| `tokens.cache.write` | `cacheCreateTokens` |
| `cost` | `estimatedCostUsd`（直接采用，发生时已按 models.dev 定价冻结） |

**未定价语义**：OAuth 订阅渠道（如 `github-copilot`、OAuth 登录的 `anthropic`）OpenCode 记 `cost: 0`，这是「订阅不计费」而非「未定价」。Phase 1 **不产生** unpriced 告警（`overall.unpricedModels` 恒空），避免订阅用户每天被误报。

**模型名口径**：使用 `providerID/modelID`（如 `deepseek/deepseek-v4-pro`、`anthropic/claude-opus-4-6`）。这保留了 OpenCode 特有的「内部供应商」维度，统计页模型分布天然可看出成本流向哪家。无轨道后缀（单轨，见 §4.4）。

**日界**：以 `time.created`（毫秒）按本地时区取 `yyyy-MM-dd`，与 Claude/Codex 口径一致。

## 3. Phase 1 总体数据流

```
opencode.db ──复制 db/-wal/-shm 到临时目录──► SQLite 只读查询（system libsqlite3）
  ──► OpenCodeRow（逐条 assistant 消息）──► 按日聚合 [String: CodexAggregateBucket]
  ──► OpenCodeUsageArchiveStore.freeze()（昨日前冻结、今天重算）
  ──► ProviderUsage.extra（today/week/month/overall + timeline + models）
  ──► UsageNormalizer.normalizeOpenCode() ──► ProviderSummary(costSummary, category: localCost)
  ──► Dashboard / MenuBar / ProxyStatsView / 设置费用来源（全部走既有 localCost 管线）
```

设计取舍：

- **SQLite 访问**：`import SQLite3`（系统库，无新依赖），不走 `Process + /usr/bin/sqlite3`（CursorProvider 旧路径），因为本 provider 每个刷新周期都要跑。先把 `opencode.db` / `-wal` / `-shm` 复制到 `NSTemporaryDirectory()` 再以 `SQLITE_OPEN_READONLY` 打开，规避 WAL 并发与锁问题（OpenCode 进程可能正在写）。查询后删除临时文件。
- **冻结归档**：镜像 `CodexNonProxyUsageArchiveStore` 语义——今天之前的日期首写即冻结、今天每次覆盖重算；`fullHistoryImportedAt == nil` 时首次 fetch 自动全量（`consumeFullHistoryImportRequest` 模式），之后只查 `time_created >= (今天 - 30 天)` 的窗口。用户清空 OpenCode 历史后统计不丢。
  - 归档路径：`~/.config/aiusage/usage-archive/opencode-usage-v1.json`
- **聚合结构复用**：`CodexAggregateBucket` / `CodexModelAggregate` / `CodexRow` / `CodexUsageArchive` 是通用聚合结构（QuotaBackend 模块内部类型），直接复用，不复制一套改名。已知技术债：命名带 Codex 前缀，待后续统一改名为 `Usage*`（不在本期做，避免无关 diff）。
- **timeline**：`hourly` 留空、按日呈现，与 Codex 一致（冻结归档无小时粒度；虽然 db 有毫秒戳，但跨「归档冻结 + 实时重算」两源的小时口径不一致，留作未来增强）。
- **会话数**：扫描窗口内 distinct `session_id` 计数，进 `overall.sessionCount`。
- **schema 漂移防御**：所有 JSON 字段缺失按 0 / nil 处理；`message` 表不存在或查询失败 → 抛 `ProviderError`，UI 呈现为「采集失败」卡片，不崩溃。

## 4. Phase 1 文件级改动清单

### 4.1 QuotaBackend 新增（6 个文件）

| 文件 | 职责 |
|------|------|
| `Providers/OpenCodeCostProvider.swift` | `id = "opencode"`，`displayName = "OpenCode"`；`fetchUsage()` 主流程（镜像 `CodexCostProvider.fetchUsage` 的聚合→extra 编码段，单轨无合并步骤）。顶部注释说明数据来源（规则 15） |
| `Providers/OpenCodeCostProvider+Discovery.swift` | 数据目录解析（§2.1 顺序，`environment` 注入便于测试）；db 临时快照复制/清理 |
| `Providers/OpenCodeCostProvider+Database.swift` | SQLite3 C API 只读封装：open/prepare/step/finalize；查询 `SELECT session_id, data FROM message WHERE time_created >= ?`；错误包装为 `ProviderError` |
| `Providers/OpenCodeCostProvider+Parsing.swift` | `data` JSON → `OpenCodeRow`（Codable 防御解析，过滤 `role != "assistant"`、`tokens` 全零行） |
| `Providers/OpenCodeCostProvider+Aggregation.swift` | dayKey / weekRange / scanWindow / aggregateDays / trailingDailyTimeline / encodeTimeline（镜像 `CodexCostProvider+Aggregation` + `+DateUtils`，遵循仓库既有 per-provider 扩展模式） |
| `Providers/OpenCodeUsageArchiveStore.swift` | actor，冻结归档（§3），无 legacy 迁移分支 |

每个文件控制在 400 行内（规则 3）。

### 4.2 QuotaBackend 修改（4 处）

| 文件 | 改动 |
|------|------|
| `Engine/ProviderRegistry.swift` | `all` 数组按字母序插入 `OpenCodeCostProvider()`（`minimax` 与 `warp` 之间） |
| `Normalizer/UsageNormalizer.swift` | ① `providerThemes` 加 `"opencode": ThemeInfo(accent: "teal", glow: "#2dd4bf")`；② `normalize` switch 加 `case "opencode"`；③ `channel(for:)` 加入 `local` 分支；④ `compactProviderLabel` 加 `"OpenCode"`；⑤ `formatSourceLabel` 加 `"opencode-session-db": "Local OpenCode sessions"` |
| `Normalizer/UsageNormalizer+OpenCode.swift`（新增） | `normalizeOpenCode(base:usage:)`：镜像 `normalizeCodexCost`，`category = ProviderCategory.localCost`，headline/metrics 文案改为 OpenCode 口径（「Local session ledger」），`unpricedModels` 恒 nil |
| `Tests/QuotaBackendTests/ProviderRegistryTests.swift` | 既有契约测试的 id 列表插入 `"opencode"`（不更新会编译失败级红测；仅改既有断言，不新增测试文件） |

### 4.3 App 层修改（10 处）

| 文件 | 改动 |
|------|------|
| `Models/AppState.swift` | ① `providerCatalogItems` 追加 `ProviderCatalogItem(id: "opencode", titleEn: "OpenCode", titleZh: "OpenCode", summaryEn: "Local token and cost ledger from OpenCode sessions", summaryZh: "基于 OpenCode 本地会话的 Token 与费用账本", channel: "local", kind: .costTracking)`；② `costTrackingSelectionMigrationKey` bump 到 `v3`（让存量用户自动启用 OpenCode，逻辑只增不减，与 v2 注释语义一致） |
| `ViewModels/ProviderRefreshCoordinator.swift` | `refreshLocalTokenStatsOnly()` 的 `active` 列表 `["claude", "codex-cost"]` → `["claude", "codex-cost", "opencode"]`（fan-out 隔离慢源） |
| `ViewModels/StatsDataAdapter.swift` | `SourceFamily` 加 `case opencode`，`matches` 按 `baseProviderId == "opencode"` |
| `Views/ProxyStatsView.swift` | ① 视图层 `SourceFamily` 加 `case opencode` + `adapterFamily` 映射（exhaustive switch）；② `opencodeLocalProviders` 计算属性；③ 家族切换器自动出现新段（CaseIterable 驱动，需确认分段标签文案处）；④ 轨道切换器保持仅 Codex（OpenCode 单轨）；⑤ 空态文案补「OpenCode」 |
| `Views/DashboardView.swift` | ① `isAwaitingLocalStats` 的硬编码 id 集合加 `"opencode"`；② 热力图从「claude/codex 两列特判」重构为数据驱动：`[HeatmapSpec]`（providers/label/asset/accent）过滤有数据项后按每行 2 列 chunk 布局；③ `opencodeLocalProviders` 计算属性 |
| `Views/MenuBarView+CostTracking.swift` | `FamilyCost`（基于 `ProxyNodeFamily` 二元）重构为 `CostSourceRow { providerId, label, iconAsset, tint, summary }`，`costFamilyProviders` 改为遍历 `["claude", "codex-cost", "opencode"]` 描述表生成；`familyCostRow` 改为吃 `CostSourceRow`——菜单栏每行的图标/名称/配色与各自工具一一对应 |
| `Views/CostTrackingCard.swift` | accent switch 加 `case "opencode": return .teal` |
| `Views/ProviderIconView.swift` | ① SF Symbol fallback 加 `case "opencode": return "terminal.fill"`；② accent 色 加 `case "opencode": return .teal`（无品牌 imageset 时走 fallback，asset 后续可补 `ProviderIcons/opencode.imageset`） |
| `Resources/Assets.xcassets/ProviderIcons/opencode.imageset` | 新增品牌图标（若无合适 SVG，先不加，靠 SF Symbol fallback；Contents.json + svg 各一文件） |
| 设置页 | **无需改动**：「费用来源」选择器与状态栏 pin 项由 `category == localCost` 通用驱动（`SettingsView+MenuBarPins.swift` / `StatusBarItemView.swift`），OpenCode 自动出现 |

### 4.4 明确不做（Phase 1）

- `UsageTrack` 不动：OpenCode 单轨（全部本地会话），无 ` (Proxy)`/` (Non-Proxy)` 后缀，无轨道切换器（同 Claude）。
- `ProxyUsageFamily` / `ProxyConfiguration` / `ProxyViewModel` 不动：无代理轨。
- `ProviderAuthManager` / `ProviderActivationManager` / `AccountStore` 不动：无多账户。
- 不新增测试文件；仅维护既有 `ProviderRegistryTests` 契约断言。

### 4.5 验收口径

1. 本机有 OpenCode 1.2+ 数据时：仪表盘出现 OpenCode 热力图与概览计入、统计页家族切换出现 OpenCode、菜单栏「费用 · 用量」出现 OpenCode 行（独立图标与青色调）、设置「费用来源」可 pin OpenCode。
2. 无 OpenCode 安装：provider 报 `no_usage_data`，卡片呈现采集失败态，其余功能不受影响。
3. OpenCode 正在运行时刷新：临时快照只读查询不报锁错误。
4. 删除 `~/.local/share/opencode` 后：历史统计仍可从冻结归档读出。

## 5. 关键实现细节备忘

- **SQLite 封装**（`+Database.swift`）：`sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)`；text 列用 `sqlite3_column_text` + `String(cString:)`；prepare 失败/step 错误统一 `ProviderError("db_error", …)`，路径经 `SensitiveDataRedactor.redactPaths(in:)` 脱敏后再进日志（规则 5）。
- **扫描窗口**：默认 30 天（`defaultScanDays` 同 Codex）；首次全量时不带 `WHERE time_created >=` 条件。窗口起点 = 本地时区今天零点 − 29 天，转 epoch 毫秒下推到 SQL，减少 JSON 解码量。
- **临时快照**：`opencode-snapshot-<uuid>.db`；复制顺序 db → wal → shm（wal/shm 容忍缺失）；`defer` 清理。
- **性能**：70 条消息 ≈ 毫秒级；十万行级别靠 30 天窗口 + 冻结归档兜底，不引入逐文件缓存（SQLite 自带索引优势，无需 `CodexCostFileScanCache` 类机制）。
- **os.Logger**：subsystem `com.aiusage.quotabackend`，category `OpenCodeCost`；禁止 print（规则 5）。

## 6. Phase 1 实施顺序

1. QuotaBackend：models 复用确认 → `+Database` → `+Parsing` → `+Discovery` → `+Aggregation` → `OpenCodeUsageArchiveStore` → 主文件 `fetchUsage`
2. Normalizer + Registry + 契约测试断言
3. App 层：catalog → 刷新 fan-out → StatsDataAdapter / ProxyStatsView → DashboardView 热力图重构 → MenuBar 重构 → 图标/配色
4. 人工验证（用户自行编译；本机有真实 OpenCode 数据可直接验收 §4.5）

## 7. Phase 2 设计（节点切换器，已实现）

> 已过寸止确认：做成**独立轻量模块**，不挂入 `NodeProfile` / `ProxyViewModel` 体系
> （该体系 Claude/Codex 二元假设深植，`isCodex` 全应用约 85 处，硬塞第三家族风险过高；
> 且 OpenCode 无代理进程，复用激活管线没有收益）。多账户（auth.json 快照）暂缓，见 §7.3。

### 7.1 模块构成（5 个新文件 + 2 处修改）

| 文件 | 职责 |
|------|------|
| `Models/OpenCodeNode.swift` | 节点模型：name / baseURL / apiKey / models / defaultModel / 可选 limit |
| `ViewModels/OpenCodeConfigManager.swift` | opencode.json 受管注入与还原（见 §7.2） |
| `ViewModels/OpenCodeNodeStore.swift` | 节点持久化（`~/.config/aiusage/opencode-nodes.json`，0600）+ 激活状态对账 |
| `Views/OpenCodeManagementView.swift` | 「OpenCode 代理」主视图：状态横幅 / 节点卡片 / 激活停用 |
| `Views/OpenCodeNodeEditorView.swift` | 节点编辑 sheet |
| `Models/AppSettings.swift` | `AppSection` 加 `opencodeManagement` |
| `Views/ContentView.swift` | 侧边栏「OpenCode 代理」入口（teal 品牌图标，与 Claude/Codex 代理并列） |

### 7.2 配置切换器：opencode.json 受管块

- `OpenCodeConfigManager`（镜像 `CodexConfigManager` 的 backup-as-source-of-truth）：
  - 注入受管键 `provider["aiusage"]`（`npm: "@ai-sdk/openai-compatible"` + baseURL/apiKey/models）+ 顶层 `model: "aiusage/<模型>"`；备份 `opencode.json.aiusage.bak`；还原即整文件回滚，重复激活/切换节点幂等。
  - JSON 结构化读写（`JSONSerialization`，pretty + sortedKeys）；检测到 `opencode.jsonc`（无法保真注释）或解析失败时拒绝接管并在 UI 横幅提示。
  - 配置含 API Key，写入后恢复 0600 权限。
  - 启动对账：用户手动改回 opencode.json 后自动清除激活标记（`OpenCodeNodeStore.reconcileWithConfigFile`）。

### 7.3 暂缓项

- **auth.json 多账户快照切换**（issue 第 4 点）：模式可镜像 Codex 订阅账号切换（快照存 Keychain、备份-写入-标记激活）；auth.json 是「每 provider 单凭据」字典，一份快照 = 一个账户组合，UI 应按「配置快照」表达。待后续单独立项。
- **菜单栏节点快切**：`MenuBarView+TrackSwitcher` 同为二元家族结构，待重构后再接入。

## 8. Phase 3 要点（可选透传代理轨）

- OpenCode 上游请求为标准 OpenAI 格式（`chat/completions`，部分模型 `responses`），透传难度低于 Claude 轨。
- 成本集中在家族枚举扩三元：`ProxyUsageFamily` / `ProxyNodeFamily` / `proxy-usage-opencode-v1.json` 归档 / `ProxyViewModel` 激活轨道 / 菜单栏 TrackSwitcher。
- 启用代理轨后 OpenCode 统计才需要双轨（`UsageTrack` 后缀机制），届时把 §4.4 的「不做」逐项解锁。
- 价值有限（db 已有全量账本），仅当用户需要「请求级实时日志 / 与 Claude、Codex 共用节点池」时再立项。

## 9. 风险与缓解

| 风险 | 缓解 |
|------|------|
| opencode.db schema 漂移（内部 API，Drizzle 迁移） | 只读 + 防御解析 + 失败降级为采集错误；社区工具（ccusage、oc-stats）同押此路径，漂移会被快速暴露 |
| OpenCode 进程写库时读取 | 临时快照 + READONLY；不持久持有连接 |
| `cost: 0` 双语义（订阅 vs 真未定价） | Phase 1 不报 unpriced；如实呈现 0 成本 + token 量 |
| 巨型 message 表 | 30 天窗口下推 SQL + 冻结归档；首次全量仅一次 |
| 桌面版数据目录不同 | Discovery 多路径探测（§2.1） |
