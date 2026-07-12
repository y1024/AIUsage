# CPA 网关菜单深度优化 · 实施总结（v0.14.2）

> 日期：2026-07-13
> 版本：v0.14.2
> 范围：CPA 网关「账号 / 添加上游 / 安全导入」语义与流程重构
> 原则：能力驱动、fail-closed、不删除不覆盖现有 CPA 账号、不改上游 CPA 项目、界面与日志不泄露 Token

## 一、本轮解决的四个根本问题

| # | 问题 | 修复方式 |
| --- | --- | --- |
| 1 | 把“AIUsage 能监控的账号”误认为“CPA 能用的上游” | 新增 `CLIProxyCapabilityMatrix` 能力矩阵，账号角色由已验证适配器与 CPA 内置路由决定 |
| 2 | 核心 OAuth、官方插件、API 上游、迁移、下游客户端混在一起 | “添加账号”重构为“添加上游”向导，五个分区各司其职 |
| 3 | “请使用 CPA 登录”对 Cursor 等无入口服务是误导 | 通用兜底状态删除，替换为结构化状态与真实动作 |
| 4 | 凭证导入无识别、无预览、无去重、同名静默改名 | 全新五阶段安全导入中心 |

## 二、方案评估结论（相对原始方案的修正）

原始方案方向全部得到代码印证并被采纳，以下 6 点在执行时做了修正：

1. **批量上传**：CPA multipart 批量 + 207 Multi-Status 是较新上游能力（PR #2335），固定核对基线 v7.2.69 不可依赖。改为客户端逐文件上传 + 本地聚合逐项结果，对所有 CPA 版本成立，效果一致。
2. **Codex auth.json 专用导入**：复用 token 展开逻辑，但**不写入** `aiusage_credential_id` 托管标记，也不允许 `aiusage-` 文件名前缀（自动重命名为 `imported-`），避免手动导入的文件被托管副本收敛事务误判所有权。
3. **未知类型 fail-closed 的允许名单**：覆盖 CPA 全部核心类型（codex/claude/anthropic/antigravity/kimi/xai/gemini/gemini-cli/vertex/qwen/iflow）并动态并入当前已启用插件的 provider ID，不阻止合法的插件账号迁移。
4. **API 上游 typed 入口**：Gemini/Claude/Codex/Vertex Key 与 Service Account 的专用表单按原方案排期属于后续版本，本轮 API 上游区只保留已验证的 OpenAI-compatible 表单，并明确说明原因（不伪装支持）。
5. **身份级去重范围**：只有 Codex（workspace/account + user）与 Antigravity（project + email）有已验证的原生身份解析器；其余 Provider 导入只做规范化 SHA-256 内容级去重，不猜身份。
6. **文件规模**：新逻辑全部放入新文件，纯逻辑层与 UI、执行层分离。

## 三、信息架构变化

### 账号页

- 主列表**只展示真实存在于 CPA 的上游**：OAuth 账号、插件账号、导入文件、AIUsage 托管副本、API 兼容上游；
- 未同步的 AIUsage 账号不再逐行混入，收敛为顶部一条紧凑入口：“可从 AIUsage 接入 N 个账号 → 去接入”；
- 摘要第 4 格从“可接入候选”改为“AIUsage 副本”（已存在于 CPA 的托管副本数）；
- 筛选器“来自 AIUsage”改为过滤 `aiusage-` 前缀的真实 CPA 副本；
- `unknown` Provider 的账号行显示“无法识别 · 需要检查”。

### 添加上游（原“添加账号”）

| 分区 | 内容 | 关键标记 |
| --- | --- | --- |
| 订阅账号登录 | Codex / Claude / Antigravity / Kimi / xAI | “核心 OAuth” pill |
| 官方插件 | 从 `/v0/management/plugins` + plugin-store 实时读取 | 未安装显示“官方插件 · 尚未安装”，安装并启用后才出现“登录” |
| 从 AIUsage 接入 | 仅 Codex、Antigravity 候选；凭据缺失→“前往订阅账号修复”，损坏→“重新登录”；下方提示行列出需 CPA 独立授权（Kimi/Claude → 一键发起 OAuth）或需插件（Gemini → 跳插件区）的 Provider | 页脚说明仅监控账号为何不在此处 |
| API 上游 | OpenAI-compatible 表单；typed Key/Service Account 编辑器明示留待后续 | 不伪装通用表单 |
| 高级迁移 | 批量导入 CPA 认证文件 + 导入 Codex auth.json 专用入口 | 见下 |

### 接入页

无变化——它本来就只展示下游客户端（Codex CLI、Claude Code、Claude Science、OpenCode），与方案要求一致。

## 四、账号支持矩阵（实现值）

| 服务 | 从 AIUsage 直接同步 | CPA 独立登录 | 呈现位置 |
| --- | ---: | ---: | --- |
| Codex | ✅ | ✅ | 从 AIUsage / 核心 OAuth |
| Antigravity | ✅ | ✅ | 从 AIUsage / 核心 OAuth |
| Claude | ❌（提示行） | ✅ | 核心 OAuth |
| Kimi | ❌（提示行） | ✅ | 核心 OAuth |
| xAI / Grok | ❌ | ✅ | 核心 OAuth |
| Gemini CLI | ❌（提示行→插件区） | 插件 | 官方插件 |
| Cursor / Copilot / Kiro / Droid / Warp / MiniMax 等 | ❌ | ❌ | 不进入 CPA 候选（订阅账号监控不受影响） |

## 五、安全导入中心（五阶段）

1. **选择文件**：多选 JSON；单文件 5 MiB、单批 ≤20 个、总计 ≤20 MiB；拒绝符号链接；不支持 ZIP/文件夹递归。
2. **本地识别**（`CLIProxyAuthImportInspector`，零 I/O 纯逻辑）：
   - 顶层 `type` 允许名单 + 已启用插件 ID，未知类型阻止；无“手动选择类型”下拉框；
   - `type` 与 `provider` 冲突阻止；必需凭据字段缺失阻止；
   - 识别误选的 API Key 配置文件与 Google 服务账号密钥，给出针对性提示；
   - 原始 Codex auth.json 自动展开嵌套 Token 并补 `type: codex`；
   - 剥离 `aiusage_credential_id` 托管标记并在预览中标注。
3. **导入预览**：Provider Logo、检测到的 Provider、脱敏账号标识（邮箱掩码）、Workspace/Project 摘要、大小、插件要求、重复/冲突状态、计划动作。
4. **冲突规划**（`CLIProxyAuthImportPlanner`）：
   - 内容级：规范化 JSON SHA-256，与现有同 Provider 文件完全相同→跳过（不按文件名判断重复）；
   - 身份级：同一强身份不同凭据→逐项确认（默认保留现有）；AIUsage 托管副本→禁止覆盖；批次内同身份多份不同凭据→保守阻止；
   - 同名不同账号→安全重命名并展示最终名称；无“全部覆盖”，不自动删除任何现有 CPA 文件。
5. **执行与结果**：逐文件上传，逐项结果（已导入 / 已重命名导入 / 已覆盖现有 / 重复已跳过 / 保留现有 / 需要插件 / 不支持 / 上传失败 / 已上传待验证）；“已上传待验证”明确提示不要重复导入；仅失败项可重试；整批完成后统一刷新账号池、模型目录与分发状态一次。

## 六、代码变更清单

### 新增文件

| 文件 | 职责 |
| --- | --- |
| `Models/CLIProxyUpstreamCapability.swift` | 能力矩阵（账号角色单一事实来源）与授权提示模型 |
| `Models/CLIProxyAuthImportPlanner.swift` | 导入识别 + 去重/冲突规划 + 会话状态（纯逻辑，无 I/O） |
| `ViewModels/CLIProxyGatewayManager+Import.swift` | 导入编排：读文件、采集现有哈希/身份、执行、逐项结果、整批刷新 |
| `Views/SubscriptionGatewayAddUpstreamSheet.swift` | “添加上游”五分区向导 + OpenAI-compatible 表单 |
| `Views/SubscriptionGatewayImportSheet.swift` | 安全导入中心界面（预览 / 冲突确认 / 结果 / 重试） |
| `Views/SubscriptionGatewayAccountDetailSheet.swift` | 账号详情 Sheet（从账号页拆出） |

### 修改文件

| 文件 | 变更 |
| --- | --- |
| `Models/CLIProxyGatewayModels.swift` | `Compatibility` 从 `.compatible/.unsupported(String)` 改为 `.compatible/.credentialMissing/.credentialInvalid(String)` |
| `ViewModels/CLIProxyGatewayManager.swift` | 候选评估走能力矩阵；不支持 Provider 不再产生候选；新增 `upstreamAuthHints`；移除旧单文件导入 |
| `Views/SubscriptionGatewayAccountsView.swift` | 主列表仅认证文件；顶部紧凑接入入口；删除“请使用 CPA 登录”；文件从 1759 行缩至 ~530 行 |
| `Views/SubscriptionGatewayComponents.swift` | Provider 显示名 / 原生身份摘要提升为共享函数 |
| `Views/SubscriptionGatewayView.swift` / `OverviewView.swift` | “添加账号”→“添加上游”文案与引导 |
| `AIUsage.xcodeproj/project.pbxproj` | 注册 6 个新文件 |
| `docs/CLIPROXYAPI_INTEGRATION_DESIGN.md` | 新增能力矩阵（§4.2）与安全导入中心（§4.5）设计，更新代码结构（§10） |
| `README.md` / `README.zh-CN.md` | CPA 章节补充能力矩阵与安全导入说明 |

## 七、兼容性保证

- 不删除、不自动修改现有 CPA 账号与手动导入的账号；
- 同步 manifest 格式（schemaVersion 1）与六状态单向同步机制不变；
- Codex、Antigravity 托管副本的同步/收敛路径不变；
- Cursor、Copilot 等只是不再作为 CPA 候选展示，订阅账号页的额度监控完全不受影响；
- CPA 更新、运行、模型目录、LAN 与代理分发功能全部保留；
- 不修改 CPA 上游项目，逐文件上传兼容 v7.2.69 固定基线与最新版。

## 八、验证

- `xcodebuild`（AIUsage scheme，arm64 Debug）编译通过，无相关警告；
- 应用可启动运行（Debug 构建）。
- 注：iCloud 同步目录（Desktop）内的 derivedData 会因 `com.apple.fileprovider` 扩展属性导致 codesign 失败，构建需使用 `~/Library/Developer/Xcode/DerivedData` 路径。

## 九、留待后续版本

- Gemini / Claude / Codex / Vertex API Key 与 Vertex Service Account 的类型化编辑器；
- ZIP / 文件夹批量导入；
- 更完整的客户端一键接入与动态插件 Provider 能力展示。
