# 多工作区账号身份链：Codex / Antigravity 去重与全链路逻辑

## 核心原则

Codex 与 Antigravity 都是 multi-workspace Provider：**同一 email 可以属于多个 Codex 工作区或多个 Antigravity project**，显示名称和导入路径也可能变化。

因此不能只按 email、套餐或单个未定型的 account 字段合并。`AccountCredentialStore.multiWorkspaceProviders` 当前包含 `"codex"` 与 `"antigravity"`：凭据层优先使用完整的 provider-native identity，缺少完整字段时才回退到 **sourceFilePath** / **credentialId**，并且不跨路径猜测合并。

- Codex：规范化的 `chatgpt_account_id/accountId + chatgpt_user_id/userId/sub`；套餐只用于展示，升降套餐不改变身份。
- Antigravity：规范化的 `projectId + accountEmail`；同邮箱不同 project 始终分离。

## 已知的 accountId 问题

| 现象 | 原因 |
|------|------|
| 历史 API 结果与 credential 中的 accountId 语义不一致 | 旧链路混用了用户级结果 ID 与 JWT `chatgpt_account_id` |
| API 失败后 accountId 格式变化 | 引擎可能回退到 credential 中的原生 workspace ID |

因此 **accountId 不能单独作为 Codex 账号的唯一标识**；只有与 user discriminator 组合后才是强原生身份。

## 唯一性策略

| 标识 | 稳定性 | 来源 | 用途 |
|------|--------|------|------|
| Codex account + user | 强身份 | auth JSON / JWT | 跨导入路径合并同一原生账号 |
| Antigravity project + email | 强身份 | auth JSON metadata | 跨导入路径合并同一原生账号 |
| sourceFilePath | 本机稳定回退 | auth 文件路径（归一化后） | 原生身份不完整时只在同路径内匹配 |
| credentialId | AIUsage 内部稳定 | 凭证创建时生成的 UUID | 已绑定记录的直接关联 |
| providerResultId | 稳定 | `provider:cred:<credentialId>` | credentialId 的载体 |
| planType | 可变化 | JWT | 仅展示，不进入 Codex 身份 key |
| email | 非单独身份 | JWT / metadata | Codex 仅展示；Antigravity 必须与 projectId 组合 |

## 单一事实来源

`multiWorkspaceProviders` 与 provider-native credential identity 定义在 `AccountCredentialStore`，所有层级通过委托访问：

```
AccountCredentialStore.multiWorkspaceProviders = ["codex", "antigravity"]
    ↑ AccountCredentialStore.isMultiWorkspace(_:)
    ↑ AccountIdentityPolicy.isMultiWorkspace(_:) ← 代理委托
    ↑ ProviderEngine.identityKey ← 直接调用 AccountCredentialStore.isMultiWorkspace

AccountCredentialStore.canonicalIdentityKey(for:)
    ├─ codex: accountId + userId
    └─ antigravity: projectId + email
AccountCredentialStore.credentialsShareCanonicalIdentity(_:_:)
    └─ 完整原生身份优先；不完整身份只允许同 auth path 回退
```

避免了各层分别硬编码 `["codex"]`，从而遗漏 Antigravity 或让两个 Provider 的身份规则漂移。

## sourceFilePath 全链路贯穿

从数据采集到存储的完整链路：

```
自动扫描分支：
  AuthContext.url.path
    → AccountFetchResult.sourceFilePath
    → ProviderSummary.sourceFilePath
    → ProviderData.sourceFilePath
    → StoredProviderAccount.sourceFilePath
    → reconcile（路径 1:1 匹配）

凭据分支：
  credential.credential（authFile 路径）
    → credentialSourceFilePath(for:)
    → ProviderSummary.sourceFilePath（补齐）
    → ProviderData.sourceFilePath
    → 与自动扫描分支在 identityKey 上汇合
```

每个 Codex workspace 的 auth 文件路径天然唯一，所以 sourceFilePath 做到 1:1 精确匹配。

路径归一化通过 `AccountCredentialStore.normalizedAuthFilePath` 实现：
`expandTilde → resolvingSymlinksInPath → standardizedFileURL → precomposedStringWithCanonicalMapping(NFC) → lowercased`

`resolveAllAuthContexts` 的去重也使用 `resolvingSymlinksInPath().standardizedFileURL.path`，与归一化对齐。

## 引擎层合并 — `ProviderEngine`

### identityKey（合并去重的核心）

对 Codex（path 优先，因为自动扫描无 credentialId 但总有 path）：

```
sourceFilePath 存在 → codex:path:<normalizedPath>
credentialId 存在 → codex:cred:<credentialId>
均缺失 → codex:generic:<resultId>
```

对其他 Provider：`accountId → label/email → generic`

### fetchMultiAccount 的 uniqueId

有 path 时 uniqueId = `codex:auto:<accountId>:path:<normalizedPath>`，确保同 user-xxx 的不同 workspace 不碰撞。

### 凭据分支 sourceFilePath 补齐

`credentialSourceFilePath(for:)` 从 `.authFile` 凭据中提取路径写入 summary，**优先使用 `metadata["sourcePath"]`（原始路径）**，而非 managed import 后的副本路径。这确保凭据分支和自动扫描分支在 `identityKey` 上汇合为同一个 key（两者都指向原始 auth 文件），避免同一 workspace 出现两条记录。

### mergeResults 失败过滤

失败凭据是否保留的判断使用 `identityKey`（对 Codex 走 path 维度）而非 `accountId`，避免 Plus/Team 共享 `user-xxx` 导致错误过滤。

## 存储层策略 — `AccountIdentityPolicy`

**文件**: `AccountStore+Persistence.swift`

### identityKey（存储去重 key）

对 Codex（credentialId 优先，因为持久化账号一般有 credentialId）：

```
credentialId 存在 → codex:cred:<credentialId>
sourceFilePath 存在 → codex:path:<normalizedPath>
均缺失 → codex:stored:<uuid>（不合并）
```

### bestStoredAccountIndex — 结果→存储匹配链

对 Codex：

```
Step 0:   credentialId 精确匹配
Step 0.5: sourceFilePath 归一化路径匹配 → 命中即返回
未命中 → 返回 nil（不继续 fallback）
```

对其他 Provider：

```
Step 0: credentialId
Step 1: accountId
Step 2: matchesLive（providerResultId / email）
Step 3: allowUnseenCredentialFallback
```

### matchesLive — 存储→活跃匹配

对 Codex：credentialId → sourceFilePath → 未命中返回 false（不走 accountId/email）

### bestCredentialMatch — 凭证→账号关联

对 Codex：仅通过 `providerResultId` 中提取的 credentialId 直接匹配，无 fallback。
`matchingCredentialsImpl` 对 Codex 在直接 credentialId 匹配之外返回空数组。

### reconcile dupe check

对 Codex：credentialId 匹配 → sourceFilePath 匹配 → 均不匹配则创建新账号。

### existingAuthenticatedCredential — 登录去重

对 multi-workspace Provider，先调用 `credentialsShareCanonicalIdentity`：完整 Codex account+user 或 Antigravity project+email 相同即可安全复用。只有强身份未命中时，后续旧式 fallback 才受 `isMultiWs` 守卫：

1. **sourceIdentifier 精确匹配** → `!isMultiWs` 跳过（Codex 的 `sourceIdentifier` = `codex-oauth:~/.codex/auth.json`，所有 workspace 共享，不能用于区分）
2. **sessionFingerprint** → `!isMultiWs` 跳过
3. **accountId 匹配** → `isMultiWs` 直接 return false（`user-xxx` 是用户级 ID，Plus/Team 相同，无法区分 workspace）
4. **accountId 不一致** → return false
5. **isMultiWs 兜底** → return false
6. **email 回退** → 只有非 multiWs 才可达

结果：同一完整原生身份可以复用；不同工作区/project、已知字段冲突或身份不完整且路径不同的登录仍创建独立凭据，不会退回 email 猜测。

### hidden 复活分支

API 失败时不覆盖 stored accountId（`isLiveSuccess` 守卫，与正常分支行为一致）。

### removeAutoDiscoveredDuplicates

两段裁剪均有 `!isMultiWorkspace(key)` 守卫：
- 无凭证+同 email：跳过 Codex
- 无@邮箱+有有效邮箱 provider：跳过 Codex

### stripCompositeAccountIds

跳过 Codex，保留复合 accountId 不拆分（避免 Plus/Team 的 accountId 变相同）。

## UI 匹配层 — `AccountStore+Matching.swift`

- `bestStoredAccountIndex(for entry:)`：Codex 走 path 匹配
- `matchingStoredAccountIndices`：Codex 仅按 path 匹配
- `matchingCredentialsImpl`：Codex 除已绑 credentialId 外返回空数组（无 email 猜测）

## 激活态检测 — `ProviderActivationManager`

### isActiveAccount

对 Codex：用 `AccountCredentialStore.normalizedAuthFilePath(entryPath)` 与存储的 activeId 比较，不用 accountId/email。

### detectActiveCodexAccount

启动时检测当前活跃的 Codex workspace：
1. 检查 `~/.codex/auth.json` 是否存在
2. 优先按 `stored.sourceFilePath` 直接匹配（自动发现账号）
3. 未命中时，遍历凭据的 `metadata["sourcePath"]` 做归一化匹配（managed import 账号的原始路径回落）
4. 仅 auth 文件**不存在**时才清空 activeId，**未匹配**时保持先前状态

### activateCodexAccount

切换激活时，优先存储 `normalizedAuthFilePath(entryPath)` 作为 activeId。

## liveProviderIdentity — UI 分组

对 Codex，用 `sourceFilePath` 归一化后的路径分组，确保同 email 不同 workspace 的 live 数据不会被合并为一行。

## Keychain 凭证去重 — provider-native canonical identity

| Provider / 完整性 | canonical identity | 说明 |
|-------------------|--------------------|------|
| Codex 完整 | `codex:account:<accountId>:user:<userId>` | account 与 user 都一致才跨路径合并；plan/email 不参与 |
| Antigravity 完整 | `antigravity:project:<projectId>:email:<email>` | project 与 email 都一致才跨路径合并 |
| authFile 身份不完整 | `provider:incomplete:...:authfile:<normalizedPath>` | 已知原生字段保留在 key 中，但只允许同归一化路径回退 |
| 非 authFile 身份不完整 | `provider:raw:<uuid>` | 每个凭证独立，不按 email 猜测 |

`credentialsShareCanonicalIdentity` 还会先拒绝双方已知 account/user/project/email 的显式冲突；只有完整身份相同，或不完整身份位于同一归一化 auth path，才允许合并。

## Codex 专属禁止项

| 行为 | 状态 | 原因 |
|------|------|------|
| email 作为匹配/去重依据 | 禁止 | 同 email 不同 workspace |
| accountId 单独作为匹配/去重依据 | 禁止 | 必须与 user discriminator 组成完整原生身份 |
| allowUnseenCredentialFallback | 禁止 | 可能跨 workspace 收养 |
| removeAutoDiscoveredDuplicates 按 email 删除 | 禁止 | 误删不同 workspace |
| API 失败时覆盖 stored accountId | 禁止 | 格式漂移 |
| stripCompositeAccountIds 拆分 | 禁止 | 拆后 accountId 碰撞 |
| existingAuthenticatedCredential nil == nil 匹配 | 禁止 | 跨 workspace 凭证误合并 |
| existingAuthenticatedCredential accountId+sourceIdentifier 匹配 | 禁止 | sourceIdentifier 不区分 workspace |
| sessionFingerprint 匹配 | 禁止 | 不同 workspace 可能有相同 fingerprint |
| mergeResults 失败过滤用 accountId | 禁止 | Plus/Team 共享 user-xxx |
| isActiveAccount 用 accountId/email | 禁止 | Plus/Team 都会匹配 |
| liveProviderIdentity 用 accountId | 禁止 | 同 user-xxx 会合并两行 |
| 不完整凭证用 accountId/email 跨路径合并 | 禁止 | 已知字段不足时必须保留路径/UUID 隔离 |

## 引擎层 vs 存储层 identityKey 优先级差异

| 层级 | 优先级 | 原因 |
|------|--------|------|
| ProviderEngine | **path → cred → generic** | 自动扫描分支无 credentialId 但总有 path |
| AccountIdentityPolicy | **cred → path → stored id** | 持久化账号通常有 credentialId |

这两者在当前场景下是安全的：凭据分支已补齐 sourceFilePath，两条路径在 merge 时汇合为同一 key。存储层优先 credentialId 是因为已入库的账号大多有此字段。

## 已知边界情况

1. **非 authFile 的 Codex 凭据**（如手动 token 登录）：无法产生 sourceFilePath，引擎 identityKey 会落到 `:cred:` 或 `:generic:`。凭证去重用 `raw:<uuid>`，不会跨 workspace 碰撞。当前 Codex 产品形态以 auth 文件为主，风险低。
2. **`CODEX_AUTH_FILE` 环境变量**：早退分支的 path 字面量可能与扫描发现的不完全一致，依赖下游 `normalizedAuthFilePath` 归一化兜底。
3. **上游丢失 sourceFilePath**：若 ProviderData 未带 path，Step 0.5 直接返回 nil，不会错误匹配但可能创建新条目。`deduplicate` 会用 `identityKey` 兜底。
4. **同 workspace 重复登录**：完整 account+user 身份会由 `credentialsShareCanonicalIdentity` 复用；若旧/新任一侧身份不完整，则只有同归一化 auth path 才合并，其他副本宁可暂时保留。
5. **Managed import 路径 vs 原始路径**：`credentialSourceFilePath` 优先使用 `metadata["sourcePath"]`（原始路径），确保与自动扫描分支的 identityKey 汇合。`detectActiveCodexAccount` 在 sourceFilePath 直接匹配失败时，通过凭据的 `sourcePath` 做归一化回落匹配。
6. **Managed 副本 refresh_token 过期**：Codex CLI/App 在本地轮换 `~/.codex/auth.json` 的 refresh_token 后，managed import 副本的 token 失效。`recoverFromSourceAndFetch` 触发链路：401 → refresh 失败 → 读 `metadata["sourcePath"]` 原始文件 → `sameCodexWorkspace`（accountId + planType 双匹配；双方 planType 均缺失时拒绝）→ 覆写副本 → 重试。文件写入失败会通过 `os.Logger` 记录警告，不影响当次请求。

## 场景验证矩阵

| # | 场景 | 凭证去重 | 账号去重 | 匹配 | 协调 |
|---|------|---------|---------|------|------|
| 1 | 多email同Team | authFile不同 | sourceFilePath不同 | Step 0.5各自命中 | 路径不同 |
| 2 | 同email不同Team | authFile不同 | sourceFilePath不同 | Step 0.5各自命中 | 路径不同 |
| 3 | 个人+Team(同email) | authFile不同 | sourceFilePath不同 | Step 0.5各自命中 | 路径不同 |
| 4 | API失败accountId变 | 不涉及 | sourceFilePath不变 | Step 0.5命中 | 路径稳定 |
| 5 | 同 user 两工作区（个人+Team） | accountId 不同 | 原生 identity 不同 | path 与 account+user 均不碰撞 | 各自独立 |
| 5b | 同 account+user 套餐升降 | canonical identity 相同 | 不创建第二原生身份 | plan 不进入 key | 安全复用 |
| 6 | 删除凭证后 | - | credentialId清空 | 不悬空引用 | 孤儿清理 |
| 7 | 自动发现(无credentialId) | - | sourceFilePath 1:1匹配 | Step 0.5直接命中 | 无需email猜测 |
| 8 | 自动+凭据双路径同workspace | 凭据补齐sourceFilePath | identityKey路径汇合 | mergeResults去重 | 不重复显示 |
| 9 | Codex CLI 轮换 refresh_token | 不涉及 | sourceFilePath不变 | recoverFromSourceAndFetch 校验 accountId+planType | 副本自动恢复 |
| 10 | 同user-xxx Plus/Team 副本都过期 | 各自独立恢复 | sourceFilePath不同 | sameCodexWorkspace planType 区分 | 不会交叉恢复 |
| 11 | 双侧 planType 缺失 | 不涉及 | sourceFilePath不变 | sameCodexWorkspace 返回 false（安全默认） | 用户需刷新 CLI 产生 JWT 后再扫描 |
| 12 | Antigravity 同邮箱不同 project | canonical identity 不同 | 不按 email 合并 | project+email 判定 | 各自独立 |
| 13 | Antigravity 同 project+email 不同导入路径 | canonical identity 相同 | 合并到 identity-rich canonical | 原生身份判定 | 不重复保留凭据 |
