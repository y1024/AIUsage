# Prompt Caching 跨厂商兼容策略

## 问题背景

AIUsage 代理在 Claude Code 与上游服务之间做协议转换。两家主流 API（Anthropic / OpenAI）的 prompt caching 机制差异巨大，直接转换会导致缓存命中率下降甚至归零。本文档记录当前项目采取的兼容策略、实现位置和已知限制。

---

## 两种缓存机制对比

| 维度 | Anthropic | OpenAI |
|------|-----------|--------|
| **触发方式** | 显式 — 开发者在 content block 上标记 `cache_control: {"type":"ephemeral"}` | 自动 — prompt 前缀 ≥1024 tokens 时引擎自动缓存 |
| **命中条件** | 到最后一个 cache breakpoint 为止的前缀完全一致 | 请求 prompt 的开头前缀完全一致 |
| **缓存粒度** | 段级别（由 breakpoint 划分） | 前缀级别（引擎自动选择切分点） |
| **折扣率** | ~90%（cache read 只收原价 10%） | ~50%（cache read 收原价 50%） |
| **写入信号** | `cache_creation_input_tokens` > 0 | 无显式信号（自动写入，无额外费用） |
| **读取信号** | `cache_read_input_tokens` > 0 | `prompt_tokens_details.cached_tokens` > 0 |
| **路由提示** | 无（由 breakpoint 匹配决定） | `prompt_cache_key`（可选，帮助引擎将请求路由到同一节点） |
| **TTL** | 5 分钟（每次命中刷新） | ~5-10 分钟（平台管理） |

### 行为差异的直观表现

- **OpenAI 侧**：对话越长，前缀重复越多，`cached_tokens` 看起来稳步增长 — 因为自动前缀匹配天然利好递增场景。
- **Anthropic 侧**：`cache_read_input_tokens` 可能忽高忽低 — 只要 breakpoint 前的内容有任何变化（动态工具结果插入、系统 prompt 修改、CLAUDE.md 更新），缓存即失效。

这不是代理层的 bug，而是机制差异导致的正常表现。

---

## 代理架构中的缓存数据流

### OpenAI Convert 模式

```
Claude Code（Anthropic 格式，含 cache_control）
  │
  ▼ CanonicalMappers.mapClaude()
Canonical（cache_control 存入 rawExtensions）
  │
  ▼ CanonicalRequestBuilders.buildChatCompletionRequest()
OpenAI 请求（cache_control 不转发；生成 prompt_cache_key 路由提示）
  │
  ▼ 上游 OpenAI 服务
OpenAI 响应（usage.prompt_tokens_details.cached_tokens）
  │
  ▼ CanonicalMappers.mapOpenAIChatCompletion()
Canonical（effectiveCachedTokens → cacheReadInputTokens；cacheCreationInputTokens = nil）
  │
  ▼ CanonicalClaudeBuilders
Claude 响应（usage.cache_read_input_tokens = 上游 cached_tokens）
```

### Anthropic Passthrough 模式

```
Claude Code（Anthropic 格式，含 cache_control）
  │
  ▼ QuotaHTTPServer+Passthrough（透传，不经 Canonical）
上游 Anthropic 兼容服务
  │
  ▼ 原样返回
Claude Code（usage 字段原生包含 cache_creation / cache_read）
```

---

## 实现的三项优化

### 1. `prompt_cache_key` — OpenAI 路由提示

**生效路径**：OpenAI Convert 模式
**代码位置**：`CanonicalRequestBuilders.swift` → `buildPrefixCacheKey()`

```swift
static func buildPrefixCacheKey(
    system: [CanonicalContentPart],
    tools: [CanonicalToolDefinition]
) -> String? {
    // 拼接 system prompt 文本 + tool 名称
    // SHA256 → 取前 16 字节 → hex 编码
}
```

**原理**：OpenAI 的自动缓存需要将相同前缀的请求路由到同一推理节点。`prompt_cache_key` 是官方提供的路由提示字段。我们基于请求中最稳定的两个前缀组成部分（system prompt + tools schema）生成确定性哈希，帮助 OpenAI 引擎更高效地命中缓存。

**为什么选 system + tools**：
- 这两部分在 Claude Code 的多轮对话中基本不变
- 消息历史和工具结果每轮都变，不适合作为 cache key 材料
- 哈希只用于路由提示，不需要覆盖全部 prompt 内容

**不适用场景**：不是所有 OpenAI 兼容 API 都支持 `prompt_cache_key`。不支持的上游会忽略该字段，不会报错。

### 2. `cache_control` 保留 — Anthropic 断点透传

**生效路径**：Anthropic Passthrough 模式 + Canonical 中间层
**代码位置**：
- `ClaudeAPIModels.swift` → `ClaudeTextBlock.cacheControl`、`ClaudeSystemBlock.cacheControl`、`ClaudeDocumentBlock.cacheControl`
- `CanonicalMappers.swift` → 映射为 `CanonicalVendorExtension(vendor: "claude", key: "cache_control", ...)`

**原理**：Claude Code 在请求的特定 content block 上标记 `cache_control: {"type":"ephemeral"}`，告诉 Anthropic 引擎"到这里为止的内容可以缓存"。如果代理在 decode → re-encode 过程中丢失这个字段，等于告诉 Anthropic "不需要缓存"，命中率直接归零。

**当前状态**：
- **入向保留**：Claude 请求的 `cache_control` 完整存入 Canonical 的 `rawExtensions`
- **OpenAI 出向不转发**：OpenAI 不支持显式 cache breakpoint，所以构建 OpenAI 请求时不使用这些 extensions
- **Passthrough 透传**：不经 Canonical 层，原始 JSON 直接转发给上游，`cache_control` 天然保留

### 3. 响应侧 cache token 归一化

**生效路径**：所有模式
**代码位置**：
- `OpenAIAPIModels.swift` → `OpenAIUsage.effectiveCachedTokens` / `effectiveInputTokens`
- `OpenAIResponsesModels.swift` → `OpenAIResponsesUsage.inputTokensDetails`
- `CanonicalMappers.swift` → `mapOpenAIChatCompletion()` / `mapOpenAIResponses()`
- `OpenAICompatibleClient.swift` → `mapResponsesUsage()`

**原理**：不同上游报告缓存统计的字段形状不同：

| 上游 | cache read 字段 | cache creation 字段 |
|------|----------------|---------------------|
| Anthropic 原生 | `cache_read_input_tokens` | `cache_creation_input_tokens` |
| OpenAI Chat Completions | `prompt_tokens_details.cached_tokens` | 无 |
| OpenAI Responses | `input_tokens_details.cached_tokens` | 无 |
| DeepSeek | `prompt_cache_hit_tokens` | 无（`prompt_cache_miss_tokens` 是反向指标） |

归一化层将这些统一映射到 `CanonicalUsage`：

```swift
CanonicalUsage(
    inputTokens: 未缓存的输入 tokens,     // 与 cache 互斥
    outputTokens: ...,
    cacheCreationInputTokens: ...,        // 仅 Anthropic 有
    cacheReadInputTokens: 缓存命中 tokens  // 所有上游都有
)
```

**关键约束**：`inputTokens` 必须只包含未缓存部分。DeepSeek 的 `prompt_tokens` 包含 cache hit，需要用 `prompt_cache_miss_tokens` 替代，或 `promptTokens - cachedTokens`。否则 cache hit 会被按 input 和 cache read 双重计费。

---

## 已知限制

### 1. OpenAI 上游无 cache creation 语义

OpenAI 的自动缓存不上报写入量。经 OpenAI Convert 模式代理后，`cache_creation_input_tokens` 始终为 0。UI 上的"缓存写入"指标对 OpenAI 上游无意义。

### 2. cache_control 在 Canonical → Claude 重建时丢失

`CanonicalClaudeBuilders.makeClaudeContentBlock()` 重建 `ClaudeTextBlock` 时只取 `text.text`，不从 `rawExtensions` 还原 `cache_control`。这在当前架构中不是问题（Canonical → Claude 只用于构建响应，不用于构建请求），但如果未来出现"Canonical → Claude 请求"的路径，需要补全。

### 3. 历史日志 legacy 字段无法拆分

v0.4.25 之前的日志只有合并的 `tokensCache`，解码时统一归入 `tokensCacheRead`（`tokensCacheCreation = 0`）。这导致历史数据的缓存命中率计算偏高（分母缺少写入部分）。

### 4. Claude Code 的上下文组织打破缓存前缀

Claude Code 是 agentic coding 工具，每轮会插入工具结果、文件内容、终端输出等动态内容。这些内容如果位于 cache breakpoint 之前，会导致前缀不匹配，缓存失效。这是 Claude Code 的工作方式决定的，不是代理层能解决的问题。

**典型失效场景**：

| 现象 | 原因 |
|------|------|
| `cache_read` 一会儿高一会儿低 | Claude Code 重组了上下文或插入了动态内容 |
| `cache_creation` 反复很大 | 前缀变了，每次都在创建新缓存段 |
| 改了 CLAUDE.md 后 cache read 骤降 | 系统级内容是缓存前缀的一部分 |
| 文件读写密集时缓存不稳定 | tool result 插入到了 breakpoint 前面 |

### 5. prompt_cache_key 不被所有上游支持

`prompt_cache_key` 是 OpenAI 官方字段，但第三方 OpenAI 兼容 API（如 OpenRouter、DeepSeek 直连）可能不支持。不支持的上游会忽略该字段，不影响功能，只是不能利用路由优化。

---

## 判断缓存是否正常工作

观察 `PROXY_LOG` 中的三组数：

| 状态 | `cache_read_tokens` | `cache_creation_tokens` | 判断 |
|------|---------------------|-------------------------|------|
| 正常复用 | 高且较稳定 | 偶尔升高 | 缓存在正常工作 |
| 频繁失效 | 忽高忽低 | 反复很高 | 前缀频繁变化，考虑排查动态内容位置 |
| 完全没缓存 | 恒 0 | 恒 0 | Anthropic 路径：缺少 `cache_control` 标记或 prompt 未达最小长度；OpenAI 路径：前缀 <1024 tokens |

---

## 相关文件索引

| 文件 | 作用 |
|------|------|
| `CanonicalRequestBuilders.swift` | `buildPrefixCacheKey()` — OpenAI 路由提示生成 |
| `CanonicalMappers.swift` | cache_control → rawExtensions 保留；usage 归一化 |
| `ClaudeAPIModels.swift` | `ClaudeTextBlock.cacheControl`、`ClaudeUsage` 定义 |
| `OpenAIAPIModels.swift` | `promptCacheKey`、`OpenAIUsage.effectiveCachedTokens` |
| `OpenAIResponsesModels.swift` | `OpenAIResponsesUsage.inputTokensDetails` |
| `OpenAICompatibleClient.swift` | `mapResponsesUsage()` — Responses → OpenAI usage 映射 |
| `QuotaHTTPServer+ClaudeProxy.swift` | PROXY_LOG 日志发射（含 cache split 字段） |
| `QuotaHTTPServer+Passthrough.swift` | Passthrough 路径的 usage 解析和日志 |
| `ProxyViewModel+ProxyServer.swift` | PROXY_LOG 解码和计价 |
| `ProxyConfiguration.swift` | `costForTokens()` 四字段计价；`cacheHitRate` 命中率公式 |
| `OpenAIUsageCacheNormalizationTests.swift` | usage 归一化回归测试（11 用例） |
| `CANONICAL_MIDDLE_LAYER_DESIGN.md §11` | `CanonicalUsage` 语义约定 |
| `PROXY_ARCHITECTURE.md §ModelPricing` | 计费公式和 legacy 迁移 |
