# Claude Code Proxy 架构文档

## 概述

Claude Code Proxy 是 AIUsage 的核心子系统，让 Claude Code 可以通过第三方 OpenAI 兼容的 API 服务来运行，同时保留原生的 Anthropic API 接口。

核心思路：Claude Code 发出的所有请求仍然是标准的 Anthropic Messages API 格式，代理在中间做协议转换和透传，客户端感知不到上游实际使用的是哪家模型。

```
Claude Code ──(Anthropic API)──▶ QuotaServer Proxy ──(OpenAI API / Anthropic API)──▶ 上游服务
```

---

## 两种代理模式

### OpenAI Convert 模式

将 Claude API 请求转换为 OpenAI 格式，发往任何 OpenAI 兼容的上游。

```
Claude Code
  │ POST /v1/messages (Anthropic format)
  ▼
QuotaHTTPServer
  │ 路由 → handleMessagesEndpoint / handleStreamingProxy
  ▼
ClaudeProxyService
  │ Claude request → Canonical → OpenAI request
  ▼
OpenAICompatibleClient
  │ POST /v1/chat/completions 或 POST /v1/responses
  ▼
上游 OpenAI 兼容服务
  │ OpenAI response
  ▼
(逆向) Canonical → Claude response → SSE / JSON 返回 Claude Code
```

支持两种上游 API 格式：
- **chat/completions**：经典 OpenAI Chat API
- **responses**：OpenAI Responses API（支持 reasoning、hosted tools、phase 等）

### Anthropic Passthrough 模式

原样转发请求到 Anthropic 官方 API，仅记录 token 用量，不做格式转换。

```
Claude Code
  │ 任意 Anthropic API 路径
  ▼
QuotaHTTPServer
  │ 路由 → handlePassthroughProxy
  ▼
直接转发到 Anthropic API
  │ 原样返回
  ▼
Claude Code
```

---

## 目录结构

```
QuotaBackend/Sources/
├── QuotaServer/                              # HTTP 服务入口
│   ├── main.swift                            # CLI 启动，环境变量解析
│   ├── QuotaHTTPServer.swift                 # NWListener HTTP 服务器 + StreamingResponse actor
│   ├── QuotaHTTPServer+ClaudeProxy.swift     # Claude API 路由和流式桥接
│   └── QuotaHTTPServer+Passthrough.swift     # Anthropic 透传代理
│
└── QuotaBackend/ClaudeProxy/
    ├── Canonical/                             # 统一中间层（生产主链路）
    │   ├── CanonicalModels.swift              # 中间层数据模型
    │   ├── CanonicalMappers.swift             # 协议 → Canonical 映射
    │   ├── CanonicalRequestBuilders.swift     # Canonical → OpenAI 请求构建
    │   ├── CanonicalClaudeBuilders.swift      # Canonical → Claude 响应构建
    │   ├── CanonicalStreamModels.swift        # 流式事件中间层模型
    │   ├── CanonicalStreamMappers.swift       # 上游流事件 → Canonical 流事件
    │   └── CanonicalLossyModels.swift         # 显式降级标记
    │
    ├── Models/                                # API 协议模型
    │   ├── ClaudeAPIModels.swift              # Anthropic Messages API
    │   ├── OpenAIAPIModels.swift              # OpenAI Chat Completions API
    │   ├── OpenAIResponsesModels.swift        # OpenAI Responses API
    │   └── EventLoggingModels.swift           # 遥测事件模型
    │
    ├── Runtime/                               # 运行时服务
    │   ├── ClaudeProxyConfiguration.swift     # 代理配置 + 环境变量加载
    │   ├── ClaudeProxyService.swift           # 核心服务（请求编排、鉴权、错误处理）
    │   └── OpenAICompatibleClient.swift       # 上游 HTTP 客户端（actor）
    │
    ├── Conversion/                            # 旧直连转换器（参考实现 + 测试基线）
    │   ├── ClaudeToOpenAIConverter.swift       # Claude → OpenAI 直接转换
    │   └── OpenAIToClaudeConverter.swift       # OpenAI → Claude 直接转换
    │
    └── Utilities/
        ├── SSEEncoder.swift                   # Claude SSE 事件序列化
        └── SharedTypes.swift                  # 共享类型说明
```

App 侧集成：

```
AIUsage/
├── Models/
│   ├── ProxyConfiguration.swift               # 代理节点配置模型（旧格式，保留兼容）
│   └── NodeProfile.swift                      # 文件化节点配置（_metadata + 完整 settings.json）
├── ViewModels/
│   ├── ProxyViewModel.swift                   # UI 状态、激活事务、桥接 NodeProfileStore
│   ├── ProxyViewModel+ProxyServer.swift       # QuotaServer 进程管理桥接
│   ├── ProxyViewModel+Aggregation.swift       # 代理统计聚合
│   ├── ProxyViewModel+LogManagement.swift     # 日志管理
│   ├── NodeProfileStore.swift                 # 文件存储层（~/.config/aiusage/profiles/）
│   └── ClaudeSettingsManager.swift            # ~/.claude/settings.json 全量写入 + 备份/恢复
└── Services/
    └── ProxyRuntimeService.swift              # 进程启停、端口清理、可执行文件发现
```

---

## 核心模块详解

### 1. QuotaHTTPServer — HTTP 服务器

**文件**: `QuotaServer/QuotaHTTPServer.swift`（624 行）

基于 `Network.framework` 的轻量 HTTP/1.1 服务器，零外部依赖。

**关键类型**:

- `QuotaHTTPServer` — 服务器主类，管理 `NWListener` 生命周期
- `StreamingResponse` — actor，管理单个流式连接的生命周期
- `HTTPRequest` / `HTTPResponse` — 请求/响应值类型

**StreamingResponse actor**:

负责 HTTP/1.1 Chunked Transfer Encoding 的正确实现：

| 方法 | 职责 |
|------|------|
| `sendHeaders(status:headers:)` | 发送状态行 + `Transfer-Encoding: chunked` |
| `sendSSEEvent(_:)` | 发送 SSE 格式的 chunked frame |
| `sendChunk(_:)` | 发送原始文本的 chunked frame |
| `sendDataChunk(_:)` | 发送原始 Data 的 chunked frame |
| `finish()` | 发送 `0\r\n\r\n` 终止帧，优雅关闭连接 |

**路由逻辑**:

```
/health               → 200 OK
/v1/messages          → handleMessagesEndpoint (非流式) 或 handleStreamingProxy (流式)
/v1/messages/count_tokens → handleCountTokensEndpoint
/v1/files             → handleFilesEndpoint (Files API)
/api/event_logging/*  → handleEventLoggingEndpoint
其他 (passthrough)    → handlePassthroughProxy
```

### 2. QuotaHTTPServer+ClaudeProxy — 代理路由与流式桥接

**文件**: `QuotaServer/QuotaHTTPServer+ClaudeProxy.swift`（678 行）

**关键函数**:

| 函数 | 职责 |
|------|------|
| `handleMessagesEndpoint(request:headers:)` | 非流式 `/v1/messages` 处理，调用 `ClaudeProxyService.handleMessages()` |
| `handleStreamingProxy(_:request:)` | 流式 `/v1/messages`，建立 SSE 通道并逐事件桥接 |
| `handleCountTokensEndpoint(request:headers:)` | Token 计数估算 |
| `handleFilesEndpoint(request:headers:)` | Files API CRUD 路由 |
| `handleEventLoggingEndpoint(request:headers:)` | 遥测事件接收（始终返回成功） |
| `proxyErrorHTTPResponse(proxy:error:headers:)` | 统一错误响应构建，附带 `request-id` 透传 |

**流式桥接流程** (`handleStreamingProxy`):

```
1. 解析 Claude 请求，鉴权
2. 创建 StreamingResponse actor
3. 发送 SSE headers（Transfer-Encoding: chunked）
4. 发送 message_start + ping
5. 初始化 CanonicalOpenAIUpstreamStreamMapper
6. 调用 ClaudeProxyService.sendStreamingClaudeRequest
   每收到一个上游事件:
   ├─ mapper 归一化为 CanonicalStreamEvent
   ├─ CanonicalClaudeStreamBuilder 生成 Claude SSE 事件
   └─ StreamingResponse.sendSSEEvent 推送给客户端
7. 发送 message_delta + message_stop
8. 记录 PROXY_LOG
9. streamer.finish() 优雅关闭
```

### 3. QuotaHTTPServer+Passthrough — Anthropic 透传代理

**文件**: `QuotaServer/QuotaHTTPServer+Passthrough.swift`（257 行）

**关键函数**:

| 函数 | 职责 |
|------|------|
| `handlePassthroughProxy(_:request:)` | 主入口，判断流式/非流式分发 |
| `handlePassthroughStreaming(...)` | 逐行转发 upstream SSE，chunked 编码 |
| `handlePassthroughNonStreaming(...)` | 同步转发，提取 usage 记录日志 |
| `forwardPassthrough(...)` | 最终转发函数 |

Passthrough 模式下，请求头原样传递（替换 `x-api-key` 为上游密钥），支持 `anthropic-beta` 等特殊头。

### 4. Canonical 中间层 — 统一协议桥接

这是当前生产主链路的核心，所有协议转换都经过 Canonical 层。

#### CanonicalModels.swift（557 行）

定义统一的中间层数据结构：

| 类型 | 职责 |
|------|------|
| `CanonicalRequest` | 统一请求：model、system、items、tools、config |
| `CanonicalResponse` | 统一响应：id、model、items、stop、usage |
| `CanonicalConversationItem` | 统一对话项：message / toolCall / toolResult / reasoning / hostedToolEvent |
| `CanonicalContentPart` | 统一内容块：text / image / document / fileRef / reasoningText / refusal |
| `CanonicalToolDefinition` | 统一工具定义：function / hosted / custom |
| `CanonicalToolConfig` | 工具选择策略：auto / required / none / specific |
| `CanonicalStop` | 停止原因：end_turn / tool_use / max_tokens / pause_turn / refusal / error |
| `CanonicalUsage` | Token 统计：input（不含缓存）/ output / cacheCreation / cacheRead / reasoning，上游字段形状经 `OpenAIUsage.effectiveInputTokens / effectiveCachedTokens` 归一化，参见 [CANONICAL_MIDDLE_LAYER_DESIGN.md §11](CANONICAL_MIDDLE_LAYER_DESIGN.md#11-canonicalusage) |

#### CanonicalMappers.swift（1044 行）

协议 → Canonical 的入站映射：

| Mapper 方法 | 方向 |
|------------|------|
| `CanonicalRequestMapper().mapClaude(_:)` | Claude MessageRequest → CanonicalRequest |
| `CanonicalResponseMapper().mapOpenAIChatCompletions(_:)` | Chat Completions Response → CanonicalResponse |
| `CanonicalResponseMapper().mapOpenAIResponses(_:)` | Responses Response → CanonicalResponse |

处理所有内容类型映射、工具定义转换、stop reason 归一化。

#### CanonicalRequestBuilders.swift（1206 行）

Canonical → OpenAI 的出站请求构建：

| Builder 方法 | 产出 |
|-------------|------|
| `buildChatCompletionRequest(from:modelOverride:)` | `OpenAIChatCompletionRequest` |
| `buildResponsesRequest(from:modelOverride:)` | `OpenAIResponsesRequest` |

关键映射逻辑：
- Claude `system` → OpenAI `messages[0].role=system` / `instructions`
- Claude `thinking` → OpenAI `reasoning` (responses) / `reasoning_content` (chat, DeepSeek 等)
- Claude `document.file_id` → OpenAI `input_file` (responses) / `type: "file"` (chat)
- Claude `tool_result` → OpenAI `role: tool` (chat) / `function_call_output` (responses)
- 角色区分 `input_text` vs `output_text`（assistant 消息使用 `output_text`）

#### CanonicalClaudeBuilders.swift（403 行）

Canonical → Claude 的出站响应构建：

| Builder 方法 | 产出 |
|-------------|------|
| `buildMessageResponse(from:originalModel:)` | `ClaudeMessageResponse` |

将 canonical response 里的 text、tool_call、reasoning 等映射回 Claude 的 content block 格式。

#### CanonicalStreamModels.swift（124 行）+ CanonicalStreamMappers.swift（373 行）

流式事件归一化层：

```
OpenAIUpstreamStreamEvent
  │ CanonicalOpenAIUpstreamStreamMapper
  ▼
CanonicalStreamEvent
  │ CanonicalClaudeStreamBuilder (in CanonicalClaudeBuilders.swift, called from QuotaHTTPServer+ClaudeProxy.swift)
  ▼
Claude SSE 事件文本
```

`CanonicalStreamEvent` 枚举：

| 事件 | 语义 |
|------|------|
| `.textDelta(text)` | 文本增量 |
| `.reasoningDelta(text)` | thinking/reasoning 增量 |
| `.toolCallStart(index, id, name)` | 工具调用开始 |
| `.toolCallDelta(index, json)` | 工具参数增量 |
| `.toolCallEnd(index)` | 工具调用结束 |
| `.completion(stop, usage)` | 消息完成 |
| `.error(message)` | 上游错误 |

Mapper 内部维护状态机：当前活跃 block 类型（text / reasoning / tool）、tool 缓冲区（等待 metadata 到达后再发送）、text block index 追踪。

### 5. ClaudeProxyService — 核心编排服务

**文件**: `ClaudeProxy/Runtime/ClaudeProxyService.swift`（444 行）

`public actor ClaudeProxyService`，提供以下能力：

| 方法 | 职责 |
|------|------|
| `authenticate(headers:)` | 验证 `x-api-key` 或 `Authorization: Bearer` |
| `handleMessages(request:)` | 非流式主链路：Claude → Canonical → OpenAI → Canonical → Claude |
| `sendStreamingClaudeRequest(_:onEvent:)` | 流式主链路：构建请求并调用上游流式 API |
| `handleCountTokens(request:)` | 启发式 token 计数 |
| `listFiles / retrieveFile / createFile / deleteFile / retrieveFileContent` | Files API 桥接 |
| `buildErrorResult(error:)` | 统一错误包装：error type 映射 + request-id 透传 |
| `mapModel(_:)` | Claude 模型名 → 上游模型名 |

**请求数据流（非流式）**:

```swift
let canonicalRequest = CanonicalRequestMapper().mapClaude(request)      // Claude → Canonical
let openAIRequest = CanonicalOpenAIRequestBuilder().buildXxxRequest(...) // Canonical → OpenAI
let openAIResponse = upstreamClient.sendXxx(request: openAIRequest)     // 发送上游
let canonicalResponse = CanonicalResponseMapper().mapOpenAIXxx(...)      // OpenAI → Canonical
let claudeResponse = CanonicalClaudeResponseBuilder().build(...)         // Canonical → Claude
```

### 6. OpenAICompatibleClient — 上游 HTTP 客户端

**文件**: `ClaudeProxy/Runtime/OpenAICompatibleClient.swift`（1015 行）

`public actor OpenAICompatibleClient`，封装所有上游通信：

| 方法 | 职责 |
|------|------|
| `sendChatCompletion(request:)` | 非流式 Chat Completions |
| `sendResponses(request:)` | 非流式 Responses API |
| `streamCompletion(request:onEvent:)` | 流式 Chat Completions |
| `streamResponses(request:onEvent:)` | 流式 Responses API |
| `listFiles / retrieveFile / uploadFile / deleteFile / retrieveFileContent` | Files API |

关键行为：
- 自动重试：当上游因 `max_tokens` 参数不兼容返回 400 时，自动移除该参数重试
- Reasoning 去重：流式 reasoning 增量可能包含重复前缀，client 会自动去重
- 错误提取：从上游 HTTP 响应中提取 `request-id` / `x-request-id` 并附加到错误对象
- API 边界强制：`sendChatCompletion` / `streamCompletion` 在配置为 `.responses` 模式时会抛错，反之亦然

### 7. API 模型层

#### ClaudeAPIModels.swift（807 行）

完整的 Anthropic Messages API 类型定义：

- `ClaudeMessageRequest` / `ClaudeMessageResponse` — 核心请求/响应
- `ClaudeContentBlock` — text / image / document / tool_use / tool_result / thinking / redacted_thinking / unknown
- `ClaudeStreamEvent` — message_start / content_block_start / content_block_delta / content_block_stop / message_delta / message_stop
- `ClaudeDelta` — text_delta / input_json_delta / thinking_delta / signature_delta / citations / unknown
- `ClaudeToolDefinition` — 含 `eager_input_streaming` 支持
- `ClaudeTokenCountRequest` / `ClaudeTokenCountResponse`
- `ClaudeFilesListResponse` / `ClaudeFileObject` — Files API

#### OpenAIAPIModels.swift（616 行）

OpenAI Chat Completions API 类型定义：

- `OpenAIChatCompletionRequest` / `OpenAIChatCompletionResponse`
- `OpenAIChatMessage` — 支持 string / array content + `reasoning_content`（DeepSeek 等）
- `OpenAIContentPart` — text / image_url / input_audio / file / unknown
- `OpenAIToolCall` / `OpenAIFunctionCall`
- `OpenAIStreamChunk` — 含自定义解码器，容错 `usage: {}` 空对象（DeepSeek 兼容）
- `OpenAIDelta` — content + `reasoning_content`

#### OpenAIResponsesModels.swift（1945 行）

OpenAI Responses API 类型定义，是最大的模型文件：

- `OpenAIResponsesRequest` / `OpenAIResponsesResponse`
- `OpenAIResponsesInputItem` — message / function_call / function_call_output / item_reference / reasoning / compaction
- `OpenAIResponsesInputContent` — input_text / input_image / input_file / output_text
- `OpenAIResponsesOutputItem` — message / function_call / reasoning / hosted tool items (file_search / web_search / computer_use / code_interpreter / mcp)
- `OpenAIResponsesStreamEvent` — 完整的流式事件体系
- `OpenAIResponsesTool` — function / file_search / web_search / code_interpreter / computer_use / mcp

### 8. 旧转换层（参考实现）

#### ClaudeToOpenAIConverter.swift（375 行）

Claude 请求 → OpenAI Chat Completions 请求的直接转换。当前已不在生产主链路中使用，保留为测试基线和参考实现。

#### OpenAIToClaudeConverter.swift（571 行）

OpenAI Chat Completions 响应 → Claude 响应的直接转换。同样保留为参考实现。

这两个文件不再承担生产职责，但在 shadow tests 中用于验证 canonical 路径的输出与直连路径一致。

---

## 配置与启动

### 环境变量

QuotaServer 通过环境变量配置代理行为：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PROXY_MODE` | `openai` 或 `passthrough` | `openai` |
| `OPENAI_API_KEY` | 上游 API 密钥（OpenAI 模式必填） | — |
| `OPENAI_BASE_URL` | 上游 API 地址 | `https://api.openai.com` |
| `OPENAI_API_MODE` | `chat_completions` 或 `responses` | `chat_completions` |
| `BIG_MODEL` | opus 映射目标 | `gpt-4o` |
| `MIDDLE_MODEL` | sonnet 映射目标 | `gpt-4o-mini` |
| `SMALL_MODEL` | haiku 映射目标 | `gpt-3.5-turbo` |
| `MAX_OUTPUT_TOKENS` | 输出 token 上限 | 无限制 |
| `ANTHROPIC_API_KEY` | 客户端鉴权密钥（可选） | — |
| `ANTHROPIC_UPSTREAM_URL` | Passthrough 上游地址 | `https://api.anthropic.com` |
| `ANTHROPIC_UPSTREAM_KEY` | Passthrough 上游密钥 | — |

### 启动命令

```bash
swift run QuotaServer --port 4318 --host 127.0.0.1
```

### ClaudeProxyConfiguration

`ClaudeProxyConfiguration` 是代理的核心配置结构，支持从环境变量和 App 侧 UI 两种方式加载。

关键方法：
- `loadFromEnvironment()` → 从 `ProcessInfo.processInfo.environment` 读取
- `mapToUpstreamModel(_:)` → 将 Claude 模型族（opus/sonnet/haiku）映射到上游模型名
- `normalizeOpenAIBaseURL(_:)` → 自动清理 URL 末尾的 `/v1/chat/completions` 等路径
- `validate()` → 校验必填字段

---

## App 侧集成

### ProxyViewModel

UI 状态管理和激活事务：

1. 用户在 UI 选择一个代理节点并点击激活
2. `ProxyViewModel` 执行事务式激活：
   - 从 `NodeProfileStore` 加载 `NodeProfile`（v0.5.0+），获取完整 `settings.json` 内容
   - 通过 `ClaudeSettingsManager.writeFullSettings()` 全量替换 `~/.claude/settings.json`（自动备份到 `settings.backup.json`）
   - 启动 `QuotaServer` 进程（通过 `ProxyRuntimeService`）
   - 写入 pricing override
   - 全部成功后才持久化 `activatedConfigId`
3. 如果中途失败，回滚所有已完成的副作用（从备份恢复 `settings.json`）

### NodeProfileStore

文件化节点配置持久化层（v0.5.0+）：

- 存储路径：`~/.config/aiusage/profiles/*.json`
- 每个 JSON 文件包含 `_metadata`（节点名称、ID、代理配置）和完整的 `settings` 字典
- 支持 CRUD、批量导入/导出、自动从旧版 UserDefaults 迁移

### ProxyRuntimeService

独立 service 层，管理 QuotaServer 进程的物理生命周期：

- 进程启动/停止
- 端口占用检测与陈旧进程清理
- QuotaServer 可执行文件发现
- Pricing override 文件写入/清理

### ClaudeSettingsManager

管理 `~/.claude/settings.json` 的读写：

- `writeFullSettings(_:)` — 全量替换 `settings.json`（自动备份当前文件到 `settings.backup.json`）
- `restoreFromBackup()` — 从备份恢复 `settings.json`（停用时调用）
- 旧方法 `writeEnv()` / `clearEnv()` 保留用于向后兼容

---

## 定价与计费

### ModelPricing 拆分字段

`ProxyConfiguration.ModelPricing` 将缓存单价从合并的 `cachePerMillion` 拆为独立的写入 / 读取两项，与 Anthropic 的真实计费分层对齐（v0.4.25+）：

| 字段 | 含义 | 默认倍率（相对 `inputPerMillion`） |
|------|------|------|
| `inputPerMillion` | 未命中缓存的输入 | 1.0× |
| `outputPerMillion` | 输出 | 独立定价 |
| `cacheCreatePerMillion` | 缓存写入（cache creation） | 1.25× |
| `cacheReadPerMillion` | 缓存读取（cache hit） | 0.1× |

编辑器提供"自动填充缓存单价"一键按倍率推导（`ProxyConfiguration.ModelPricing.defaultCacheWriteMultiplier` / `defaultCacheReadMultiplier`）。

### 计费公式

```
cost_usd = (input * inputPerMillionUSD
          + output * outputPerMillionUSD
          + cacheCreate * cacheCreatePerMillionUSD
          + cacheRead  * cacheReadPerMillionUSD) / 1_000_000
```

四项字段**互斥不相交**。保证这一点的责任在 upstream → `CanonicalUsage` 的归一化层，详见 [CANONICAL_MIDDLE_LAYER_DESIGN.md §11](CANONICAL_MIDDLE_LAYER_DESIGN.md#11-canonicalusage)。特别注意 DeepSeek 的 `prompt_tokens` 本身**包含** cache-hit 部分，必须用 `prompt_cache_miss_tokens` 或 `promptTokens - cachedTokens` 作为 `inputTokens`，否则 cache-hit 部分会被双计。

### 遗留字段迁移

历史 `ProxyConfiguration.json` / `ProxyStatistics` / `ProxyRequestLog` 只有合并的 `cachePerMillion` / `tokensCache` / `totalTokensCache`：

- **Decoder 兼容**：若只存在 legacy 标量，自动合成 `cacheReadPerMillion = legacy`、`cacheCreatePerMillion = legacy × 1.25`；若只存在 split 字段则按 split 读取；两者同在时以 split 优先。
- **Encoder 双写**：新代码同时写 legacy + split 字段，旧版 AIUsage 仍可读取。后续若要下线可先停写 legacy 键，保留 decoder 一段时间。
- **历史日志**：老日志的合并 `tokensCache` 无从拆分，统一归入 `tokensCacheRead`（`tokensCacheCreation = 0`）。UI 上的"缓存命中率" = `cacheRead / (input + cacheRead + cacheCreation)` 在这类记录上会偏高（不计写入分母），迁移期内可接受。

### 上游 → QuotaServer → AIUsage 的 usage 管道

1. **上游**：Anthropic-native 原生发 `cache_creation_input_tokens` / `cache_read_input_tokens`；OpenAI-compat 上游按各家形状上报（见 Canonical §11 归一化表）。
2. **QuotaServer**：
   - [`QuotaHTTPServer+ClaudeProxy.swift`](../QuotaBackend/Sources/QuotaServer/QuotaHTTPServer+ClaudeProxy.swift) 在非流式路径直接读 `response.usage`，流式路径从 `messageDelta.usage` 逐事件累积 `reportedInputTokens` / `reportedCacheCreation` / `reportedCacheRead`；`OpenAICompatibleClient` 对 streaming 自动附加 `stream_options.include_usage: true` 确保上游发送 usage chunk。
   - [`QuotaHTTPServer+Passthrough.swift`](../QuotaBackend/Sources/QuotaServer/QuotaHTTPServer+Passthrough.swift) 直接从 Anthropic 原生 usage 读取，不经 Canonical 归一化。
3. **日志 JSON**：PROXY_LOG 行同时发射 `cache_creation_tokens` / `cache_read_tokens`（split）+ `cache_tokens`（总和，向后兼容）。
4. **AIUsage 侧**：[`ProxyViewModel+ProxyServer.swift`](../AIUsage/ViewModels/ProxyViewModel+ProxyServer.swift) 优先读 split 字段，缺失则按 legacy `cache_tokens` 兜底并全部归入 `cacheRead`。成本由 `ProxyConfiguration.ModelPricing.costForTokens` 使用上面的公式算出。

---

## Files API 桥接

代理支持 Claude Files API 到 OpenAI Files API 的桥接：

| Claude 端点 | 桥接方式 |
|-------------|---------|
| `GET /v1/files` | → OpenAI `GET /v1/files`，映射元数据格式 |
| `GET /v1/files/:id` | → OpenAI `GET /v1/files/:id`，映射元数据格式 |
| `POST /v1/files` | 解析 multipart，→ OpenAI `POST /v1/files`（自动补 `purpose=user_data`） |
| `DELETE /v1/files/:id` | → OpenAI `DELETE /v1/files/:id` |
| `GET /v1/files/:id/content` | → OpenAI `GET /v1/files/:id/content`，透传原始二进制 |

要求 `anthropic-beta: files-api-2025-04-14` 请求头。

---

## 错误处理

### 错误类型体系

```
UpstreamError
├── .httpError(statusCode, message, requestID?)   → 上游 HTTP 错误
├── .invalidURL(url)                               → URL 构造失败
├── .invalidResponse(message)                      → API 边界违反
├── .decodingFailed(message)                       → JSON 解码失败
└── .streamingFailed(message)                      → 流式传输中断

ConfigurationError
├── .missingAPIKey / .invalidURL / .invalidModel / .invalidPort

ConversionError
└── 协议转换中遇到的不可恢复问题
```

### 错误映射

上游 HTTP 状态码映射为 Claude 错误类型：

| HTTP Status | Claude Error Type |
|-------------|------------------|
| 400 | `invalid_request_error` |
| 401 | `authentication_error` |
| 402 | `billing_error` |
| 429 | `rate_limit_error` |
| 504 | `timeout_error` |
| 529 | `overloaded_error` |
| 5xx | `api_error` |

上游 `request-id` / `x-request-id` 会透传到 Claude 错误响应的 `request_id` 字段和 HTTP 响应头，方便排障。

---

## 测试矩阵

### 测试文件

| 文件 | 覆盖范围 | 测试数 |
|------|---------|--------|
| `QuotaHTTPServerProxyIntegrationTests.swift` | 端到端集成：路由、鉴权、非流式/流式、工具调用、图片、文件、reasoning、错误、usage | 29 |
| `CanonicalMiddleLayerTests.swift` | Canonical 层映射正确性、shadow tests（与直连转换器对比） | 12 |
| `ClaudeProxyConverterTests.swift` | 直连转换器单测 | 33 |
| `OpenAIResponsesTests.swift` | Responses API 模型、流式事件、reasoning、tool streaming | 12 |
| `OpenAIUsageCacheNormalizationTests.swift` | 上游 usage → CanonicalUsage 归一化（DeepSeek flat / OpenAI nested / 无 cache 字段 / 破损数据）锁回归 | 11 |
| `HTTPServerTests.swift` | HTTP 请求解析、二进制安全 | 9 |
| `ProxyIntegrationTestSupport.swift` | Mock 上游服务器、测试辅助工具 | — |

### 回归脚本

```bash
scripts/run_claude_proxy_regression.sh
```

执行：
1. `swift test --filter QuotaHTTPServerProxyIntegrationTests`
2. `xcodebuild -scheme AIUsage -configuration Debug build`

### 覆盖的高频链路

- 非流式/流式文本生成（chat_completions 和 responses 两条路径）
- 多工具调用与 tool loop 历史保真
- 图片输入 + document/file_id 输入
- Reasoning / thinking 桥接
- Fine-grained tool streaming（参数缓冲 + metadata 延迟到达）
- `pause_turn` / `max_tokens` 等 stop reason 对齐
- 上游 400/429 错误到 Claude 错误格式的映射
- Request-ID 透传
- Files API CRUD
- Anthropic Passthrough 转发

---

## 已知限制

1. **Hosted tool 挂起状态**：OpenAI hosted tools（file_search / web_search 等）的"仍在执行中"状态在 Claude 消息 schema 中没有完全等价的回填项，跨回合只能保守降级成 `pause_turn`。

2. **Token 计数为估算**：`/v1/messages/count_tokens` 使用启发式规则（字符数 ÷ 4），不是真实 tokenizer。

3. **旧转换器保留**：`ClaudeToOpenAIConverter` / `OpenAIToClaudeConverter` 不再处于生产主链路，但保留为测试参考基线，需注意不要让两套实现漂移。

4. **Canonical 层 v1 范围**：当前 canonical 层覆盖核心共享语义，vendor-specific 能力（如 Claude `cache_control`、`citations`、OpenAI `encrypted_content`）通过 `rawExtensions` 透传而非强类型建模。

---

## CodeX 代理（CodeX Proxy）

让 OpenAI Codex CLI 通过第三方 **OpenAI 兼容上游** 运行，是与 Claude Code 代理平行、相互独立的第二条代理轨道。

```
Codex CLI ──(OpenAI Responses API)──▶ QuotaServer(PROXY_TARGET=codex) ──(原样转发)──▶ OpenAI 兼容上游
```

### 设计要点：忠实透传（Phase B）

Codex 的 `wire_api` 恒为 **Responses**。代理对 Codex **完全透明（等价直连）**：不经过 Canonical 改写，原样转发请求体，仅做三件事——

1. 按节点配置把 `model` 映射到上游模型（未配置覆盖则不动）；
2. 注入上游鉴权（`OPENAI_API_KEY`），剔除会与上游连接/鉴权冲突的入站头；
3. 转发 Codex 的关键头（`OpenAI-Beta` / `originator` / `session_id` / `conversation_id` / `User-Agent`）。

usage 走**旁路解析**（非流式读响应体顶层 `usage`，流式读 `response.completed` 帧内 `response.usage`），用于复用既有 `PROXY_LOG` 与统计，不改变回传给 Codex 的字节。

> **为什么不做协议转换**：忠实透传最大化兼容 Codex 原生的 `instructions` / `reasoning` / 工具语义（`local_shell`、`apply_patch`、`function`、`custom` 等），避免有损改写。Canonical→Responses 转换层与 chat-completions / 非透传分支已在本阶段裁剪，留待 Phase 2（见下「技术债」）。

### 进程与隔离模型

- 每个 CodeX 节点启动**独立的 QuotaServer 进程**，以环境变量 `PROXY_TARGET=codex` 区分；`main.swift` 中 `PROXY_TARGET=codex` 时启用 CodeX 代理并禁用 Claude 代理，避免端口/语义冲突。
- CodeX 写 `~/.codex/config.toml`，Claude 写 `~/.claude/settings.json`，**两条轨道互不影响、可同时激活**。
- 默认端口 **4319**（避开 Claude 默认 8080）；本地 `http`（Codex 不信任自签证书，默认不启用 HTTPS）。

### 配置文件管理（外科式合并）

`CodexConfigManager`（App 侧，`~/.codex/config.toml`）：

- 激活时注入三段**受管理 sentinel 块**（纯字符串处理，不引入 TOML 第三方库）：
  - **HEADER 块**：顶层 `model` / `model_provider = aiusage-proxy`；
  - **BASE 块（通用配置基底，可选）**：把「通用配置」`CodexGlobalConfig.tomlText` 与节点 `ProxySettings.extraTOML` 按**顶层键合并**后注入（**节点键覆盖全局同名键 / 同名表头**），顶层 key 与 `[table]` 分别归位，避免重复键报错；
  - **PROVIDER 块**：`[model_providers.aiusage-proxy]`（`base_url = http://host:port/v1`、`wire_api = "responses"`、`experimental_bearer_token = <clientKey>`）。
- 注入前会从用户原文里剥离与 BASE 块冲突的顶层键与表段，再按「HEADER → BASE 顶层键 → 清理后的用户正文 → BASE 表段 → PROVIDER」重新组装，保证 TOML 结构合法。
- **备份即真相源**：激活前把干净原文备份到 `config.toml.aiusage.bak`，保证重复激活幂等；停用整文还原并删除备份。
- `config.toml` 可能含 token，写入后 `chmod 0600`。

#### 双层配置模型（对齐 Claude Code）

CodeX 与 Claude 一致采用「实时文件 + 受管理片段」双层心智，二者职责严格区分：

- **通用配置基底**（`CodexGlobalConfig`，存 `~/.config/aiusage/codex-global-config.json`，由 `NodeProfileStore` 持久化）：带 `enabled`（Merge 开关）+ 原文 `tomlText`，仅在激活节点/订阅时合并写入 `config.toml`；类比 Claude 的 `GlobalConfig`/`settings.json` 片段。
- **节点原文 TOML**（`ProxySettings.extraTOML`）：单个 CodeX 节点的额外顶层键，激活时与通用配置合并，**优先级更高**。
- **`config.toml` 实时文件**：磁盘上真实生效的文件本身（含上面注入的受管理块），只读/编辑入口与上面两层解耦。

### 鉴权链（两段密钥分离）

```
Codex CLI  ──Bearer <clientKey>──▶  本地代理(校验 expectedClientKey)  ──OPENAI_API_KEY──▶  上游
```

`clientKey`（即 `effectiveClientKey`，留空回退 `"proxy-key"`）由 `config.toml` 的 `experimental_bearer_token` 下发给 Codex，本地代理据此校验；真实上游密钥仅存在于服务进程环境变量，不下发给 Codex。

### 系统代理 no_proxy 自动修复

Codex（Rust `reqwest`）会读取 macOS 系统代理，且**不尊重** `127.0.0.1` 例外，导致发往本地回环的请求被系统代理拦截回 502（`curl` 不受影响，故曾长期误判为上游问题）。

- `SystemProxyDetector`（`SCDynamicStoreCopyProxies`）检测系统代理是否启用。
- `CodexNoProxyFixer`：激活 CodeX 节点且**检测到系统代理时**，往 `~/.codex/.env` 写入受管理块 `no_proxy/NO_PROXY = 127.0.0.1,localhost,::1`（Codex 启动会加载该文件）；停用/启动清理时移除还原。
- **隔离保证**：no_proxy 仅含本地回环，对订阅账号（chatgpt.com）/ 任意外网 API **零影响**（它们照常走系统代理）；只作用于 `~/.codex`，不碰用户 shell 配置。
- UI 横幅（`SystemProxyWarningBanner`）作轻量信息提示并提供「复制 no_proxy」兜底。

### `/v1/models` 透传

Codex 启动会 `GET /v1/models` 刷新模型列表。代理忠实转发上游结果（`fetchRawModels`），避免 404 噪音。

### 上游瞬时故障重试

第三方中转 / Cloudflare 偶发 5xx。`OpenAICompatibleClient` 对 **500/502/503/504** 自动重试（最多 3 次，退避 0.4s/0.9s）：

- 非流式（`sendRawResponses`）/ 模型列表（`fetchRawModels`）：拿到响应后判定状态码再决定重试。
- 流式（`streamRawResponses` → `connectStreamWithRetry`）：**在回传任何 SSE 帧之前**完成状态码判定，因此重试对客户端无副作用（此时只发了 200 响应头）。

> SSE 切帧注意：Foundation 的 `AsyncBytes.lines` 会吞掉帧间空行，故除空行外，新的 `event:` 行也作为切帧信号，避免上游多帧被拼成一帧。

### 双轨激活与互斥

- `ProxyViewModel` 用 `activatedConfigId`（Claude）与 `activatedCodexConfigId`（CodeX）**两条独立激活轨道**；`persistActivationSelection(isCodex:)` 只更新本轨道，`isEnabled` 以「任一轨道激活」聚合；互斥仅在**同家族**内（切换 Claude 节点不影响 CodeX，反之亦然）。
- **代理 ↔ 订阅账号互斥**（都写 `~/.codex`）：激活 CodeX 代理 → `markCodexSubscriptionInactiveForProxy()` 把订阅账号标记为未激活；激活 CodeX 订阅账号（写 `~/.codex/auth.json`）→ 发 `codexSubscriptionAccountActivating` 通知 → `ProxyViewModel` 自动停用正在运行的 CodeX 代理并还原 `config.toml`。
- **UI 层防双高亮（启动期竞态兜底）**：菜单栏轨道 / 侧边栏订阅区 / 订阅菜单项统一以「代理节点占用 `config.toml`（`activatedId(isCodex:) != nil`）即为生效身份」为准——此时订阅一律渲染为未激活，杜绝两条轨道在 UI 同时高亮。

### 统计与 UI

- `ProxyNodeFamily`（`.claude` / `.codex`）贯穿聚合层：`allLogs` / `modelAggregates` / `overallStats` 等均支持可选 `family` 过滤（缓存键含 family）。
- 侧边栏新增独立「CodeX 代理」菜单（`CodexProxyManagementView`，基于 `ProxyManagementView(family: .codex)`）；CodeX 菜单隐藏 Claude 的 `GlobalConfigSection` / `settings.json` 入口，确保字段隔离。
- **统一切换器（订阅账号 + API 节点）**：CodeX 菜单顶部用 `CodexSubscriptionSection` 列出订阅账号（`~/.codex/auth.json`，点击经 `ProviderActivationManager.activateAccount` 激活，自动停用代理节点）；顶部菜单栏 `proxyTrackSwitcher(.codex)` 在同一轨道里同时列「订阅 / API 节点」两段，单一激活态在菜单栏、侧边栏、订阅项三处同步高亮。
- **配置编辑（双层，置于订阅区上方）**：`CodexGlobalConfigSection` 提供两个解耦入口——
  - **通用配置卡片**：Merge 开关 + 顶层条目数摘要 + 编辑（`CodexGlobalConfigEditorView`，编辑 `CodexGlobalConfig.tomlText` 原文片段）；
  - **`config.toml` 实时文件入口**：`CodexConfigEditorView` 查看/编辑磁盘真实文件，含受管理代理块只读提示 + 保存后恢复 0600 权限。
  - 两个编辑器复用同一套 **TOML 语法高亮**（`TOMLSyntaxTextView` 包 NSTextView + `TOMLHighlighter` 行级词法着色）+ **轻量语法检查**（`TOMLLinter`：段头括号闭合 / 引号成对，宽松不误报跨行数组与多行字符串）。CodeX 家族工具栏不再重复 `config.toml` / `settings.json` 按钮。
- **节点编辑器原文 TOML 页**：`CodexProxyEditorView` 新增「Advanced · Extra TOML」分节，可视化字段之外直接编辑该节点 `extraTOML`（同样高亮 + 检查），激活时与通用配置合并、节点优先。
- **订阅行 UX（账号列表）**：区标题为「账号列表」（`CodexSubscriptionSection`）。每行 = 抓手 + 图标 + 主标题(邮箱) + 色彩 plan 徽标（`membershipBadgeTint`：Free/Plus/Pro/Business/Enterprise 统一色板）+ 可编辑备注行（`noteRow` → `AccountNoteEditorView`，取代无意义的 ID 文本）+ 内联用量 pill（`usageWindowPills`：取订阅 OAuth 直连的 ChatGPT 用量窗口剩余百分比，>50% 绿 / >20% 橙 / 其余红）+ 激活开关。激活态行底色/描边用品牌蓝（`codexBrand`），与节点列表一致。
- **激活开关统一**：订阅行用与节点列表同一套 `ProxyActivationToggleStyle`（开=`activateAccount` 互斥激活、关=`deactivateAccount` 清除激活标记），不再用「激活按钮 + 状态药丸」。plan 映射对齐 openai/codex `KnownPlan`（见下「Plan 映射」）。
- **拖拽重排（手势驱动「实时让位」）**：节点列表（`ProxyManagementView`，含 Claude/CodeX）与账号列表（`CodexSubscriptionSection`）共用同一套**仅抓手** `DragGesture`（`.global` 坐标系）方案，取代旧的 `onDrag/onDrop` + `DropDelegate`（已删除）。变高行用 `PreferenceKey`（`NodeRowHeightKey` / `SubscriptionRowHeightKey`）实测高度算中心点；被拖行跟手浮起（scale + 阴影 + `zIndex`），其余行按目标条目下标实时平移一个步幅让位；`onEnded` + `defer` 必定复位拖拽态（修复旧实现「松手卡黑」）。落点经 `moveConfiguration(fromId:toIndex:)`（节点，过滤家族后换算全局插入下标）/ `CodexSubscriptionOrderStore.reorder(_:)`（账号，整表持久化到 UserDefaults，菜单栏共用）提交。节点区标题为「节点列表」。
- 「用量统计」（`StatsHubView`，原「Token 统计」，侧边栏已重命名并下移至「消息」上方；消息与设置同区、上方加分割线）顶部分段在 **本地日志 / 代理实测** 间切换（二者口径重叠，分层展示、绝不相加）；代理统计页在混合家族时显示 全部 / Claude 代理 / CodeX 代理 分段。
- **新建/复制节点默认排到列表最前**（`NodeProfileStore.save` 对新档取 `min(sortOrder)-1` 并前插，UI 数组同步前插）。

### Plan 映射（ChatGPT / Codex 订阅）

`CodexProvider.planDisplayName(forRaw:)` / `workspaceType(fromPlan:)` 基于 openai/codex `codex-rs/login/src/token_data.rs` 的 `KnownPlan` 解析 JWT `chatgpt_plan_type`，但展示名贴合 ChatGPT 现行命名：

- 个人计划：`free` → Free、`go` → Go、`plus` → Plus、`pro` → Pro（工作区均归 Personal）；
- 团队/企业/教育：`team` / `business` / `self_serve_business_usage_based` → **Business**（ChatGPT Team 已更名为 Business，旧 `team` 值统一展示为 Business）、`enterprise` / `enterprise_cbp_usage_based` / `hc` → Enterprise、`edu` / `education` → Edu（归对应工作区）；
- 未知值原样透传。`accountPlan` 统一存展示名，徽标与 `eyebrow` 直接复用。

### 关键文件

| 文件 | 职责 |
|------|------|
| `ClaudeProxy/Runtime/CodexProxyConfiguration.swift` | CodeX 代理配置 + 环境变量加载（`PROXY_TARGET=codex`） |
| `ClaudeProxy/Runtime/CodexProxyService.swift` | `public actor`：鉴权、忠实透传（响应/流式/models）、usage 旁路解析、错误映射 |
| `QuotaServer/QuotaHTTPServer+CodexProxy.swift` | `/v1/responses`（流式/非流式）+ `/v1/models` 入站处理 |
| `ClaudeProxy/Runtime/OpenAICompatibleClient.swift` | `sendRawResponses` / `streamRawResponses` / `fetchRawModels` + 瞬时 5xx 重试 |
| `AIUsage/Models/ProxyConfiguration.swift` | `NodeType.codexProxy`、`ProxyNodeFamily` |
| `AIUsage/Models/CodexGlobalConfig.swift` | CodeX「通用配置基底」模型（`enabled` + `tomlText`，存 `codex-global-config.json`） |
| `AIUsage/ViewModels/CodexConfigManager.swift` | `~/.codex/config.toml` 外科式合并（HEADER/BASE/PROVIDER 三段，顶层键合并、节点覆盖全局）+ 备份还原 |
| `AIUsage/Services/SystemProxyDetector.swift` | 系统代理检测 |
| `AIUsage/Services/CodexNoProxyFixer.swift` | `~/.codex/.env` no_proxy 受管理块写入/还原 |
| `AIUsage/Views/CodexProxyManagementView.swift` | CodeX 菜单 + 统一切换器组件（`CodexSubscriptionSection`：账号列表/手势拖拽重排/可编辑备注/用量 pill/统一激活开关 + `CodexGlobalConfigSection` 双层配置卡片）+ `CodexSubscriptionOrderStore`（订阅顺序持久化，菜单栏共用） |
| `AIUsage/Views/ProxyManagementView.swift` | 节点列表（Claude/CodeX 共用，`family` 过滤）+ 手势拖拽重排（`DragGesture` 实时让位，落点经 `moveConfiguration` 换算全局下标）+ 统计/最近请求展开 |
| `AIUsage/Views/CodexConfigEditorView.swift` | `config.toml` 实时文件编辑器 + 通用配置片段编辑器（`CodexGlobalConfigEditorView`）+ TOML 语法高亮（`TOMLSyntaxTextView` / `TOMLHighlighter`）+ 语法检查（`TOMLLinter`） |
| `AIUsage/Views/CodexProxyEditorView.swift` / `SystemProxyWarningBanner.swift` / `StatsHubView.swift` | CodeX 节点编辑器（含「Advanced · Extra TOML」原文页）、系统代理提示、统一统计入口 |
| `QuotaBackend/.../Providers/CodexProvider.swift` | CodeX usage 抓取 + `planDisplayName`/`workspaceType`（对齐 openai/codex `KnownPlan`） |

### 已知限制 / 技术债（Phase 2）

1. **仅 OpenAI 兼容上游**：当前 Phase B 只闭环 OpenAI 兼容上游的 Responses 忠实透传。**Anthropic 上游 / 仅支持 chat-completions 的上游**接入 CodeX 属 Phase 2——届时需重新引入 Canonical→Responses 转换层（本阶段已裁剪以保持无冗余）。
2. **`makeUpstreamClientConfiguration()` 复用 `ClaudeProxyConfiguration`** 作为「OpenAI 上游配置」载体（与 Claude 入站无关），是有意的代码复用技术债，Phase 2 抽象上游配置时再拆分。
3. **`maxOutputTokens` 在忠实透传下不生效**：透传不改写请求体，故节点的「最大输出 Token」字段对 CodeX 当前无强制作用（保留字段供 Phase 2 转换层使用）。
4. **原生工具受上游能力约束**：若上游不支持 Codex 原生工具类型（`local_shell` / `apply_patch` 等），由上游返回错误，代理忠实回传——属上游限制，非代理问题。
