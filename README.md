<p align="center">
  <img src="docs/images/app-icon.png" alt="AIUsage icon" width="128">
</p>

<h1 align="center">AIUsage</h1>

<h4 align="center">One dashboard for all your AI subscriptions</h4>

<p align="center">
  Track quotas, costs, and accounts across 10+ AI providers.<br>
  Built-in Claude Code proxy for any OpenAI-compatible model.
</p>

<p align="center">
  <a href="README.zh-CN.md">中文说明</a> · <strong>English</strong>
</p>

<p align="center">
  <a href="https://github.com/sylearn/AIUsage/releases"><img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white"></a>
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native-f97316?style=flat-square&logo=swift&logoColor=white">
  <a href="https://github.com/sylearn/AIUsage/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/sylearn/AIUsage?style=flat-square&color=22c55e&label=release"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-Apache%202.0-0ea5e9?style=flat-square"></a>
  <a href="https://github.com/sylearn/AIUsage/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/sylearn/AIUsage?style=flat-square&color=f59e0b"></a>
  <a href="https://github.com/sylearn/AIUsage/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/sylearn/AIUsage/total?style=flat-square&color=6366f1&label=downloads"></a>
</p>

<p align="center">
  <sup>Sponsored by</sup><br>
  <a href="https://sucloud.vip">
    <img src="docs/images/sucloud-logo.png" alt="Sucloud" width="180">
  </a><br>
  <sub>500+ AI models · Text, image, video & audio · Top models included · Pay-as-you-go</sub>
</p>

<p align="center">
  <img src="docs/images/dashboard-overview_en.png" alt="AIUsage dashboard" width="100%">
</p>

---

## Table of Contents

- [Features](#features)
- [Preview](#preview)
- [Install](#install)
- [Proxies](#proxies)
- [Acknowledgements](#acknowledgements)
- [Sponsor](#sponsor)
- [Support the Author](#support-the-author)
- [License](#license)

## Features

| Feature | Description |
| --- | --- |
| **12+ AI Providers** | Codex, Copilot, Cursor, Antigravity, Kiro, Warp, Gemini CLI, Amp, Droid, Claude Code, Kimi, MiniMax — one dashboard |
| **Multi-account** | Multiple accounts per provider, independent refresh, one-click CLI switching |
| **Usage Stats** | Unified cost & token breakdown across **Local Logs** (Claude Code / Codex sessions) and **Proxy Logs** — per-model trends, time-period analysis, source-aware "All Sources" aggregation |
| **Claude Code Proxy** | Use Claude Code with DeepSeek, GPT, Ollama or any OpenAI-compatible model; Anthropic passthrough for usage logging |
| **CodeX Proxy** | Point Codex CLI at any OpenAI-compatible upstream; unified switcher across subscription accounts and API nodes, surgical `config.toml` merge |
| **Menu Bar** | Multi-account status bar icons, quota/cost metrics, quick-glance popover, colored progress bars |
| **Credential Vault** | macOS Keychain storage for all managed credentials |

## Preview

<table>
  <tr>
    <td width="50%"><img src="docs/images/dashboard-overview_en.png" alt="Dashboard"></td>
    <td width="50%"><img src="docs/images/provider-monitoring_en.png" alt="Provider monitoring"></td>
  </tr>
  <tr>
    <td align="center"><strong>Dashboard</strong></td>
    <td align="center"><strong>Provider & Multi-account Monitoring</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/Claude-Code-Proxy-1_en.png" alt="Claude Code proxy node management"></td>
    <td width="50%"><img src="docs/images/Claude-Code-Proxy-2_en.png" alt="Claude Code proxy configuration"></td>
  </tr>
  <tr>
    <td align="center"><strong>Claude Code Proxy · Node Management</strong></td>
    <td align="center"><strong>Claude Code Proxy · Configuration</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/Codex-Proxy-stats_en.png" alt="CodeX proxy"></td>
    <td width="50%"><img src="docs/images/proxy-stats_en.png" alt="Usage stats"></td>
  </tr>
  <tr>
    <td align="center"><strong>CodeX Proxy · Nodes &amp; Subscriptions</strong></td>
    <td align="center"><strong>Usage Stats (Claude &amp; Codex)</strong></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/images/menu_bar_en.png" alt="Menu bar" width="50%"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><strong>Menu Bar</strong></td>
  </tr>
</table>

## Install

Download `.dmg` or `.zip` from the [Releases](https://github.com/sylearn/AIUsage/releases) page.

## Proxies

AIUsage ships two independent proxies — one for **Claude Code**, one for **CodeX (Codex CLI)** — each with node management, usage logging and a unified switcher.

### Claude Code Proxy

Use Claude Code CLI with any OpenAI-compatible model, or transparently log Anthropic API usage.

| Mode | What it does |
|------|-------------|
| **OpenAI Proxy** | Translates Claude API → OpenAI format. Works with DeepSeek, GPT, Azure, Ollama, etc. |
| **Anthropic Passthrough** | Forwards requests as-is, logs input/output/cache tokens for cost tracking |

**Quick start:** Open AIUsage → Claude Code Proxy → New Node → Configure → Activate. Settings are written to `~/.claude/settings.json` automatically.

### CodeX Proxy

Point the Codex CLI at any OpenAI-compatible upstream (Responses API), and switch between **subscription accounts** and **API nodes** from one place — they are mutually exclusive, so only one identity is ever active.

| Capability | What it does |
|------------|-------------|
| **OpenAI-compatible upstream** | Routes Codex CLI through any `responses`-compatible endpoint |
| **Unified switcher** | One toggle across subscription accounts (`~/.codex/auth.json`) and API nodes (`config.toml`) |
| **Surgical config merge** | Injects managed blocks into `~/.codex/config.toml` while preserving your own settings; global fragment + per-node TOML override |

**Quick start:** Open AIUsage → CodeX Proxy → New Node (or pick a subscription account) → Configure → Activate. `~/.codex/config.toml` is merged automatically.

---

## Acknowledgements

Inspired by [`CodexBar`](https://github.com/steipete/CodexBar) and [`Quotio`](https://github.com/nguyenphutrong/quotio).

## Sponsor

<p align="center">
  <a href="https://sucloud.vip">
    <img src="docs/images/sucloud-logo.png" alt="Sucloud" width="180">
  </a>
</p>

<p align="center">
  <a href="https://sucloud.vip"><strong>Sucloud</strong></a> — AI API aggregation platform with 500+ models.<br>
  Full modality coverage (text, image, video, audio) including Claude, GPT, Gemini and more.<br>
  RMB payment supported, no overseas card required.
</p>

<p align="center">
  <img alt="Models" src="https://img.shields.io/badge/500%2B%20Models-full%20modality-6366f1?style=flat-square">
  <img alt="Pricing" src="https://img.shields.io/badge/0.7%C2%A5%20%3D%20%241-pay--as--you--go-22c55e?style=flat-square">
  <img alt="Bonus" src="https://img.shields.io/badge/%240.2-welcome%20bonus-f59e0b?style=flat-square">
</p>

## Support the Author

If AIUsage helps you, consider buying the author a coffee. Your support helps keep the project maintained and improved.

<p align="center">
  <img src="docs/images/donate-qrcode.jpg" alt="Donation QR code" width="220">
</p>

## Friendly Links

- [Linux.do Community](https://linux.do)

## License

[Apache License 2.0](LICENSE)
