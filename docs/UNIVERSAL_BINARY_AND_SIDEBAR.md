# Universal Binary 发布 & 侧边栏代理分组

> 本文档总结 v0.13.1 的两项改动：启用 Intel（x86_64）支持的 Universal Binary 构建（自此长期生效），以及侧边栏「代理」入口的折叠分组重构。

---

## 一、Intel 芯片支持评估结论

**结论：完全可行，代码层零障碍。** 此前发布包是 arm64-only，原因只在构建配置，不在代码：

| 检查项 | 结果 |
| --- | --- |
| 第三方依赖 | 仅 Sparkle 2.9.1，其官方产物本身已是 Universal（x86_64 + arm64） |
| 系统框架 | SwiftUI / Charts / Network / CryptoKit / SQLite3 等，Intel 的 macOS 14 全部可用 |
| 架构相关代码 | 全代码库无任何 `#if arch` 条件编译；唯一沾边处是 `AntigravityProvider` 的硬编码 User-Agent `"Darwin/arm64"`（模拟官方客户端指纹，保持不动） |
| 部署目标 | macOS 14.0，正好覆盖可升级 Sonoma/Sequoia 的 2018–2020 款 Intel Mac |
| 运行负载 | 轮询 + 本地代理，CPU 轻量，Intel 性能无压力 |

**注意**：Apple 已宣布 macOS 26 (Tahoe) 是最后一个支持 Intel 的大版本，Intel 用户群在收缩，本项目按「Universal 单包」策略维持支持即可，无需分架构发包。

## 二、Universal Binary 构建改造

两处改动，发布链路（CI / Sparkle appcast / 更新流程）完全不变：

### 1. `scripts/package-release.sh`

- `xcodebuild` 的 destination 从 `platform=macOS` 改为 **`generic/platform=macOS`**。
  具体 destination 只会编译宿主机架构（CI 的 arm64 runner 上产出 arm64-only）；generic destination 会构建全部标准架构（arm64 + x86_64）。
- 新增 `verify_universal` 校验：打包前用 `lipo -archs` 检查主程序与 `QuotaServer` helper 必须同时包含 arm64 与 x86_64 切片，否则构建失败——防止将来配置回退时静默发布单架构包。

### 2. `project.pbxproj` 的「Build QuotaServer Helper」脚本阶段

- `swift build` 按 Xcode 传入的 `ARCHS` 逐个追加 `--arch` 参数：
  - Release（generic destination）→ `--arch arm64 --arch x86_64`，产出 Universal helper；
  - Debug（`ONLY_ACTIVE_ARCH=YES`）→ 仅本机架构，不拖慢日常开发构建。
- 使用 `--arch` 后 SwiftPM 的输出目录会从 `.build/<config>/` 变为 `.build/apple/Products/<Config>/`，脚本改用 `--show-bin-path` 动态解析，不再硬编码路径。
- universal 产物复制到标准 nested-code 目录 `AIUsage.app/Contents/Helpers/QuotaServer`；脚本会清掉增量构建遗留的 `Contents/Resources/Helpers/QuotaServer`，避免同一 helper 被封装两次。
- 开启 Xcode 签名时，helper 使用宿主的 `EXPANDED_CODE_SIGN_IDENTITY` 先签并 strict 校验，随后由 Xcode 签外层 App；发布 staging 也执行相同的 inside-out 顺序。

### 预期影响

- 发布包体积增大约 60–80%（当前 zip 不足 10 MB，可接受）。
- 如需在 Apple Silicon 上验证 x86_64 切片，可用 Rosetta：`arch -x86_64 <binary>`。

## 三、侧边栏「代理」折叠分组

### 动机

四个代理入口（Codex / OpenCode / Claude Code / Claude Science）平铺在侧边栏，且各自带「代理」后缀，冗余；后续新增代理还会继续膨胀。

### 方案（macOS 原生可折叠 Section）

- 新增「代理」分组标题，使用 SwiftUI `Section(isExpanded:)`（macOS 14+），悬停显示原生展开/收起箭头，交互与访达/邮件侧边栏一致。
- 组内条目去掉「代理」后缀，只显示应用名：**Codex、OpenCode、Claude Code、Claude Science**。
- 展开状态持久化到 UserDefaults（`sidebarProxiesGroupExpanded`，缺省展开），重启保持。
- 分组收起时，从菜单栏 / 设置跳转到某个代理页会自动展开分组，避免选中项被藏起来。
- 原有的右键隐藏、设置页可见性开关逻辑不变；整组条目都被隐藏时分组标题也不渲染。

### 涉及文件

| 文件 | 改动 |
| --- | --- |
| `AIUsage/Views/SidebarNavigation.swift` | `primary` 拆分为 `primaryTop` + `proxies` + `primaryBottom`（`primary` 保留为三者拼接，供设置页平铺）；代理条目改短名；新增分组标题 `proxiesGroupTitle` |
| `AIUsage/Views/ContentView.swift` | 侧边栏 List 引入可折叠 `Section`；新增选中代理页时自动展开的 `onChange` |
| `AIUsage/Models/AppSettings.swift` | 新增 `sidebarProxiesGroupExpanded` 持久化（DefaultsKey + @Published + 落盘 sink） |
| `Resources/{en,zh_CN}.lproj/Localizable.strings` | `nav.proxy_management` 值改短名；补齐 `nav.group.proxies` 及其余三个代理键 |

### 后续新增代理

只需在 `SidebarNavigation.proxies` 数组中追加一条 `SidebarNavItem`，并在 `ContentView` 的 detail switch 中补充对应页面即可，分组、折叠、隐藏逻辑自动生效。

## 四、FAQ：Universal 与「未来不支持」警告

### 为什么会看到「未来不支持 / Rosetta」弹窗？

macOS 26.4 起，**任何通过 Rosetta 2 运行的进程**启动时都会弹一次「该 App 未来将不受支持」通知（Rosetta 在 macOS 28 基本移除）。触发条件是*进程实际走 Rosetta 翻译执行*，而不是"二进制里含 x86_64 切片"。

- Universal 应用在 M 芯片上原生运行 arm64 切片，`sysctl.proc_translated = 0`，**不会触发该警告**；系统信息里种类显示为 Universal，Apple 明确归类为「升级后继续可用」。
- 本机曾出现的弹窗来自发布验证时用 `arch -x86_64` 强制以 Rosetta 运行 QuotaServer 的冒烟测试，属于测试行为，正常用户不会遇到。
- 真正会被警告的是 Intel-only（种类="Intel"）应用——恰恰是我们改成 Universal 之前的反面情形（arm64-only 则是 Intel 用户直接打不开）。

### 要不要按架构拆成两个包（arm64 / x86_64 各发一份）？

**不推荐，维持 Universal 单包。** 拆分的代价：

- Sparkle 单一 appcast 不支持同一版本挂两个 enclosure（官方明确视为 duplicate），必须拆**两条 feed**，构建时按架构注入不同的 `SUFeedURL`；
- 存量老版本内嵌的是同一条 feed URL，还需要先发过渡版本做分流；
- CI 要出双包、双签名、双 appcast，Releases 资产翻倍；用户首次下载还得自己选对架构，Intel 用户误下 arm64 包会直接无法启动；
- 收益只有单包体积减半（zip 18 MB → ~9 MB），对本项目无意义。Sparkle 维护者的原话：分架构分发"不是 Apple/macOS 的方式"。

### 自动更新会下载错架构吗？

不会。Universal 单包模式下所有用户走同一条 appcast、下载同一个包，安装后系统自动执行本机架构的切片——0.13.0（arm64-only）的老用户通过 Sparkle 升到 0.13.1 Universal 也完全正常，不存在"下载到不适合自己版本"的问题。

## 五、验证记录

- Debug 构建通过（Xcode 26 / Swift 6.2）。
- 运行验证：分组展开态短名显示正确、悬停出现折叠箭头；`defaults write … sidebarProxiesGroupExpanded -bool false` 后重启，分组保持收起、四个代理条目隐藏，其余条目正常。
- 注意：Debug 构建若在 iCloud 同步目录（如 `Desktop`）下的 DerivedData 输出，codesign 可能因 `com.apple.fileprovider.fpfs#P` 扩展属性报 detritus 错误；改用 `~/Library/Developer/` 下的 DerivedData 即可（发布脚本已有 `strip_bundle_detritus` 处理，不受影响）。
