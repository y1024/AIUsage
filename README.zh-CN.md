<p align="center">
  <img src="docs/images/app-icon.png" alt="AIUsage 图标" width="128">
</p>

<h1 align="center">AIUsage</h1>

<h4 align="center">AI 订阅一站式看板</h4>

<p align="center">
  额度、费用、多账号、Claude Code 代理，尽在掌控。<br>
  内置 Claude Code 代理，接入任意 OpenAI 兼容模型。
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>中文说明</strong>
</p>

<p align="center">
  <a href="https://github.com/sylearn/AIUsage/releases"><img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white"></a>
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <a href="https://github.com/sylearn/AIUsage/releases/latest"><img alt="版本" src="https://img.shields.io/github/v/release/sylearn/AIUsage?style=flat-square&color=22c55e&label=release"></a>
  <a href="LICENSE"><img alt="许可证" src="https://img.shields.io/badge/license-Apache%202.0-0ea5e9?style=flat-square"></a>
  <a href="https://github.com/sylearn/AIUsage/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/sylearn/AIUsage?style=flat-square&color=f59e0b"></a>
  <a href="https://github.com/sylearn/AIUsage/releases"><img alt="下载量" src="https://img.shields.io/github/downloads/sylearn/AIUsage/total?style=flat-square&color=6366f1&label=downloads"></a>
</p>

<p align="center">
  <sup>赞助商</sup><br>
  <a href="https://sucloud.vip">
    <img src="docs/images/sucloud-logo.png" alt="Sucloud" width="180">
  </a><br>
  <sub>500+ AI 模型 · 文本/图像/视频/音频全模态覆盖 · 顶级模型全接入 · 按量计费</sub>
</p>

<p align="center">
  <img src="docs/images/dashboard-overview.png" alt="AIUsage 仪表盘" width="100%">
</p>

---

## 目录

- [功能](#功能)
- [界面预览](#界面预览)
- [安装](#安装)
- [代理](#代理)
- [致谢](#致谢)
- [赞助商](#赞助商)
- [支持作者](#支持作者)
- [许可证](#许可证)

## 功能

| 功能 | 说明 |
| --- | --- |
| **11+ AI 服务商** | Codex、Copilot、Cursor、Antigravity、Kiro、Warp、Gemini CLI、Droid、Claude Code、Kimi、MiniMax — 一个看板搞定 |
| **多账号管理** | 同一服务商多个账号独立刷新，一键切换 CLI 活跃账号 |
| **用量统计** | 统一汇总 Claude/Codex 代理归档与仅统计 Token 的 Codex 非代理会话：按模型拆分费用与 Token，趋势曲线、多时段分析，可按来源聚合查看 |
| **Claude Code 代理** | 用 Claude Code 跑 DeepSeek、GPT、Ollama 等任意 OpenAI 兼容模型；Anthropic 透传模式记录用量 |
| **Codex 代理** | 把 Codex CLI 指向任意 OpenAI 兼容上游；订阅账号与 API 节点统一切换器，外科式合并 `config.toml` |
| **菜单栏快览** | 多账号状态栏图标 + 配额/费用指标，快览弹窗含摘要统计、彩色进度条、费用追踪 |
| **凭证保险库** | macOS Keychain 安全存储 |

## 界面预览

<table>
  <tr>
    <td width="50%"><img src="docs/images/dashboard-overview.png" alt="仪表盘"></td>
    <td width="50%"><img src="docs/images/provider-monitoring.png" alt="服务商监控"></td>
  </tr>
  <tr>
    <td align="center"><strong>仪表盘</strong></td>
    <td align="center"><strong>服务商与多账号监控</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/Claude-Code-Proxy-1.png" alt="Claude Code 代理节点管理"></td>
    <td width="50%"><img src="docs/images/Claude-Code-Proxy-2.png" alt="Claude Code 代理配置"></td>
  </tr>
  <tr>
    <td align="center"><strong>Claude Code 代理 · 节点管理</strong></td>
    <td align="center"><strong>Claude Code 代理 · 配置</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/Codex-Proxy-stats.png" alt="Codex 代理"></td>
    <td width="50%"><img src="docs/images/proxy-stats.png" alt="用量统计"></td>
  </tr>
  <tr>
    <td align="center"><strong>Codex 代理 · 节点与订阅</strong></td>
    <td align="center"><strong>用量统计（Claude 与 Codex）</strong></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/images/menu_bar.png" alt="菜单栏" width="50%"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><strong>菜单栏</strong></td>
  </tr>
</table>

## 安装

从 [Releases](https://github.com/sylearn/AIUsage/releases) 页面下载 `.dmg` 或 `.zip`。

## 代理

AIUsage 内置两套相互独立的代理 —— 分别面向 **Claude Code** 与 **Codex（Codex CLI）**，各自支持节点管理、用量记录与统一切换器。

### Claude Code 代理

将 Claude Code CLI 接入任意 OpenAI 兼容模型，或透明记录 Anthropic API 用量。

| 模式 | 说明 |
|------|------|
| **OpenAI 代理** | Claude API → OpenAI 格式转换，支持 DeepSeek、GPT、Azure、Ollama 等 |
| **Anthropic 透传** | 请求原样转发，记录输入/输出/缓存 Token，精确追踪费用 |

**快速开始：** 打开 AIUsage → Claude Code 代理 → 新建节点 → 配置 → 激活。`~/.claude/settings.json` 自动更新。

### Codex 代理

把 Codex CLI 指向任意 OpenAI 兼容上游（Responses API），并在**订阅账号**与 **API 节点**之间一处切换 —— 两者互斥，任意时刻只有一个身份生效。

| 能力 | 说明 |
|------|------|
| **OpenAI 兼容上游** | 让 Codex CLI 走任意 `responses` 兼容端点 |
| **统一切换器** | 订阅账号（`~/.codex/auth.json`）与 API 节点（`config.toml`）一个开关统一切换 |
| **外科式合并** | 向 `~/.codex/config.toml` 注入受管理块、保留你的原有配置；通用配置片段 + 节点级 TOML 覆盖 |

**快速开始：** 打开 AIUsage → Codex 代理 → 新建节点（或选择订阅账号）→ 配置 → 激活。`~/.codex/config.toml` 自动合并。

Claude Code 与 Codex 的用量、计费、缓存和归档细节见 [docs/USAGE_AND_BILLING.md](docs/USAGE_AND_BILLING.md)。

---

## 致谢

灵感参考自 [`CodexBar`](https://github.com/steipete/CodexBar) 与 [`Quotio`](https://github.com/nguyenphutrong/quotio)。

## 赞助商

<p align="center">
  <a href="https://sucloud.vip">
    <img src="docs/images/sucloud-logo.png" alt="Sucloud" width="180">
  </a>
</p>

<p align="center">
  <a href="https://sucloud.vip"><strong>Sucloud</strong></a> — 为国内开发者提供稳定高效的 AI 生产力基座。<br>
  500+ 模型全模态覆盖（文本/图像/视频/音频），Claude、GPT、Gemini 等顶级模型全部接入。<br>
  人民币充值，无需海外卡，0.7¥ = $1 超高性价比。
</p>

<p align="center">
  <img alt="模型" src="https://img.shields.io/badge/500%2B%20模型-全模态覆盖-6366f1?style=flat-square">
  <img alt="费率" src="https://img.shields.io/badge/0.7%C2%A5%20%3D%20%241-按量计费-22c55e?style=flat-square">
  <img alt="福利" src="https://img.shields.io/badge/%240.2-注册即送-f59e0b?style=flat-square">
</p>

## 支持作者

如果 AIUsage 对你有帮助，欢迎请作者喝一杯咖啡。你的支持会帮助项目持续维护与改进。

<p align="center">
  <img src="docs/images/donate-qrcode.jpg" alt="打赏二维码" width="220">
</p>

## 友链

- [Linux.do 社区](https://linux.do)

## 许可证

[Apache License 2.0](LICENSE)
