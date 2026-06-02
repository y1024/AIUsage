import Foundation

extension UsageNormalizer {

    // MARK: - Kimi Code
    // 把 Kimi Code `/usages` 的频控窗口 + 周限规整成统一卡片（对齐 Codex 的双窗口排序）：
    //   primary  → 5 小时滚动频控窗口（"5h Window"），secondary → 周限（"Weekly Window"）。

    static func normalizeKimi(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary {
            let label = extraString(usage, "primaryLabel").flatMap { $0.isEmpty ? nil : $0 } ?? "5h Window"
            windows.append(createPercentWindow(label: label, window: w))
        }
        if let w = usage.secondary {
            let label = extraString(usage, "secondaryLabel").flatMap { $0.isEmpty ? nil : $0 } ?? "Weekly Window"
            windows.append(createPercentWindow(label: label, window: w))
        }
        if let w = usage.tertiary {
            let label = extraString(usage, "tertiaryLabel").flatMap { $0.isEmpty ? nil : $0 } ?? "Rate Limit"
            windows.append(createPercentWindow(label: label, window: w))
        }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)

        let planName = usage.accountPlan?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Kimi Code"
        let modelEntitlement = extraString(usage, "modelEntitlement").flatMap { $0.isEmpty ? nil : $0 }
        let rateReset = usage.primary?.resetAt
        let weeklyReset = usage.secondary?.resetAt

        var metrics: [MetricInfo] = [
            MetricInfo(label: "Plan", value: planName)
        ]
        if let email = usage.accountEmail?.nilIfEmpty {
            metrics.append(MetricInfo(label: "Account", value: email))
        }
        if let model = modelEntitlement {
            metrics.append(MetricInfo(label: "Model", value: model))
        }
        if let reset = formatShortDateTime(rateReset) {
            metrics.append(MetricInfo(label: "5h Reset", value: reset))
        }
        if let reset = formatShortDateTime(weeklyReset) {
            metrics.append(MetricInfo(label: "Weekly Reset", value: reset))
        }
        metrics.append(MetricInfo(label: "Source", value: formatSourceLabel(usage.source)))

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: usage.accountPlan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = rateReset ?? weeklyReset
        base.nextResetLabel = formatShortDateTime(rateReset ?? weeklyReset)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(planName)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Tracked",
            secondary: remainingPercent == nil ? "Kimi Code subscription usage" : "tightest Kimi Code window",
            supporting: usage.accountEmail?.nilIfEmpty ?? modelEntitlement ?? "Kimi Code"
        )
        base.metrics = metrics
        base.windows = windows
        base.spotlight = "Kimi Code shares one quota across CLI, IDE, and API keys. The weekly window resets every 7 days; the rolling rate-limit window recovers within a few hours."
        return base
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
