# Claude Science 代理 · 技术开发文档

> 本文件是「Claude Science 代理」轨的**唯一技术参考**（架构 + 实现 + 逆向依据 + 排障）。新会话从这里即可快速掌握该功能全貌，无需翻阅历史对话。

## 1. 概述

「Claude Science 代理」是 AIUsage 的一条独立代理轨（`GlobalProxyTrack.science`）。目标：**免 Claude 订阅**启动本地的 Claude Science，把它的推理请求经本地 `QuotaServer` 导向你自选的第三方模型（任意 OpenAI 兼容 / Anthropic 端点），同时保留 Science 的工具调用、Skill、MCP、代码执行等原生体验。

```
Claude Science daemon（虚拟登录）
  │  ANTHROPIC_BASE_URL = http://127.0.0.1:14402
  ▼
QuotaServer（复用 Claude 转换链路：剥离入站 Bearer、注入第三方 key、按档映射模型）
  ▼
第三方模型（Anthropic 直连透传 / OpenAI 兼容端点）
```

定位：个人学习与研究，使用者自负风险。推理走你自付的第三方，**不经过 Anthropic 服务端做推理**；登录用本地自造虚拟凭证，**零真实 Anthropic 凭证参与推理**。全部用原生 Swift 复用现有 `QuotaServer`，无 node / python 运行时依赖；UI 与 Codex / OpenCode 菜单统一。

## 2. 核心原理

Claude Science 的登录只是「启动门票」：登录后推理打到哪，由环境变量 `ANTHROPIC_BASE_URL` 决定。本集成做两件事：

1. **越过登录门**：在独立 data-dir 写一份 Science 认可格式的**虚拟 OAuth**凭证（AES-256-GCM v2 + HKDF-SHA256 派生密钥），让 daemon 以「本地会话」态可用，全程不碰真实登录。
2. **改推理去向**：把 `ANTHROPIC_BASE_URL` 指向本地 `QuotaServer`，代理剥掉 Science 带来的 OAuth、换成你的第三方 key、按需翻译协议，最终打到你选的模型。

## 3. 两种运行形态

| | 隔离沙箱（默认，安全） | 接管真实实例（可选，需自负风险） |
|---|---|---|
| 内部 daemon data-dir | `~/.config/aiusage/science-sandbox/home/.claude-science` | `~/.config/aiusage/science-adopt/home/.claude-science`（**独立**，非真实目录） |
| 对外端口 | 14410（直接监听） | 8765 由**反代 `ScienceAuthProxy`** 占用，内部 daemon 在 14411 |
| 真实实例影响 | 零影响（独立 HOME / 端口 / data-dir） | **不碰真实凭证**，仅改写运行期 `~/.claude-science/operon.lock`（停用即删还原） |
| 目标 | 浏览器免登录使用 | 让双击桌面 app 也稳定免登录 |

两种形态推理链路一致（都经 14402 代理）；接管态额外在 8765 上加一层**注 cookie + 改写 Origin** 的反代，把流量转发到独立的内部 daemon（14411）。

## 4. 端口与常量

所有 Science 端口落在 AIUsage 自有的 **144xx 端口族**（区别于同类工具、避开常用端口）；对外唯一例外是 8765（桌面 app 硬编码默认端口）。定义见 `GlobalProxyConfig.swift`。

| 常量 | 值 | 说明 |
|---|---|---|
| `defaultSciencePort` | 14402 | 本地推理代理（QuotaServer）端口，独立于 Codex/Claude/OpenCode |
| `defaultScienceListenPort` | 14410 | 沙箱 Science `serve --port` |
| `realInstancePort` | 8765 | 接管态**对外端口**（= 桌面 app 默认），由反代 `ScienceAuthProxy` 占用 |
| `realInstanceInternalPort` | 14411 | 接管态**内部 daemon** `serve --port`（反代转发目标） |
| `defaultSandboxEmail` | `aiusage@cslocal.invalid` | 虚拟假账号（**必须以 `.invalid` 保留顶级域结尾**，RFC 2606 永不可解析）；每账号独立 data-dir 与对话历史 |
| admin 路径 | `/__aiusage/admin/claude-upstream` | 进程内热切换上游（复用 Claude 轨路由） |

## 5. 数据流

### 5.1 一键开始（`ScienceProxyManager.start`）

```
1. 起推理代理进程：GlobalProxyRuntime.science.start(port: 14402, env, node)
     └─ env 来自 ClaudeGlobalProxyAdapter.startEnv，但【剥掉 ANTHROPIC_API_KEY】（见 §6.1）
2. 起 Science：
     ├─ 沙箱：ScienceSandbox.prepare → ScienceVirtualLogin.ensure → ScienceSandbox.launch(14410)
     └─ 接管（解耦）：
          ScienceRealAdopt.prepareForAdopt（退桌面 app + 腾空 8765/14411 + 删残留劫持锁）
          → ScienceRealAdopt.startInternalDaemon（独立 data-dir，内部端口 14411）
3. 健康检查：轮询内部 daemon /health（接管态 14411，沙箱态 14410）
3b. 接管态：
     ScienceAuthProxy.start(8765 → 14411) 等 bind .ready
     → ScienceRealAdopt.hijackLock（改写真实 operon.lock: port→8765, sock→adopt, pid→内部daemon真实pid）
     → 自探 GET 8765/ 返回 200 才落激活态，否则整栈回滚报错
4. 持久化激活态；就绪则开浏览器（接管态直接开 http://localhost:8765/）
```

### 5.2 推理请求路径

```
Science daemon
  │ POST http://127.0.0.1:14402/v1/messages
  │ Authorization: Bearer <Science 自造的虚拟 OAuth token>   ← 不是我们的 client key
  ▼
QuotaHTTPServer.handleMessagesEndpoint / handleStreamingProxy
  │ proxy.authenticate(headers) → expectedClientKey == nil → 直接放行（剥离并忽略入站 Bearer）
  ▼
ClaudeProxyService
  │ mapToUpstreamModel(request.model)：claude-opus-*→big / sonnet-*→middle / haiku-*→small
  │ 注入节点真实上游 key，Claude→Canonical→(OpenAI|Anthropic) 转换
  ▼
第三方模型
```

### 5.3 热切换上游节点（`switchActiveNode`）

进程不重启、Science 无感：POST `switchPayload` 到 `/__aiusage/admin/claude-upstream`，运行中替换上游 baseURL / key / 模型映射。

## 6. 鉴权与协议归一

### 6.1 为什么 Science 轨要「剥掉 client key」

这是 Science 轨与 Claude Code 轨最关键的差异，也是「Agent Failed / session no longer valid」的根因。

- **Claude Code 轨**：写 `~/.claude/settings.json`，让 CLI 带固定 `ANTHROPIC_AUTH_TOKEN = client key`；代理校验入站 header == client key。
- **Science 轨**：Science daemon 每次推理都带**它自己铸造的虚拟 OAuth Bearer**，我们无法让它改带固定 client key。若代理仍要求 client key，入站被判 **401** → Science 误报「session 失效」。

解法（strip-and-ignore）：Science 轨启动 env **不设 `ANTHROPIC_API_KEY`**（`ScienceProxyManager.start` 里 `env.removeValue(forKey: "ANTHROPIC_API_KEY")`）→ `ClaudeProxyConfiguration.expectedClientKey == nil` → `authenticate()` 直接返回 `true` → 代理放行入站、剥离并忽略 Science 的 Bearer，再注入节点真实上游 key。安全边界靠「代理只监听回环 127.0.0.1」。

### 6.2 `thinking.type` 归一

Claude Science 发 `thinking.type: "auto"`，而 Anthropic 兼容上游只认 `enabled / disabled / adaptive`。`QuotaHTTPServer+Passthrough.swift` 的 `normalizeThinkingType` 在转发前把非法值归一为 `adaptive`。

### 6.3 模型映射

底部显示的 `claude-opus/sonnet/haiku` 是 Science **写死的 UI 名**，改不了也不用改。代理按档位重映射到你节点配的真实第三方模型（`opus→big / sonnet→middle / haiku→small`），推理**实际走第三方**。

## 7. 接管真实实例（桌面 app 免登录）· 解耦反代方案

让**双击 Claude Science.app / 浏览器打开 `http://localhost:8765`** 都免登录。这是本项目独有、CSswitch 没有的能力，实现集中在 `ScienceAuthProxy` + `ScienceRealAdopt`。

### 7.1 逆向依据（Claude Science daemon 内部机制）

对 `claude-science` 二进制（bun 打包）与桌面启动器（`ClaudeScience`，Swift/Cocoa）反编译得到：

- **登录门是 cookie 会话**（fastify）：`GET /` 必须带 `operon_auth`（HttpOnly cookie）否则 `401 → /login`；`operon_csrf` 供 SPA 读出做 `x-operon-csrf` 双提交。这两个 cookie 只能由加载一次性 nonce 链接（`/?nonce=<nonce>`）时服务端 `Set-Cookie` 下发；nonce 单次、约 3 分钟，可通过控制套接字 `daemon.sock` 的 `POST /nonce` 铸取。cookie 绑定 daemon 本次启动的签名密钥，**daemon 重启即失效**（那句 "session expired"）。
- **同源校验**：对**改状态请求**（发消息 POST、`/api/ws` 长连）daemon 只放行**自身监听端口**的 origin。关键函数：
  - `pf_(O,z) = (z ? z.has(O) : npG.test(O)) || SF(O)`，其中 `npG = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/`。当 daemon 配了 allowlist（`strictOriginRef.value` 为 Set）时走 `z.has(O)`**精确匹配**，只含自身端口 origin。
  - WS 用 `Pb_(origin, strictOrigin ?? strictOriginRef.value)`，同样精确匹配。
  - 因此浏览器带来的 `http://localhost:8765` origin 会被判 `403 forbidden origin`（POST）/ `WS rejected: origin not allowed`（WS）。
  - `SF(O) = no7()?.test(O)`，`no7()` 由 `OPERON_EXTRA_ALLOWED_ORIGINS` 环境变量 + config 的 `extra_allowed_origins` 构成（备选放行途径，本项目未用）。
- **`require_token = false` 被封死**：写进 config 直接拒启动，无法从配置关鉴权。
- **桌面启动器（`ClaudeScience`）行为**：它不是常驻窗口，而是个 launcher——启动时 spawn `claude-science serve --port 8765`。若 8765 被占，daemon `EADDRINUSE` 退出，launcher 走「successor 让位」分支：
  - 检测「是否已有别的 daemon 在服务」——逆向确认走 `pidIsOperonDaemon`：读 `~/.claude-science/operon.lock` 的 `pid`，要求该进程**活着且命令行含 claude-science**。
  - 有 successor → 打印 `successor daemon detected — staying up`，用锁里的 `sock` 铸 nonce，`Opening http://localhost:8765/?nonce=…`，**不弹错**。
  - 无 successor → 弹 `Claude Science daemon exited (status 1) / failed to start`。

### 7.2 实现要点

**`ScienceRealAdopt`（解耦）**
1. 内部 daemon 跑在**独立 data-dir**（`~/.config/aiusage/science-adopt`）、内部端口 14411，铸本地虚拟登录，env 注入 `ANTHROPIC_BASE_URL=14402`。**绝不碰真实 `~/.claude-science` 凭证**——桌面 app 对真实目录的任何 `stop` 都杀不到我们（data-dir 不同）。
2. `hijackLock()`：改写 `~/.claude-science/operon.lock` 的 `port→8765`、`sock→独立 daemon sock`、`pid→内部 daemon 真实 pid`（用 `lsof` 查监听 14411 的 claude-science pid）。真实 pid 是让桌面 app successor 检测「staying up」的关键（早前写占位 pid=1 会被判无 successor → 弹 failed-to-start）。operon.lock 是**运行期状态文件**（非凭证），停用即删还原。
3. `prepareForAdopt()` / `stopAdoptedDaemon()`：退桌面 app、腾空 8765/14411（`freePortIfClaudeScience` 只 `kill` claude-science 进程）、删劫持锁。

**`ScienceAuthProxy`（8765 反向代理，回环 127.0.0.1 + ::1）**
1. `start()` 为 async，等 `NWListener` 到 `.ready` 才返回；bind 失败即抛 `listenFailed`（不再静默假成功）。
2. 通过独立 daemon 的 `daemon.sock` 铸 nonce → `GET /?nonce` 换取 `operon_auth`/`operon_csrf` cookie，内存缓存。
3. 每个请求转发到 14411 时：注入当前有效 cookie；**改写 `Host` / `Origin` / `Referer`**，把浏览器的 `:8765` 换成 daemon 自身 `http://127.0.0.1:14411`——过 daemon 的同源门（否则发消息 403、WS reject）。
4. `/login` → 直接 `302` 到 `redirect` 目标（默认 `/`）；对 `text/html` 响应额外 `Set-Cookie`，使 SPA 能读出 csrf。
5. **WebSocket**（`/api/ws`）：注 cookie + 改写 Origin 后原样双向隧道对拷。
6. 上游 `401` 或 `302→/login`（cookie 因 daemon 重启失效）时**自动重铸 cookie 重试一次**。
7. `probe(listenPort:)`：启动后自探 `GET /` 返回 200 才算就绪。

**顺序建议**：先在 AIUsage 里开「接管真实实例」+ 一键开始（反代占住 8765、锁 pid 对齐内部 daemon），再双击桌面 app，即稳定免登录。若桌面 app 已先占 8765，一键开始会自动腾空再占。

## 8. 虚拟登录（`ScienceVirtualLogin`）

Swift/CryptoKit 实现的本地 OAuth 伪造器（node/rust/swift 三方字节对拍钉死）：

- 加密：AES-256-GCM（v2 格式），密钥用 HKDF-SHA256（`info="operon:aes-256-gcm:oauth"`，AAD=`"v2:oauth"`）派生。
- 产物三件套：`.oauth-tokens/<uuid>.enc`、`encryption.key`、`active-org.json`；`token_expires_at` 设远期 → 绝不触发联网刷新。
- 幂等：完整自洽→复用；部分损坏→修复但保 org（旧对话不丢）；真首次→铸新 org。写入用 `O_EXCL` 临时文件 + rename + `0600`。
- 护栏：
  - **绝不写真实凭证目录**（护栏 0，最高优先）；沙箱与接管都用独立 data-dir。
  - email 必须以 `.invalid` 保留顶级域结尾（`refusedEmail` 否则抛错），保证不可路由假账号。
  - auth_dir 必须解析在隔离根之下（挡符号链接重定向）；写前拒符号链接。
- 钥匙串：沙箱用**独立空密码 login.keychain**（仅作用于该 HOME），消除系统级弹窗、零接触真实钥匙串。

## 9. 文件清单与职责

### 新增（`AIUsage/Services/Science/`）

| 文件 | 职责 |
|---|---|
| `ScienceVirtualLogin.swift` | 虚拟 OAuth 伪造器（GCM/HKDF/幂等/护栏） |
| `ScienceSandbox.swift` | 隔离沙箱：APFS 克隆运行时、独立钥匙串、launch/stop/health、`claude-science url` 取带令牌链接 |
| `ScienceRealAdopt.swift` | 接管真实实例（解耦）：独立 data-dir 起内部 daemon(14411)、劫持/还原真实 `operon.lock`、端口兜底腾空（只杀 claude-science）、查内部 daemon 真实 pid |
| `ScienceAuthProxy.swift` + `+Helpers.swift` | 8765 反向代理：铸 nonce→cookie、注入、改写 Host/Origin/Referer、`/login`→302、HTTP 缓冲 + WS 隧道、401 重铸、bind 就绪等待 + 自探 |

### 新增（ViewModel / View）

| 文件 | 职责 |
|---|---|
| `ViewModels/ScienceProxyManager.swift` | 编排：一键开始/停止/热切换、沙箱 vs 接管分支、错误回滚、浏览器打开 |
| `Views/ScienceProxyManagementView.swift` | 管理页（与 Codex/OpenCode 同风格：Hero 卡 + 配置卡 + 接管开关） |

### 复用 / 改动

| 文件 | 改动 |
|---|---|
| `Models/GlobalProxyConfig.swift` | `.science` 枚举 + `sciencePort/sandboxEmail/adoptRealInstance` + 默认值（144xx 族 + `aiusage.invalid`）+ `effective*` 计算属性 |
| `Services/GlobalProxyRuntime.swift` | `.science` 常驻进程实例、`all`、`instance(for:)`、`trackLabel` |
| `ViewModels/GlobalProxyTrackAdapters.swift` | Science 轨**复用 `ClaudeGlobalProxyAdapter`**（推理即 Anthropic Messages） |
| `Models/AppSettings.swift` | `AppSection.scienceProxyManagement` |
| `Views/SidebarNavigation.swift` | 侧边栏条目（`atom` 图标 / 紫色） |
| `Views/ContentView.swift` | `.scienceProxyManagement → ScienceProxyManagementView` |
| `ViewModels/ProxyViewModel+ProxyServer.swift` | 启动恢复：`ScienceProxyManager.shared.restoreOnLaunch()` |
| `Views/MenuBarView+TrackSwitcher.swift` | `.science` 分支 `EmptyView`（Science 只在侧边栏管理，不进菜单栏） |
| `QuotaBackend/…/QuotaHTTPServer+Passthrough.swift` | `normalizeThinkingType`（`auto`→`adaptive`） |

## 10. 安全铁律（与项目规则一致）

- 凭据只进 Keychain / `0600` 文件，绝不进 UserDefaults 或命令行 / 日志。
- 入站 `Authorization` / `x-api-key` 一律剥离不转发；代理只监听回环。
- 沙箱绝不碰真实 `~/.claude-science`、绝不用 8765。
- 接管态（解耦）**不碰真实凭证**：内部 daemon / 虚拟登录只落独立 `~/.config/aiusage/science-adopt`，仅改写运行期 `operon.lock`（停用即删还原），端口兜底只 `kill` claude-science 进程。
- 不写系统全局环境变量（避免污染真实 Claude Code）。

## 11. 已知限制

1. **桌面 app 免登录依赖「先起接管、反代占住 8765」**：接管态由 `ScienceAuthProxy` 牢占 8765 + 劫持锁写内部 daemon 真实 pid，双击桌面 app 命中 successor 让位 → 免登录。若接管**未在跑**时双击桌面 app，它会用自己的真实登录占 8765（正常行为）。
2. **`claude-science stop` 的连带**：劫持锁写了内部 daemon 真实 pid，手动执行 `claude-science stop` 会顺锁杀到内部 daemon；双击启动流程不调用 stop，真被杀由健康检查兜底重启。
3. **daemon 持续打印 `claudeAiFetch: 401 → treating as logged-out`**：Science 启动阶段访问硬编码 Anthropic 接口失败后的**正常「登出态」降级**，不影响第三方推理。
4. **Anthropic 托管远程 MCP**（`*.mcp.claude.com`）在虚拟登录下不可用（需真实 Anthropic 授权），会被跳过；本地内置 MCP 正常。
5. **MCP apps 的沙箱源（`localhost:8767`）**：其 iframe 直连 8767 不过反代，高级「运行 app」类功能可能仍需登录；核心对话不受影响。

## 12. 排障速查

| 现象 | 根因 | 处置 |
|---|---|---|
| 对话报 "Agent Failed / session no longer valid" | 代理要求 client key，入站 401 | 确认 Science 轨启动剥掉了 `ANTHROPIC_API_KEY`（§6.1） |
| 400 `thinking.type: unknown variant 'auto'` | 上游只认 adaptive/enabled/disabled | `normalizeThinkingType` 是否生效（§6.2） |
| 浏览器/桌面 app 显示 `/login` | 8765 反代没起，或锁未劫持 | 看 8765 是否 AIUsage 占用、`operon.lock` 是否 port=8765；一键开始有自探回滚 |
| 进主页但 "Couldn't send message — forbidden origin" / 新建项目一直重连 | daemon 同源校验拒 8765 origin | 反代是否改写了 Origin/Referer（§7.2.3） |
| 双击桌面 app 弹 "daemon exited (status 1) / failed to start" | 劫持锁 pid 不是活着的 claude-science | `hijackLock` 是否写了内部 daemon 真实 pid（§7.2） |
| 端口占用/孤儿 daemon | 上次异常退出残留 | 一键开始会 `freePortIfClaudeScience` 腾空 8765/14411 |

## 13. 实现状态

- [x] 导航接入（AppSection / 侧边栏 / ContentView）
- [x] `GlobalProxyConfig` 扩展（Science 字段 + 接管开关 + 144xx 端口族 + `aiusage.invalid` 默认值）
- [x] `GlobalProxyRuntime.science` 常驻进程
- [x] 虚拟 OAuth 伪造器（Swift/CryptoKit）
- [x] 隔离沙箱启动器（14410）
- [x] 接管真实实例（解耦）：独立 adopt data-dir + 14411 内部 daemon + 8765 注 cookie 反代
- [x] `ScienceAuthProxy` 反向代理（nonce→cookie / 改写 Host·Origin·Referer / `/login` 302 / WS 隧道 / bind 等待 / 自探）
- [x] 桌面 app successor 让位（劫持锁写内部 daemon 真实 pid）
- [x] 修复推理 401（strip client key）与 `thinking.type`（auto→adaptive）
- [x] 模型映射（档位映射到节点真实第三方模型）
- [x] 管理页 UI（与 Codex/OpenCode 统一，去掉冗余说明文案）
- [x] 编译通过（xcodebuild Debug）
- [x] 端到端实测：浏览器可对话/新建项目；双击桌面 app 免登录不 failed-to-start；真实凭证零改动
