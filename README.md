# AIUsage

<p align="center">
  <img src="docs/images/app-icon.png" alt="AIUsage icon" width="120">
</p>

<p align="center">
  <strong>One dashboard for all your AI subscriptions — quotas, costs, accounts, and Claude Code proxy.</strong>
</p>

<p align="center">
  <a href="README.zh-CN.md">中文说明</a> · <strong>English</strong>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Native%20App-f97316?style=flat-square&logo=swift&logoColor=white">
  <img alt="Version" src="https://img.shields.io/badge/version-0.6.2-22c55e?style=flat-square">
  <img alt="License" src="https://img.shields.io/badge/license-Apache%202.0-0ea5e9?style=flat-square">
</p>

<p align="center">
  <img src="docs/images/dashboard-overview_en.png" alt="AIUsage dashboard" width="100%">
</p>

## Features

| Feature | Description |
| --- | --- |
| **10+ AI providers** | Codex, Copilot, Cursor, Antigravity, Kiro, Warp, Gemini CLI, Amp, Droid, Claude Code — one dashboard |
| **Multi-account** | Multiple accounts per provider, independent refresh, one-click CLI switching |
| **Claude Code stats** | Per-model cost & token breakdown, trend charts, time-period analysis |
| **Claude Code proxy** | Use Claude Code with DeepSeek, GPT, Ollama or any OpenAI-compatible model; Anthropic passthrough for usage logging |
| **Proxy stats** | Per-model cost/token trends, distribution charts, configurable log retention |
| **Menu bar** | Multi-account status bar icons with quota/cost metrics, quick-glance popover with summary stats, colored progress bars, and cost tracking |
| **Credential vault** | macOS Keychain storage for managed credentials |

## Preview

<table>
  <tr>
    <td width="50%"><img src="docs/images/dashboard-overview_en.png" alt="Dashboard"></td>
    <td width="50%"><img src="docs/images/provider-monitoring_en.png" alt="Provider monitoring"></td>
  </tr>
  <tr>
    <td align="center"><strong>Dashboard</strong></td>
    <td align="center"><strong>Provider & multi-account monitoring</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/claude-code-stats_en.png" alt="Claude Code stats"></td>
    <td width="50%"><img src="docs/images/codex-account-detail_en.png" alt="Account detail"></td>
  </tr>
  <tr>
    <td align="center"><strong>Claude Code stats</strong></td>
    <td align="center"><strong>Account detail</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/Claude-Code-Proxy-1_en.png" alt="Proxy management"></td>
    <td width="50%"><img src="docs/images/Claude-Code-Proxy-2_en.png" alt="Proxy configuration"></td>
  </tr>
  <tr>
    <td align="center"><strong>Proxy node management</strong></td>
    <td align="center"><strong>Proxy configuration</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/proxy-stats_en.png" alt="Proxy stats"></td>
    <td width="50%"><img src="docs/images/menu_bar_en.png" alt="Menu bar"></td>
  </tr>
  <tr>
    <td align="center"><strong>Proxy statistics</strong></td>
    <td align="center"><strong>Menu bar</strong></td>
  </tr>
</table>

## Install

Download `.dmg` or `.zip` from the [Releases](https://github.com/sylearn/AIUsage/releases) page.

## Claude Code Proxy

Use Claude Code CLI with any OpenAI-compatible model, or transparently log Anthropic API usage.

| Mode | What it does |
|------|-------------|
| **OpenAI Proxy** | Translates Claude API → OpenAI format. Works with DeepSeek, GPT, Azure, Ollama, etc. |
| **Anthropic Passthrough** | Forwards requests as-is, logs input/output/cache tokens for cost tracking |

**Quick start:** Open AIUsage → Claude Code Proxy → New Node → Configure → Activate. Settings are written to `~/.claude/settings.json` automatically.

## Acknowledgements

Inspired by [`CodexBar`](https://github.com/steipete/CodexBar) and [`Quotio`](https://github.com/nguyenphutrong/quotio).

## Friendly Links

- [Linux.do Community](https://linux.do)

## License

[Apache License 2.0](LICENSE)
