# AIUsage Architecture

## Overview

AIUsage is a macOS-native SwiftUI application that monitors AI subscription quotas across multiple providers, with an integrated Claude Code proxy for using third-party models. The codebase consists of two main modules: the **AIUsage app** (SwiftUI frontend + state management) and the **QuotaBackend** SwiftPM package (provider engines, normalizers, proxy runtime).

## Directory Structure

```
AIUsage/
├── AIUsageApp.swift              # @main, scene setup, EnvironmentObject wiring
├── Models/
│   ├── AppState.swift            # Thin facade: UI navigation + coordinator references
│   ├── AppSettings.swift         # UserDefaults-backed preferences (ObservableObject)
│   ├── AccountStore.swift        # Account registry & credential management
│   ├── ProviderModels.swift      # App-side ProviderData, alerts, etc.
│   ├── ProxyConfiguration.swift  # Proxy node config model (legacy, kept for compat) + NodeType / ProxyNodeFamily
│   └── NodeProfile.swift         # File-based node profile (_metadata + full settings.json)
├── Services/
│   ├── APIService.swift          # HTTP client for remote QuotaServer
│   ├── SecureAccountVault.swift  # Keychain read/write for account metadata
│   ├── SystemProxyDetector.swift # Detects macOS system proxy (CodeX no_proxy fix)
│   ├── CodexNoProxyFixer.swift   # Writes/removes managed no_proxy block in ~/.codex/.env
│   ├── ProviderAuthManager.swift # Auth flow orchestration (slim router)
│   └── ProviderAuth/
│       ├── ProviderAuthTypes.swift
│       ├── ProviderManagedImportStore.swift
│       ├── CLIExecutableResolver.swift
│       ├── LoginPhase.swift              # Shared login phase enum for all login coordinators
│       ├── CodexLoginCoordinator.swift   # Browser login (CLI subprocess + auto-open system browser)
│       ├── GeminiLoginCoordinator.swift  # Browser login (loopback OAuth)
│       ├── AntigravityLoginCoordinator.swift # Browser login (loopback OAuth)
│       ├── CopilotLoginCoordinator.swift # GitHub device flow
│       ├── KiroLoginCoordinator.swift    # AWS SSO device flow
│       ├── ProviderAuthCandidateDiscovery.swift
│       └── ProviderAuthParsing.swift
├── ViewModels/
│   ├── ProviderRefreshCoordinator.swift  # Refresh engine, timers, data pipeline
│   ├── ProviderActivationManager.swift   # CLI active account detection
│   ├── ProxyViewModel.swift              # Proxy node lifecycle (dual track: Claude + CodeX) & process management
│   ├── CodexConfigManager.swift          # ~/.codex/config.toml surgical merge + backup/restore
│   ├── NodeProfileStore.swift            # File-based profile CRUD (~/.config/aiusage/profiles/)
│   └── ClaudeSettingsManager.swift       # ~/.claude/settings.json full write + backup/restore
└── Views/
    ├── ContentView.swift           # NavigationSplitView shell
    ├── DashboardView.swift         # Main dashboard
    ├── ProviderCard.swift          # Rich quota card UI
    ├── StatsHubView.swift          # Unified "Usage Stats" entry: Local Logs / Proxy segmented switch
    ├── CostTrackingView.swift      # Usage stats for Claude Code + Codex (per-source / All Sources)
    ├── ProxyManagementView.swift   # Proxy node list (family-filtered: .claude / .codex) + gesture drag-to-reorder
    ├── CodexProxyManagementView.swift # CodeX proxy menu (wraps ProxyManagementView(family: .codex))
    ├── CodexProxyEditorView.swift  # CodeX node editor (single model)
    ├── SystemProxyWarningBanner.swift # System-proxy notice in CodeX menu
    ├── ProxyStatsView.swift        # Proxy usage statistics (family-aware)
    ├── SettingsView.swift          # Preferences UI (sidebar navigation, 7 categories)
    ├── JSONRawEditorView.swift     # Raw JSON editor for node profiles
    ├── SettingsVisualEditorView.swift # Visual settings.json editor
    ├── ProfileExportView.swift     # Batch profile export UI
    ├── ProviderAccountEditorView.swift # "Connect account" sheet (per provider)
    ├── ProviderLoginStatusCard.swift   # Unified login card shared by all 5 login flows
    └── ...

QuotaBackend/Sources/
├── QuotaBackend/
│   ├── ProviderProtocol.swift    # Core protocols & types
│   ├── Engine/
│   │   ├── ProviderEngine.swift          # Concurrent provider orchestration
│   │   ├── ProviderRegistry.swift        # Static provider list
│   │   ├── AccountCredentialStore.swift  # Keychain credential storage
│   │   └── BrowserDiscovery.swift        # Browser profile helpers
│   ├── Providers/
│   │   ├── ClaudeProvider.swift         # Local JSONL log scanner
│   │   ├── CodexProvider.swift          # OpenAI Codex API (multi-workspace)
│   │   ├── CodexCostProvider.swift      # Local Codex session JSONL scanner (+FileScanCache, +ArchiveStore)
│   │   ├── CopilotProvider.swift        # GitHub Copilot
│   │   ├── CursorProvider.swift         # Cursor IDE
│   │   ├── GeminiProvider.swift         # Google Gemini CLI
│   │   ├── AmpProvider.swift            # Amp
│   │   ├── DroidProvider.swift          # Droid (+API, +Auth, +Helpers, +Parsing)
│   │   ├── KimiProvider.swift           # Kimi Code subscription (/usages: weekly + rate-limit windows)
│   │   ├── KiroProvider.swift           # Kiro (+Auth, +Parsing)
│   │   ├── MiniMaxProvider.swift        # MiniMax Token Plan (/token_plan/remains: 5h + weekly)
│   │   ├── WarpProvider.swift           # Warp
│   │   └── AntigravityProvider.swift    # Antigravity (multi-workspace)
│   ├── Normalizer/
│   │   ├── UsageNormalizer.swift        # Raw → ProviderSummary + DashboardOverview
│   │   ├── UsageNormalizer+<Provider>.swift  # Per-provider normalizers (11 files)
│   │   └── ProviderSummary.swift        # Normalized summary structs
│   ├── ClaudeProxy/
│   │   ├── Canonical/             # Unified middle layer (production pipeline)
│   │   ├── Runtime/               # Proxy service, upstream client (+ CodexProxyConfiguration/Service)
│   │   ├── Conversion/            # Legacy converters (reference impl)
│   │   ├── Models/                # API model definitions
│   │   └── Utilities/             # SSE encoder
│   └── Utilities/
│       └── DateFormatting.swift   # Shared formatters (SharedFormatters, DateFormat)
└── QuotaServer/
    ├── main.swift                          # CLI entry point (PROXY_TARGET=codex selects CodeX proxy)
    ├── QuotaHTTPServer.swift               # NWListener HTTP server + StreamingResponse
    ├── QuotaHTTPServer+ClaudeProxy.swift   # Claude API routing & streaming bridge
    ├── QuotaHTTPServer+CodexProxy.swift    # CodeX /v1/responses + /v1/models faithful passthrough
    └── QuotaHTTPServer+Passthrough.swift   # Anthropic passthrough proxy
```

## Singleton Architecture

```mermaid
graph TD
    AppState["AppState (facade)"] --> AppSettings
    AppState --> AccountStore
    AppState --> RefreshCoordinator["ProviderRefreshCoordinator"]
    AppState --> ActivationManager["ProviderActivationManager"]

    RefreshCoordinator --> AccountStore
    RefreshCoordinator --> AppSettings
    RefreshCoordinator --> Engine["ProviderEngine"]
    ActivationManager --> AccountStore
    ActivationManager --> AppSettings
```

| Singleton | Responsibility |
|-----------|---------------|
| **AppState** | UI navigation state, selected providers, read-through forwarding, `objectWillChange` aggregation |
| **AppSettings** | UserDefaults-backed preferences: theme, language, refresh intervals, backend mode |
| **AccountStore** | Account registry, credential lifecycle, normalization/dedup, Keychain persistence |
| **ProviderRefreshCoordinator** | Refresh timers, `ProviderEngine` orchestration, local/remote fetch, data merging |
| **ProviderActivationManager** | CLI active account detection (Codex/Gemini), auth file I/O |

All singletons forward `objectWillChange` to `AppState`, so views observing `@EnvironmentObject var appState` refresh automatically.

## Data Flow: Provider Refresh

```mermaid
sequenceDiagram
    participant UI as View
    participant AS as AppState
    participant RC as RefreshCoordinator
    participant ENG as ProviderEngine
    participant P as Provider
    participant N as UsageNormalizer

    UI->>AS: refreshAllProviders()
    AS->>RC: refreshAllProviders()
    RC->>RC: set isRefreshingAllProviders
    RC->>ENG: fetchAll(ids:)
    ENG->>P: fetch(credential:)
    P-->>ENG: ProviderUsage
    ENG->>N: normalize(usages:)
    N-->>ENG: [ProviderSummary] + DashboardOverview
    ENG-->>RC: results
    RC->>RC: merge providers, reconcile AccountStore
    RC-->>AS: objectWillChange
    AS-->>UI: SwiftUI re-render
```

## Proxy Subsystem

详细架构文档见 [PROXY_ARCHITECTURE.md](PROXY_ARCHITECTURE.md)。

两条相互独立、可同时激活的代理轨道（`ProxyViewModel` 用 `activatedConfigId` / `activatedCodexConfigId` 分别跟踪，互斥仅限同家族 `ProxyNodeFamily`）：

- **Claude Code 轨道**（`.anthropicDirect` / `.openaiProxy`）：写 `~/.claude/settings.json`。
- **CodeX 轨道**（`.codexProxy`）：写 `~/.codex/config.toml`（`CodexConfigManager` 外科式合并），详见 PROXY_ARCHITECTURE.md「CodeX 代理」章。

**Process lifecycle** (managed by `ProxyViewModel` + `ProxyRuntimeService`):

1. User activates a proxy node in the UI
2. `ProxyViewModel` executes transactional activation:
   - Loads full settings from `NodeProfileStore` profile (v0.5.0+) or legacy `ProxyConfiguration`
   - **Claude track**: writes complete `~/.claude/settings.json` via `ClaudeSettingsManager.writeFullSettings()` (auto-backup to `settings.backup.json`)
   - **CodeX track**: spawns `QuotaServer(PROXY_TARGET=codex)`, then injects managed block into `~/.codex/config.toml` (backup-as-source-of-truth); if a system proxy is detected, writes `no_proxy` into `~/.codex/.env`
   - Spawns `QuotaServer` process (via `ProxyRuntimeService`)
   - Writes pricing override (Claude track only)
   - Persists `activatedConfigId` / `activatedCodexConfigId` only after all steps succeed
3. Pipes stdout/stderr, parses `PROXY_LOG:` JSON lines for stats
4. On deactivation: kills process, restores `settings.json` / `config.toml` (+ `.env`) from backup, rolls back state

**Proxy modes**:
- **OpenAI Convert** (Claude track): Claude API → Canonical Middle Layer → OpenAI `chat/completions` or `responses` → upstream
- **Anthropic Passthrough** (Claude track): Transparent forwarding with token usage logging
- **CodeX Faithful Passthrough**: OpenAI Responses inbound forwarded verbatim to an OpenAI-compatible upstream (no Canonical rewrite; only model + auth adjusted)

**Conversion pipeline**: Claude-track protocol conversion goes through a Canonical Middle Layer (see [CANONICAL_MIDDLE_LAYER_DESIGN.md](CANONICAL_MIDDLE_LAYER_DESIGN.md)). The CodeX track is passthrough-only in Phase B.

## Storage Locations

| Location | Content |
|----------|---------|
| **UserDefaults** | App preferences, selected providers, stats |
| **Keychain** (`SecureAccountVault`) | Account registry metadata (emails, notes, IDs) |
| **Keychain** (`AccountCredentialStore`) | Provider credentials (cookies, tokens, API keys) |
| `~/.config/aiusage/profiles/*.json` | Node profile files (`_metadata` + full `settings.json` content) |
| `~/.claude/settings.json` | Claude Code configuration (full replacement on activation) |
| `~/.claude/settings.backup.json` | Backup of `settings.json` before activation |
| `~/.config/aiusage/proxy-logs.json` | Proxy request logs (with day-based retention) |
| `~/.config/aiusage/proxy-pricing.json` | Model pricing overrides |
| `~/.codex/config.toml` | CodeX configuration; managed `model_provider=aiusage-proxy` block injected on activation (chmod 0600) |
| `~/.codex/config.toml.aiusage.bak` | Backup of `config.toml` before injection (backup-as-source-of-truth; removed on restore) |
| `~/.codex/.env` | Managed `no_proxy` block (loopback only) written when a system proxy is detected; removed on deactivation |
| `~/.config/claude/projects/**/*.jsonl` | Claude Code usage logs (read-only by ClaudeProvider) |
| `~/.codex/sessions/**/*.jsonl`, `~/.codex/archived_sessions/**/*.jsonl` | Codex session logs (read-only by CodexCostProvider; overridable via `$CODEX_HOME`) |
| `~/Library/Caches/AIUsage/codex-cost-file-cache-v*.json` | CodexCostFileScanCache — per-file scan results, keyed on size + mtime so reopened sessions skip re-parsing |
| `~/Library/Caches/AIUsage/codex-cost-usage-archive-v*.json` | CodexUsageArchiveStore — rolled-up per-day token totals so the `.all` view can stretch beyond the 30-day live scan window |

## Supported Providers

| ID | Provider | Channel | Auth Method |
|----|----------|---------|-------------|
| codex | Codex (OpenAI) | CLI | `codex login` flow (system browser) |
| copilot | GitHub Copilot | IDE | GitHub device flow |
| cursor | Cursor | IDE | Browser session |
| antigravity | Antigravity | IDE | Google OAuth (loopback) |
| kiro | Kiro | IDE | AWS SSO device flow |
| warp | Warp | IDE | Auth file |
| gemini | Gemini CLI | CLI | Google OAuth |
| kimi | Kimi Code | CLI | API key (`sk-…`, manual paste or `~/.kimi/config.toml`) |
| minimax | MiniMax Token Plan | CLI | Subscription key (`sk-cp-…`, manual paste) |
| amp | Amp | CLI | Browser session |
| droid | Droid | CLI | Browser session / API |
| claude | Claude Code | Local | JSONL log scan (`~/.config/claude/projects`) |
| codex-cost | Codex | Local | JSONL log scan (`~/.codex/sessions` + archived sessions, full-history import on demand) |

## Account Login Flow (v0.7.1+)

Five providers use an interactive sign-in flow driven by a dedicated `*LoginCoordinator`
(Codex / Gemini / Antigravity browser-loopback, Copilot / Kiro device-code). They share:

- **`LoginPhase`** (Service layer, `ProviderAuth/LoginPhase.swift`): the single phase enum
  (`idle / launching / waitingForBrowser / waitingForCompletion / succeeded / failed`) every
  coordinator publishes. Coordinators never auto-open an embedded WebView — they open the
  **system browser** via `NSWorkspace`, matching native macOS sign-in behavior.
- **`ProviderLoginStatusCard`** (View layer): one card UI reused by all five sections. The
  view maps `LoginPhase` + the editor's `errorMessage`/`isWorking` into a single
  `ProviderLoginVisualState` where **error always wins over success** and the account-import
  step shows a distinct `connecting` state. This removes the previous bug where a green
  "completed" badge and a red error could appear at once.

`coordinator.phase == .succeeded` only means the browser/device step finished; the account is
actually connected by the subsequent `importCandidate` step in `ProviderAccountEditorView+Actions`.

## Auto-Update UX (v0.7.2+)

`SparkleController` (`AIUsageApp.swift`) wraps Sparkle with a launch-time silent probe
(`checkForUpdateInformation()`) and Sparkle 2 **gentle reminders** (`SPUStandardUserDriverDelegate`).
Scheduled/background update discovery never steals focus with a modal; instead it publishes
`availableUpdateVersion`. The sidebar footer (`SidebarFooterView` in `ContentView.swift`) always shows
the current `vX.Y.Z` in the bottom-left and reveals an animated "Update available" pill when a new
version is found. Clicking it runs the standard Sparkle flow (release notes → install → auto relaunch).

## CI/CD

Single GitHub Actions workflow (`.github/workflows/release.yml`):
- **Trigger**: push tag `v*.*.*` or manual dispatch
- **Steps**: checkout → validate version consistency (Info.plist + project.pbxproj + tag) → SPM resolve → build release → sign with Sparkle → upload DMG/ZIP → publish GitHub Release → update appcast.xml

**Version must match in three places**: `Info.plist` (CFBundleShortVersionString + CFBundleVersion), `project.pbxproj` (MARKETING_VERSION), and Git tag.

## Settings UI Architecture (v0.5.1+)

The `SettingsView` uses a **sidebar navigation + content area** two-column layout with 7 categories:

| Category | Content |
|----------|---------|
| **General** | Language, theme, display currency, launch at login, hide dock icon |
| **Data & Refresh** | Backend mode (local/remote), remote server config, provider/CC auto-refresh intervals |
| **Menu Bar** | Quota account pinning, cost source pinning + per-source config |
| **Card Appearance** | Quota card style (bar/ring/segments), progress meaning (remaining/used), preview |
| **Proxy** | Auto-start proxy on launch, proxy log retention |
| **Notifications** | Enable notifications, low quota alert threshold, Claude Code daily cost alert |
| **About** | Version, automatic updates, check for updates, GitHub link |

Menu bar display is hardcoded to `iconAndMetric` mode with `both` (quota% + cost) metric type. The settings sidebar navigation state is managed by a `SettingsCategory` enum.
