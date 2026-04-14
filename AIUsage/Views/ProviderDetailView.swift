import SwiftUI
import AppKit
import QuotaBackend

struct ProviderDetailView: View {
    let provider: ProviderData
    let titleOverride: String?
    let subtitleOverride: String?
    let accountDisplayOverride: String?
    let accountEntry: ProviderAccountEntry?
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) var dismiss
    @State private var copiedMessage: String?
    @State private var showingNoteEditor = false
    @State private var showingRemovalAlert = false

    init(
        provider: ProviderData,
        titleOverride: String? = nil,
        subtitleOverride: String? = nil,
        accountDisplayOverride: String? = nil,
        accountEntry: ProviderAccountEntry? = nil
    ) {
        self.provider = provider
        self.titleOverride = titleOverride
        self.subtitleOverride = subtitleOverride
        self.accountDisplayOverride = accountDisplayOverride
        self.accountEntry = accountEntry
    }
    
    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var isRefreshing: Bool {
        appState.isRefreshInProgress(for: provider)
    }

    private var refreshTimestamp: Date? {
        appState.accountRefreshDate(for: provider)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 头部
                headerSection
                
                Divider()
                
                // Headline 信息
                headlineSection

                if accountEntry != nil {
                    Divider()
                    accountManagementSection
                }
                
                // Quota Windows
                if !provider.windows.isEmpty {
                    Divider()
                    windowsSection
                }
                
                // Metrics
                if !provider.metrics.isEmpty {
                    Divider()
                    metricsSection
                }
                
                // Cost Summary (for local-cost providers)
                if let costSummary = provider.costSummary {
                    Divider()
                    costSection(costSummary)
                }
                
                // Models (for cost tracking providers)
                if let models = provider.models, !models.isEmpty {
                    Divider()
                    modelsSection(models)
                }
                
                // Spotlight
                if let spotlight = provider.spotlight {
                    Divider()
                    spotlightSection(spotlight)
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingNoteEditor) {
            if let accountEntry {
                AccountNoteEditorView(
                    providerTitle: accountEntry.providerTitle,
                    accountLabel: accountEntry.cardTitle,
                    note: accountEntry.accountNote
                ) { updatedNote in
                    appState.updateAccountNote(for: accountEntry, note: updatedNote)
                }
                .environmentObject(appState)
            }
        }
        .alert(
            t("Remove Account", "删除账号"),
            isPresented: $showingRemovalAlert
        ) {
            Button(t("Delete", "删除"), role: .destructive) {
                if let accountEntry {
                    appState.deleteAccount(accountEntry)
                }
                dismiss()
            }
            Button(t("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(
                t(
                    "This removes the account from your monitor list. If a credential is linked, it will also be removed from Keychain. Hidden accounts can be restored from the Providers toolbar.",
                    "这会把该账号从监控列表中移除；如果绑定了凭证，也会一并从钥匙串删除。已隐藏账号可以在服务商顶部工具栏恢复。"
                )
            )
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 16) {
            ProviderIconView(provider.providerId, size: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(width: 64, height: 64)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(detailTitle)
                    .font(.title)
                    .bold()
                
                if let subtitle = detailSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                if let account = detailAccountLabel {
                    Label(account, systemImage: accountIdentityIcon(for: account))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if let membership = provider.membershipLabel {
                        badge(text: membership, tint: membershipBadgeTint(for: membership))
                    }

                    if shouldShowStatusBadge {
                        badge(text: localizedStatusLabel(provider.statusLabel), tint: statusColor)
                    }
                }

                if let refreshTimestamp {
                    HStack(spacing: 4) {
                        Text(t("Updated", "更新于"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        RefreshableTimeView(
                            date: refreshTimestamp,
                            language: appState.language,
                            font: .caption2,
                            foregroundStyle: .secondary
                        )
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task {
                            await appState.refreshProviderCardNow(provider)
                        }
                    } label: {
                        Label(
                            isRefreshing ? t("Refreshing Account", "刷新账号中") : t("Refresh Account", "刷新账号"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)

                    if let copyTarget = copyTargetValue {
                        Button {
                            copyToPasteboard(copyTarget)
                            copiedMessage = t("Copied", "已复制")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedMessage = nil
                            }
                        } label: {
                            Label(t("Copy", "复制"), systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let copiedMessage {
                    Text(copiedMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Headline Section
    
    private var headlineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider.headline.eyebrow)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            
            Text(provider.headline.primary)
                .font(.system(size: 36, weight: .bold))
            
            Text(provider.headline.secondary)
                .font(.title3)
                .foregroundColor(.secondary)
            
            if let supporting = provider.headline.supporting {
                Text(supporting)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private var accountManagementSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Account Management", "账号管理"))
                .font(.title2)
                .bold()

            if let accountEntry {
                VStack(alignment: .leading, spacing: 8) {
                    Text(accountEntry.cardTitle)
                        .font(.headline)

                    Text(accountEntry.cardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let accountLabel = detailAccountLabel {
                        Label(accountLabel, systemImage: accountIdentityIcon(for: accountLabel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(
                        accountEntry.accountNote?.nilIfBlank
                            ?? t("No note yet. Add one to make this account easier to recognize later.", "当前还没有注释。你可以补一条，后面就更容易区分这个账号。")
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        showingNoteEditor = true
                    } label: {
                        Label(t("Edit Note", "编辑注释"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showingRemovalAlert = true
                    } label: {
                        Label(t("Remove from Monitor", "移出监控"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
    
    // MARK: - Windows Section
    
    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Quota Windows", "配额窗口"))
                .font(.title2)
                .bold()
            
            VStack(spacing: 12) {
                ForEach(provider.windows) { window in
                    QuotaWindowRow(window: window)
                }
            }
        }
    }
    
    // MARK: - Metrics Section
    
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Metrics", "指标"))
                .font(.title2)
                .bold()
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(provider.metrics) { metric in
                    MetricCard(metric: metric)
                }
            }
        }
    }
    
    // MARK: - Cost Section
    
    private func costSection(_ costSummary: CostSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Claude Code Stats", "Claude Code 统计"))
                .font(.title2)
                .bold()
            
            HStack(spacing: 16) {
                if let today = costSummary.today {
                    CostPeriodCard(label: t("Today", "今天"), period: today)
                }
                if let week = costSummary.week {
                    CostPeriodCard(label: t("This Week", "本周"), period: week)
                }
                if let month = costSummary.month {
                    CostPeriodCard(label: t("This Month", "本月"), period: month)
                }
            }
        }
    }
    
    // MARK: - Models Section
    
    private func modelsSection(_ models: [ModelInfo]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Models", "模型"))
                .font(.title2)
                .bold()
            
            VStack(spacing: 8) {
                ForEach(models) { model in
                    HStack {
                        Text(model.label)
                            .font(.body)
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.value)
                                .font(.callout)
                                .bold()
                            
                            if let note = model.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
        }
    }
    
    // MARK: - Spotlight Section
    
    private func spotlightSection(_ spotlight: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                provider.category == "local-cost"
                    ? t("About This Tracker", "关于此追踪源")
                    : t("About This Provider", "关于此服务商"),
                systemImage: "lightbulb.fill"
            )
                .font(.headline)
                .foregroundColor(.orange)
            
            Text(spotlight)
                .font(.body)
                .foregroundColor(.secondary)
                .lineSpacing(4)
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Helpers

    private var detailSubtitle: String? {
        if let subtitleOverride = subtitleOverride?.nilIfBlank {
            return subtitleOverride
        }
        if provider.name != provider.label {
            return provider.name
        }
        return nil
    }

    private var detailTitle: String {
        titleOverride?.nilIfBlank ?? provider.label
    }

    private var detailAccountLabel: String? {
        preferredAccountIdentityLabel(
            [
                accountDisplayOverride,
                provider.accountLabel,
                provider.accountId
            ],
            excluding: detailTitle
        )
    }
    
    private func localizedStatusLabel(_ label: String) -> String {
        guard appState.language == "zh" else { return label }
        switch label {
        case "Healthy":  return "正常"
        case "Watch":    return "偏低"
        case "Critical": return "告急"
        case "Error":    return "错误"
        case "Tracking": return "追踪中"
        case "Idle":     return "空闲"
        case "Active":   return "活跃"
        default: return label
        }
    }

    private var accentColor: Color {
        switch provider.providerId {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude": return .purple
        case "cursor": return .green
        case "gemini": return .orange
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "warp": return .pink
        case "amp": return .teal
        default: return .gray
        }
    }
    
    private var statusColor: Color {
        switch provider.status {
        case .healthy: return .green
        case .watch: return .orange
        case .critical: return .red
        case .error: return .gray
        case .tracking: return .blue
        case .idle: return .secondary
        }
    }

    private var shouldShowStatusBadge: Bool {
        switch provider.status {
        case .critical, .error, .tracking, .idle:
            return true
        case .healthy, .watch:
            return false
        }
    }

    private func badge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .bold()
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(colorScheme == .dark ? 0.35 : 0.18), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private var copyTargetValue: String? {
        detailAccountLabel?.nilIfBlank
            ?? provider.accountLabel?.nilIfBlank
            ?? provider.accountId?.nilIfBlank
            ?? titleOverride?.nilIfBlank
            ?? detailSubtitle?.nilIfBlank
            ?? provider.sourceLabel.nilIfBlank
    }
    
    
    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - Supporting Components

struct QuotaWindowRow: View {
    let window: QuotaWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.label)
                    .font(.headline)
                
                Spacer()
                
                Text(window.value)
                    .font(.callout)
                    .bold()
            }
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 8)
                    
                    // Remaining (green to red gradient)
                    if let remaining = window.remainingPercent {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(progressColor(remaining))
                            .frame(width: geometry.size.width * (remaining / 100), height: 8)
                    }
                }
            }
            .frame(height: 8)
            
            Text(window.note)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
    
    private func progressColor(_ remaining: Double) -> Color {
        if remaining > 50 {
            return .green
        } else if remaining > 20 {
            return .orange
        } else {
            return .red
        }
    }
}

struct MetricCard: View {
    let metric: Metric
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(metric.value)
                .font(.title3)
                .bold()
            
            if let note = metric.note {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct CostPeriodCard: View {
    let label: String
    let period: CostPeriod
    @EnvironmentObject var appState: AppState

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            Text(formatCurrency(period.usd))
                .font(.title2)
                .bold()

            if let tokens = period.tokens {
                Text("\(formatNumber(tokens)) \(t("tokens", "个 tokens"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let rangeLabel = period.rangeLabel {
                Text(rangeLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}


#Preview {
    let sampleProvider = ProviderData(
        id: "copilot",
        providerId: "copilot",
        accountId: nil,
        name: "GitHub Copilot",
        label: "Copilot",
        description: "GitHub Copilot usage tracking",
        category: "quota",
        channel: "ide",
        status: .healthy,
        statusLabel: "Healthy",
        theme: ProviderTheme(accent: "blue", glow: "#5aa2ff"),
        sourceLabel: "GitHub CLI",
        sourceType: "gh-cli",
        fetchedAt: SharedFormatters.iso8601String(from: Date()),
        accountLabel: "copilot@example.com",
        membershipLabel: "Pro",
        headline: Headline(
            eyebrow: "Plan · Individual Pro",
            primary: "72%",
            secondary: "tightest remaining allowance",
            supporting: "Billing cycle: Mar 1 → Mar 31"
        ),
        metrics: [
            Metric(label: "Account", value: "octocat", note: nil),
            Metric(label: "Plan", value: "Individual Pro", note: nil),
            Metric(label: "Reset", value: "Mar 31, 11:59 PM", note: nil),
            Metric(label: "Source", value: "GitHub CLI", note: nil)
        ],
        windows: [
            QuotaWindow(label: "Premium", remainingPercent: 72, usedPercent: 28, value: "72% left", note: "1,200 total • Resets Mar 31", resetAt: nil),
            QuotaWindow(label: "Chat", remainingPercent: nil, usedPercent: nil, value: "Unlimited", note: "No fixed cap detected", resetAt: nil),
            QuotaWindow(label: "Completions", remainingPercent: 85, usedPercent: 15, value: "850 left", note: "1,000 total • Resets Mar 31", resetAt: nil)
        ],
        remainingPercent: 72,
        nextResetAt: "2026-03-31T23:59:59Z",
        nextResetLabel: "Mar 31, 11:59 PM",
        spotlight: "Copilot can mix unlimited and metered lanes. The dashboard keeps unlimited channels visible, but only metered windows affect watch and critical states.",
        models: nil,
        costSummary: nil
    )
    
    ProviderDetailView(provider: sampleProvider)
}
