import Foundation

// MARK: - Usage Normalizer
// Swift port of normalizeUsage.js — converts raw ProviderUsage into ProviderSummary

public enum UsageNormalizer {

    static let providerThemes: [String: ThemeInfo] = [
        "amp":     ThemeInfo(accent: "teal",   glow: "#38cbd6"),
        "antigravity": ThemeInfo(accent: "sky", glow: "#5cc9ff"),
        "claude":  ThemeInfo(accent: "sunset", glow: "#ff9d6c"),
        "codex":   ThemeInfo(accent: "violet", glow: "#8d7dff"),
        "copilot": ThemeInfo(accent: "blue",   glow: "#5aa2ff"),
        "cursor":  ThemeInfo(accent: "emerald",glow: "#4dd4aa"),
        "droid":   ThemeInfo(accent: "amber",  glow: "#ffb34d"),
        "gemini":  ThemeInfo(accent: "iris",   glow: "#7f8cff"),
        "kiro":    ThemeInfo(accent: "violet", glow: "#9046ff"),
        "warp":    ThemeInfo(accent: "rose",   glow: "#ff7eb2")
    ]

    public static func normalize(provider: any ProviderFetcher, usage: ProviderUsage) -> ProviderSummary {
        let theme = providerThemes[provider.id] ?? ThemeInfo(accent: "slate", glow: "#8e96a8")
        let sourceLabel = formatSourceLabel(usage.source)

        let uniqueId: String
        if let acctId = usage.usageAccountId {
            uniqueId = "\(provider.id):\(acctId)"
        } else {
            uniqueId = provider.id
        }

        var base = ProviderSummary(
            id: uniqueId,
            providerId: provider.id,
            accountId: usage.usageAccountId,
            name: provider.displayName,
            label: compactProviderLabel(provider.id, fallback: usage.label),
            description: provider.description,
            category: "snapshot",
            channel: channel(for: provider.id),
            status: "healthy",
            statusLabel: "Active",
            theme: theme,
            sourceLabel: sourceLabel,
            sourceType: usage.source?.type ?? "unknown",
            fetchedAt: usage.fetchedAt,
            accountLabel: nil,
            membershipLabel: nil,
            remainingPercent: nil,
            nextResetAt: nil,
            nextResetLabel: nil,
            headline: HeadlineInfo(eyebrow: "", primary: "", secondary: "", supporting: ""),
            metrics: [],
            windows: [],
            costSummary: nil,
            models: nil,
            spotlight: "",
            unpricedModels: nil,
            raw: usage
        )

        switch provider.id {
        case "warp":    return normalizeWarp(base: &base, usage: usage)
        case "antigravity": return normalizeAntigravity(base: &base, usage: usage)
        case "claude":  return normalizeClaude(base: &base, usage: usage)
        case "copilot": return normalizeCopilot(base: &base, usage: usage)
        case "codex":   return normalizeCodex(base: &base, usage: usage)
        case "gemini":  return normalizeGemini(base: &base, usage: usage)
        case "kiro":    return normalizeKiro(base: &base, usage: usage)
        case "cursor":  return normalizeCursor(base: &base, usage: usage)
        case "amp":     return normalizeAmp(base: &base, usage: usage)
        case "droid":   return normalizeDroid(base: &base, usage: usage)
        default:
            base.headline = HeadlineInfo(eyebrow: "Live snapshot", primary: base.label, secondary: "Fetched successfully", supporting: sourceLabel)
            base.spotlight = "This provider is connected."
            return base
        }
    }

    public static func errorSummary(provider: any ProviderFetcher, error: Error) -> ProviderSummary {
        let theme = providerThemes[provider.id] ?? ThemeInfo(accent: "slate", glow: "#8e96a8")
        let msg = SensitiveDataRedactor.redactedMessage(for: error)
        return ProviderSummary(
            id: provider.id,
            providerId: provider.id,
            accountId: nil,
            name: provider.displayName,
            label: compactProviderLabel(provider.id, fallback: provider.displayName),
            description: provider.description,
            category: "snapshot",
            channel: channel(for: provider.id),
            status: "error",
            statusLabel: "Error",
            theme: theme,
            sourceLabel: "Unavailable",
            sourceType: "unknown",
            fetchedAt: nil,
            accountLabel: nil,
            membershipLabel: nil,
            remainingPercent: nil,
            nextResetAt: nil,
            nextResetLabel: nil,
            headline: HeadlineInfo(eyebrow: "Collection failed", primary: "Unavailable", secondary: msg, supporting: "Check local auth or provider session"),
            metrics: [],
            windows: [],
            costSummary: nil,
            models: nil,
            spotlight: "This provider could not be fetched during the current refresh cycle.",
            unpricedModels: nil,
            raw: nil
        )
    }

    // MARK: - Warp

    private static func normalizeWarp(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        base.accountLabel = preferredAccountEmail(usage)

        let requestsRemaining = extra(usage, "requestsRemaining") as? Int
        let requestLimit = extra(usage, "requestLimit") as? Int
        let requestsUsed = extra(usage, "requestsUsed") as? Int
        let assistantRequestsUsed = extra(usage, "assistantRequestsUsed") as? Int
        let bonusCreditsRemaining = extra(usage, "bonusCreditsRemaining") as? Int
        let bonusCreditsTotal = extra(usage, "bonusCreditsTotal") as? Int
        let isUnlimited = extra(usage, "isUnlimited") as? Bool ?? false

        var windows: [WindowInfo] = []
        if let w = usage.primary { windows.append(createQuotaWindow(label: "Requests", window: w)) }
        if let w = usage.secondary { windows.append(createQuotaWindow(label: "Assistant Credits", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)

        let primaryText: String
        if let rem = requestsRemaining, let lim = requestLimit {
            primaryText = "\(formatInt(rem)) / \(formatInt(lim))"
        } else {
            primaryText = remainingPercent.map { formatPercent($0) } ?? "Connected"
        }

        let supporting: String
        if let bonus = bonusCreditsRemaining {
            supporting = "\(formatInt(bonus)) bonus credits remain"
        } else {
            supporting = formatSourceLabel(usage.source)
        }

        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = usage.primary?.resetAt ?? usage.secondary?.resetAt
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: isUnlimited ? "Unlimited mode" : "Desktop quota cache",
            primary: primaryText,
            secondary: requestsRemaining != nil && requestLimit != nil ? "main request reserve" : "quota snapshot",
            supporting: supporting
        )
        base.metrics = [
            MetricInfo(label: "Main Pool", value: "\(formatInt(requestsUsed ?? 0)) used"),
            MetricInfo(label: "Assistant Pool", value: assistantRequestsUsed.map { "\(formatInt($0)) used" } ?? "Not available"),
            MetricInfo(label: "Bonus Credits", value: bonusCreditsRemaining.map { "\(formatInt($0)) / \(formatInt(bonusCreditsTotal ?? 0))" } ?? "None"),
            MetricInfo(label: "Source", value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Warp can read from local app cache, which makes the panel feel instantaneous and keeps the design centered on what is actually left right now."
        return base
    }

    // MARK: - Claude

    private static func normalizeAntigravity(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let trackedModels = extraTrackedModels(usage)
        let windows = trackedModels.map { model in
            WindowInfo(
                label: model.label,
                remainingPercent: model.remainingPercent,
                usedPercent: max(0, 100 - model.remainingPercent),
                value: "\(formatPercent(model.remainingPercent)) left",
                note: joinParts([model.providerLabel, formatShortDateTime(model.resetAt)]) ?? formatShortDateTime(model.resetAt) ?? "Live snapshot",
                resetAt: model.resetAt
            )
        }

        let remainingPercent = trackedModels.map(\.remainingPercent).min() ?? pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan ?? "Unknown"
        let projectId = extraString(usage, "projectId")
        let modelCount = extraInt(usage, "modelCount") ?? trackedModels.count
        let authFileCount = extraInt(usage, "authFileCount") ?? 1
        let selectedAuthFile = extraString(usage, "selectedAuthFile")

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = trackedModels.compactMap { $0.resetAt }.compactMap(parseDate).min().map { SharedFormatters.iso8601String(from: $0) }
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Antigravity quota snapshot" : "lowest remaining model",
            supporting: usage.accountEmail ?? projectId ?? "CLIProxy auth file"
        )
        base.metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Project", value: projectId ?? "Unknown"),
            MetricInfo(label: "Tracked Models", value: formatInt(modelCount)),
            MetricInfo(label: "Source", value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.models = trackedModels.isEmpty ? nil : trackedModels.map {
            ModelInfo(
                label: $0.label,
                value: formatPercent($0.remainingPercent),
                note: joinParts([$0.providerLabel, formatShortDateTime($0.resetAt)])
            )
        }
        base.spotlight = authFileCount > 1
            ? "Antigravity auth files detected: \(formatInt(authFileCount)). This snapshot uses the most recently updated file (\(selectedAuthFile ?? "unknown"))."
            : "Antigravity exposes per-model quotas, so the dashboard keeps each model separate and puts the tightest ones first."
        return base
    }

    // MARK: - Claude

    private static func normalizeClaude(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let monthUsd   = extraDouble(usage, "currentMonth.estimatedCostUsd") ?? 0
        let weekUsd    = extraDouble(usage, "currentWeek.estimatedCostUsd") ?? 0
        let todayUsd   = extraDouble(usage, "today.estimatedCostUsd") ?? 0
        let overallUsd = extraDouble(usage, "overall.estimatedCostUsd") ?? 0
        let monthTokens = extraInt(usage, "currentMonth.totalTokens") ?? 0
        let weekTokens  = extraInt(usage, "currentWeek.totalTokens") ?? 0
        let todayTokens = extraInt(usage, "today.totalTokens") ?? 0
        let overallTokens = extraInt(usage, "overall.totalTokens") ?? 0
        let usageRows   = extraInt(usage, "overall.usageRows") ?? 0
        let dupRows     = extraInt(usage, "overall.duplicateRowsRemoved") ?? 0
        let unpricedModels = extraStringArray(usage, "overall.unpricedModels")

        let rawModelItems = (usage.extra["currentMonth.models"]?.value as? [AnyCodable]) ?? []
        let topModels: [ModelInfo] = rawModelItems
            .prefix(5)
            .compactMap { item in
                guard let m = item.value as? [String: AnyCodable],
                      let model = m["model"]?.value as? String,
                      let cost = m["estimatedCostDisplay"]?.value as? String else { return nil }
                let tokens: Int
                switch m["totalTokens"]?.value {
                case let v as Int: tokens = v
                case let v as Double: tokens = Int(v)
                default: tokens = 0
                }
                return ModelInfo(label: model, value: formatInt(tokens), note: cost)
            }

        let modelBreakdown = extractModelBreakdown(usage, "currentMonth.models")
        let modelBreakdownToday = extractModelBreakdown(usage, "today.models")
        let modelBreakdownWeek = extractModelBreakdown(usage, "currentWeek.models")
        let modelBreakdownOverall = extractModelBreakdown(usage, "overall.models")

        let modelTimelines: [ModelTimelineSeries] = extraModelTimelines(usage, "timeline.byModel")

        base.accountLabel = preferredAccountEmail(usage)
        base.category = "local-cost"
        base.status = "healthy"
        base.statusLabel = "Healthy"
        base.headline = HeadlineInfo(
            eyebrow: "Local spend ledger",
            primary: formatCurrency(monthUsd),
            secondary: "\(formatInt(monthTokens)) tokens this month",
            supporting: "Week \(formatCurrency(weekUsd)) • Today \(formatCurrency(todayUsd))"
        )
        base.metrics = [
            MetricInfo(label: "Today",      value: formatCurrency(todayUsd),  note: "\(formatInt(todayTokens)) tokens"),
            MetricInfo(label: "This Week",  value: formatCurrency(weekUsd),   note: "\(formatInt(weekTokens)) tokens"),
            MetricInfo(label: "This Month", value: formatCurrency(monthUsd),  note: "\(formatInt(monthTokens)) tokens"),
            MetricInfo(label: "Scanned Calls", value: formatInt(usageRows),   note: "\(formatInt(dupRows)) duplicate rows removed")
        ]
        base.windows = []
        base.costSummary = CostSummaryInfo(
            today: CostPeriod(usd: todayUsd, tokens: todayTokens, rangeLabel: extraString(usage, "today.key") ?? "Today"),
            week:  CostPeriod(usd: weekUsd,  tokens: weekTokens,  rangeLabel: extraString(usage, "currentWeek.key") ?? "This week"),
            month: CostPeriod(usd: monthUsd, tokens: monthTokens, rangeLabel: extraString(usage, "currentMonth.key") ?? "This month"),
            overall: CostPeriod(usd: overallUsd, tokens: overallTokens, rangeLabel: "Overall"),
            timeline: CostTimelineInfo(
                hourly: extraCostTimeline(usage, "timeline.hourly"),
                daily: extraCostTimeline(usage, "timeline.daily")
            ),
            modelBreakdown: modelBreakdown.isEmpty ? nil : modelBreakdown,
            modelBreakdownToday: modelBreakdownToday.isEmpty ? nil : modelBreakdownToday,
            modelBreakdownWeek: modelBreakdownWeek.isEmpty ? nil : modelBreakdownWeek,
            modelBreakdownOverall: modelBreakdownOverall.isEmpty ? nil : modelBreakdownOverall,
            modelTimelines: modelTimelines.isEmpty ? nil : modelTimelines
        )
        base.models = topModels.isEmpty ? nil : topModels
        base.nextResetAt = nil
        base.spotlight = "This tracker reads Claude Code JSONL logs and estimates spend from local usage, so it works best as a cost ledger rather than an official subscription meter."
        base.unpricedModels = unpricedModels.isEmpty ? nil : unpricedModels
        return base
    }

    // MARK: - Copilot

    private static func normalizeCopilot(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let planName = usage.accountPlan ?? "Unknown"
        let accountLogin = usage.accountLogin ?? "GitHub account"
        let quotaResetAt = extraString(usage, "quotaResetAt")
        let planNote = extraString(usage, "planNote")

        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createEntitlementWindow(label: "Premium", window: w)) }
        if let w = usage.secondary { windows.append(createEntitlementWindow(label: "Chat", window: w)) }
        if let w = usage.tertiary  { windows.append(createEntitlementWindow(label: "Completions", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)

        var metrics: [MetricInfo] = [
            MetricInfo(label: "Account", value: accountLogin),
            MetricInfo(label: "Plan",    value: planName, note: planNote?.isEmpty == false ? planNote : nil),
            MetricInfo(label: "Reset",   value: extraString(usage, "resetDescription") ?? formatShortDateTime(quotaResetAt) ?? "Unknown"),
            MetricInfo(label: "Source",  value: formatSourceLabel(usage.source))
        ]
        if let email = usage.accountEmail {
            metrics.insert(MetricInfo(label: "Email", value: email), at: 1)
        }

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: planName)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = quotaResetAt
        base.nextResetLabel = formatShortDateTime(quotaResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(planName)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Unlimited",
            secondary: remainingPercent == nil ? "Most Copilot lanes are unlimited" : "tightest Copilot lane",
            supporting: accountLogin
        )
        base.metrics = metrics
        base.windows = windows
        base.spotlight = "Copilot can mix unlimited and metered lanes. The dashboard keeps unlimited channels visible, but only metered windows affect watch and critical states."
        return base
    }

    // MARK: - Codex

    private static func normalizeKiro(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let rawWindows = [usage.primary, usage.secondary, usage.tertiary].compactMap { $0 }
        let windows = rawWindows.map { window in
            createPercentWindow(label: window.label ?? "Usage Lane", window: window)
        }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan ?? "Standard"
        let authProvider = extraString(usage, "authProvider")
        let authMethod = formatKiroAuthMethod(extraString(usage, "authMethod"))
        let region = extraString(usage, "region") ?? "us-east-1"
        let tokenExpiresAt = extraString(usage, "tokenExpiresAt")
        let quotaEntryCount = extraInt(usage, "quotaEntryCount") ?? windows.count
        let hiddenQuotaCount = extraInt(usage, "hiddenQuotaCount") ?? 0

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = rawWindows.compactMap { $0.resetAt }.compactMap(parseDate).min().map { SharedFormatters.iso8601String(from: $0) }
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Kiro usage snapshot" : "tightest Kiro lane",
            supporting: usage.accountEmail ?? usage.accountName ?? authProvider.map { "Kiro \($0)" } ?? "Kiro account"
        )
        base.metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? usage.accountName ?? "Unknown"),
            MetricInfo(label: "Auth", value: joinParts([authProvider, authMethod]) ?? authMethod ?? "Unknown"),
            MetricInfo(label: "Region", value: region, note: tokenExpiresAt.flatMap { formatShortDateTime($0) }.map { "token expires \($0)" }),
            MetricInfo(label: "Source", value: formatSourceLabel(usage.source), note: "\(formatInt(quotaEntryCount)) lanes tracked")
        ]
        base.windows = windows
        base.spotlight = hiddenQuotaCount > 0
            ? "Kiro reported \(formatInt(quotaEntryCount)) usage lanes. This card shows the three tightest ones first so attention stays on the lanes that will run out soonest."
            : "Kiro usage is pulled from the same AWS-backed endpoint the desktop app uses, so this snapshot reflects the live agentic request lanes exposed by the app."
        return base
    }

    // MARK: - Codex

    private static func normalizeCodex(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "5h Window", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Weekly Window", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Code Review", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan.map { titleCase($0) } ?? "Unknown"

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = usage.primary?.resetAt ?? usage.secondary?.resetAt
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Usage snapshot ready" : "lowest remaining window",
            supporting: usage.accountEmail ?? "OpenAI account"
        )
        base.metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Plan",    value: plan),
            MetricInfo(label: "Source",  value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Codex has multiple overlapping guardrails, so the UI surfaces all windows together and uses the tightest one to drive alerting."
        return base
    }

    // MARK: - Gemini

    private static func normalizeGemini(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "Pro", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Flash", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Flash Lite", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan ?? "Unknown"
        let projectId = extraString(usage, "projectId")
        let lowestPercentLeft = extraDouble(usage, "lowestPercentLeft")

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = usage.primary?.resetAt ?? usage.secondary?.resetAt
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Gemini quota snapshot" : "lowest remaining family",
            supporting: usage.accountEmail ?? projectId ?? "Gemini CLI account"
        )
        base.metrics = [
            MetricInfo(label: "Account",          value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Project",           value: projectId ?? "Unknown"),
            MetricInfo(label: "Lowest Remaining",  value: lowestPercentLeft.map { formatPercent($0) } ?? "Unknown"),
            MetricInfo(label: "Source",            value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Gemini quota is model-family based, so the dashboard groups the lowest remaining family first and keeps the project context attached."
        return base
    }

    // MARK: - Cursor

    private static func normalizeCursor(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "Main Plan", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Auto / Composer", window: w)) }
        if let w = usage.tertiary  { windows.append(createPercentWindow(label: "Named Models", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let membershipType = membershipBadge(from: usage.accountPlan ?? extraString(usage, "membershipType")) ?? "Subscription"
        let billingReset = extraString(usage, "billingCycleResetDescription") ?? "Billing cycle detected"
        let billingEnd = extraString(usage, "billingCycleEnd")

        let includedUsed = extraDouble(usage, "includedPlan.usedUsd")
        let includedLimit = extraDouble(usage, "includedPlan.limitUsd")
        let onDemandUsed = extraDouble(usage, "onDemand.usedUsd")

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: membershipType)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = billingEnd
        base.nextResetLabel = formatShortDateTime(billingEnd)
        base.headline = HeadlineInfo(
            eyebrow: "Membership · \(membershipType)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Cursor usage snapshot" : "tightest remaining allowance",
            supporting: billingReset
        )
        base.metrics = [
            MetricInfo(label: "Account",      value: usage.accountEmail ?? usage.accountName ?? "Unknown"),
            MetricInfo(
                label: "Included Plan",
                value: {
                    if let includedUsed, let includedLimit {
                        return "\(formatCurrency(includedUsed)) / \(formatCurrency(includedLimit))"
                    }
                    return "Not available"
                }()
            ),
            MetricInfo(label: "On-demand",    value: onDemandUsed.map { "\(formatCurrency($0)) used" } ?? "Not available"),
            MetricInfo(label: "Source",       value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Cursor mixes percent-based allowances with dollar-based plan spend, so the card pairs remaining percentages with included and on-demand spend signals."
        return base
    }

    // MARK: - Amp

    private static func normalizeAmp(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let remaining = extraInt(usage, "remaining")
        let quota = extraInt(usage, "quota")
        let hourlyReplenishment = extraInt(usage, "hourlyReplenishment")
        let estimatedFullResetAt = extraString(usage, "estimatedFullResetAt")

        let remainingPercent: Double?
        if let r = usage.primary?.remainingPercent { remainingPercent = r }
        else if let rem = remaining, let q = quota, q > 0 { remainingPercent = Double(rem) / Double(q) * 100 }
        else { remainingPercent = nil }

        var windows: [WindowInfo] = []
        if let w = usage.primary { windows.append(createQuotaWindow(label: "Free Quota", window: w)) }

        let (status, statusLabel) = resolveStatus(remainingPercent)

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: usage.accountPlan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = estimatedFullResetAt
        base.nextResetLabel = formatShortDateTime(estimatedFullResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Free tier reserve",
            primary: "\(formatInt(remaining ?? 0)) / \(formatInt(quota ?? 0))",
            secondary: remainingPercent.map { "\(formatPercent($0)) left" } ?? "Unknown",
            supporting: hourlyReplenishment.map { "Replenishes about \(formatInt($0)) units per hour" } ?? "Live browser cookie import"
        )
        base.metrics = [
            MetricInfo(label: "Used",        value: formatInt(extraInt(usage, "used") ?? 0)),
            MetricInfo(label: "Remaining",   value: formatInt(remaining ?? 0)),
            MetricInfo(label: "Hourly Refill", value: hourlyReplenishment.map { "\(formatInt($0))/h" } ?? "Unknown"),
            MetricInfo(label: "Source",      value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Amp is best viewed as a replenishing credit pool, so the card highlights remaining balance and refill cadence instead of a hard billing period."
        return base
    }

    // MARK: - Droid

    private static func normalizeDroid(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary   { windows.append(createPercentWindow(label: "Standard", window: w)) }
        if let w = usage.secondary { windows.append(createPercentWindow(label: "Premium", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let planName = extraString(usage, "planName") ?? "Factory usage"
        let orgName = extraString(usage, "organizationName")
        let periodEnd = extraString(usage, "periodEnd")

        let stdUserTokens = extraInt(usage, "standard.userTokens") ?? 0
        let stdTotalAllowance = extraInt(usage, "standard.totalAllowance") ?? 0
        let stdUnlimited = extra(usage, "standard.unlimited") as? Bool ?? false
        let premUserTokens = extraInt(usage, "premium.userTokens") ?? 0
        let premTotalAllowance = extraInt(usage, "premium.totalAllowance") ?? 0
        let premUnlimited = extra(usage, "premium.unlimited") as? Bool ?? false

        let periodStart = extraString(usage, "periodStart")

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: planName)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = periodEnd
        base.nextResetLabel = formatShortDateTime(periodEnd)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(planName)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil ? "Token telemetry ready" : "lowest remaining token pool",
            supporting: orgName ?? usage.accountEmail ?? "Factory account"
        )
        base.metrics = [
            MetricInfo(label: "Standard Tokens", value: "\(formatInt(stdUserTokens)) / \(stdUnlimited ? "Unlimited" : formatInt(stdTotalAllowance))"),
            MetricInfo(label: "Premium Tokens",  value: "\(formatInt(premUserTokens)) / \(premUnlimited ? "Unlimited" : formatInt(premTotalAllowance))"),
            MetricInfo(label: "Billing Period",  value: formatRange(periodStart, periodEnd)),
            MetricInfo(label: "Source",          value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        base.spotlight = "Droid usage is token-heavy, so the panel keeps raw token counts visible next to the percentage-based pools."
        return base
    }

    // MARK: - Dashboard Overview

    public static func createDashboardOverview(summaries: [ProviderSummary], generatedAt: String) -> DashboardOverview {
        let active     = summaries.filter { $0.status != "error" }
        let attention  = summaries.filter { $0.status == "watch" || $0.status == "critical" }
        let critical   = summaries.filter { $0.status == "critical" }
        let localCost  = summaries.filter { $0.category == "local-cost" }
        let resetSoon  = summaries.filter { s in s.nextResetAt.map { isWithinHours($0, hours: 24) } ?? false }

        let localCostMonthUsd = localCost.reduce(0.0) { $0 + ($1.costSummary?.month?.usd ?? 0) }
        let localWeekTokens   = localCost.reduce(0) { $0 + ($1.costSummary?.week?.tokens ?? 0) }

        var alerts: [AlertInfo] = []
        for s in summaries {
            if s.status == "critical" {
                alerts.append(AlertInfo(tone: "critical", providerId: s.id, title: "\(s.label) needs attention", body: s.headline.secondary))
            } else if s.status == "watch" {
                alerts.append(AlertInfo(tone: "watch", providerId: s.id, title: "\(s.label) is getting tight", body: s.headline.secondary))
            } else if let unpriced = s.unpricedModels, !unpriced.isEmpty {
                alerts.append(AlertInfo(tone: "neutral", providerId: s.id, title: "\(s.label) has unpriced models", body: unpriced.joined(separator: ", ")))
            }
        }

        return DashboardOverview(
            generatedAt: generatedAt,
            activeProviders:    active.count,
            attentionProviders: attention.count,
            criticalProviders:  critical.count,
            resetSoonProviders: resetSoon.count,
            localCostMonthUsd:  roundNumber(localCostMonthUsd, digits: 2),
            localWeekTokens:    localWeekTokens,
            stats: [
                StatInfo(label: "Connected Sources", value: "\(active.count)",    note: "\(summaries.count) providers in the mesh"),
                StatInfo(label: "Attention Queue",   value: "\(attention.count)", note: critical.count > 0 ? "\(critical.count) critical right now" : "Everything is within normal range"),
                StatInfo(label: "Tracked Local Cost", value: formatCurrency(localCostMonthUsd), note: "\(formatInt(localWeekTokens)) tokens observed this week"),
                StatInfo(label: "Resets In 24h",     value: "\(resetSoon.count)", note: resetSoon.isEmpty ? "No urgent resets detected" : "A few windows are about to roll over")
            ],
            alerts: Array(alerts.prefix(6))
        )
    }

    // MARK: - Window Helpers

    private static func createPercentWindow(label: String, window: RawQuotaWindow) -> WindowInfo {
        let remaining = window.remainingPercent
        let used = window.usedPercent ?? remaining.map { 100 - $0 }
        let note = window.resetDescription ?? formatShortDateTime(window.resetAt) ?? "Live snapshot"
        return WindowInfo(
            label: label,
            remainingPercent: remaining,
            usedPercent: used,
            value: remaining.map { "\(formatPercent($0)) left" } ?? "Tracked",
            note: note,
            resetAt: window.resetAt
        )
    }

    private static func createEntitlementWindow(label: String, window: RawQuotaWindow) -> WindowInfo {
        if window.unlimited == true {
            return WindowInfo(label: label, remainingPercent: nil, usedPercent: nil, value: "Unlimited", note: window.resetDescription ?? "No fixed cap detected", resetAt: window.resetAt)
        }
        let remaining = window.remainingPercent
        let entitlement = window.entitlement ?? 0
        let rem = window.remaining ?? 0
        var note = "\(formatInt(entitlement)) total"
        if let rd = window.resetDescription { note += " • \(rd)" }
        return WindowInfo(
            label: label,
            remainingPercent: remaining,
            usedPercent: window.usedPercent ?? remaining.map { 100 - $0 },
            value: "\(formatInt(rem)) left",
            note: note,
            resetAt: window.resetAt
        )
    }

    private static func createQuotaWindow(label: String, window: RawQuotaWindow) -> WindowInfo {
        if window.unlimited == true {
            return WindowInfo(label: label, remainingPercent: nil, usedPercent: nil, value: "Unlimited", note: window.resetDescription ?? "No cap detected", resetAt: window.resetAt)
        }
        let remaining = window.remainingPercent
        let note = window.resetDescription ?? formatShortDateTime(window.resetAt) ?? "Live snapshot"
        return WindowInfo(
            label: label,
            remainingPercent: remaining,
            usedPercent: window.usedPercent,
            value: remaining.map { "\(formatPercent($0)) left" } ?? "Unknown",
            note: note,
            resetAt: window.resetAt
        )
    }

    private static func pickSmallestRemaining(_ windows: [WindowInfo]) -> Double? {
        let values = windows.compactMap { $0.remainingPercent }
        return values.isEmpty ? nil : values.min()
    }

    private static func resolveStatus(_ remaining: Double?) -> (String, String) {
        guard let r = remaining else { return ("healthy", "Active") }
        if r <= 12 { return ("critical", "Critical") }
        if r <= 30 { return ("watch", "Watch") }
        return ("healthy", "Healthy")
    }

    // MARK: - Extra field accessors

    private static func extra(_ usage: ProviderUsage, _ key: String) -> Any? {
        usage.extra[key]?.value
    }

    private static func extraString(_ usage: ProviderUsage, _ key: String) -> String? {
        usage.extra[key]?.value as? String
    }

    private static func extraInt(_ usage: ProviderUsage, _ key: String) -> Int? {
        switch usage.extra[key]?.value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        default: return nil
        }
    }

    private static func extraDouble(_ usage: ProviderUsage, _ key: String) -> Double? {
        switch usage.extra[key]?.value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        default: return nil
        }
    }

    private static func extraStringArray(_ usage: ProviderUsage, _ key: String) -> [String] {
        (usage.extra[key]?.value as? [AnyCodable])?.compactMap { $0.value as? String } ?? []
    }

    private static func extraCostTimeline(_ usage: ProviderUsage, _ key: String) -> [CostTimelinePoint] {
        guard let items = usage.extra[key]?.value as? [AnyCodable] else { return [] }
        return items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let bucket = dict["bucket"]?.value as? String,
                  let label = dict["label"]?.value as? String else {
                return nil
            }

            let usd: Double
            switch dict["usd"]?.value {
            case let value as Double:
                usd = value
            case let value as Int:
                usd = Double(value)
            default:
                usd = 0
            }

            let tokens: Int
            switch dict["tokens"]?.value {
            case let value as Int:
                tokens = value
            case let value as Double:
                tokens = Int(value)
            default:
                tokens = 0
            }

            return CostTimelinePoint(bucket: bucket, label: label, usd: usd, tokens: tokens)
        }
    }

    private static func extractModelBreakdown(_ usage: ProviderUsage, _ key: String) -> [ModelCostInfo] {
        let rawItems = (usage.extra[key]?.value as? [AnyCodable]) ?? []
        return rawItems.compactMap { item in
            guard let m = item.value as? [String: AnyCodable],
                  let model = m["model"]?.value as? String else { return nil }
            func intVal(_ k: String) -> Int {
                switch m[k]?.value {
                case let v as Int: return v
                case let v as Double: return Int(v)
                default: return 0
                }
            }
            func dblVal(_ k: String) -> Double {
                switch m[k]?.value {
                case let v as Double: return v
                case let v as Int: return Double(v)
                default: return 0
                }
            }
            return ModelCostInfo(
                model: model,
                totalTokens: intVal("totalTokens"),
                inputTokens: intVal("inputTokens"),
                outputTokens: intVal("outputTokens"),
                cacheReadTokens: intVal("cacheReadTokens"),
                cacheCreateTokens: intVal("cacheCreateTokens"),
                estimatedCostUsd: dblVal("estimatedCostUsd"),
                percentage: dblVal("percentage")
            )
        }
    }

    private static func extraModelTimelines(_ usage: ProviderUsage, _ key: String) -> [ModelTimelineSeries] {
        guard let items = usage.extra[key]?.value as? [AnyCodable] else { return [] }
        return items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let model = dict["model"]?.value as? String else { return nil }
            let hourlyRaw = dict["hourly"]?.value as? [AnyCodable] ?? []
            let dailyRaw = dict["daily"]?.value as? [AnyCodable] ?? []
            let hourly = parseCostTimelinePoints(hourlyRaw)
            let daily = parseCostTimelinePoints(dailyRaw)
            guard !hourly.isEmpty || !daily.isEmpty else { return nil }
            return ModelTimelineSeries(model: model, hourly: hourly, daily: daily)
        }
    }

    private static func parseCostTimelinePoints(_ items: [AnyCodable]) -> [CostTimelinePoint] {
        items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let bucket = dict["bucket"]?.value as? String,
                  let label = dict["label"]?.value as? String else { return nil }
            let usd: Double
            switch dict["usd"]?.value {
            case let v as Double: usd = v
            case let v as Int: usd = Double(v)
            default: usd = 0
            }
            let tokens: Int
            switch dict["tokens"]?.value {
            case let v as Int: tokens = v
            case let v as Double: tokens = Int(v)
            default: tokens = 0
            }
            return CostTimelinePoint(bucket: bucket, label: label, usd: usd, tokens: tokens)
        }
    }

    private struct TrackedModel {
        let label: String
        let remainingPercent: Double
        let resetAt: String?
        let providerLabel: String?
    }

    private static func extraTrackedModels(_ usage: ProviderUsage) -> [TrackedModel] {
        guard let items = usage.extra["trackedModels"]?.value as? [AnyCodable] else { return [] }
        return items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let label = dict["label"]?.value as? String,
                  let remainingPercent = dict["remainingPercent"]?.value as? Double else {
                return nil
            }

            let resetAt = (dict["resetAt"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            let providerLabel = (dict["providerLabel"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }

            return TrackedModel(
                label: label,
                remainingPercent: remainingPercent,
                resetAt: resetAt,
                providerLabel: providerLabel
            )
        }
    }

    // MARK: - Format Helpers

    static func formatSourceLabel(_ source: SourceInfo?) -> String {
        guard let s = source else { return "Unknown source" }
        if s.mode == "manual" { return s.type == "env-var" ? "Environment variable" : "Manual credentials" }
        if s.mode == "stored" {
            let labels: [String: String] = [
                "keychain-credential": "Stored credential",
                "webview-session": "WebView session",
                "pasted-cookie": "Pasted cookie"
            ]
            return labels[s.type] ?? "Stored session"
        }
        if s.type == "browser-cookie" { return [s.browserName, s.profile].compactMap { $0 }.joined(separator: " · ").isEmpty ? "Browser session" : [s.browserName, s.profile].compactMap { $0 }.joined(separator: " · ") }
        let labels: [String: String] = [
            "app-cache": "Desktop cache",
            "cli-proxy-auth-file": "CLIProxy auth file",
            "gh-cli": "GitHub CLI",
            "cli-auth-file": "Local CLI session",
            "claude-project-logs": "Local Claude logs",
            "gemini-cli": "Gemini CLI OAuth",
            "kiro-ide-auth-file": "Kiro IDE session",
            "pasted-cookie": "Pasted cookie",
            "imported-credential": "Imported credential"
        ]
        return labels[s.type] ?? s.type
    }

    private static func channel(for providerId: String) -> String {
        switch providerId {
        case "cursor", "copilot", "kiro", "antigravity", "warp":
            return "ide"
        case "claude":
            return "local"
        default:
            return "cli"
        }
    }

    private static func compactProviderLabel(_ providerId: String, fallback: String) -> String {
        switch providerId {
        case "claude":
            return "Claude Code Spend"
        case "copilot":
            return "Copilot"
        case "gemini":
            return "Gemini CLI"
        default:
            return fallback
        }
    }

    private static func preferredAccountEmail(_ usage: ProviderUsage) -> String? {
        guard let email = usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.contains("@") else {
            return nil
        }
        return email
    }

    private static func membershipBadge(from raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let uppercase = value.uppercased()
        if uppercase.contains("ULTRA") { return "Ultra" }
        if uppercase.contains("ENTERPRISE") { return "Enterprise" }
        if uppercase.contains("BUSINESS") { return "Business" }
        if uppercase.contains("TEAM") { return "Team" }
        if uppercase.contains("PREMIUM") { return "Premium" }
        if uppercase.contains("PRO") { return "Pro" }
        if uppercase.contains("PLUS") { return "Plus" }
        if uppercase.contains("MAX") { return "Max" }
        if uppercase.contains("FREE") { return "Free" }
        if uppercase.contains("HOBBY") { return "Hobby" }
        if uppercase.contains("LOCAL") { return "Local" }

        return titleCase(value)
    }

    private static func formatKiroAuthMethod(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "social": return "Google OAuth"
        case "idc": return "AWS Builder ID"
        default: return titleCase(value)
        }
    }

    private static func warpDomainLabel(_ domain: String) -> String {
        ["dev.warp.Warp-Stable": "Warp Stable", "dev.warp.Warp-Preview": "Warp Preview", "dev.warp.Warp-Nightly": "Warp Nightly"][domain] ?? domain
    }

    static func formatCurrency(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.minimumFractionDigits = value >= 1 ? 2 : 4
        fmt.maximumFractionDigits = value >= 1 ? 2 : 4
        return fmt.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    static func formatPercent(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.maximumFractionDigits = 1
        return "\(fmt.string(from: NSNumber(value: value)) ?? "0")%"
    }

    static func formatInt(_ value: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatRange(_ start: String?, _ end: String?) -> String {
        [start, end].compactMap { $0 }.compactMap { s -> String? in
            guard let d = SharedFormatters.parseISO8601(s) else { return nil }
            return DateFormat.string(from: d, format: "MMM d")
        }.joined(separator: " → ")
    }

    static func formatShortDateTime(_ value: String?) -> String? {
        guard let v = value, let date = parseDate(v) else { return nil }
        return DateFormat.string(from: date, format: "MMM d, HH:mm")
    }

    private static func parseDate(_ s: String) -> Date? {
        SharedFormatters.parseISO8601(s)
    }

    private static func isWithinHours(_ value: String, hours: Double) -> Bool {
        guard let date = parseDate(value) else { return false }
        let diff = date.timeIntervalSinceNow
        return diff > 0 && diff <= hours * 3600
    }

    private static func joinParts(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap { $0 }
        return filtered.isEmpty ? nil : filtered.joined(separator: " / ")
    }

    private static func titleCase(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "_- ")).map { $0.capitalized }.joined(separator: " ")
    }

    private static func roundNumber(_ value: Double, digits: Int) -> Double {
        let factor = pow(10.0, Double(digits))
        return (value * factor).rounded() / factor
    }
}
