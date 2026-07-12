# CLIProxyAPI（CPA 网关）集成架构

> 状态：CPA 网关已随 AIUsage v0.14.0 正式发布；中英文界面素材、Release 资产与 appcast 均已完成
> 更新日期：2026-07-12
> 上游核对基线：`router-for-me/CLIProxyAPI` 发布版 `v7.2.67`（`2075f77c`）
> 最近一次官方完整资产 live 回归：`v7.2.69`，2026-07-12；路由与安全源码引用仍固定到上面的可复核提交。
> 参考实现：`nguyenphutrong/quotio` master `ecd9d6f1`，发布版 `v0.22.0`

## 0. 当前实现摘要

AIUsage 将 CLIProxyAPI（下文简称 CPA）作为受管 sidecar 集成，而不是新增一条独立代理轨。CPA 负责订阅账号池、OAuth、路由与故障切换；AIUsage 负责二进制生命周期、账号接入体验、受管 API Provider、代理分发、调用统计和安全边界。

当前版本在首版安全内核上完成了以下产品化调整：

- 页面从首版的五个工程标签重构为四个用户任务区：`概览 / 账号 / 接入 / 设置`；
- 页头直接以“一个账号池，连接 4 个 AIUsage 应用与多协议本地 API 客户端”的单行概念说明解释产品关系，不再用一张无操作的说明卡占据概览空间；
- 增加 AIUsage 自有的 CPA 网关标识，并在侧边栏、页头和功能卡片复用；
- CPA auth records 与可接入的 AIUsage 账号合并为一个账号中心，不再上下重复展示同一同步副本；
- 页头、账号中心和空状态都提供明显的“添加账号”入口；
- 添加向导支持五个 CPA 原生 OAuth、动态 Provider 插件、OpenAI-compatible API Key 上游、CPA auth JSON 导入和 AIUsage 现有账号接入；
- OAuth 支持状态轮询、设备码展示、重新打开浏览器、超时与显式取消；
- 账号详情展示状态、成功/失败请求数、账号级模型、刷新/重试信息，并可编辑 CPA `note` 和 `priority`；
- 账号同步改为持久化单向同步清单与规范化 JSON SHA-256 状态机，不再只凭确定性文件名判断“已同步”；
- 接入页面读取磁盘中的真实分发结果，区分“已连接”和“待应用”，移除已有连接前必须确认；
- 概览的账号、模型、已接入应用、CPA 版本改为紧凑指标；模型目录将 CPA OpenAI、Anthropic、Gemini 三种视图归并为规范模型，同时保留每种 API 格式真正需要的路由 ID；
- 三个紧凑配置目标明确映射到 Codex、OpenCode、Claude Code、Claude Science 四个应用；Claude Code/Science 共用一个受管连接，并以单个 Claude Logo 表示该系列，避免叠加不协调的 Science 图标；
- 托管接入卡只保留应用映射与连接状态，不在小卡片内堆叠 endpoint/API key/模型继承等实现说明；
- 外部客户端接入不再被描述为单一 OpenAI-compatible 入口：页面明确列出 OpenAI Responses / Chat / legacy Completions、Anthropic Messages、Gemini 原生路由及共用 client key 的认证头；四个主协议卡点击后打开接入详情小窗；
- 设置页移除大块、不可操作的安全说明卡；供应链、进程、Secret、默认 loopback 与显式 LAN 边界仍由运行时强制，并完整记录在本文架构章节；
- 运行配置使用保留未知字段的增量 YAML 合并；CPA 写入的插件和上游配置不会在重启时被清空，插件目录固定在跨版本数据目录；
- CPA 二进制继续独立于 AIUsage 更新，支持下载、校验、dry run、版本提升和回滚。

本文中的“同步”始终表示 **AIUsage → CPA 的单向凭据副本**。CPA 不会反向覆盖 AIUsage 凭据，两端也不会共同写同一个 auth file。

## 1. 产品定位与边界

正确的依赖方向是：

```text
AIUsage 订阅账号 ──显式单向接入──┐
CPA OAuth / 插件 / API Key / JSON ├─→ CPA 账号与上游池
                                 │
                                 └─→ 本地多协议 API 网关
                                      │
                                      ├─→ AIUsage Codex 代理
                                      ├─→ AIUsage Claude Code / Science 代理
                                      ├─→ AIUsage OpenCode 代理
                                      ├─→ OpenAI Responses / Chat 客户端
                                      ├─→ Anthropic Messages 客户端
                                      └─→ Gemini 客户端
```

职责划分：

| 组件 | 负责 | 不负责 |
| --- | --- | --- |
| CPA | OAuth/auth file、动态 Provider 插件、OpenAI-compatible 上游、账号轮询、冷却、重试、故障切换、多协议本地 API | AIUsage 代理节点、AIUsage 成本数据库、AIUsage 自身更新 |
| AIUsage CPA 模块 | CPA 下载/校验/运行/更新、账号中心、单向接入、Management API、受管 Provider、分发状态 | 修改 CPA Go 源码、猜测未知凭据格式、双向 token 同步 |
| 现有 AIUsage 代理 | 协议适配、CLI 配置接管、节点切换、调用统计与成本归因 | CPA auth store 管理 |

CPA 不是 Codex、Claude Code、OpenCode 之外的“第四条代理”。它是这些代理可共同消费的上游 CPA 网关。

## 2. 已复用的 AIUsage 基础

集成没有重造已有系统：

1. `AppSection`、`SidebarNavigation`、`ContentView` 提供侧边栏入口和页面路由。
2. `APIProvider` 统一承载 base URL、API key、协议格式、模型和默认模型。
3. `APIProviderDistributor` 幂等分发主 Provider 到 Codex、Claude Code、OpenCode，并保留链接节点的 `overriddenKeys`。
4. `GlobalProxyManager` 和各 CLI config manager 继续负责实际激活、热切换、写入与恢复。
5. `ProxyPortArbiter` 负责端口冲突判断；CPA 不会因为端口被占用就杀死未知进程。
6. `AccountCredentialStore` 的 canonical Keychain vault 保存 management key 与 gateway client key。
7. 现有代理日志仍是请求计量的唯一来源，避免同一请求重复入库。

固定受管 Provider：

```text
id: aiusage.cliproxyapi.gateway
name: CPA Gateway
baseURL: http://127.0.0.1:<port>/v1
format: openAIResponses
apiKey: AIUsage 生成的 gateway client key
models: GET /v1/models
```

选择 OpenAI Responses 作为 AIUsage **受管 Provider 的内部主格式**，是因为 Codex 分发需要 Responses，Claude 轨已有 Claude → Responses 转换，OpenCode 也能消费该格式。这不代表 CPA 只支持 Responses 或只支持 OpenAI-compatible 客户端；外部应用可以按自身 SDK 直接使用 CPA 的 OpenAI、Anthropic、Gemini 或 Codex 路由。

## 3. 信息架构

### 3.1 导航位置与自有标识

`CPA 网关` 位于 `订阅账号` 与 `API 提供商` 之间：

```text
仪表盘
订阅账号
CPA 网关
API 提供商

代理
  Codex
  OpenCode
  Claude Code
  Claude Science
```

`cliproxyapi.imageset` 是 AIUsage 为“CPA 网关”设计的产品标识，不宣称是上游 CLIProxyAPI 官方 Logo。该资源通过 `ProviderIconView("cliproxyapi")` 在侧边栏、页头、添加向导和状态卡中保持一致；具体服务商继续复用 OpenAI、Claude、Gemini、xAI、Kimi、MiniMax 等现有 Provider Icons。

页头承担产品解释，不把说明混入可操作模块：

```text
CPA 网关 · CLIProxyAPI
一个账号池，连接 4 个 AIUsage 应用与多协议本地 API 客户端
```

概念条只说明关系，不伪装成按钮或设置项；页头仍保留“添加账号”和运行状态这两个真实操作/状态入口。

### 3.2 四个任务区

#### 概览

- CPA 安装、运行与版本状态；
- 原先重复的“启动 CPA”引导与“本地网关”卡合并为一张运行卡：停止时承担启动，运行后展示状态、PID、本机/LAN 地址、刷新与停止；
- 账号、模型、已接入应用、CPA 版本四个紧凑指标；账号显示 `可用数 / 总数`，应用显示四个实际应用中已接入的数量；
- 实时模型目录：合并默认 OpenAI `/v1/models`、带 `Anthropic-Version` 的 Anthropic `/v1/models` 与 Gemini `/v1beta/models`；精确解码 CPA 的 `claude-fable-5-dd-<reversed-id>` Anthropic 兼容别名，再按规范 ID 合并，同一个逻辑模型只计数、展示一次；
- 页面打开时立即读取，运行中每 30 秒轻量刷新；账号操作与页面轮询共享按 CPA PID 隔离的单飞任务，重启不会复用旧进程响应；单协议暂时失败时保留成功结果和上次目录，并显示 partial/stale 状态；
- 模型按真实厂商分组，Logo 仅由 `owned_by → canonical ID → display name` 推断，API 格式绝不参与品牌判断；列表只展示厂商 Logo、模型名和规范 ID，避免重复 API 标签挤压或换行；点击详情后再查看兼容的 OpenAI / Anthropic / Gemini API，并分别复制对应路由 ID；
- 搜索同时覆盖名称、规范 ID、厂商、API 格式和全部路由 ID；未知或未来别名不猜测合并，以 CPA 中性标识保守展示；
- 启动、停止、安装/更新、添加账号等主操作；同一个运行状态不重复出现两个启动按钮；
- 从“未安装 → 已安装 → 运行 → 添加账号 → 接入应用”的引导步骤。

#### 账号

- 统一账号中心，按 Provider 分组；
- 搜索和 `全部 / 可用 / 异常 / 已停用 / 来自 AIUsage` 筛选；
- CPA 账号与尚未接入的 AIUsage 候选账号合并展示；
- 启停、重新同步、同步模式、详情和删除；
- 明显的“添加账号”入口和完整添加向导。

四区导航使用覆盖整个视觉胶囊的显式命中区，文字、图标与周围留白均可一次点击。AIUsage 账号候选不再由 SwiftUI `body` 同步读取 Keychain 和凭据文件，而是在账号注册表变化时于后台生成一次快照；CPA stdout/stderr 也按短时间窗批量发布，避免高流量日志反复使根视图失效。

#### 接入

- Codex、Claude 系列、OpenCode 三个紧凑、可自适应排列的配置目标卡片，并明确展示其对应的四个实际应用；Claude 系列只使用一个 Claude Logo，双应用关系由文字说明；卡片正文只显示应用名与连接状态；
- 从 `APIProviderDistributor.currentTargets(for:)` 读取真实链接状态；
- 本地选择只表示待应用草稿，不把 checkbox 当成已连接真值；
- 应用后重新读取真实状态；
- 移除已有受管节点前显示目标清单并确认；
- 独立的“客户端 API 接口”卡向本机/LAN 外部应用说明多协议端点；这与上方 AIUsage 一键托管接入是两种不同使用方式；
- 四个主协议卡只展示协议名、HTTP 方法、最多两行的用途摘要和 Base/REST 层级，不再在有限空间塞入完整 route 与认证头；
- 点击协议卡打开接入详情小窗，完整展示用途、认证要求以及服务器 Origin、客户端 `Base URL` 或 REST API Root、完整请求 endpoint；所有值可完整显示、选择和复制；
- Gemini 详情明确区分直接 REST 请求与 Google GenAI SDK：前者使用 `/v1beta` REST API Root，后者使用 Origin 作为 `base_url` 并单独设置 `api_version=v1beta`；
- Gemini 详情允许从实时模型目录选择或手动填写模型 ID；留空复制 `{model}` 模板，输入 `gemini-…` 或 `models/gemini-…` 都会规范化为恰好一层 `/models/`；含空格、额外 `/`、`?`、`#` 或路径片段的值不会被标记为完整端点；
- “更多支持路由”折叠区补充 legacy Completions、模型列表、Responses compact、Anthropic count tokens、Gemini stream、Codex alias 等路由；
- 展示遮罩的共用 CPA client key，并明确 `Authorization: Bearer`、`X-Api-Key`、`X-Goog-Api-Key` 三种认证头。

#### 设置

- 自动启动、端口、round-robin/fill-first、重试和上游代理；
- 默认关闭的“允许局域网客户端访问”：开启前二次确认，应用后绑定 `0.0.0.0`；产品用途是开放带 client key 的推理接口，但底层监听器上的其他路由仍需依靠关闭控制面板、remote policy 与独立 management key 防护；
- CPA 官方插件总开关；
- 设置草稿采用逐字段三方合并：用户已修改的字段继续保留，账号/插件页产生的外部运行时更新只合入未修改字段；
- CPA 独立检查更新、安装、版本切换与删除回退副本；
- 折叠的诊断区提供脱敏日志、受管存储入口、官方仓库与第三方声明；
- 不再放置没有操作价值的大块安全说明卡，避免将实现约束重复成界面文案。

诊断与更新不再占用顶层标签，而是收拢到“设置与维护”；安全边界仍由本文第 8 节定义并由底层代码执行，不依赖用户阅读界面说明。运行摘要和接入目标都使用紧凑信息密度，不再以原始表单或纯说明卡占满页面。

## 4. 统一账号中心

### 4.1 合并规则

账号中心的主数据源包含：

1. CPA Management API 返回的 `CLIProxyAuthFile`；
2. CPA `openai-compatibility` 配置实体（即使 `/auth-files` 暂未或不再返回 runtime record，也可启用、停用和删除）；
3. AIUsage 中具有受管 credential 且通过兼容性判断的 `CLIProxyAccountSyncCandidate`。

已在 CPA 中存在的同步副本只显示为一条 CPA 账号记录，并附加单向同步状态；只有尚未接入或 CPA 副本缺失的候选账号才作为独立行出现。清单记录的 `authFileName + providerId + credentialId` 是关联依据；确定性文件名只作为迁移兼容和诊断回退，不再独自决定同步状态。

### 4.2 添加账号向导

所有入口打开同一个向导，按凭据来源组织：

1. **CPA 原生 OAuth**
   - Codex；
   - Claude / Anthropic；
   - Antigravity；
   - Kimi；
   - xAI。
2. **动态 Provider 插件**
   - 从当前 CPA 的 `/v0/management/plugins` 和 `/v0/management/plugin-store` 动态读取；
   - 支持安装、启用、必要时重启 CPA，再启动插件 OAuth；
   - 当前官方构建可由此暴露 Gemini CLI，未来新增 Provider 不需要 AIUsage 硬编码成新的原生 OAuth 枚举。
3. **OpenAI-compatible API Key 上游**
   - 用户填写名称、Base URL、API key 和模型映射；
   - 通过 CPA `openai-compatibility` 配置接入；
   - 写入、启停或删除后重启受管 CPA，使 runtime auth 与模型注册立即按持久化配置重建；
   - API key 不进入日志或诊断包。
4. **现有 AIUsage 账号**
   - 仅展示有可解析 credential 的候选项；
   - Codex、Antigravity 等经过 adapter 验证的格式可单向复制；
   - 不兼容账号解释原因并引导使用 CPA OAuth/插件，不猜测转换。
5. **CPA auth JSON**
   - 使用系统文件选择器；
   - 只接受单个 `.json`，限制大小，要求顶层 JSON object；
   - 本地校验后通过 loopback Management API 上传；
   - 文件名冲突时生成唯一名称，不静默覆盖现有记录。

### 4.3 OAuth 状态机

原生 OAuth 与插件 OAuth 共享可观察状态：

```text
idle
  → starting(provider)
  → waiting(provider, url, state, flow, userCode, expiresIn)
  → succeeded(provider)

waiting
  ├─ 用户取消 → DELETE /oauth-session → cancelled
  ├─ 超时     → DELETE /oauth-session → failed(timeout)
  └─ 上游失败 → failed(message)
```

实现约束：

- 每次流程有独立 operation ID，旧轮询不能覆盖新流程；
- 浏览器 URL 只接受 `http/https`；
- device flow 显示并可复制 `user_code`；
- 用户可以重新打开授权页；
- 每秒查询 `get-auth-status`，成功后刷新账号、模型和同步状态；
- 取消、超时和异常都尝试清理 CPA OAuth session；
- 一个流程结束前不允许并发启动另一个流程。

### 4.4 每账号详情

账号列表和详情使用 CPA 返回的真实字段：

- provider、label/email、source、auth index；
- ready / paused / attention、status message；
- 成功请求数、失败请求数；
- last refresh、next retry、project/account type；
- 账号级模型列表：`GET /auth-files/models?name=...`；
- 普通 auth file 的 `note` 与 `priority`：通过 `/auth-files/fields` 更新；runtime/config provider 不显示不适用的 auth-file 编辑器；
- 启停、删除与重新同步。

CPA 若没有返回某字段，UI 显示空态，不从其他字段推导虚假数值。删除只删除 CPA 副本，AIUsage 原账号保持不变；确认文案明确这一边界。

## 5. AIUsage 账号的持久化单向同步

### 5.1 为什么需要同步清单

首版根据确定性文件名判断 CPA 是否已有副本。这只能回答“同名文件是否存在”，无法区分：

- AIUsage 源凭据已经刷新；
- CPA 副本被 CPA 或用户修改；
- 两边同时变化；
- CPA 副本被删除；
- 旧版本已经复制成功，但本地 UI 没有历史状态。

当前产品化版本增加 `account-sync-manifest.json`。清单只保存身份元数据、同步模式、时间和内容指纹，不保存 credential JSON、token、cookie 或 API key。

```swift
struct CLIProxyAccountSyncRecord: Codable {
    let providerId: String
    let credentialId: String
    let authFileName: String
    let sourceFingerprint: String
    let lastCopiedFingerprint: String
    let lastSyncedAt: Date
    var mode: CLIProxyAccountSyncMode
}
```

文件位置：

```text
~/Library/Application Support/AIUsage/CLIProxyAPI/account-sync-manifest.json
```

权限固定为 `0600`，schema 带版本号，损坏时按错误处理而不是猜测恢复 token。

### 5.2 Canonical JSON SHA-256

指纹计算流程：

1. 读取 JSON；
2. 要求顶层为 object；
3. 使用 `JSONSerialization` 重新编码并按 key 排序；
4. 对规范化字节计算 SHA-256。

这样缩进、空白和 object key 顺序变化不会被误判为凭据变化。

- `sourceFingerprint`：AIUsage 原始 credential JSON 的规范化 SHA-256；
- `lastCopiedFingerprint`：经过 provider adapter 转成 CPA auth schema 后，最后一次成功上传内容的规范化 SHA-256；
- 刷新状态时还会下载当前 CPA 副本，计算 `cpaFingerprint` 与 `lastCopiedFingerprint` 比较。

这些摘要只用于本机变化检测，不作为认证材料，也不输出到普通日志。清单中的文件名仍用于定位 Management API record，但“文件名相同”不再等于“内容同步”。

### 5.3 同步状态

| 状态 | 判定 | UI 与动作 |
| --- | --- | --- |
| `notSynced` | 没有清单记录，CPA 也没有可采纳副本 | 显示“接入 CPA” |
| `current` | 源指纹未变，CPA 指纹等于最后复制指纹 | 显示“副本最新” |
| `sourceChanged` | AIUsage 源已变，CPA 副本未变 | 手动更新；仅在 CPA 副本仍等于上次复制值时才允许 `keepUpdated` 更新 |
| `cpaChanged` | AIUsage 源未变，CPA 副本已变 | 阻止自动覆盖，要求查看并确认 |
| `conflict` | AIUsage 源与 CPA 副本都变了 | 阻止自动覆盖，显式冲突确认 |
| `missing` | 有清单记录，但 CPA 副本不存在 | 显示“恢复 CPA 副本” |

兼容迁移：若没有清单记录，但确定性名称下的 CPA 文件与当前 adapter 输出的 canonical hash 完全一致，可以“采纳”为 `manualCopy` 记录；若内容不同则为 `conflict`，不能静默接管。

### 5.4 两种单向模式

`manualCopy`：

- 默认模式；
- 源凭据变化后只显示状态，由用户点击更新；
- 适合希望 CPA 副本完全独立的账号。

`keepUpdated`：

- 仅在刷新时发现 `sourceChanged` 且 CPA 副本仍等于最后复制内容时自动上传；
- 遇到 `cpaChanged` 或 `conflict` 永不自动覆盖；
- 用户可随时切回 `manualCopy`；
- 它仍是 AIUsage → CPA 单向更新，不是双向同步。
- 它不等于可长期共享 OAuth refresh token。CPA 的正常 token 轮换会改变副本指纹并停止自动更新；旋转型 OAuth 账号默认仍使用 `manualCopy`，长期使用优先在 CPA 内独立登录。

强制覆盖是独立的破坏性动作。UI 明确说明：覆盖可能丢弃 CPA 较新的 refresh token、导致需要重新登录，但不会改变 AIUsage 原凭据。

### 5.5 不做双向 token 同步的理由

- AIUsage 和 CPA 都可能刷新 access/refresh token；
- 两端同时轮换同一 refresh token 会产生竞态、旧值覆盖和 token reuse 错误；
- 两端 auth schema、provider type 和嵌套结构并不完全相同；
- last-write-wins 无法判断哪端修改是新授权、刷新还是人工修复；
- CPA 删除/停用副本不应破坏 AIUsage 的监控账号；
- AIUsage 原账号删除也不应默认销毁用户在 CPA 中独立维护的凭据。

因此明确禁止目录监听复制、CPA → AIUsage token 回写、共享同一 auth file，以及根据修改时间覆盖另一端。

## 6. Management API 与能力边界

`CLIProxyManagementClient` 统一封装 loopback `/v0/management`：

- auth file：列表、下载、上传、启停、字段更新、删除、账号级模型；
- OAuth：原生授权 URL、插件授权 URL、状态查询、session 取消；
- Provider 插件：已注册插件、插件商店、安装、启用；
- OpenAI-compatible：读取原始 JSON 对象后无损追加新上游，保留已有模型的 `thinking`、模态字段及未来未知字段，再提交 CPA 要求的完整列表；
- 网关模型：使用 client key 分别请求 OpenAI、Anthropic、Gemini 模型视图；AIUsage 受管 Responses Provider 仍只使用默认 OpenAI `/v1/models`，不把跨协议目录错误写入代理配置。

所有 Management API 请求使用 management key；客户端 `/v1` 请求使用独立 client key。URL path component、auth filename、JSON 类型和响应状态都在客户端层验证，View 不直接拼 HTTP 请求。

能力边界：

- **本轮已开放**：五个原生 OAuth、动态 Provider 插件安装/启用/OAuth、OpenAI-compatible API Key 上游、auth JSON、AIUsage 单向接入；
- **尚未开放为通用表单**：CPA 各类专用 `gemini-api-key`、`claude-api-key`、`codex-api-key`、`vertex-api-key` 的完整增删改 UI；
- **原因**：这些路由的 schema、替换语义和 secret 生命周期不同，不能用一个“API Key”表单猜测写入；
- **扩展方式**：为每一类上游增加独立 typed model、先 GET 后变更、secret 脱敏、版本能力探测和 live 回归，再放入同一添加向导。

动态插件也受安装版本约束。UI 只展示当前 CPA Management API 实际返回的插件/商店条目；Management API 不存在时降级为不可用提示，不用静态列表伪装支持。plugins 总开关关闭时，只有用户显式点击安装/启用，AIUsage 才会打开开关并重启受管 CPA。

## 7. 接入 AIUsage 代理与本地 API 客户端

### 7.1 真实分发状态

接入页不把本地 checkbox 当作连接真值。页面加载和每次应用后，调用现有 `APIProviderDistributor` 读取固定受管 Provider 的真实目标集合：

```text
Codex
Claude Code（同时覆盖既有 Science 消费路径）
OpenCode
```

应用规则：

1. CPA 运行且 `/v1/models` 可达后幂等 upsert 主 `APIProvider`；
2. base URL、client key、模型库和默认模型作为共享字段；
3. 链接节点的本地 `overriddenKeys` 保留；
4. 重复应用不会创建重复节点；
5. 端口、key 或模型变化后从主 Provider 同步；
6. 用户取消勾选已连接目标时，先列出将移除的代理并确认；
7. 只移除 CPA 受管链接节点，不删除其他节点，也不影响 CPA 账号池。

第一阶段仍不直接改写 Codex/Claude/OpenCode 的用户配置。用户激活节点时继续走现有可恢复的 CLI 配置接管事务。

### 7.2 外部客户端与协议边界

接入页把两类行为明确分开：

1. **AIUsage 托管接入**：上方三个紧凑目标卡通过现有 Distributor 一键创建或移除受管节点；
2. **本地 API 接入**：下方端点卡提供 CPA 的本机/LAN 地址、协议和认证帮助，供 Cursor、Cherry Studio、SDK、脚本及其他客户端自行配置，不改写这些应用的配置。LAN 未显式开启时只显示本机地址。

所有外部协议共用同一把 **gateway client key**，但沿用各协议惯用的认证头：

| 协议 | 推荐认证头 | 说明 |
| --- | --- | --- |
| OpenAI / Codex | `Authorization: Bearer <client-key>` | Responses、Chat Completions、legacy Completions 和 Codex alias |
| Anthropic | `X-Api-Key: <client-key>` | Messages；客户端仍应按 Anthropic SDK 要求发送版本头 |
| Gemini | `X-Goog-Api-Key: <client-key>` | Gemini `v1beta` 原生路由 |

常见客户端的连接层级：

| 协议 | 客户端设置 / API Root | 请求示例 |
| --- | --- | --- |
| OpenAI Responses / Chat | `http://127.0.0.1:<port>/v1` | `/responses`、`/chat/completions` |
| Anthropic | `http://127.0.0.1:<port>` | `/v1/messages` |
| Gemini REST | `http://127.0.0.1:<port>/v1beta`（REST API Root） | `/models/{model}:generateContent` |
| Google GenAI SDK | `base_url=http://127.0.0.1:<port>`，另设 `api_version=v1beta` | SDK 自行拼接版本与模型路径 |

若用户在设置中显式开启 LAN，可在“本机 / 局域网”分段选择器之间切换；检测到多个私有或 RFC 6598 共享 IPv4 地址时，再从地址菜单选择具体地址。路径规则不变，只把 origin 换成所选地址，例如 `http://192.168.1.20:<port>`。界面不会把 `0.0.0.0` 当作可复制地址。

界面不推荐把 key 放到 query string。gateway client key 只授权推理/模型路由，不能用于 `/v0/management`；Management API 始终使用另一把仅供 AIUsage 持有的 management key。

### 7.3 CPA 本地协议目录

默认运行时 origin 为：

```text
http://127.0.0.1:<port>
```

LAN 模式下 CPA 监听 `0.0.0.0:<port>`，但 UI 只展示从已启用接口检测到的私有或 RFC 6598 共享 IPv4 候选地址；后者常见于 VPN/Tailnet。AIUsage 自己的 Management API、健康检查和受管 Provider 始终从 `127.0.0.1` 连接，不因 LAN 模式改变信任边界。

接入页首先展示四个最常用入口。列表卡只承担协议选择；详情小窗把 Origin、Base URL/REST API Root 与完整 route 分开，避免把 `/responses` 或含 `{model}` 的模板误填到客户端 Base URL 字段：

| 协议 | 方法与路径 | 典型用途 |
| --- | --- | --- |
| OpenAI Responses | `POST /v1/responses` | Responses API、Codex 和新式 OpenAI 客户端 |
| OpenAI Chat Completions | `POST /v1/chat/completions` | 仍使用 Chat Completions 的 OpenAI-compatible 应用 |
| Anthropic Messages | `POST /v1/messages` | Claude SDK 与原生 Messages 客户端 |
| Gemini GenerateContent | `POST /v1beta/models/{model}:generateContent` | Gemini REST；详情另给 Google GenAI SDK 的双参数配置 |

“更多支持路由”用于能力查阅，不把低频接口都扩展成大卡片：

| 协议族 | 方法与路径 | 能力 |
| --- | --- | --- |
| OpenAI | `GET /v1/models` | 模型列表；概览的实时模型目录也使用此路由 |
| OpenAI | `POST /v1/completions` | legacy Completions |
| OpenAI | `GET ws://<host>:<port>/v1/responses` | Responses WebSocket 入口；HTTPS origin 对应 `wss://` |
| OpenAI | `POST /v1/responses/compact` | Responses compact |
| Anthropic | `GET /v1/models` | Anthropic 模型列表语义；发送 `Anthropic-Version` 时按 Anthropic 处理 |
| Anthropic | `POST /v1/messages/count_tokens` | Messages token count |
| Gemini | `GET /v1beta/models` | 模型列表 |
| Gemini | `GET /v1beta/models/{model}` | 单模型详情 |
| Gemini | `POST /v1beta/models/{model}:streamGenerateContent` | 流式内容生成 |
| Gemini | `POST /v1beta/models/{model}:countTokens` | Token 计数 |
| Gemini | `POST /v1beta/interactions` | Gemini interactions |
| Codex alias | `GET ws://<host>:<port>/backend-api/codex/responses` | Codex Responses WebSocket alias；HTTPS origin 对应 `wss://` |
| Codex alias | `POST /backend-api/codex/responses` | Codex Responses HTTP alias |
| Codex alias | `POST /backend-api/codex/responses/compact` | Codex compact alias |

这张目录来自当前核对的 CPA `v7.2.67` 路由注册。界面只承诺当前构建实际开放的能力；后续 CPA 若改变路由，AIUsage 应通过版本/能力探测更新说明，不能根据模型名称猜测协议支持。

UI 默认遮罩 client key，复制必须由用户显式触发；若剪贴板内容仍是该 key，60 秒后自动清除。AIUsage 托管的 CPA 默认只监听 `127.0.0.1`；只有用户在设置中确认后才绑定 `0.0.0.0`。LAN 模式仍写入 `allow-remote: false`、关闭控制面板并要求 client key；外部客户端直连产生的用量当前不写入 AIUsage 代理统计。

详情小窗的复制语义固定：

1. `Origin`：只含 scheme、host、port；
2. `Base URL / REST API Root`：OpenAI 使用 `/v1`，Anthropic 使用根路径；Gemini 直接 REST 使用 `/v1beta`，Google GenAI SDK 则复制 Origin 为 `base_url` 并独立设置 `api_version=v1beta`；
3. `Full request endpoint`：用于直接 HTTP 请求，例如 `/v1/messages`；含模型占位符的 Gemini 路由必须在 UI 中明确标为模板，不能伪装成已完整解析的地址。

## 8. 运行时、Secret 与独立更新

### 8.1 Secret 分离

两把 key 不可复用：

1. **Management key**
   - 仅供 AIUsage 调用 `/v0/management`；
   - 原文保存在 canonical Keychain vault；
   - 不写入 API Provider 或下游节点。
2. **Gateway client key**
   - 供 AIUsage 链接节点和用户显式配置的本机或 LAN 客户端调用 CPA；
   - 随机生成，可轮换；
   - UI 默认遮罩；
   - config 和节点配置权限受控。

运行配置更新只替换 `cpa-client-*` 命名空间中的旧托管 key，并去除当前 key 的重复项；其他 CPA client key 原样保留。这样 Keychain 轮换可撤销旧 AIUsage key，同时不会把用户自行添加的 key 当成托管凭据删除。复杂或 inline 的 `api-keys` YAML 不做猜测性重写，而是中止并保留原配置。

OAuth token 和第三方上游 API key 由 CPA auth/config store 管理。日志脱敏 Bearer、Authorization/Cookie、OAuth/device code、access/refresh/id token、management key 和 client key。复制到剪贴板的 client key 若仍未被其他内容替换，会在 60 秒后清除。

### 8.2 进程安全

`CLIProxyRuntimeController` 记录并核验：

- `Process`、PID、启动 token；
- executable 与 config 的解析后绝对路径；
- 监听端口、启动时间和期望退出状态。

规则：

- 默认绑定 `127.0.0.1`；仅在用户二次确认 LAN 开关后绑定 `0.0.0.0`；
- 无论监听范围如何，`remote-management.allow-remote` 都固定为 `false`，控制面板固定关闭；启动 sidecar 时显式清除会覆盖该策略的 `MANAGEMENT_PASSWORD` 环境变量；
- 推理/模型路由必须持有 gateway client key；该 key 不能调用 Management API，Management API 使用从不展示的独立高熵 management key；
- `ws-auth` 始终强制为 `true`，避免 CPA 的 `/v1/ws` 条件路由绕过 client key；
- CPA v7.2.67 的 remote IP 判断依赖 Gin `ClientIP()`，不能把 `allow-remote: false` 视作严格网络防火墙；即使伪造转发头绕过 IP 判断，仍必须通过独立 management key，因此 key 分离是强制边界；
- LAN 当前是 HTTP 明文，client key、提示词与响应可能被同网段监听；确认弹窗要求只在可信网络使用，TLS 留作后续 typed 配置；
- 启动前经过 `ProxyPortArbiter`；
- 端口被未知进程占用时只报错，不杀进程；
- 正常停止先 terminate，超时后仅对身份核验通过的自有 PID 发 SIGKILL；
- App 崩溃后只有 executable、config 参数和状态记录全部匹配才清理孤儿；
- 意外退出限次重启，更新和配置变更使用串行事务；
- stdout/stderr 持续 drain；正则脱敏在读取线程完成，日志按短时间窗批量发布到最多 200 行的有界内存，避免每行触发整页重绘。

### 8.3 CPA 独立更新

CPA 更新不依赖 AIUsage 发版：

```text
checking
  → downloading
  → verifying SHA-256 digest
  → restricted extracting
  → ad-hoc signing
  → Mach-O architecture validation
  → isolated loopback dry run
  → stabilizing managed config and relative plugins
  → promoting current symlink
  → restarting managed runtime
```

失败时删除未提升版本并保留原 `current`；新版本提升后正式启动失败则回滚 previous。无论 CPA 当时是否运行，切换 `current` 前都会先写受管配置并把唯一的相对/缺省插件来源稳定到持久目录，因此后续版本清理不会先删掉尚未迁移的插件。安装只接受固定仓库的官方 macOS release asset、匹配当前硬件的架构和 Release 提供的 `sha256:` digest。

安全校验继续保留首版已实现的路径穿越/符号链接逃逸检查、预期二进制名、0755、ad-hoc codesign、临时空 auth 目录、临时端口 `/healthz` 与 Management API dry run。

## 9. 持久化布局

```text
~/Library/Application Support/AIUsage/CLIProxyAPI/
├── versions/
│   ├── v7.2.66/CLIProxyAPI
│   └── v7.2.67/CLIProxyAPI
├── current -> versions/v7.2.67
├── config.yaml
├── auth/
├── plugins/
├── logs/
├── state.json
└── account-sync-manifest.json
```

权限：

- 根目录、`versions/`、`auth/`、`plugins/`、`logs/`：`0700`；
- config、state、auth file、sync manifest：`0600`；
- binary：`0755`；
- management/client key 原文位于 Keychain，不写入 sync manifest；
- 诊断包不包含 config 全文、auth file、sync fingerprints 或 secret。

`state.json` 保存非敏感运行设置；版本真值来自 `current` symlink；账号同步真值来自 manifest + source/CPA canonical fingerprints。

新建的 `plugins.dir` 写为 `<root>/plugins` 的绝对路径，避免 CPA 默认相对目录随 `versions/vX/` 工作目录改变。升级时若配置已有绝对目录则继续尊重该目录；相对或缺省 `plugins` 会扫描已安装版本，即使 `current` 已先切到新版也能找到唯一旧来源。迁移前完成全量冲突预检，只复制、不删除源文件；发现多个非空候选、符号链接/特殊文件或目标冲突时明确失败，不静默任选或合并。

`config.yaml` 不再从零生成：AIUsage 只增量更新 host、port、auth-dir、自己的 key、`ws-auth`、routing、retry、plugin enabled/dir 等受管路径，保留其他 `api-keys`、CPA Management API 管理的 `plugins.configs/store-*`、`openai-compatibility` 和未知字段；遇到无法安全处理的 inline mapping 或复杂 sequence 会报错而不是破坏性重写。

## 10. 代码结构

```text
AIUsage/
├── Models/
│   └── CLIProxyGatewayModels.swift
├── Resources/Assets.xcassets/ProviderIcons/
│   └── cliproxyapi.imageset/
├── Services/
│   ├── CLIProxyPaths.swift
│   ├── CLIProxyReleaseClient.swift
│   ├── CLIProxyBinaryStore.swift
│   ├── CLIProxyConfigStore.swift
│   ├── CLIProxySecretStore.swift
│   ├── CLIProxyRuntimeController.swift
│   ├── CLIProxyManagementClient.swift
│   └── CLIProxyCredentialAdapter.swift
├── ViewModels/
│   └── CLIProxyGatewayManager.swift
└── Views/
    ├── SubscriptionGatewayView.swift
    ├── SubscriptionGatewayComponents.swift
    ├── SubscriptionGatewayOverviewView.swift
    ├── SubscriptionGatewayAccountsView.swift
    ├── SubscriptionGatewayConnectionsView.swift
    └── SubscriptionGatewaySettingsView.swift
```

职责约束：

- `SubscriptionGatewayView` 只负责页头、四区导航、sheet/alert 编排；
- 四个 section view 负责各自用户任务，不直接访问 Process、Keychain、YAML 或 HTTP；
- `SubscriptionGatewayComponents` 提供网关卡片、状态 pill、Provider icon、copy field 和导航状态；
- `CLIProxyGatewayManager` 聚合更新、账号、OAuth、插件、单向同步、模型和分发状态；
- `CLIProxyManagementClient` 是 Management API 的 typed transport boundary；
- `CLIProxyCredentialAdapter` 只转换 allowlist 内已验证格式；
- `CLIProxyRuntimeController` 只管理配置、进程和健康；
- `CLIProxyBinaryStore` 只管理安装、校验、版本切换和回滚；
- 现有代理只消费普通受管 Provider/链接节点，不依赖 CPA 具体类型。

拆分的目的不是增加抽象层，而是防止首版单个 SwiftUI 文件同时承担安装、账号、分发、更新和诊断，从而难以测试和继续扩展。

## 11. 产品化验证矩阵

门禁需要同时覆盖“首版内核未回退”和“CPA 网关产品交互真实可用”。

### 11.1 自动化与构建

| 范围 | 验证项 | 预期 |
| --- | --- | --- |
| macOS 构建 | arm64 Debug、arm64 Release、x86_64 Release | 新拆分 Views、资源和 Models 全部编译 |
| QuotaBackend | 全量 Swift tests | 现有代理转换、统计和配置无回归 |
| updater regression | release 选择、digest、受限解压、版本提升/回滚 | 首版供应链边界保持 |
| runtime | 默认 loopback、显式 LAN bind、端口冲突、PID 身份、退出清理、重启、环境变量清理 | 不误杀未知进程；LAN 不开启 remote policy，management/client key 始终分离 |
| JSON fingerprint | key 顺序/缩进等价、非 object 拒绝、内容变化 | canonical SHA-256 状态稳定 |
| sync manifest | encode/decode、0600、损坏数据、迁移采纳 | 不保存 credential 内容 |
| sync states | 六种状态与 `manualCopy/keepUpdated` | 冲突不自动覆盖 |
| auth import | 后缀、大小、object、唯一文件名 | 非法文件在上传前被拒绝 |
| OAuth | 原生/插件 session decode、device code、cancel、timeout | 无残留并发轮询 |
| distribution | 真实 targets、幂等 upsert、移除 | 不产生重复链接节点 |
| config merge | 保留额外 `api-keys`、`openai-compatibility`、`plugins.configs/store-*`、未知字段；托管 key 轮换去重；`ws-auth=true`；绝对/相对/缺省插件目录与升级后跨版本迁移 | 重启和更新不丢动态配置；冲突不落盘 |
| settings merge | 本地只改端口、外部只改插件开关的三方合并 | 两项修改同时保留，不因跨页操作静默回退 |
| model catalog | 三视图解码、Anthropic 反转别名 canonicalization、大小写去重、route ID 保留、厂商品牌解析、30 秒刷新、PID 单飞、partial/stale/空态 | 一个逻辑模型只显示一次；每种 API 仍复制正确 route ID；受管 Provider 只使用原 OpenAI 列表 |
| local API guide | 协议卡 → 详情小窗、Origin/Base/endpoint 三层复制、Gemini 模型替换、低频 route 复制、协议认证头与遮罩 key | 复制值完整且对应当前 port，management key 不外泄 |
| LAN settings | 旧 state 无字段迁移、开关往返、`127.0.0.1 ↔ 0.0.0.0`、确认弹窗、私有/共享 IPv4 候选、多地址选择 | 默认关闭；开启后 client key 与 `ws-auth=true` 必需且 `allow-remote: false` |

### 11.2 官方 CPA live 回归

使用隔离临时目录和官方完整 release asset：

1. 下载、校验、安装并启动当前官方完整 macOS release，验证 `/healthz`；
2. auth JSON 上传 → 列表 → 启停 → `note/priority` → 下载 → 删除；
3. 读取动态 plugin 列表；插件/store 响应与 OAuth device-flow 解码在离线 fixture 验证；
4. 先写入带 `thinking/input-modalities` 的已有 OpenAI-compatible provider，再通过客户端追加第二项，验证高级字段未丢失；
5. OpenAI-compatible provider 启停使用 PATCH，并验证配置状态；
6. 分别读取 OpenAI、Anthropic、Gemini 模型视图，验证 `gpt-image-2` 与 `claude-fable-5-dd-2-egami-tpg` 归并为一个规范模型、各 API route ID 均保留，且受管 Responses Provider 的 OpenAI 模型列表不变；
7. 停止 CPA，执行 AIUsage 受管 YAML 合并，再启动 CPA，验证两个 provider、额外 client key、插件目录和模型注册均保留，旧托管 key 被撤销且 `ws-auth` 收紧为 true；
8. 将隔离配置切换到 LAN 模式，确认官方 CPA 能以 `host: 0.0.0.0` 启动并保持 `remote-management.allow-remote: false` 与 `ws-auth: true`；
9. 删除临时 provider，退出后清理整个临时根目录。

该自动化不伪造 OAuth 成功，也不安装并执行第三方插件。真实 OAuth、插件安装/启用/授权和最终推理请求属于 11.4 的显式人工链路。

live 回归不能使用或提交个人真实 token。需要真实订阅授权的最终推理请求只做人工验收，测试产物必须清理。

### 11.3 UI 人工验收

- 侧边栏和页头显示一致的 CPA 网关标识；
- 页头显示“账号池 → 4 个 AIUsage 应用 + 多协议本地 API”概念关系，概览中不再重复一张无操作的说明卡；
- 900×600、扩大侧边栏、宽窗口下四区导航、账号分组和添加向导不截断；四个页签的文字、图标、左右留白和上下边缘均一次点击切换；
- 模型刷新、账号快照生成和 CPA 持续输出日志时，连续往返四个页签仍即时响应；渲染路径不执行 Keychain 或 `Data(contentsOf:)`；
- 四个概览指标保持紧凑；模型目录按规范模型计数，厂商分组与 Logo 正确，协议别名不重复占卡；列表不显示会挤压名称的兼容 API 标签，搜索任一路由 ID 都能命中，详情可分别查看兼容 API 并复制真实 ID；
- 深色/浅色/提高对比度、全键盘和 VoiceOver 走通主路径，sheet 内失败结果可见；
- 已同步账号不再在“AIUsage 候选”和“CPA 账号池”重复出现；
- `sourceChanged/cpaChanged/conflict/missing` 的状态文案与动作一致；
- 覆盖 CPA 修改、删除 CPA 账号、移除代理连接都有明确确认；
- device code 可复制，OAuth 可取消并可再次启动；
- 插件安装后需要重启时给出过程状态，重启后刷新能力；
- API Key 输入、日志、错误横幅和诊断中不泄露 secret；
- 三个 AIUsage 托管目标卡在窄/宽窗口下均保持紧凑，并准确映射四个应用；
- 本地 API 主端点及折叠路由与当前 runtime port 一致，三类认证头正确，复制 client key 不暴露 management key；
- 四个协议卡的两行摘要可完整换行，长说明进入详情；详情小窗能分别复制 Origin、Base/REST Root 和完整 endpoint，Gemini 输入模型后路径即时解析，低频 HTTP/WebSocket 路由按正确 scheme 复制完整值或明确模板；
- 概览只有一张运行卡；设置中开启 LAN 必须确认，接入页可在本机/LAN Base URL 间切换并在多网卡时选择具体地址，关闭后立即恢复仅本机；
- CPA 更新无需更新 AIUsage，旧版本仍可回滚。

### 11.4 发布前真实链路

至少人工覆盖：

1. Codex → AIUsage Responses → CPA → 可用订阅；
2. Claude Code tool call → AIUsage canonical conversion → CPA；
3. OpenCode streaming/tool call → AIUsage → CPA；
4. 账号 A 冷却后切换账号 B；
5. AIUsage source 更新且 CPA 未改时 `keepUpdated` 正常更新；
   对会轮换 refresh token 的账号额外验证：CPA 侧刷新后必须转为 `cpaChanged/conflict` 并停止自动覆盖；
6. 两端都变时保持 `conflict`，不自动覆盖；
7. 一个动态插件 Provider 完成安装、授权与模型读取；
8. 一个 OpenAI-compatible API Key 上游完成最小模型请求；
9. 使用同一 gateway client key 分别完成 OpenAI Responses 或 Chat、Anthropic Messages、Gemini GenerateContent 的最小请求；
10. 核对 legacy Completions、models、compact、countTokens、stream 和 Codex alias 至少能到达正确 handler；若上游账号/模型不支持，应返回协议内错误而不是路由 404 或认证串线。

## 12. 发布门槛

以下条件全部满足才合并或进入正式版本：

- 三个构建 slice 和 QuotaBackend tests 通过；
- updater/runtime/live Management API 回归通过；
- Apple Silicon 实机和 Intel 构建/环境至少各验证一次资产选择；
- 六状态单向同步与冲突确认经过自动化或人工复核；
- 插件与 OpenAI-compatible 写入不会覆盖 CPA 其他配置；
- 未发现 secret 出现在日志、UserDefaults、诊断包、截图或提交 diff；
- 第三方 MIT license 继续随发布包提供；
- 更新失败、运行失败和 CPA 配置失败均有可恢复路径；
- 架构文档、用户文案与实际 UI 保持一致。

## 13. 后续阶段

当前架构预留但不在本轮伪装完成的事项：

1. 为 Gemini、Claude、Codex、Vertex 等 CPA 专用 API-key schema 增加独立 typed 编辑器；
2. 插件卸载、插件源管理与版本固定策略；
3. 账号近期请求明细的筛选和导出；当前详情以 CPA 返回的成功/失败计数为主；
4. 外部客户端直连 CPA 时的独立 `cliproxy-direct` 用量来源与去重；
5. LAN 的 TLS 证书、Bonjour 服务发现、IP allowlist 和 client key 轮换 UI；当前版本只提供可信网络内的显式开关；
6. 更细的账号路由规则、模型排除和 alias 编辑器；
7. 对 sync manifest 的 schema migration 与备份恢复 UI。

这些扩展继续遵循同一原则：能力由当前 CPA 实例探测，secret 由 typed boundary 管理，变更可审计且不破坏 AIUsage 原账号。

## 14. 明确不做

- fork 或修改 CPA Go 源码；
- 把 CPA 编译进 AIUsage 主进程；
- 复制 Quotio 的全部 Agent 配置系统；
- 让 CPA 成为第四条 AIUsage 代理轨；
- 静默安装第三方二进制或插件；
- 后台双向复制 OAuth token；
- 用文件名或修改时间替代内容状态判断；
- 根据未知 JSON 字段猜测 provider；
- 共享同一个 auth file 给 AIUsage 和 CPA 共同写入；
- 默认开放 LAN 或 remote management；
- 让 CPA 直接覆盖 Codex/Claude/OpenCode 用户配置；
- 把 CPA usage 与 AIUsage proxy usage重复入库。

## 15. 关键架构决定

1. **sidecar 而非 SDK**：保持上游可独立更新和故障隔离。
2. **一个受管 Provider 而非三套 CPA 配置**：复用现有 Distributor 和覆盖语义。
3. **四个用户任务区而非五个工程标签**：减少重复状态和设置暴露。
4. **统一账号中心而非两个账号列表**：同步副本只出现一次。
5. **添加向导按凭据来源组织**：OAuth、插件、API Key、AIUsage、JSON 都有明确入口。
6. **manifest + canonical hash 而非文件名判断**：能够识别两端变化和冲突。
7. **单向同步而非双向 token 镜像**：避免刷新竞态和不可解释覆盖。
8. **读取真实分发状态而非相信 UI 草稿**：应用、取消和移除都有确定结果。
9. **CPA 独立更新而非跟随 AIUsage 发版**：上游修复可以安全、快速交付，同时保留校验和回滚。
10. **AIUsage 内部主格式与 CPA 外部协议解耦**：受管 Provider 选择 Responses，不把整个 CPA 能力错误缩减为“OpenAI-compatible Base URL”。
11. **说明放在页头、能力放在任务卡**：概念条负责解释关系，概览指标、模型目录和接入端点只承载状态或可执行动作。
12. **LAN 是显式数据面开关而非远程管理开关**：默认 loopback；开启时面向用户开放带 client key 的推理/模型路由，remote policy 仍关闭，Management API 继续使用从不展示的独立高熵密钥。
13. **协议卡负责选择、详情小窗负责完整值**：主页面保持信息密度；Origin、Base URL、完整 endpoint、认证与模型占位符在小窗中无截断呈现，复制语义不再含糊。
14. **配置增量合并必须保留所有权边界**：AIUsage 只轮换自己命名空间的 client key、只更新受管字段；用户 key、绝对插件目录和未知配置不被重建覆盖。
15. **跨页设置采用逐字段三方合并**：设置草稿与插件/账号操作可以并存，避免“最后一次写入”静默撤销另一页刚完成的动作。

## 参考

- [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- [CLIProxyAPI v7.2.67 路由注册](https://github.com/router-for-me/CLIProxyAPI/blob/2075f77c8ebe9ec872759965661936fb1ac2931f/internal/api/server.go#L516-L562)
- [CLIProxyAPI client key 认证入口](https://github.com/router-for-me/CLIProxyAPI/blob/2075f77c8ebe9ec872759965661936fb1ac2931f/internal/access/config_access/provider.go#L55-L103)
- [CLIProxyAPI host / LAN 配置](https://github.com/router-for-me/CLIProxyAPI/blob/2075f77c8ebe9ec872759965661936fb1ac2931f/config.example.yaml#L1-L12)
- [CLIProxyAPI Management remote policy](https://github.com/router-for-me/CLIProxyAPI/blob/2075f77c8ebe9ec872759965661936fb1ac2931f/internal/api/handlers/management/handler.go#L262-L396)
- [CLIProxyAPI Management API](https://help.router-for.me/management-api.html)
- [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio)
