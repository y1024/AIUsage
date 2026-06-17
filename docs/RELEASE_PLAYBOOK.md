# Release Playbook

## 目标

对这个仓库来说，“发布完成”必须同时满足：

- `main` 已推送到 GitHub
- `v<version>` tag 已推送
- GitHub Actions `Release Build` 成功
- GitHub Releases 页面已有 `dmg` 和 `zip`
- `appcast.xml` 已由工作流更新并回写到 `main`
- Release Notes 已补成用户可读版本
- 产物用稳定自签名证书签名（CI 已强制校验，详见「代码签名」一节）
- 本地已重新同步远端 `main`

只要缺一项，都不算真正发版完成。

## 发版前

先确认版本号已同步更新：

- `AIUsage/Info.plist`
- `AIUsage.xcodeproj/project.pbxproj`
- `README.md`
- `README.zh-CN.md`

建议先看工作区：

```bash
git status -sb
```

## 本地预检

每次发版前至少跑这四步：

```bash
cd QuotaBackend && swift test
cd ..
./scripts/run_claude_proxy_regression.sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release build CODE_SIGNING_ALLOWED=NO
./scripts/package-release.sh <version>
```

含义很简单：

- `swift test` 检查后端与包测试
- `run_claude_proxy_regression.sh` 检查 Claude 代理主链路
- `xcodebuild ... Release` 提前暴露 Release-only 编译问题
- `package-release.sh` 提前暴露本地打包问题

## 标准发版

### 1. 提交并推送

```bash
git add <changed-files>
git commit -m "Release <version>"
git push origin main
git tag -a v<version> -m "Release <version>"
git push origin v<version>
```

### 2. 盯工作流

```bash
gh run list --workflow "Release Build" --limit 3
gh run watch <run_id> --interval 10 --exit-status
```

如果失败，先直接看日志：

```bash
gh run view <run_id> --log-failed
```

### 3. 核对 Release

```bash
gh release view v<version> --json tagName,name,body,url,assets
```

必须确认：

- 有 `AIUsage-<version>-macOS.dmg`
- 有 `AIUsage-<version>-macOS.zip`
- Release 不是 draft
- 正文不是默认空模板

### 4. 拉回远端回写

```bash
git fetch origin
git pull --ff-only origin main
git status -sb
```

重点是把工作流自动更新的 `appcast.xml` 拉回本地。

## Release Notes

工作流只会自动生成默认 changelog 链接，所以每次都要手动补正文：

```bash
gh release edit v<version> --notes-file <notes-file>
```

推荐结构：

```md
## <version> 更新内容

### 体验修复
- ...

### 稳定性与维护
- ...

**Full Changelog**: https://github.com/sylearn/AIUsage/compare/v<prev>...v<version>
```

## 失败后的正确做法

如果 `Release Build` 失败，不要直接跳新版本号。

正确流程：

1. 在 `main` 修当前版本问题
2. 重新跑本地预检
3. 提交修复
4. 强制移动同一个 tag
5. 重新推送 `main` 和 tag

命令：

```bash
git add <changed-files>
git commit -m "<fix message>"
git push origin main
git tag -fa v<version> -m "Release <version>"
git push origin v<version> --force
```

## 代码签名（稳定自签名证书）

发布产物用**一张固定不变的自签名证书**签名（不是 ad-hoc）。原因：ad-hoc 签名指纹每次构建都变，macOS 钥匙串把指纹记在每个条目的 ACL 里，更新后旧的「始终允许」全部失效，用户每次更新都要重新授权（issue #35）。每次用同一张证书签，App 的 designated requirement 恒定（`certificate leaf = H"..."`），「始终允许」就能跨版本保留。

工作机制（已写进发布管线，自动生效，无需手动操作）：

- `release.yml` 的 `Import code signing certificate` 步骤：从 secret 解出 `.p12` → 临时钥匙串导入 → 取 identity → 写入 `MACOS_SIGNING_IDENTITY` / `MACOS_SIGNING_KEYCHAIN`。
- `package-release.sh`：检测到 `MACOS_SIGNING_IDENTITY` 就用该证书签名，并**强制校验**产物是 cert-pinned（不是则 `exit 1`，绝不静默回退 ad-hoc）。secret 缺失时才回退 ad-hoc（方便 fork 构建）。

依赖的仓库 secret（缺一不可，否则回退 ad-hoc）：

- `MACOS_CERT_P12_BASE64`：证书 `.p12` 的 base64
- `MACOS_CERT_PASSWORD`：`.p12` 密码

证书首次生成（**只做一次，之后永远复用同一张**）：

```bash
./scripts/generate-signing-cert.sh
# 产物在 dist/（已 gitignore）：aiusage-signing.p12 + .p12.base64
# 把打印的密码和 .p12.base64 内容分别填进上面两个 secret
```

> ⚠️ 不要重新生成证书。换证书 = 换指纹 = 所有用户被多问一次「始终允许」。务必把 `dist/aiusage-signing.p12` 和密码离线备份好，长期复用。

## 关键坑点

### 1. 只看本地 Debug 没用

- CI 上的 Release 构建更严格
- 一定要跑本地 Release 构建
- CI 失败时先看日志，不要靠猜

### 2. 不只是主 App，会一起构建 QuotaServer helper

- 主 App 能编译，不代表 Release workflow 一定能过
- Claude 代理相关回归必须每次发版前都跑

### 3. `appcast.xml` 的最终版本在远端

- 发版成功后，工作流会自动回写 `appcast.xml`
- 所以最后一定要 `git pull --ff-only origin main`

### 4. Release Notes 不会自动写好

- 默认只有 `Full Changelog`
- 必须手动补用户可读说明

### 5. `codesign` 容易被扩展属性绊倒

典型报错：

```text
resource fork, Finder information, or similar detritus not allowed
```

常见来源：

- `com.apple.FinderInfo`
- `com.apple.fileprovider.fpfs#P`

经验结论：

- 不要删掉 `scripts/package-release.sh` 里的 detritus 清理逻辑
- 不要在桌面仓库目录里的 staging `.app` 上直接做签名
- 先复制到 `/tmp` 临时目录签名和做 DMG staging，再把最终产物写回 `dist/`

### 6. 签名证书必须长期复用同一张

- 发布用稳定自签名证书（见「代码签名」一节），不是 ad-hoc
- **绝不重新生成证书**：换证书 = 用户被多问一次「始终允许」
- 证书或 secret 丢了：先找回备份，找不到再重生成（并预期老用户多授权一次）
- CI 若误回退 ad-hoc，`package-release.sh` 会 `exit 1`，不会静默发车

## 最短手顺

```bash
git status -sb
cd QuotaBackend && swift test
cd ..
./scripts/run_claude_proxy_regression.sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release build CODE_SIGNING_ALLOWED=NO
./scripts/package-release.sh <version>
git add <changed-files>
git commit -m "Release <version>"
git push origin main
git tag -a v<version> -m "Release <version>"
git push origin v<version>
gh run list --workflow "Release Build" --limit 3
gh run watch <run_id> --interval 10 --exit-status
gh release view v<version> --json tagName,name,body,url,assets
git fetch origin
git pull --ff-only origin main
git status -sb
```
