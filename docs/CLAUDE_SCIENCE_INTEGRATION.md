# Claude Science 代理 · 技术开发文档

> 本文件是「Claude Science 代理」轨的**唯一技术参考**（架构 + 实现 + 逆向依据 + 排障）。新会话从这里即可快速掌握该功能全貌，无需翻阅历史对话。

## 1. 概述

「Claude Science 代理」是 AIUsage 的一条独立代理轨（`GlobalProxyTrack.science`）。目标：**免 Claude 订阅**启动本地的 Claude Science，把它的推理请求经本地 `QuotaServer` 导向你自选的第三方模型（任意 OpenAI 兼容 / Anthropic 端点），同时保留 Science 的工具调用、Skill、MCP、代码执行等原生体验。

```
Claude Science daemon（虚拟登录）
  │  ANTHROPIC_BASE_URL = http://127.0.0.1:14402
  ▼
QuotaServer（复用 Claude 转换链路：剥离入站 Bearer、注入第三方 key、按档映射模型）
  │ GET /v1/models → 当前节点「模型库与定价」的 Science 兼容目录
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
| 对外端口 | 14410 由**反代 `ScienceAuthProxy`** 占用，内部 daemon 在 14412 | 8765 由**反代 `ScienceAuthProxy`** 占用，内部 daemon 在 14411 |
| 真实实例影响 | 零影响（独立 HOME / 端口 / data-dir） | **不碰真实凭证**，仅改写运行期 `~/.claude-science/operon.lock`（停用即删还原） |
| 目标 | 浏览器免登录使用 | 让双击桌面 app 也稳定免登录 |

两种形态都采用“公开反代 → 内部 daemon”：推理统一经 14402；`ScienceAuthProxy` 注入本地 cookie、改写 Origin，并直接返回当前节点 `/api/models`。沙箱为 14410→14412，接管为 8765→14411；只有接管态会改写真实运行期 lock。

## 4. 端口与常量

所有 Science 端口落在 AIUsage 自有的 **144xx 端口族**（区别于同类工具、避开常用端口）；对外唯一例外是 8765（桌面 app 硬编码默认端口）。定义见 `GlobalProxyConfig.swift`。

| 常量 | 值 | 说明 |
|---|---|---|
| `defaultSciencePort` | 14402 | 本地推理代理（QuotaServer）端口，独立于 Codex/Claude/OpenCode |
| `defaultScienceListenPort` | 14410 | 沙箱公开入口，由 `ScienceAuthProxy` 监听 |
| `realInstancePort` | 8765 | 接管态**对外端口**（= 桌面 app 默认），由反代 `ScienceAuthProxy` 占用 |
| `realInstanceInternalPort` | 14411 | 接管态**内部 daemon** `serve --port`（反代转发目标） |
| `defaultScienceSandboxInternalPort` | 14412 | 沙箱态**内部 daemon** `serve --port`（反代转发目标） |
| `defaultSandboxEmail` | `aiusage@cslocal.invalid` | 虚拟假账号（**必须以 `.invalid` 保留顶级域结尾**，RFC 2606 永不可解析）；每账号独立 data-dir 与对话历史 |
| admin 路径 | `/__aiusage/admin/claude-upstream` | 进程内热切换上游（复用 Claude 轨路由） |

## 5. 数据流

### 5.1 一键开始（`ScienceProxyManager.start`）

```
0. 幂等清场：停公开反代、当前模式的独立 daemon/运行期 lock 与推理代理；随后只在 AIUsage 自有 data-dir 中归一旧选择别名
1. 起推理代理进程：GlobalProxyRuntime.science.start(port: 14402, env, node)
     └─ env 来自 ClaudeGlobalProxyAdapter.startEnv，但【剥掉 ANTHROPIC_API_KEY】（见 §6.1）
     └─ 追加当前节点模型库、默认模型和 Science 目录开关（只传模型 ID，不传密钥/定价）
2. 起内部 Science daemon：
     ├─ 沙箱：停止旧直连实例 → ScienceSandbox.prepare → ScienceVirtualLogin.ensure → ScienceSandbox.launch(14412)
     └─ 接管（解耦）：
          ScienceRealAdopt.prepareForAdopt（退桌面 app + 腾空 8765/14411 + 删残留劫持锁）
          → ScienceRealAdopt.startInternalDaemon（独立 data-dir，内部端口 14411）
3. 健康检查：轮询内部 daemon /health（沙箱 14412，接管 14411）；失败即停 daemon + 推理代理
4. 起公开反代并自探：
     ├─ 沙箱：ScienceAuthProxy.start(14410 → 14412)
     └─ 接管：ScienceAuthProxy.start(8765 → 14411) → ScienceRealAdopt.hijackLock
     自探公开端口 GET / 返回 200 才落激活态，否则停反代/daemon/推理代理并还原运行期 lock
5. 持久化激活态；浏览器直接打开公开端口（不再生成或绕行一次性 daemon URL）
```

### 5.2 模型目录路径

Claude Science 启动或打开模型设置时会调用 Anthropic SDK 的 `models.list(limit: 1000)`，也就是请求 `GET http://127.0.0.1:14402/v1/models?limit=1000`。AIUsage 的目录规则：

1. 优先读取活动节点的 `modelLibrary`；旧节点模型库为空时才回退 `defaultModel + big/middle/small`。
2. 精确去重、保留顺序与大小写；拒绝空值、控制字符、超过 512 字节的 ID，最多 1000 项。
3. 为兼容仍会过滤非 `claude-` ID 的 Science 版本，协议适配层发布 Claude 形态的本地选择 ID。当前节点默认项使用 Science 已持久化到旧 frame 的 `claude-opus-4-8` 作为**默认选择槽**，其他当前节点模型使用 `claude-aiusage-v1-<slug>-<fnv64>`。这个槽只代表“当前节点默认模型”，不保留旧模型、不会额外插入兼容项，picker 的条目数和顺序仍与当前节点目录一一对应。节点库真的包含同名 `claude-opus-4-8` 且它不是默认项时，该 raw 模型使用独立哈希 ID，因此不会重复或冲突。
4. Science 会把纯小写 kebab-case（如 `codex-auto-review`）主动显示成 `Internal`。AIUsage 只在 `name/display_name` 序列化时给会命中该规则的名称加一个不可见 U+2060 展示保护符；视觉上仍是原始模型 ID，保护符不会进入模型库、别名哈希、请求体、日志、计价或上游路由。
5. 推理时选择 ID 在本地精确还原为真实模型 ID。当前节点不存在的旧缓存选择安全回退到新节点默认模型，不会误打到旧节点模型。
6. 为使**旧会话也只引用当前目录**，启动前（daemon 已停）与热切换完成后，`ScienceSelectionNormalizer` 会把 AIUsage 自有 sandbox/adopt data-dir 中、不属于当前目录的 `claude-aiusage-v1-*` frame 选择事务性归一到持久默认槽。它绝不扫描/修改真实 `~/.claude-science`，也不改 raw/native ID；数据库 schema 或 `frames` trigger 不在已知白名单时整库跳过。Science 自带 `root_seq` UPDATE trigger 会被事务内临时值规避并在提交前逐行校验恢复，保证对话顺序不变。热切换归一与运行中的 daemon 并发访问同一数据库：SQLite busy timeout（3s）之外，命中 `database is locked / busy` 竞争时会退避 700ms 重试一次，仍失败则报「节点已切换，但无法更新已保存的模型选择」，切换本身不回滚。
7. 只有 Science 进程启用该目录；普通 Claude Code 轨的 opus/sonnet/haiku 映射语义不变。

两种模式的 `ScienceAuthProxy` 都直接拦截最终 `GET /api/models`，返回当前内存快照并设置 `Cache-Control: no-store`。热切换节点时先原子更新 QuotaServer 上游/目录，再替换反代快照，因此沙箱与接管都会立即显示当前节点列表，绕过 Science 后端「成功 5 分钟、失败 60 秒」缓存；响应不含 `fetch_error`，并带节点名和每百万 token 输入/输出价格说明。

### 5.3 推理请求路径

```
Science daemon
  │ POST http://127.0.0.1:14402/v1/messages
  │ Authorization: Bearer <Science 自造的虚拟 OAuth token>   ← 不是我们的 client key
  ▼
QuotaHTTPServer.handleMessagesEndpoint / handleStreamingProxy
  │ proxy.authenticate(headers) → expectedClientKey == nil → 直接放行（剥离并忽略入站 Bearer）
  ▼
ClaudeProxyService
  │ mapToUpstreamModel(request.model)：Science 别名→精确真实模型；否则 opus/sonnet/haiku→三档模型
  │ 注入节点真实上游 key，Claude→Canonical→(OpenAI|Anthropic) 转换
  ▼
第三方模型
```

### 5.4 热切换上游节点（`switchActiveNode`）

进程不重启、Science 无感：POST `switchPayload` 到 `/__aiusage/admin/claude-upstream`，把上游 baseURL / key、三档映射、模型目录和默认模型作为一次受 admin token 保护的更新原子换入。两种模式随后替换 `ScienceAuthProxy` 的目录快照，并把 AIUsage 自有数据库中的失效 transport alias 归一到当前默认槽；不重启 daemon 或登录会话。

## 6. 鉴权与协议归一

### 6.1 为什么 Science 轨要「剥掉 client key」

这是 Science 轨与 Claude Code 轨最关键的差异，也是「Agent Failed / session no longer valid」的根因。

- **Claude Code 轨**：写 `~/.claude/settings.json`，让 CLI 带固定 `ANTHROPIC_AUTH_TOKEN = client key`；代理校验入站 header == client key。
- **Science 轨**：Science daemon 每次推理都带**它自己铸造的虚拟 OAuth Bearer**，我们无法让它改带固定 client key。若代理仍要求 client key，入站被判 **401** → Science 误报「session 失效」。

解法（strip-and-ignore）：Science 轨启动 env **不设 `ANTHROPIC_API_KEY`**（`ScienceProxyManager.start` 里 `env.removeValue(forKey: "ANTHROPIC_API_KEY")`）→ `ClaudeProxyConfiguration.expectedClientKey == nil` → `authenticate()` 直接返回 `true` → 代理放行入站、剥离并忽略 Science 的 Bearer，再注入节点真实上游 key。安全边界靠「代理只监听回环 127.0.0.1」。

### 6.2 `thinking.type` 归一

Claude Science 发 `thinking.type: "auto"`，而 Anthropic 兼容上游只认 `enabled / disabled / adaptive`。`QuotaHTTPServer+Passthrough.swift` 的 `normalizeThinkingType` 在转发前把非法值归一为 `adaptive`。

### 6.3 模型映射

模型设置现在显示当前节点「模型库与定价」里的真实名称。Science 内部使用兼容选择 ID，代理按以下优先级解析：

1. 当前 Science 选择 ID → 该目录项的精确真实 ID；其中持久默认选择槽 `claude-opus-4-8` 始终解析为当前节点默认模型；
2. 当前节点库中的 raw ID → 精确原样直通；
3. 旧节点残留的 `claude-aiusage-v1-*` → 当前节点默认模型；
4. 其他 `claude-opus/sonnet/haiku` 兼容请求 → 原有 big/middle/small 三档映射。

因此库里的原生 Claude 型号也不会再因为名称含 `opus/sonnet/haiku` 而被二次改写。日志和计价仍记录还原后的真实 `upstream_model`，继续命中现有模型库定价。

## 7. 接管真实实例（桌面 app 免登录）· 解耦反代方案

让**双击 Claude Science.app / 浏览器打开 `http://localhost:8765`** 都免登录。这是本项目独有、CSswitch 没有的能力，实现集中在 `ScienceAuthProxy` + `ScienceRealAdopt`。

### 7.1 逆向依据（Claude Science daemon 内部机制）

对 `claude-science` 二进制（bun 打包）与桌面启动器（`ClaudeScience`，Swift/Cocoa）反编译得到：

- **登录门是 cookie 会话**（fastify）：`GET /` 必须带 `operon_auth`（HttpOnly cookie）否则 `401 → /login`；`operon_csrf` 供 SPA 读出做 `x-operon-csrf` 双提交。nonce 单次、约 3 分钟，可通过控制套接字 `daemon.sock` 的 `POST /nonce` 铸取。旧版在加载 `GET /?nonce=<nonce>` 时下发 cookie；0.1.15 系列改为同源表单 `POST /api/auth/nonce`（`nonce=<nonce>&dest=/`）。cookie 绑定 daemon 本次启动的签名密钥，**daemon 重启即失效**（那句 "session expired"）。
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
1. `start()` 先完成 nonce → cookie 会话初始化，再等 `NWListener` 到 `.ready`；认证初始化或 bind 失败都会抛出明确错误，不再静默带病启动。
2. 首选通过独立 daemon 的 `daemon.sock` 铸 nonce；兼容 Content-Length、chunked、嵌套 nonce/登录 URL 等响应。私有响应格式变化时，回退到同版本官方 CLI `claude-science url --data-dir`。
3. nonce 严格编码；先走 0.1.15+ 的同源表单 `POST /api/auth/nonce`，若未下发会话 cookie，再用同一 nonce 回退旧版 `GET /?nonce=...`。旧版拒绝 POST 时不会消耗 nonce，因此双协议可共存。会话 cookie 从所有 `Set-Cookie` 动态提取，不再只硬编码 `operon_auth`/`operon_csrf`，并在内存缓存。
4. 每个请求转发到 14411 时：注入当前有效 cookie；**改写 `Host` / `Origin` / `Referer`**，把浏览器的 `:8765` 换成 daemon 自己公布的 `http://localhost:14411`——通过新版 daemon 更严格的 authority/同源检查。
5. `/login` → 直接 `302` 到 `redirect` 目标（默认 `/`）；对 `text/html` 响应额外 `Set-Cookie`，使 SPA 能读出 csrf。
6. **WebSocket**（`/api/ws`）：注 cookie + 改写 Origin 后原样双向隧道对拷。
7. 上游 `401` 或 `302→/login`（cookie 因 daemon 重启失效）时**自动重铸 cookie 重试一次**；重铸失败直接返回 503，不再无 cookie 透传。
8. `probe(listenPort:)`：不跟随登录重定向，启动后自探 `GET /` 直接返回 200 才算就绪；失败输出脱敏的 status、Location、Content-Type 与正文摘要。

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
| `ScienceSandbox.swift` | 隔离沙箱：APFS 克隆运行时、独立钥匙串、内部 daemon launch/stop/health |
| `ScienceRealAdopt.swift` | 接管真实实例（解耦）：独立 data-dir 起内部 daemon(14411)、劫持/还原真实 `operon.lock`、端口兜底腾空（只杀 claude-science）、查内部 daemon 真实 pid |
| `ScienceAuthProxy.swift` + `+Helpers.swift` | 沙箱 14410 / 接管 8765 的公开反向代理：兼容型 nonce→cookie 初始化（CLI 回退）、动态 cookie 注入、localhost authority 改写、`/login`→302、HTTP/WS 转发、401 重铸、脱敏自探；两种模式都直接提供无缓存的当前节点模型目录 |
| `ScienceSelectionNormalizer.swift` | 仅限 AIUsage 自有 sandbox/adopt 数据库的旧选择归一：SQLite busy timeout + 事务、schema/trigger 白名单、`root_seq` 原值校验、raw/native ID 与真实目录硬护栏 |
| `ScienceManagedDaemonStopper.swift` | 兜底停止 AIUsage 自管 daemon（Science 未安装 / 另一模式崩溃残留）：仅接受两个固定 AIUsage data-dir，JSON lock PID + 命令行同时命中 `claude-science` 与精确 `--data-dir` 才发 SIGTERM；每次 teardown 顺带清扫另一模式的残留 |

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
| `QuotaBackend/…/ScienceModelProtocolAdapter.swift` | Science 协议适配边界：目录规范化、选择 ID、展示保护、选择 ID→raw 精确解析与旧选择安全回退 |
| `QuotaBackend/…/ClaudeProxyConfiguration.swift` | 持有协议适配结果，并把 Science 选择解析接入既有模型路由 |
| `QuotaBackend/…/QuotaHTTPServer.swift` + `+ClaudeProxy.swift` | Science 专用 Anthropic `GET /v1/models`；热切换时原子替换上游与目录 |
| `QuotaBackend/…/QuotaHTTPServer+Passthrough.swift` | `normalizeThinkingType`（`auto`→`adaptive`）及发送前模型别名解析 |

## 10. 安全铁律（与项目规则一致）

- 凭据只进 Keychain / `0600` 文件，绝不进 UserDefaults 或命令行 / 日志。
- 入站 `Authorization` / `x-api-key` 一律剥离不转发；代理只监听回环。
- 沙箱绝不碰真实 `~/.claude-science`、绝不用 8765。
- 旧选择归一只接受两个 AIUsage 固定 data-dir，解析符号链接后再次校验；只改失效的 `claude-aiusage-v1-*`，未知 schema/trigger 整库 fail-closed。
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
| 模型设置显示默认 Claude 型号并提示 `Couldn't load the full model list` | 本地 `/v1/models` 未启用、Science 仍连接旧版 QuotaServer，或目录为空 | 重启 Science 轨使新 env 生效；检查 `GET :14402/v1/models?limit=1000` 应返回当前节点真实模型名（部分 JSON 名称会带不可见 U+2060，§5.2） |
| 模型名显示 `Internal` | 原始名称命中 Science 的 lowercase-kebab 隐藏规则，或仍在运行未带展示保护符的旧代理 | 重启 Science 轨并刷新页面；确认 `/api/models.name` / `/v1/models.display_name` 视觉文本为节点原始模型名（§5.2） |
| 旧会话显示 `… · unavailable` | frame 仍引用旧节点的 transport alias，或数据库 schema/trigger 已变化而被安全跳过 | 重启到新版目录；normalizer 会把 AIUsage 自有数据库里的失效 `claude-aiusage-v1-*` 归一到当前默认槽，但不会向 picker 添加旧模型、不会改 raw/native ID 或真实 Science 数据（§5.2） |
| 浏览器/桌面 app 显示 `/login` | 公开反代没起；接管态也可能是锁未劫持 | 沙箱查 14410→14412，接管查 8765→14411 与 `operon.lock`；一键开始有公开端口自探回滚 |
| `stage=mint-nonce` / `stage=exchange-cookies` | daemon 控制端点或会话协议变化 | 查看错误中的脱敏 status/Location/Content-Type/body；不会记录 nonce、cookie 或 token |
| 进主页但 "Couldn't send message — forbidden origin" / 新建项目一直重连 | daemon 同源校验拒 8765 origin | 反代是否改写了 Origin/Referer（§7.2.3） |
| 双击桌面 app 弹 "daemon exited (status 1) / failed to start" | 劫持锁 pid 不是活着的 claude-science | `hijackLock` 是否写了内部 daemon 真实 pid（§7.2） |
| 端口占用/孤儿 daemon | 上次异常退出残留，或用户把代理/公开入口配到内部保留端口 | 默认布局为代理 14402、沙箱 14410→14412、接管 8765→14411；启动前会拒绝重复/保留端口，接管还会安全腾空 8765/14411 |

## 13. 实现状态

- [x] 导航接入（AppSection / 侧边栏 / ContentView）
- [x] `GlobalProxyConfig` 扩展（Science 字段 + 接管开关 + 144xx 端口族 + `aiusage.invalid` 默认值）
- [x] `GlobalProxyRuntime.science` 常驻进程
- [x] 虚拟 OAuth 伪造器（Swift/CryptoKit）
- [x] 隔离沙箱：14412 内部 daemon + 14410 注 cookie/目录反代
- [x] 接管真实实例（解耦）：独立 adopt data-dir + 14411 内部 daemon + 8765 注 cookie 反代
- [x] `ScienceAuthProxy` 两模式公开反向代理（兼容型 nonce→cookie / CLI 回退 / 动态 cookie / localhost authority / WS 隧道 / 脱敏自探）
- [x] 桌面 app successor 让位（劫持锁写内部 daemon 真实 pid）
- [x] 修复推理 401（strip client key）与 `thinking.type`（auto→adaptive）
- [x] 节点模型库目录（Anthropic `/v1/models` + Science 兼容别名 + 精确真实模型路由）
- [x] 沙箱与接管即时模型列表（公开反代拦截 `/api/models`，热切换不受 Science 5 分钟缓存影响）
- [x] 旧会话选择归一（仅 AIUsage 自有 DB、事务/schema/trigger/root_seq 护栏，picker 不混入旧节点目录）
- [x] 旧别名安全回退、原始目录 ID 精确直通、普通 Claude Code 三档映射隔离
- [x] 管理页 UI（与 Codex/OpenCode 统一，去掉冗余说明文案）
- [x] 编译通过（xcodebuild Debug）
- [x] 端到端实测：浏览器可对话/新建项目；双击桌面 app 免登录不 failed-to-start；真实凭证零改动
