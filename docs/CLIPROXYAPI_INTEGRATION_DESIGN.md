# CLIProxyAPI 订阅网关集成方案

> 状态：首个可用版本已实现；独立更新、受管运行时、账号池、OAuth、现有账号显式同步、代理分发与诊断均已接通
> 调研日期：2026-07-12
> 上游基线：`router-for-me/CLIProxyAPI` main `6fc4f0c4`；最新发布版 `v7.2.67`
> 参考实现：`nguyenphutrong/quotio` master `ecd9d6f1`；最新发布版 `v0.22.0`
> 实现分支：`codex/cliproxyapi-subscription-gateway`

当前实现进度（2026-07-12）：

- 已接入“订阅网关”侧边栏与版本管理页面；
- 已实现官方完整 macOS 资产选择、GitHub Release API 检查和应用内下载；
- 已实现 SHA-256 digest、受限 archive 提取、ad-hoc codesign、Mach-O 架构校验；
- 已实现临时 loopback 端口 `/healthz` dry-run、版本目录、原子 `current` 切换和回退；
- 已使用官方 `v7.2.67` arm64 完整资产在隔离临时目录完成真实端到端验证；
- 已实现正式 sidecar 运行时：loopback 绑定、端口仲裁、受管 PID、健康检查、限次重启、退出清理和严格身份核验的孤儿回收；
- 已复用 `AccountCredentialStore` 的统一 Keychain vault 保存 management key 与 client key；非敏感设置写入权限为 `0600` 的独立状态文件；
- 已接通 CPA Management API：auth file 列表、启停、删除、上传、OAuth 状态轮询和模型目录；
- 已实现 Codex 与 Antigravity 现有 AIUsage auth-file 账号的显式、幂等“同步副本到 CPA”；不兼容账号会给出原因，不会猜测转换；
- 已实现 CPA 原生 Codex、Claude、Antigravity、Kimi、xAI OAuth 添加入口；
- 已创建固定受管 `APIProvider`，并复用 `APIProviderDistributor` 一键分发到 Codex、Claude Code、OpenCode；
- 已在订阅账号卡右键菜单加入同步/重新同步或跳转 CPA 的轻量入口；
- 已将页面整理为运行、账号池、代理分发、更新、诊断五个标签；运行日志在内存中限长并对两类 key 脱敏；
- 已用官方 `v7.2.67` 在隔离目录完成常驻启动、`/healthz`、Management API 上传/列表/停用/删除与 `/v1/models` 真实端到端验证。

### 本次实现记录

| 阶段 | 实现结果 | 验证方式 |
| --- | --- | --- |
| A. 更新内核 | 完整官方资产、digest、受限解压、签名、架构、dry-run、版本切换/回退 | 离线回归 + 官方 Release live 回归 |
| B. 运行时 | 配置生成、Keychain、端口仲裁、PID 所有权、健康检查、重启/停止 | Debug/Release 构建 + 官方二进制 live 启动 |
| C. 账号池 | Management API、OAuth、启停/删除、模型读取 | live API 上传、列表、停用、删除 |
| D. 账号桥接 | Codex/Antigravity 受管 auth file 显式复制；其他账号能力判定 | 转换规则审查 + UI 能力提示 |
| E. 代理融合 | 固定受管 APIProvider + 现有三轨分发器 | 编译期接线 + 原分发器回归测试 |
| F. 用户入口 | 订阅网关五标签 + 订阅账号卡 CPA 操作 | Debug/Release SwiftUI 构建 |

账号同步采用“显式副本”语义：CPA 的停用、删除或刷新不会修改 AIUsage 原账号；AIUsage 原账号更新后，用户可点击“重新同步”。这是首版比自动双向同步更安全、也更容易解释和回滚的边界。

## 1. 结论

可行，而且与 AIUsage 现有架构高度互补。

正确的产品定位不是把 CLIProxyAPI（下文简称 CPA）加入为 Codex、Claude Code、OpenCode 之外的“第四条代理轨”，而是增加一个位于它们上游的“订阅网关”：

- CPA 负责多订阅账号、OAuth/API Key 凭据、账号池、轮询/填满优先、冷却和故障转移；
- AIUsage 继续负责节点建模、协议适配、全局代理热切换、CLI 配置接管、调用统计和成本归因；
- CPA 对 AIUsage 暴露一个固定的本地 OpenAI Responses 端点；
- AIUsage 把这个端点注册为一个受管 `APIProvider`，再复用现有 `APIProviderDistributor` 一键分发到 Codex、Claude Code、OpenCode。

最终用户路径应当是：

```text
在“订阅网关”安装并启动 CPA
  → 从现有“订阅账号”选择可接入账号，或在 CPA 中新增授权
  → AIUsage 按提供商选择“关联 / CPA 重新授权 / 显式一次性导入”
  → CPA 形成一个本地账号池和固定 API 端点
  → 点击“添加到代理”
  → AIUsage 自动创建/同步一个受管 API 提供商
  → 复用现有分发器生成 Codex / Claude Code / OpenCode 链接节点
  → 用户在现有代理页激活，或在全局代理中热切换到该节点
```

## 2. 已核对的事实

### 2.1 AIUsage 已经具备的基础

AIUsage 当前不是从零开始：

1. `AppSection`、`SidebarNavigation` 和 `ContentView` 已形成可扩展的侧边栏分区。
2. `APIProvider` 已统一承载 base URL、API Key、接口格式、模型库、默认模型与定价。
3. `APIProviderDistributor` 已支持把一个主配置幂等分发到 Codex、Claude Code、OpenCode，并维护：
   - `linkedProviderId`；
   - 本地覆盖字段 `overriddenKeys`；
   - 主配置更新后的增量同步；
   - 删除时的级联删除或解除链接；
   - 新节点端口避让。
4. `GlobalProxyManager` 已让 Codex、Claude Code、OpenCode 拥有固定本地端点，并可通过管理路由热切换上游节点。
5. `CodexConfigManager`、`ClaudeSettingsManager`、`OpenCodeConfigManager` 已处理 CLI 配置写入和恢复。
6. `ProxyPortArbiter` 已聚合三轨代理和全局代理的在用端口。
7. AIUsage 已使用 Sparkle 更新自身，并已经有外部 helper 的进程启动、健康检查、父进程退出清理和发布打包经验。
8. App Sandbox 当前关闭，应用具备网络访问和启动外部进程的现实条件；最低系统为 macOS 14。

因此，新功能不应复制一套“Agent 配置器”或另一套节点系统。最有价值的工作是补齐 CPA 的二进制生命周期、账号池管理，以及到现有 `APIProvider` 的桥接。

### 2.2 CPA 当前提供的能力

当前 CPA 源码和配置确认了以下能力：

- OpenAI Chat Completions、OpenAI Responses、Anthropic、Gemini、Codex 等兼容接口；
- Claude、Codex、Gemini、Antigravity、Kimi、xAI 等 OAuth 流程；
- 多账号轮询和 fill-first 路由；
- 账号冷却、重试、模型排除、模型别名、credential prefix；
- `/v0/management` 管理 API；
- auth file 列表、上传、删除、启停、字段修改和每账号模型列表；
- API key 管理、路由策略、proxy URL、配置读写、日志和 usage queue；
- `127.0.0.1` 本地运行或显式允许远程管理；
- macOS arm64 和 amd64 发布资产；
- GitHub Release 资产 digest，可用于 SHA-256 校验。

注意：上游 README 已说明，CPA 自 v6.10.0 起不再内置持久化用量统计。第一阶段不能把“CPA 自带完整历史统计”当作成立条件。

### 2.3 Quotio 中值得复用的做法

Quotio 已验证 macOS 原生壳管理 CPA 的路线可行，值得采用的部分包括：

- 首次使用时按架构下载，不强制把所有架构二进制塞进 App；
- 版本目录 + `current` 符号链接；
- GitHub Atom feed 低成本检查版本，只有真正更新时才请求 Release API；
- Release asset digest 的 SHA-256 校验；
- 解压路径穿越和符号链接逃逸检查；
- 下载后设置 0755 并做 ad-hoc codesign；
- 新版本先在临时端口 dry run，再提升为 current；
- 保留旧版本并支持回滚；
- Management API 统一管理账号、设置与日志；
- Agent 配置写入前做备份。

不应照搬的部分：

- 不应通过 `lsof <port>` 后杀掉端口上的所有进程；AIUsage 必须只终止自己创建且经过路径/PID 身份核验的子进程。
- 不需要复制 Quotio 的 Agent 配置写入逻辑；AIUsage 已有更贴合自身节点模型的三套配置管理器。
- 不应让 CPA 的管理 key 和对外 API key 共用。
- 不应让 CPA 与 AIUsage 同时统计同一条请求，否则会重复计量。

## 3. 产品信息架构

### 3.1 新的侧边栏入口

新增：

```swift
case subscriptionGateway
```

中文名：`订阅网关`
英文名：`Subscription Gateway`

位置放在 `订阅账号` 与 `API 提供商` 之间，而不是放进“代理”折叠组：

```text
仪表盘
订阅账号
订阅网关       ← 新增
API 提供商

代理
  Codex
  OpenCode
  Claude Code
  Claude Science
```

原因：CPA 是把订阅转换为 API 的上游网关；Codex/Claude/OpenCode 才是消费上游的下游代理。

### 3.2 页面结构

`SubscriptionGatewayView` 使用一个页面内的五个标签：

1. **概览**
   - 未安装 / 已安装版本 / 可更新版本；
   - 运行状态、PID、监听地址、端口、启动时间；
   - 启动、停止、重启；
   - 当前账号数量、可用账号数量；
   - 本地端点与“复制端点”；
   - 更新、版本回退。

2. **账号池**
   - 按提供商分组；
   - 显示 AIUsage 现有订阅账号与 CPA 账号的关联状态；
   - 从现有订阅账号发起“接入 CPA”，但先展示兼容性与授权方式；
   - 添加 Claude、Codex、Gemini、Antigravity、Kimi、xAI 等 OAuth 账号；
   - 上传受支持的 auth file；
   - 启用/停用、删除；
   - 展示账号状态、最近请求、冷却原因、可用模型；
   - OAuth 取消和超时必须可恢复。

3. **接入代理**
   - 显示 CPA 统一端点、client API key（默认遮罩）、模型目录；
   - `同步模型`；
   - `添加到 Codex`、`添加到 Claude Code`、`添加到 OpenCode`；
   - `全部添加`；
   - 显示每个目标当前状态：未添加、已链接、存在本地覆盖、主配置待同步；
   - 支持“重置为继承”；
   - 可选的“添加后打开对应代理页”，不默认强行激活。

4. **路由与设置**
   - 端口，默认 `14420`；
   - `round-robin` / `fill-first`；
   - session affinity；
   - retry、cooldown、quota exceeded 行为；
   - 上游网络代理 URL；
   - 随 AIUsage 启动；
   - 局域网访问放入高级设置，默认关闭。

5. **诊断**
   - 经过脱敏的进程日志；
   - Management API 连通性；
   - `/v1/models` 探测；
   - 配置路径、auth 目录、当前二进制路径；
   - 导出不含 secret/auth file 的诊断包。

现有“订阅账号”页同时增加轻量入口，不把用户强制带到另一套账号体系：

- 账号卡显示 `未接入`、`可关联`、`需在 CPA 授权`、`已接入`、`需重新授权`、`CPA 不支持`；
- 主操作统一叫“接入 CPA”，能力判定完成后再显示具体动作；
- 多选工具栏提供“批量接入 CPA”，但 OAuth 逐项排队、逐项确认；
- 点击状态可跳转到订阅网关中的对应 CPA auth record；
- 不在列表上展示“自动同步已开启”，避免制造 token 会持续一致的错误预期。

## 4. 运行时数据流

推荐的默认链路是统一走 OpenAI Responses：

```text
Claude Code / Codex / OpenCode
          │
          ▼
AIUsage 现有代理轨
  - 固定本地 client endpoint
  - 协议转换或忠实透传
  - 节点切换
  - 调用/成本统计
          │ OpenAI Responses
          ▼
CPA Subscription Gateway
  - 多订阅账号池
  - round-robin / fill-first
  - cooldown / retry / failover
          │
          ▼
Claude / Codex / Gemini / Antigravity / ...
```

CPA 受管提供商固定使用：

```text
id: aiusage.cliproxyapi.gateway
name: CLIProxyAPI Subscription Gateway
baseURL: http://127.0.0.1:14420/v1
format: openAIResponses
apiKey: 由 AIUsage 生成的 gateway client key
models: 从 GET /v1/models 同步
defaultModel: 用户选择，或模型目录的稳定首选项
```

选择 Responses 的理由：

- Codex 现有分发规则只接受 Responses；
- Claude 轨已有经过回归测试的 Claude → Responses 转换；
- OpenCode 轨原生支持 Responses；
- 一个主配置即可复用现有 `APIProviderDistributor` 分发到三处；
- 避免额外引入“一个网关、三个协议主配置”的复杂 UI。

未来如确认某类请求必须 Anthropic 原生透传，可再增加“协议变体”，不应作为第一阶段阻塞项。

## 5. 模块与文件结构

```text
AIUsage/
├── Models/
│   └── CLIProxyGatewayModels.swift
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
    └── SubscriptionGatewayView.swift
```

职责约束：

- View 不直接发网络请求、不直接操作 `Process`、不直接改 YAML；
- `CLIProxyRuntimeController` 只管理进程、设置与健康状态；
- `CLIProxyBinaryStore` 只管理版本目录、校验、切换和回滚；
- `CLIProxyManagementClient` 只封装 `/v0/management`；
- `CLIProxyCredentialAdapter` 只处理已验证且显式列入 allowlist 的格式，禁止通用代码猜测字段；
- `CLIProxyGatewayManager` 是 CPA 与现有 `APIProviderStore` / `APIProviderDistributor` 的唯一桥；
- 三套现有代理和 CLI config manager 不依赖 CPA 类型，只消费普通链接节点。

## 6. 持久化布局

建议放在 Application Support，避免混入源码或用户手写配置：

```text
~/Library/Application Support/AIUsage/CLIProxyAPI/
├── versions/
│   ├── v7.2.66/
│   │   └── CLIProxyAPI
│   └── v7.2.67/
│       └── CLIProxyAPI
├── current -> versions/v7.2.67
├── config.yaml
├── auth/
├── logs/
├── runtime.pid.json
└── state.json
```

权限：

- 根目录、`auth/`、`logs/`：0700；
- config、auth file、state、runtime PID record：0600；
- binary：0755；
- 不把 auth file、OAuth token、management key 加入 AIUsage 日志、诊断包或同步数据。

`state.json` 只保存非敏感运行设置。版本状态从 `current` 符号链接和版本目录恢复；AIUsage 账号关联由确定性 CPA 文件名重建，不另存 token 或 link 数据库。两把 key 保存在统一 Keychain vault 中。

## 7. Secret 模型

必须分成两把 key：

1. **Management key**
   - 只供 AIUsage 调用 `/v0/management`；
   - 原文保存在 Keychain；
   - config 中 CPA 启动后可能写成 hash，AIUsage 不从 config 反推原文；
   - 不写入 `APIProvider` 或任何下游节点。

2. **Gateway client key**
   - 供 Codex/Claude/OpenCode 节点访问 CPA；
   - 随机生成，可轮换；
   - config 与现有节点文件必须保持 0600；
   - UI 默认遮罩，复制动作显式触发；
   - 轮换时通过 `CLIProxyProviderSyncService` 一次性同步所有链接节点。

OAuth token 由 CPA 的 auth store 管理。AIUsage 不做后台、定时或双向 token 镜像；用户可以从现有“订阅账号”发起接入，但每次必须明确显示最终采用的是 CPA 重新授权、仅关联，还是经过验证的一次性导入。

### 7.1 现有订阅账号是否值得同步

值得做，但应把功能命名为“接入 CPA”或“关联到订阅网关”，而不是承诺“自动同步凭据”。原因是 AIUsage 的账号卡和真实 secret 是分离的：`StoredProviderAccount` 只保存 `credentialId`，真正的凭据位于统一 credential vault。CPA 的 auth store 又要求自身的 provider `type` 和字段结构。直接复制账号卡、邮箱或任意 auth file 都不能构成可靠的 CPA 账号。

正确目标包含两层：

1. **身份与状态同步**：长期保持。AIUsage 知道某个订阅账号对应哪个 CPA auth record，并把 CPA 的可用、冷却、禁用、需重新授权状态显示回账号卡。
2. **secret 迁移**：只在明确支持时发生一次。由 provider adapter 转换、上传并验证，成功后 CPA 独立持有和刷新它的副本；后续不再由 AIUsage 覆盖。

### 7.2 为什么不能持续复制 token 文件

- AIUsage 的 Codex、Gemini 等 provider 会在 token 过期时刷新并回写原 auth file；
- CPA 也会刷新自己 auth store 中的 access token / refresh token；
- 两边同时持有并轮换同一 refresh token，可能产生刷新竞态、旧 token 覆盖新 token 或 `refresh_token_reused`；
- AIUsage 的 Codex 文件可包含嵌套 `tokens`，CPA Codex auth record 使用带 `type: codex` 的扁平字段；Gemini 在 CPA 中使用 `gemini-cli` provider 标识；
- CPA 的文件型 token store 依赖顶层 `type` 识别 provider，没有该字段时会得到 `unknown`。

因此禁止：目录监控后自动复制、登录时静默复制、CPA → AIUsage 反向回填 refresh token，以及“哪个文件更新就覆盖另一边”的 last-write-wins 策略。

### 7.3 四级接入能力

```swift
enum CPABridgeCapability {
    case linkExistingCPAAccount       // CPA 已有同一身份，只建立关联
    case reauthenticateInCPA          // 默认安全路径：在 CPA 完成新授权
    case oneTimeValidatedImport       // 显式、可审计、导入后由 CPA 独立管理
    case unsupported(reason: String)  // 只保留 AIUsage 监控能力
}
```

当前基线下的保守兼容矩阵：

| AIUsage 账号 | AIUsage 当前凭据来源 | 官方 CPA 当前能力 | 第一版策略 |
|---|---|---|---|
| Codex | token 或 `auth.json` | 原生 Codex OAuth / device login | 默认 CPA 重新授权；精确格式适配与验证完成后，才开放高级“一次性导入” |
| Gemini | `oauth_creds.json` | `gemini-cli` auth provider / OAuth 插件 | 默认 CPA 重新授权；不原样复制文件 |
| Antigravity | auth file / OAuth | 原生 Antigravity OAuth | 默认 CPA 重新授权；一次性导入列为后续受控能力 |
| Claude | AIUsage 当前主要是代理用量归档，不是可复用账号 secret | 原生 Claude OAuth | 从账号入口启动 CPA 授权并关联，不从用量账号反推 token |
| Kimi | `~/.kimi/config.toml` API key | CPA 原生 Kimi 路径使用 OAuth token | 不把 API key 假装成 OAuth；需要时作为独立 API Provider 处理，或在 CPA 重新授权 |
| Copilot / Kiro | token / auth file | 官方 CPA 基线无对应原生账号类型 | 不支持接入，只保留 AIUsage 监控 |
| Cursor | browser cookie / web session | 无对应原生账号类型 | 禁止导入浏览器会话 |
| Droid / MiniMax | API key、token 或本地文件 | 无等价原生订阅账号类型 | 继续走现有 API Provider 能力，不进入 CPA OAuth 账号池 |
| Warp / 成本类 provider | 本地状态或统计数据 | 无等价认证目标 | 不支持接入 |

该矩阵必须是运行时能力表，而不是永久写死。CPA 更新后，AIUsage 通过版本号、Management API/插件能力探测和 adapter 最低版本共同决定按钮状态；未知版本默认降级为“在 CPA 重新授权”，不能自动放宽导入。

### 7.4 账号关联模型

```swift
struct CPAAccountLink: Codable, Identifiable {
    let id: UUID
    let aiUsageAccountId: String
    let providerId: String
    let cpaAuthIndex: String?       // Management API 的 auth_index
    let cpaAuthFileName: String?    // 仅作诊断回退，不作为唯一身份
    let importMode: ImportMode
    let sourceFingerprint: String?  // 单向摘要，不能还原 secret
    let normalizedIdentity: String? // provider + accountId/email 的规范化结果
    let linkedAt: Date
    var lastValidatedAt: Date?
    var status: CPAAccountLinkStatus
}
```

去重顺序：CPA `auth_index` → provider + account id → provider + 规范化 email → credential fingerprint。文件名只能辅助显示，不能作为唯一键。fingerprint 使用保存在 Keychain 的本地随机 key 做 HMAC-SHA256，不保存裸 credential hash；所有比较日志只记录摘要后缀，不输出 secret。

### 7.5 “接入 CPA”事务

从现有订阅账号卡点击后执行：

1. 用 `credentialId` 从统一 vault 解析 `AccountCredential`；解析失败时只提示“原凭据不可用”，不猜测邮箱字段；
2. `CLIProxyCredentialBridge` 根据 provider、auth method、CPA 版本和已安装插件返回 capability；
3. 先查询 CPA auth records，若同 provider + identity 已存在，优先让用户确认“仅关联”；
4. `reauthenticateInCPA`：打开 CPA 官方 OAuth/device flow，成功后用 provider + email/account id 绑定；
5. `oneTimeValidatedImport`：在内存中转换为 CPA schema，先做本地 schema 校验，再经 Management API 上传；
6. 上传后重新读取 auth record、模型列表并完成一次最小真实请求；任一步失败则删除本次新建的 CPA record，不改变 AIUsage 原凭据；
7. 成功后写入非敏感 `CPAAccountLink`，清除内存中的明文材料；
8. 后续只同步状态，不同步 token。

批量操作也逐账号执行以上事务，并显示每项结果；不允许“全部导入”跳过确认。对于需要 OAuth 的多个账号，可以排队逐个授权，取消某项不影响已完成项。

### 7.6 删除、失效与重新授权

- 删除 AIUsage 订阅账号时：提供“仅解除关联”和“同时删除 CPA 凭据”两个显式选项，默认仅解除关联；
- 删除 CPA auth record 时：AIUsage 账号仍保留监控能力，关联状态变为 `missingInCPA`；
- 身份变化或 refresh 失败时：状态变为 `reauthorizationRequired`，不自动从 AIUsage vault 再复制一次；
- CPA 中新授权的账号若与 AIUsage 已有账号匹配，可以建议关联；没有匹配时不自动创建含 secret 的 AIUsage credential；
- 用户可执行“重新匹配”，但跨 provider 永不自动匹配。

## 8. 二进制安装与更新

### 8.1 策略

默认采用“用户首次启用时下载”，不把 CPA 二进制静态打进 AIUsage：

- 避免 Universal App 同时携带 arm64、amd64 两份大二进制；
- CPA 更新不要求发布新的 AIUsage；
- 用户明确同意后才下载并执行第三方组件；
- 可以在 UI 中展示来源、版本、许可证和 release notes。

### 8.2 更新状态机

```text
idle
  → checking
  → downloading
  → verifying
  → installing
  → dryRunning
  → promoting
  → active

任一步失败：
  → failed
  → 删除未提升的新版本
  → current 保持不变

新版本提升后正式启动失败：
  → rollingBack
  → current 指回 previous
  → 重启 previous
```

### 8.3 更新检查

- 自动检查用 `releases.atom` + ETag，间隔不短于 6 小时；
- 用户手动检查时可立即请求；
- 只有安装时才请求 GitHub Release API 获取目标架构资产和 digest；
- 使用真实硬件架构选择 `darwin_arm64/aarch64` 或 `darwin_amd64`，不能只看当前编译 slice；
- 默认不自动安装，只提示；可在高级设置中开启自动更新，但仍要走完整 dry run 和回滚。

### 8.4 供应链校验

安装必须全部通过：

1. HTTPS 下载固定仓库 `router-for-me/CLIProxyAPI` 的 Release asset；
2. Release asset 必须提供 `sha256:` digest；缺失时拒绝自动安装；
3. 下载后计算 SHA-256 并比对；
4. 解压前/后防止 `../` 路径穿越和 symlink escape；
5. 只接受预期文件名和 Mach-O 可执行文件；
6. 校验架构与当前 Mac 匹配；
7. 设置 0755；
8. 做 ad-hoc codesign；
9. 在空的临时 auth 目录和临时配置上 dry run；
10. 通过健康检查后才切换 `current`。

### 8.5 Dry run 验证

不使用真实 auth 目录，避免测试版本刷新或改写真实 token。临时实例至少验证：

- 进程在超时内保持存活；
- 仅监听临时的 127.0.0.1 端口；
- `/v0/management/config` 使用临时 management key 返回合法 JSON；
- `/v1/models` 使用临时 client key 返回合法 OpenAI models 结构，即使模型数组为空；
- 关闭后端口释放；
- 正式提升后，再用真实配置做第二次健康检查；失败即自动回滚。

## 9. 进程生命周期

`CLIProxyRuntime` 必须记录并核验：

- `Process` 实例；
- PID；
- executable 的解析后绝对路径；
- config 的绝对路径；
- 启动 token；
- 监听端口；
- 启动时间和期望退出标记。

规则：

- 正常停止先发 terminate，超时后只对已核验的自有 PID 发 SIGKILL；
- 禁止因为端口被占就杀死未知进程；
- 启动前把 CPA 端口加入 `ProxyPortArbiter`；
- App 正常退出时同步停止；
- App 崩溃后若发现残留 PID，只有 executable、config 参数和保存状态全部匹配时才清理；
- 意外退出使用指数退避，最多自动重启 3 次；
- 更新/配置重启使用串行事务，避免 stop 的异步清理杀死刚启动的新进程；
- stdout/stderr 持续 drain，按行脱敏后放入有界 ring buffer，防止 pipe 填满导致子进程卡死。

## 10. 与现有 API 提供商/代理融合

`CLIProxyProviderSyncService` 使用固定 provider id 幂等 upsert：

```swift
enum ManagedAPIProviderID {
    static let cliProxyGateway = "aiusage.cliproxyapi.gateway"
}
```

同步规则：

1. CPA 启动且 `/v1/models` 可达后创建或更新主 `APIProvider`；
2. base URL、gateway client key、模型库和默认模型是共享字段；
3. 用户在链接节点中做的本地覆盖继续由 `overriddenKeys` 保护；
4. 重复点击“添加”不得产生重复节点；
5. CPA 端口或 key 变化后调用 `syncFromMaster`；
6. 用户删除 CPA 功能时，必须让用户选择：
   - 删除所有链接节点；
   - 解除链接，保留为普通节点；
7. `GlobalProxyManager.availableNodes()` 会自然看到这些链接节点，无需 CPA 专用热切换逻辑。

第一阶段不直接改写 `~/.codex/config.toml`、`~/.claude/settings.json`、`~/.config/opencode/opencode.json`。只有用户在现有代理页启用节点时，继续走现有可恢复的配置接管事务。

## 11. 模型同步

`GET /v1/models` 是 CPA → AIUsage 的模型目录入口。

同步流程：

1. 使用 gateway client key 请求模型列表；
2. 规范化、排序、去重；
3. 保留用户已填写的定价，不因模型刷新清空；
4. 新模型默认无定价；
5. 已消失的模型先标记 unavailable，不立即删除；
6. 当前默认模型消失时提示用户选择，不静默换模型；
7. 同步成功后更新受管 `APIProvider`，再同步到已链接节点。

CPA auth file 的“账号可用模型”适合账号详情展示，不应直接等同于整个网关的 `/v1/models` 结果。

## 12. 用量与统计边界

第一阶段以 AIUsage 现有代理日志为唯一计量源：

- 由 AIUsage 代理发往 CPA 的请求已经被 AIUsage 记录；
- 同一请求不能再从 CPA usage queue 导入，否则 token 和成本会重复；
- CPA 账号池页可以展示运行状态、冷却和最近请求，但不把这些信息写入成本数据库。

后续如果允许外部客户端绕过 AIUsage 代理直接访问 CPA，则增加独立来源 `cliproxy-direct`，并使用 request id / session id / 时间窗去重。该能力不属于第一阶段。

## 13. 安全默认值

- host 固定 `127.0.0.1`；
- remote management 固定关闭；
- management key 必填；
- gateway client key 必填；
- 不使用示例 key；
- 局域网访问默认不展示在基础设置；
- 开启 LAN 时强提示暴露范围，并要求确认 API key 已轮换；
- OAuth callback 只接受 loopback；
- 浏览器返回必须匹配 state；
- 日志脱敏 Bearer、Cookie、API key、OAuth code、refresh token；
- 诊断包不包含 config 全文和 auth file；
- 不后台镜像 AIUsage 已有订阅凭据；一次性导入必须经过 provider adapter、用户确认和 CPA 端验证；
- 不自动启用上游动态 library plugins；
- CPA management control panel 默认禁用，第一阶段使用原生 UI 和 Management API。

## 14. 分阶段实现与实际状态

### Phase 1：运行内核与安全更新（已完成）

- 新导航和空状态页面；
- paths、config、binary store、release client；
- 下载、digest 校验、解压防护、ad-hoc sign；
- start/stop/restart、健康检查、崩溃恢复；
- 版本目录、dry run、提升、回滚；
- `ProxyPortArbiter` 纳入 CPA；
- App 退出清理。

完成标准：没有账号时也能安全安装、启动、更新和回滚。

### Phase 2：账号池与 Management API（V1 已完成）

- Management client；
- auth file 列表、状态、启停、删除、上传；
- Claude/Codex/Antigravity/Kimi/xAI OAuth（当前 CPA Management API 没有 Gemini OAuth URL 路由，不虚构入口）；
- 以确定性 auth file 名称实现可重建关联，并加入能力矩阵；
- 现有订阅账号卡的“接入 CPA”入口和状态回显；
- 先实现 CPA 重新授权与已有 CPA 账号关联；
- Codex/Antigravity provider adapter、导入预检和幂等覆盖；其他格式保持禁用，待逐个验证后再开放；
- 路由策略、重试、proxy URL；
- 原生账号池 UI。

完成情况：现有账号可安全发起接入，也可独立添加多个 CPA 账号；账号关联可从确定性文件名重建，CPA 已真实验证 `/v1/models` 与 auth 增删改查。真实上游推理需要用户自己的有效订阅凭据，不写入自动化测试；任何失败均不修改 AIUsage 原凭据。

### Phase 3：一键接入三套代理（已完成）

- 生成/轮换 gateway client key；
- 固定受管 `APIProvider`；
- 模型同步；
- 复用 `APIProviderDistributor`；
- 每个目标的链接、继承、解除链接状态；
- 添加后跳转现有代理页；
- 端口/key 变更的事务同步。

完成标准：同一 CPA 网关能幂等加入 Codex、Claude Code、OpenCode，并在全局代理中热切换。

### Phase 4：诊断、稳定性与发布门禁（功能内已完成，发布流程留待合并时执行）

- 脱敏、限长运行日志与受管文件入口；
- OAuth/更新/崩溃错误在页面内回显；
- Intel + Apple Silicon 真机验证；
- 正式 release notes 与发布签名在合并发布时执行，不在功能分支提前发布；
- 设计文档和用户文档同步。

### 分支内的具体执行顺序

本次大改动只在 `codex/cliproxyapi-subscription-gateway` 开发，不直接在 `main` 堆叠。实际执行记录如下：

1. **基线与更新内核**：先落独立 updater、隔离回归和官方 Release live 验证。
2. **运行时与 secret**：接 Application Support 权限、统一 Keychain、配置生成、进程所有权和端口仲裁。
3. **Management API**：接 health/auth list/models，再接上传、启停、删除和 OAuth。
4. **账号桥接**：先完成能力矩阵，只开放已核对格式的 Codex/Antigravity 显式副本同步。
5. **受管 Provider 与三轨分发**：复用现有 store/distributor，不另造第四套代理。
6. **完整 UI 与账号卡入口**：连接五标签页面、账号卡右键入口、更新/回退和脱敏诊断。
7. **门禁**：Debug/Release、QuotaBackend tests、离线 updater、官方 CPA live Management API、diff/secret 检查。

建议的合并策略是一个功能分支、多个可审查提交、最终一个 PR；不为每个小步骤再建长期分支。Phase 1 和账号桥接核心可以使用短期 worktree 做实验，但只有门禁通过的提交才进入功能分支。

## 15. 测试矩阵

下列矩阵同时记录已自动化的 V1 门禁和正式发布前仍需人工/真实账号验证的场景。当前自动化已覆盖版本/资产/校验和/安全解压/配置权限、官方二进制 dry-run 与常驻启动、health、Management API 增删改查和 models；需要有效订阅、OAuth 人工交互或 Intel 环境的条目保留为发布验收项。

### 单元测试

- 版本比较（含 prerelease）；
- asset 架构匹配；
- digest 缺失和 checksum mismatch；
- YAML 引号转义、受管字段生成与 `0600` 权限；
- 日志脱敏；
- 模型目录合并和定价保留；
- managed provider 幂等 upsert；
- key 轮换同步；
- PID/executable/config 身份核验。
- credential capability matrix（provider、auth method、CPA 版本、插件能力）；
- account identity 规范化、去重与 fingerprint 不可逆性；
- adapter 输入缺字段、嵌套/扁平格式差异和未知 provider 拒绝；
- link store 不含 token、cookie、API key；

### 集成测试

- 空 auth 目录 dry run；
- management key 错误；
- client key 错误；
- 端口已被 AIUsage 其它代理占用；
- 端口被未知进程占用时只报错、不杀进程；
- 更新时正在运行；
- 新版本正式启动失败后回滚；
- App 正常退出和崩溃恢复；
- OAuth 成功、取消、超时、重复回调；
- 已有 CPA 同身份账号只关联，不重复创建；
- 一次性导入成功后不再跟随源 auth file 更新；
- 一次性导入上传后验证失败会清理 CPA 新记录，AIUsage 原凭据不变；
- AIUsage 与 CPA 同时发生 token refresh 时，桥接层不会互相覆盖文件；
- CPA 账号被外部删除后，AIUsage 只标记关联失效；
- 批量接入中单项取消/失败不回滚其他成功项；
- 账号停用后 CPA 自动换账号；
- `/v1/models` 刷新后链接节点同步；
- 重复“全部添加”不产生重复节点；
- 删除 provider 时级联/解除链接两条路径。

### 端到端协议测试

至少覆盖：

1. Codex → AIUsage Responses → CPA → Codex subscription；
2. Claude Code tool call → AIUsage canonical conversion → CPA → 可用订阅；
3. OpenCode streaming/tool call → AIUsage → CPA；
4. 账号 A 冷却后自动切账号 B；
5. 三条轨同时启用时端口无冲突、统计不重复。

## 16. 发布门槛

以下条件全部满足才进入正式版本：

- Debug 与 Release 构建通过；
- `swift test --package-path QuotaBackend` 通过；
- 现有 Claude proxy、Science auth proxy 回归通过；
- 新 CPA regression harness 通过；
- Apple Silicon 和 Intel/虚拟 Intel 环境至少各验证一次安装资产；
- 下载资产 checksum mismatch 能被阻断；
- 更新失败能自动回滚；
- 未发现 secret 出现在日志、UserDefaults、诊断包、提交 diff；
- 第三方 MIT license 随发布包或 About/Notices 页面提供；
- release playbook 增加 CPA 二进制生命周期检查。

## 17. 明确不做

第一版不做以下事情：

- fork 或修改 CPA 的 Go 源码；
- 把 CPA SDK 编译进 AIUsage 进程；
- 复制 Quotio 全部功能；
- 让 CPA 成为新的 AIUsage 代理轨；
- 后台、定时或双向复制 AIUsage 订阅账号 token；
- 把 provider 不同的 token/API key/cookie 通过猜字段强行转换；
- 让 AIUsage 与 CPA 共同写同一个 OAuth auth file；
- 默认开放 LAN 或远程管理；
- 让 CPA 直接覆盖 Codex/Claude/OpenCode 配置；
- 把 CPA usage 与 AIUsage proxy usage 双重入库；
- 静默自动安装第三方二进制。

## 18. 最终建议

以 sidecar 方式集成官方 CPA 二进制，原生实现 Management API 客户端，并用固定的受管 `APIProvider` 接入现有分发器，是当前最小风险、最少重复、最符合 AIUsage 架构的方案。现有订阅账号应当接入这一流程，但长期同步对象是账号身份和 CPA 状态，不是 OAuth token；默认采用 CPA 独立授权，只有通过专用 adapter 和端到端验证的提供商才提供显式一次性导入。

实现顺序不能从 UI 或 OAuth 开始。应先完成可校验、可 dry run、可回滚、只管理自有 PID 的运行内核；然后再接账号池；最后用现有 `APIProviderDistributor` 打通三套代理。这样每一阶段都有独立的安全闭环，也不会把第三方进程生命周期问题扩散进现有代理系统。

## 参考

- [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- [CLIProxyAPI Management API](https://help.router-for.me/management-api.html)
- [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio)
