# Claude Desktop 一键接入指南

> 适用范围：AIUsage 的 `Claude → Desktop` 功能。它把 Claude Code 代理节点中的任意第三方模型接入 Claude Desktop 官方 3P Gateway；它不是 Science 的虚拟登录，也不会退出或替换你的 Anthropic 账号。

## 1. 一分钟使用

1. 在侧边栏打开 `Claude`，选择顶部 `Desktop / 桌面端接入`。
2. 在共享路由卡中选择一个已经配置模型库的 Claude 节点。
3. 选择 `热切换三档` 或 `节点全部模型`；再按需打开 `模型设置`，为确实支持 1M 上下文的真实模型开启 `1M`。
4. 点 `一键接入 Desktop`。
5. AIUsage 会准备 localhost HTTPS、启动共享 Gateway、应用自有 3P profile，并重新打开 Claude Desktop。
6. 配置与本机端口正常后显示 `已接入`；当 Claude Desktop 的第一条真实请求到达 AIUsage 后，状态变为 `已连接`。

断开时点 `断开并恢复`。AIUsage 会按连接前快照恢复配置、关闭 Desktop HTTPS 监听，并退出正在运行的 Claude Desktop；它不会再次自动打开。下次手动打开 Desktop 时会读取已恢复的配置。

## 2. 页面怎么读

### 顶部三个产品入口

- `Code / 代理与节点`：管理 Claude Code 使用的节点与全局代理。
- `Desktop / 桌面端接入`：把同一批节点接入 Claude Desktop 官方 3P 模式。
- `Science / 研究工作台`：独立的 Science 沙箱/接管流程。

Code 与 Desktop 共享 Claude Gateway 和当前节点，但使用独立客户端密钥与独立配置生命周期。Desktop 可以单独接入，并不要求先开启 Code 全局代理；如果两端同时接入，切节点会同步影响两端。Science 只共享节点库，不共享运行时或登录状态。

### Desktop HTTPS 端口

- 页面底部直接显示独立的 `Desktop HTTPS 端口` 输入框，默认 `14403`，所有 Desktop 节点统一使用；
- 已接入时端口不可修改，先断开再保存，下一次接入生效；
- 节点编辑器不再需要单独开启 HTTPS。节点只负责上游协议、密钥和模型；Desktop 页面统一负责 TLS、证书与本机端口。
- 端口卡右上角的问号包含完整地址、重启恢复语义、安全边界和断开行为，主页面不重复铺陈这些说明。

### 状态

| AIUsage 状态 | 含义 |
|---|---|
| 未接入 | 没有由 AIUsage 管理 Desktop profile |
| 准备中 | 正在准备证书、Gateway、profile 或重启 Desktop |
| 已接入 | profile 与本机 HTTPS 端口已就绪，但本次 AIUsage 启动后尚未观测到 Desktop 的真实请求 |
| 已连接 | 已确认真实 Desktop 请求到达当前 Gateway |
| 已保护 | 当前 `appliedId` 已切到其它 profile；“断开”不会覆盖它，再次明确点击“一键接入”可授权 AIUsage 接管 |
| 需要处理 | 某一阶段失败；错误应说明发生在配置、连接还是上游 |

`已连接`只证明 Desktop → AIUsage 的本地链路成立。如果上游节点返回 401、429、502 或模型错误，AIUsage 仍应保留“本地已连接”事实，并单独显示上游故障。

AIUsage 重启后会重新启动已接入 Desktop 所需的本机 HTTPS 端口，路线会保持点亮；`已连接`不会跨进程沿用，因为它只代表本次运行实际收到过请求。即使关闭通用的“启动时恢复代理”，已被 Desktop profile 引用的本机端口也仍会恢复，避免留下可见配置却没有服务。

## 3. 两种 Desktop 模型模式

### 热切换三档

Desktop 始终显示 `AIUsage Opus / Sonnet / Haiku` 三个稳定档位。三条安全 Model ID 不随节点变化，Gateway 在内部把它们映射到当前节点的 big / middle / small 模型。切换共享节点后，下一条请求立即走新目标，不重写 Desktop 可见目录，也不重启 Desktop。

适合频繁切节点、希望模型选择器保持简洁的用户。

### 节点全部模型

Desktop 显示当前节点模型库中的全部模型，Display name 保留真实模型名称。AIUsage 仍会为每个真实模型生成符合 Desktop 校验规则的安全 Model ID，Gateway 再把该 ID 精确映射回真实上游；真实第三方 slug 不会直接塞进 route ID。

适合主要使用单个节点、希望明确选择该节点全部模型的用户。切换节点或修改模型库时，Gateway 会先热切换上游；由于 Desktop 的可见目录也发生了变化，AIUsage 会重载正在运行的 Desktop。Desktop 未运行时则只更新配置，下次打开自然读取新目录。

### Model ID、Display name 与真实上游

Claude Desktop 对 Gateway 的 Model ID 有严格校验。AIUsage 把三个概念分开：

| 字段 | 示例 | 用途 |
|---|---|---|
| Model ID | `claude-sonnet-4-6-aiusage-v1` | Desktop 接受的安全路由；智能模式固定，完整模式按真实模型稳定派生 |
| Display name | `AIUsage Sonnet` 或 `codex-auto-review` | 智能模式显示档位；完整模式显示真实名称 |
| Upstream model | `codex-auto-review` | AIUsage 当前节点实际接收的模型 |

为什么 Model ID 不能直接写 `codex-auto-review`、`gpt-*` 或 `gemini-*`：Claude Desktop 1.12603.1 会拒绝包含已知第三方标记的 Gateway route。即使前面添加 `claude-sonnet-`，只要 ID 后半段还出现 `codex`、`gpt`、`gemini`、`glm`、`qwen`、`deepseek` 等词，整份 `inferenceModels` 仍可能被判无效。

因此两种模式都使用 Claude 形态的安全 route：智能模式固定三条 route；完整模式为模型库中的每个真实模型派生安全 route，并只在 Display name、AIUsage 映射和调用日志中保留真实名称。

## 4. 逐模型 1M 开关

在 `模型设置` 中，每个条目都对应当前节点的一个真实上游模型，并有独立的 `1M` 开关。设置按“节点 + 真实模型 ID”保存，并同步到：

- AIUsage 自有 Desktop profile 的 `inferenceModels[].supports1m`；
- 本地 `/v1/models` 返回的 `supports1m`；
- 当前 Gateway 的热切换 payload。

默认关闭。只有上游供应商明确支持该上下文长度时才开启；此开关只让 Desktop 提供 1M variant，不能让本来不支持 1M 的模型获得额外能力。

### Desktop 是否支持节点热切换？

支持，但表现取决于模型模式：`热切换三档`的可见目录固定，节点切换完全发生在常驻 Gateway 内，下一条请求立即生效且 Desktop 不重启；`节点全部模型`同样先热切换 Gateway，但为了让 Desktop 显示新节点的真实模型列表，会自动重载正在运行的 Desktop。`supports1m` 等可见能力变化在两种模式下都会触发必要的重载。

### Science 为什么不需要这两种模式？

Science 有独立 Gateway 和网页目录，始终使用当前 Science 节点的完整真实模型列表。切换 Science 节点时，AIUsage 会热更新它的上游和模型目录，不重启 Science daemon；刷新 Science 网页即可取得最新列表。它不共享 Code/Desktop 的活动节点，因此不会被 Code 全局代理或 Desktop 模式切换带动。

## 5. 常见问题

### `Invalid custom3p enterprise config: inferenceModels`

含义：Claude Desktop 在启动阶段拒绝了 Model ID，Gateway 还没有收到业务请求。

处理：

1. 确认使用的是包含 opaque route 修复的新版本 AIUsage。
2. 断开并重新接入，让 profile 重新生成。
3. 新生成的第三方 Model ID 不应包含真实 upstream slug；热切换三档应使用固定 route（如 `claude-sonnet-4-6-aiusage-v1`），节点全部模型应使用 AIUsage 派生的安全 route。
4. 在 AIUsage 的模型设置中检查“当前目标”；不要通过修改 Desktop 的 Display name 来修路由。

### 只有 legacy model

通常是 `inferenceModels` 中任意一项校验失败导致整批目录不可用。检查所有 Model ID，而不是只检查当前选中的模型。

### AIUsage 显示“已连接”，Claude 显示 Gateway 502

这说明 Desktop 配置、证书、鉴权和本地路由已经工作，失败发生在 AIUsage → 当前节点上游：

1. 在 `Code / 代理与节点` 检查所选节点是否可用。
2. 核对节点 Base URL、协议模式（Anthropic / OpenAI Chat / OpenAI Responses）和上游服务状态。
3. 切换到一个已验证可用的节点后再次测试。

不要把上游 502 当作 Desktop 未接入；两者的处理方向完全不同。

### `The configured API key was rejected by the inference provider`

如果 DeepSeek 等直连节点正常、只有 `CPA 网关` 返回该错误，问题通常不在 Desktop 的模型选择，而在 AIUsage → CPA 的本地 client key。旧版本中，CPA 重建 Keychain、轮换托管 key，或正式版与 Debug 版同时运行时，已分发节点及运行中的 Desktop Gateway 可能仍保存旧 key，因此 CPA 返回 401。

当前实现会在 AIUsage 启动和 CPA 运行状态变化时自动修复：

1. 只读取 CPA 进程实际加载配置中的 AIUsage 自有 client key；不会借用共享配置里其它客户端创建的 key；
2. 更新 `CPA 网关` 主配置；
3. 同步现有 Codex、Claude、OpenCode 链接节点；
4. 若相关代理正在运行，即使只有 Desktop consumer，也重新推送上游配置。

更新到包含该修复的构建并重新打开 AIUsage 即可，不需要手工复制 key。若 CPA 配置存在但只包含外部工具创建的 key，AIUsage 会停止自动接管并要求重新生成自己的托管 key，避免误用其它客户端凭据。自动修复后仍为 401 时，再检查 AIUsage 托管 key 是否被主动禁用；普通第三方 Anthropic 节点则应检查节点自身的上游 API key。

### 一直停在“已接入”

这表示 profile 已应用但 AIUsage 没看到真实 Desktop 请求。可依次检查：

1. Claude Desktop 是否完成重启。
2. Desktop 是否显示第三方 Gateway，而不是另一套登录/企业配置。
3. 本机证书是否被信任。
4. 其它 profile 工具是否在 AIUsage 之后切换了 `appliedId`。

AIUsage 不会为解决此问题自动退出 Anthropic 账号，也不会清除全局 Claude Code OAuth。

## 6. 配置安全与恢复

AIUsage 管理自己的稳定 profile，并在首次接入前保存四个目标文件的字节快照、存在性和权限。写入使用 advisory lock、原子替换与 durable journal。

- Desktop 使用独立随机客户端 key；不复用上游 key。
- Gateway 默认只监听 localhost。
- profile、journal 和相关配置保持 `0600`。
- 断开时只有 AIUsage 仍拥有当前 profile 才执行恢复。
- 若其它工具已切换 profile，AIUsage进入保护状态，不覆盖对方修改。
- App 在 apply 中途退出时，下次启动先恢复未完成事务。

架构、测试矩阵和剩余交付项见 [Claude Desktop 集成规划与架构](./CLAUDE_DESKTOP_INTEGRATION.md)。
