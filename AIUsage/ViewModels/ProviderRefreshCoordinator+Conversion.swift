import Foundation
import os.log
import QuotaBackend
import UserNotifications

extension ProviderRefreshCoordinator {
    // MARK: - QuotaBackend → ProviderData conversion

    func convertSummary(_ s: QuotaBackend.ProviderSummary) -> ProviderData {
        ProviderData(
            id: s.id,
            providerId: s.providerId,
            accountId: s.accountId,
            name: s.name,
            label: s.label,
            description: s.description,
            category: s.category,
            channel: s.channel,
            status: ProviderStatus(rawValue: s.status) ?? .healthy,
            statusLabel: s.statusLabel,
            theme: ProviderTheme(accent: s.theme.accent, glow: s.theme.glow),
            sourceLabel: s.sourceLabel,
            sourceType: s.sourceType,
            fetchedAt: s.fetchedAt,
            accountLabel: s.accountLabel,
            membershipLabel: s.membershipLabel,
            workspaceLabel: s.workspaceLabel,
            headline: Headline(eyebrow: s.headline.eyebrow, primary: s.headline.primary, secondary: s.headline.secondary, supporting: s.headline.supporting),
            metrics: s.metrics.map { Metric(label: $0.label, value: $0.value, note: $0.note) },
            windows: s.windows.map { QuotaWindow(label: $0.label, remainingPercent: $0.remainingPercent, usedPercent: $0.usedPercent, value: $0.value, note: $0.note, resetAt: $0.resetAt) },
            remainingPercent: s.remainingPercent,
            nextResetAt: s.nextResetAt,
            nextResetLabel: s.nextResetLabel,
            spotlight: s.spotlight,
            models: s.models?.map { ModelInfo(label: $0.label, value: $0.value, note: $0.note) },
            costSummary: s.costSummary.map { cs in
                CostSummary(
                    today: cs.today.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    week: cs.week.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    month: cs.month.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    overall: cs.overall.map { CostPeriod(usd: $0.usd, tokens: $0.tokens, rangeLabel: $0.rangeLabel) },
                    timeline: cs.timeline.map { timeline in
                        CostTimeline(
                            hourly: timeline.hourly.map {
                                CostTimelinePoint(bucket: $0.bucket, label: $0.label, usd: $0.usd, tokens: $0.tokens)
                            },
                            daily: timeline.daily.map {
                                CostTimelinePoint(bucket: $0.bucket, label: $0.label, usd: $0.usd, tokens: $0.tokens)
                            }
                        )
                    },
                    modelBreakdown: cs.modelBreakdown?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelBreakdownToday: cs.modelBreakdownToday?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelBreakdownWeek: cs.modelBreakdownWeek?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelBreakdownOverall: cs.modelBreakdownOverall?.map {
                        ModelCostBreakdown(model: $0.model, totalTokens: $0.totalTokens, inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens, cacheCreateTokens: $0.cacheCreateTokens, estimatedCostUsd: $0.estimatedCostUsd, percentage: $0.percentage)
                    },
                    modelTimelines: cs.modelTimelines?.map {
                        ModelTimelineSeries(
                            model: $0.model,
                            hourly: $0.hourly.map { CostTimelinePoint(bucket: $0.bucket, label: $0.label, usd: $0.usd, tokens: $0.tokens) },
                            daily: $0.daily.map { CostTimelinePoint(bucket: $0.bucket, label: $0.label, usd: $0.usd, tokens: $0.tokens) }
                        )
                    }
                )
            },
            sourceFilePath: s.sourceFilePath
        )
    }

    func convertOverview(_ o: QuotaBackend.DashboardOverview) -> DashboardOverview {
        DashboardOverview(
            generatedAt: o.generatedAt,
            activeProviders: o.activeProviders,
            attentionProviders: o.attentionProviders,
            criticalProviders: o.criticalProviders,
            resetSoonProviders: o.resetSoonProviders,
            localCostMonthUsd: o.localCostMonthUsd,
            localWeekTokens: o.localWeekTokens,
            stats: o.stats.map { OverviewStat(label: $0.label, value: $0.value, note: $0.note) },
            alerts: o.alerts.map {
                Alert(id: $0.id, tone: $0.tone, providerId: $0.providerId, title: $0.title, body: $0.body)
            }
        )
    }

    var language: String { settings.language }

    func localizeProviderData(_ provider: ProviderData) -> ProviderData {
        guard language == "zh" else { return provider }

        return ProviderData(
            id: provider.id,
            providerId: provider.providerId,
            accountId: provider.accountId,
            name: provider.name,
            label: provider.label,
            description: localizedDynamicText(provider.description),
            category: provider.category,
            channel: provider.channel,
            status: provider.status,
            statusLabel: provider.statusLabel,
            theme: provider.theme,
            sourceLabel: localizedDynamicText(provider.sourceLabel),
            sourceType: provider.sourceType,
            fetchedAt: provider.fetchedAt,
            accountLabel: provider.accountLabel,
            membershipLabel: provider.membershipLabel,
            workspaceLabel: provider.workspaceLabel,
            headline: Headline(
                eyebrow: localizedDynamicText(provider.headline.eyebrow),
                primary: localizedDynamicText(provider.headline.primary),
                secondary: localizedDynamicText(provider.headline.secondary),
                supporting: provider.headline.supporting.map(localizedDynamicText)
            ),
            metrics: provider.metrics.map {
                Metric(
                    label: localizedDynamicText($0.label),
                    value: localizedDynamicText($0.value),
                    note: $0.note.map(localizedDynamicText)
                )
            },
            windows: provider.windows.map {
                QuotaWindow(
                    label: localizedDynamicText($0.label),
                    remainingPercent: $0.remainingPercent,
                    usedPercent: $0.usedPercent,
                    value: localizedDynamicText($0.value),
                    note: localizedDynamicText($0.note),
                    resetAt: $0.resetAt
                )
            },
            remainingPercent: provider.remainingPercent,
            nextResetAt: provider.nextResetAt,
            nextResetLabel: provider.nextResetLabel,
            spotlight: provider.spotlight.map(localizedDynamicText),
            models: provider.models?.map {
                ModelInfo(
                    label: $0.label,
                    value: localizedDynamicText($0.value),
                    note: $0.note.map(localizedDynamicText)
                )
            },
            costSummary: provider.costSummary.map { summary in
                CostSummary(
                    today: summary.today.map(localizedCostPeriod),
                    week: summary.week.map(localizedCostPeriod),
                    month: summary.month.map(localizedCostPeriod),
                    overall: summary.overall.map(localizedCostPeriod),
                    timeline: summary.timeline.map { timeline in
                        CostTimeline(
                            hourly: timeline.hourly.map(localizedTimelinePoint),
                            daily: timeline.daily.map(localizedTimelinePoint)
                        )
                    },
                    modelBreakdown: summary.modelBreakdown,
                    modelBreakdownToday: summary.modelBreakdownToday,
                    modelBreakdownWeek: summary.modelBreakdownWeek,
                    modelBreakdownOverall: summary.modelBreakdownOverall,
                    modelTimelines: summary.modelTimelines
                )
            },
            sourceFilePath: provider.sourceFilePath
        )
    }

    func localizedCostPeriod(_ period: CostPeriod) -> CostPeriod {
        CostPeriod(
            usd: period.usd,
            tokens: period.tokens,
            rangeLabel: period.rangeLabel.map(localizedDynamicText)
        )
    }

    func localizedTimelinePoint(_ point: CostTimelinePoint) -> CostTimelinePoint {
        CostTimelinePoint(
            bucket: point.bucket,
            label: localizedDynamicText(point.label),
            usd: point.usd,
            tokens: point.tokens
        )
    }

    func localizeOverview(_ overview: DashboardOverview) -> DashboardOverview {
        guard language == "zh" else { return overview }

        return DashboardOverview(
            generatedAt: overview.generatedAt,
            activeProviders: overview.activeProviders,
            attentionProviders: overview.attentionProviders,
            criticalProviders: overview.criticalProviders,
            resetSoonProviders: overview.resetSoonProviders,
            localCostMonthUsd: overview.localCostMonthUsd,
            localWeekTokens: overview.localWeekTokens,
            stats: overview.stats.map {
                OverviewStat(
                    label: localizedDynamicText($0.label),
                    value: localizedDynamicText($0.value),
                    note: localizedDynamicText($0.note)
                )
            },
            alerts: overview.alerts.map {
                Alert(
                    id: $0.id,
                    tone: $0.tone,
                    providerId: $0.providerId,
                    title: localizedDynamicText($0.title),
                    body: localizedDynamicText($0.body)
                )
            }
        )
    }

    func localizedDynamicText(_ text: String) -> String {
        guard language == "zh", !text.isEmpty else { return text }

        let exact: [String: String] = [
            "Connected Sources": "监控服务",
            "Attention Queue": "状态提醒",
            "Tracked Local Cost": "费用追踪",
            "Resets In 24h": "即将刷新",
            "Tracked Services": "监控服务",
            "Live Accounts": "在线账号",
            "Cost Tracking": "费用追踪",
            "Status Alerts": "状态提醒",
            "Live snapshot": "实时快照",
            "Fetched successfully": "抓取成功",
            "This provider is connected.": "该服务已连接。",
            "Collection failed": "采集失败",
            "Unavailable": "不可用",
            "Check local auth or provider session": "请检查本地登录态或服务会话",
            "Unknown source": "未知来源",
            "Environment variable": "环境变量",
            "Manual credentials": "手动凭证",
            "Browser session": "浏览器会话",
            "Desktop cache": "桌面缓存",
            "CLIProxy auth file": "CLIProxy 授权文件",
            "GitHub CLI": "GitHub CLI",
            "Local CLI session": "本地 CLI 会话",
            "Local Claude logs": "本地 Claude 日志",
            "Gemini CLI OAuth": "Gemini CLI OAuth",
            "Kiro IDE session": "Kiro IDE 会话",
            "Stored credential": "已存凭证",
            "WebView session": "WebView 会话",
            "Pasted cookie": "粘贴的 Cookie",
            "Stored session": "已存会话",
            "Imported credential": "导入的凭证",
            "Saved": "已保存",
            "Awaiting a live session": "等待在线会话",
            "Unknown": "未知",
            "None": "无",
            "Connected": "已连接",
            "Unlimited": "无限",
            "Not available": "暂无",
            "Tracked": "已跟踪",
            "No fixed cap detected": "未检测到固定上限",
            "No cap detected": "未检测到上限",
            "main request reserve": "主额度余量",
            "quota snapshot": "配额快照",
            "Antigravity quota snapshot": "Antigravity 配额快照",
            "lowest remaining model": "剩余最低的模型",
            "Most Copilot lanes are unlimited": "Copilot 大多数通道为无限制",
            "tightest Copilot lane": "最紧张的 Copilot 通道",
            "Kiro usage snapshot": "Kiro 用量快照",
            "tightest Kiro lane": "最紧张的 Kiro 通道",
            "Usage snapshot ready": "用量快照已就绪",
            "lowest remaining window": "剩余最低的窗口",
            "Gemini quota snapshot": "Gemini 配额快照",
            "lowest remaining family": "剩余最低的模型组",
            "Cursor usage snapshot": "Cursor 用量快照",
            "tightest remaining allowance": "最紧张的额度窗口",
            "Token telemetry ready": "Token 统计已就绪",
            "lowest remaining token pool": "剩余最低的 Token 池",
            "Unlimited mode": "无限模式",
            "Desktop quota cache": "桌面配额缓存",
            "Local cost telemetry": "本地费用统计",
            "Local spend ledger": "本地费用账本",
            "Account": "账号",
            "Email": "邮箱",
            "Plan": "计划",
            "Workspace": "工作空间",
            "Reset": "重置",
            "Source": "来源",
            "Project": "项目",
            "Tracked Models": "跟踪模型",
            "Main Pool": "主额度",
            "Assistant Pool": "助手额度",
            "Bonus Credits": "奖励额度",
            "Premium": "Premium",
            "Chat": "聊天",
            "Completions": "补全",
            "Auth": "认证",
            "Region": "区域",
            "Today": "今天",
            "This Week": "本周",
            "This Month": "本月",
            "Scanned Calls": "扫描调用数",
            "Scanned Turns": "扫描轮次",
            "Requests": "请求数",
            "Assistant Credits": "助手额度",
            "Main Plan": "主计划",
            "Named Models": "具名模型",
            "Free Quota": "免费额度",
            "Used": "已用",
            "Remaining": "剩余",
            "Hourly Refill": "每小时回补",
            "Included Plan": "套餐额度",
            "On-demand": "按量",
            "Lowest Remaining": "最低剩余",
            "Billing Period": "计费周期",
            "Billing cycle detected": "已检测到账期",
            "Standard Tokens": "标准 Tokens",
            "Premium Tokens": "高级 Tokens",
            "GitHub account": "GitHub 账号",
            "OpenAI account": "OpenAI 账号",
            "Gemini CLI account": "Gemini CLI 账号",
            "Kiro account": "Kiro 账号",
            "Local Codex logs": "本地 Codex 日志",
            "Reset unavailable": "重置时间未知",
            "Reset date unknown": "重置日期未知",
            "Everything is within normal range": "目前都在正常范围内",
            "No urgent resets detected": "暂无即将重置的窗口",
            "A few windows are about to roll over": "有些窗口即将重置",
            "Warp can read from local app cache, which makes the panel feel instantaneous and keeps the design centered on what is actually left right now.": "Warp 可以直接读取本地应用缓存，所以面板刷新很快，重点也能放在当前还剩多少。",
            "This tracker reads local Claude Code JSONL logs and derives token and cost totals from usage entries, so it works best as a local ledger rather than an official subscription meter.": "这个追踪源会读取本地 Claude Code JSONL 日志，并根据 usage 记录推导 Token 与费用总量，所以它更适合作为本地账本，而不是官方订阅额度计量器。",
            "This tracker reads local Codex session JSONL logs and derives token deltas from token_count events, using turn_context model markers when available.": "这个追踪源会读取本地 Codex 会话 JSONL 日志，从 token_count 事件推导 token 增量，并优先使用 turn_context 中的模型标记。",
            "Usage-derived Claude token and cost ledger from local logs": "基于本地日志推导的 Claude Token 与费用账本",
            "Local token and cost ledger from Claude Code logs": "基于 Claude Code 本地日志的 Token 与费用账本",
            "Local token ledger from Codex session logs": "基于 Codex 本地会话日志的 Token 账本",
            "Codex": "Codex",
            "Local token ledger": "本地 Token 账本",
            "Codex session logs this month": "本月 Codex 会话日志",
            "Local ledgers and usage-derived spend": "本地账本与用量推导费用",
            "Copilot can mix unlimited and metered lanes. The dashboard keeps unlimited channels visible, but only metered windows affect watch and critical states.": "Copilot 同时存在无限和限额通道。面板会保留无限通道的可见性，但只有有限额的窗口会影响偏低和告急状态。",
            "Codex has multiple overlapping guardrails, so the UI surfaces all windows together and uses the tightest one to drive alerting.": "Codex 有多层重叠的限制窗口，所以界面会把它们一起展示，并用最紧张的那个来驱动提醒。",
            "Gemini quota is model-family based, so the dashboard groups the lowest remaining family first and keeps the project context attached.": "Gemini 的配额是按模型族划分的，所以面板会优先展示剩余最低的模型组，并保留项目上下文。",
            "Cursor mixes percent-based allowances with dollar-based plan spend, so the card pairs remaining percentages with included and on-demand spend signals.": "Cursor 同时存在百分比额度和按美元计的套餐消耗，所以卡片会同时展示剩余百分比、套餐内额度和按量消耗信号。",
            "Amp is best viewed as a replenishing credit pool, so the card highlights remaining balance and refill cadence instead of a hard billing period.": "Amp 更适合看成会持续回补的额度池，所以卡片会重点展示剩余额度和回补节奏，而不是固定账期。",
            "Droid usage is token-heavy, so the panel keeps raw token counts visible next to the percentage-based pools.": "Droid 的用量以 token 为主，所以面板会在百分比池旁边保留原始 token 数量。",
            "GitHub Education access": "GitHub 教育权益",
            "Personal": "个人",
            "Team": "团队",
            "Business": "商业",
            "Enterprise": "企业",
            "Edu": "教育"
        ]
        if let mapped = exact[text] {
            return mapped
        }

        var result = text
        result = replacingRegex(#"^Plan · (.+)$"#, in: result, template: "计划 · $1")
        result = replacingRegex(#"^Membership · (.+)$"#, in: result, template: "会员 · $1")
        result = replacingRegex(#"^(.+) left$"#, in: result, template: "剩余 $1")
        result = replacingRegex(#"^(.+) used$"#, in: result, template: "已用 $1")
        result = replacingRegex(#"^(\d[\d,]*) total$"#, in: result, template: "总量 $1")
        result = replacingRegex(#"^(\d[\d,]*) duplicate rows removed$"#, in: result, template: "已去重 $1 条")
        result = replacingRegex(#"^(\d[\d,]*) tokens$"#, in: result, template: "$1 个 tokens")
        result = replacingRegex(#"^(\d[\d,]*) tokens this month$"#, in: result, template: "本月 $1 tokens")
        result = replacingRegex(#"^(\d[\d,]*) tokens observed this week$"#, in: result, template: "本周记录 $1 tokens")
        result = replacingRegex(#"^(\d[\d,]*) providers in the mesh$"#, in: result, template: "当前连接 $1 个服务")
        result = replacingRegex(#"^(\d[\d,]*) critical right now$"#, in: result, template: "当前有 $1 个告急")
        result = replacingRegex(#"^(\d[\d,]*) lanes tracked$"#, in: result, template: "跟踪 $1 个通道")
        result = replacingRegex(#"^token expires (.+)$"#, in: result, template: "token 将于 $1 过期")
        result = replacingRegex(#"^(.+) needs attention$"#, in: result, template: "$1 需要关注")
        result = replacingRegex(#"^(.+) is getting tight$"#, in: result, template: "$1 余额趋紧")
        result = replacingRegex(#"^(.+) has unpriced models$"#, in: result, template: "$1 有未定价模型")
        result = replacingRegex(#"^(.+) • Reset unavailable$"#, in: result, template: "$1 • 重置时间未知")
        result = replacingRegex(#"^(.+) • Resets soon$"#, in: result, template: "$1 • 即将重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)d (\d+)h$"#, in: result, template: "$1 • $2天$3小时后重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)h (\d+)m$"#, in: result, template: "$1 • $2小时$3分钟后重置")
        result = replacingRegex(#"^(.+) • Resets in (\d+)m$"#, in: result, template: "$1 • $2分钟后重置")
        result = replacingRegex(#"^Resets soon$"#, in: result, template: "即将重置")
        result = replacingRegex(#"^Resets in (\d+)d (\d+)h$"#, in: result, template: "$1天$2小时后重置")
        result = replacingRegex(#"^Resets in (\d+)h (\d+)m$"#, in: result, template: "$1小时$2分钟后重置")
        result = replacingRegex(#"^Resets in (\d+)m$"#, in: result, template: "$1分钟后重置")
        result = replacingRegex(#"^Antigravity auth files detected: (\d[\d,]*)\. This snapshot uses the most recently updated file \((.+)\)\.$"#,
                                in: result,
                                template: "检测到 $1 个 Antigravity 授权文件，当前快照使用的是最近更新的那个（$2）。")
        result = replacingRegex(#"^Antigravity exposes per-model quotas, so the dashboard keeps each model separate and puts the tightest ones first\.$"#,
                                in: result,
                                template: "Antigravity 提供按模型拆分的配额，所以面板会保留每个模型的独立窗口，并把最紧张的那些放在前面。")
        result = replacingRegex(#"^Kiro reported (\d[\d,]*) usage lanes\. This card shows the three tightest ones first so attention stays on the lanes that will run out soonest\.$"#,
                                in: result,
                                template: "Kiro 报告了 $1 个用量通道，这张卡片会优先展示最紧张的三个，方便你先关注最先见底的通道。")
        result = replacingRegex(#"^Kiro usage is pulled from the same AWS-backed endpoint the desktop app uses, so this snapshot reflects the live agentic request lanes exposed by the app\.$"#,
                                in: result,
                                template: "Kiro 的用量来自桌面应用同一个 AWS 接口，所以这个快照能反映应用当前暴露出来的实时 agent 请求通道。")
        result = replacingRegex(#"^Resets (.+) at (.+)$"#, in: result, template: "重置于 $1 $2")
        result = replacingRegex(#"^(.+) bonus credits remain$"#, in: result, template: "剩余 $1 奖励额度")
        result = replacingRegex(#"^Week (.+) • Today (.+)$"#, in: result, template: "本周 $1 • 今日 $2")
        return result
    }

    func replacingRegex(_ pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: - Claude threshold + notifications

    func checkClaudeCodeDailyThreshold() {
        guard settings.claudeCodeDailyThreshold > 0 else {
            return
        }

        let today = SharedFormatters.iso8601String(from: Date()).prefix(10)
        if settings.lastNotifiedDate == String(today) {
            return
        }

        guard let claudeProvider = providers.first(where: { $0.baseProviderId == "claude" }),
              let todayCost = claudeProvider.costSummary?.today?.usd else {
            return
        }

        guard todayCost >= settings.claudeCodeDailyThreshold else {
            return
        }

        providerRefreshLog.info("Sending Claude Code threshold notification: $\(todayCost, privacy: .public) > $\(self.settings.claudeCodeDailyThreshold, privacy: .public)")
        sendClaudeCodeThresholdNotification(cost: todayCost, threshold: settings.claudeCodeDailyThreshold)
        settings.lastNotifiedDate = String(today)
    }

    func sendClaudeCodeThresholdNotification(cost: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = settings.t("Claude daily cost alert", "Claude 每日消费提醒")
        content.body = settings.t(
            "Today's cost $\(String(format: "%.2f", cost)) has exceeded the threshold of $\(String(format: "%.2f", threshold))",
            "今日消费 $\(String(format: "%.2f", cost)) 已超过阈值 $\(String(format: "%.2f", threshold))"
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claude-code-threshold-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        DispatchQueue.main.async {
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    providerRefreshLog.error("Failed to send notification: \(error.localizedDescription)")
                } else {
                    providerRefreshLog.info("Claude Code threshold notification sent: $\(cost, privacy: .public) > $\(threshold, privacy: .public)")
                }
            }
        }
    }

    func sendErrorNotification(_ message: String) {
        let redactedMessage = SensitiveDataRedactor.redactPaths(in: message)
        providerRefreshLog.error("AIUsage error: \(redactedMessage)")
    }
}
