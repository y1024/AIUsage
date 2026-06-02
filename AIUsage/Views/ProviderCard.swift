import SwiftUI
import AppKit
import QuotaBackend

struct ProviderCard: View {
    let provider: ProviderData
    let titleOverride: String?
    let subtitleOverride: String?
    let footerAccountLabelOverride: String?
    let accountEntry: ProviderAccountEntry?
    let refreshAction: (() async -> Void)?
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @EnvironmentObject var activationManager: ProviderActivationManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var showingDetail = false
    @State private var activationMessage: String?
    @State private var showActivationAlert = false

    init(
        provider: ProviderData,
        titleOverride: String? = nil,
        subtitleOverride: String? = nil,
        footerAccountLabelOverride: String? = nil,
        accountEntry: ProviderAccountEntry? = nil,
        refreshAction: (() async -> Void)? = nil
    ) {
        self.provider = provider
        self.titleOverride = titleOverride
        self.subtitleOverride = subtitleOverride
        self.footerAccountLabelOverride = footerAccountLabelOverride
        self.accountEntry = accountEntry
        self.refreshAction = refreshAction
    }
    private var isRefreshing: Bool {
        refreshCoordinator.isRefreshInProgress(for: provider)
    }

    private var refreshTimestamp: Date? {
        refreshCoordinator.accountRefreshDate(for: provider)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                providerIcon
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.headline)
                        .bold()
                    
                    if let subtitle = headerSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        if isActiveProviderAccount && canActivateProvider {
                            badge(text: L("Active", "当前"), tint: .green)
                        }

                        if let membership = provider.membershipLabel {
                            badge(text: membership, tint: membershipBadgeTint(for: membership))
                        }

                        if shouldShowStatusBadge {
                            statusBadge
                        }
                    }
                }
            }

            if let headlineValue = compactHeadlineValue {
                Text(headlineValue)
                    .font(.system(size: provider.remainingPercent == nil ? 30 : 24, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if useMultiWindowLayout {
                Spacer(minLength: 0)
                MultiWindowQuotaView(windows: provider.windows, accentColor: accentColor)
            } else {
                Spacer(minLength: 0)

                if let remaining = provider.remainingPercent {
                    QuotaIndicatorView(remainingPercent: remaining, accentColor: accentColor, resetAt: provider.nextResetAt)
                } else {
                    Color.clear.frame(height: quotaIndicatorPlaceholderHeight)
                }
            }
            
            // 底部信息
            HStack(alignment: .center) {
                if let account = footerAccountLabel {
                    Label(account, systemImage: accountIdentityIcon(for: account))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if canActivateProvider && !isActiveProviderAccount {
                    Button {
                        activateThisAccount()
                    } label: {
                        Label(L("Activate", "激活"), systemImage: "bolt.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(accentColor)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
                    .help(L("Set as active CLI account", "设为当前 CLI 账号"))
                }

                Button {
                    Task {
                        if let refreshAction {
                            await refreshAction()
                        } else {
                            await refreshCoordinator.refreshProviderCardNow(provider)
                        }
                    }
                } label: {
                    ZStack {
                        if isRefreshing {
                            SmallProgressView()
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(isHovered ? accentColor : .secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isHovered ? accentColor.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isRefreshing ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .disabled(isRefreshing)
                .help(L("Refresh only this account", "只刷新这个账号"))

                if let refreshTimestamp, !isRefreshing {
                    RefreshableTimeView(
                        date: refreshTimestamp,
                        language: appState.language,
                        font: .caption2,
                        foregroundStyle: .secondary
                    )
                }
            }
        }
        .frame(minHeight: 148)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(cardBackgroundColor)
                .shadow(color: cardShadowColor,
                       radius: isHovered ? 12 : 4, 
                       x: 0, 
                       y: isHovered ? 6 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(cardBorderColor, lineWidth: isHovered ? 1.5 : 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            showingDetail = true
        }
        .contextMenu {
            Button {
                showingDetail = true
            } label: {
                Label(L("Open Details", "查看详情"), systemImage: "doc.text.magnifyingglass")
            }

            Button {
                Task {
                    if let refreshAction {
                        await refreshAction()
                    } else {
                        await refreshCoordinator.refreshProviderCardNow(provider)
                    }
                }
            } label: {
                Label(L("Refresh This Account", "刷新此账号"), systemImage: "arrow.clockwise")
            }

            if canActivateProvider {
                Divider()
                if isActiveProviderAccount {
                    Label(L("Active Account", "当前账号"), systemImage: "checkmark.circle.fill")
                } else {
                    Button {
                        activateThisAccount()
                    } label: {
                        Label(L("Set as Active Account", "设为当前账号"), systemImage: "bolt.fill")
                    }
                }
            }

            if let account = footerAccountLabel {
                Button {
                    copyToPasteboard(account)
                } label: {
                    Label(L("Copy Account", "复制账号"), systemImage: "doc.on.doc")
                }
            }
        }
        .sheet(isPresented: $showingDetail) {
            ProviderDetailView(
                provider: provider,
                titleOverride: titleOverride,
                subtitleOverride: subtitleOverride,
                accountDisplayOverride: footerAccountLabelOverride,
                accountEntry: accountEntry
            )
        }
        .alert(L("Account Switch", "账号切换"), isPresented: $showActivationAlert) {
            Button("OK") { activationMessage = nil }
        } message: {
            Text(activationMessage ?? "")
        }
    }
    
    // MARK: - Components
    
    private var providerIcon: some View {
        ProviderIconView(provider.providerId, size: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(width: 44, height: 44)
    }

    private var headerTitle: String {
        titleOverride?.nilIfBlank ?? provider.label
    }

    private var headerSubtitle: String? {
        subtitleOverride?.nilIfBlank
    }

    private var footerAccountLabel: String? {
        if let wsLabel = provider.workspaceLabel, wsLabel != "Personal",
           let email = preferredAccountIdentityLabel(
               [footerAccountLabelOverride, provider.accountLabel, provider.accountId],
               excluding: headerTitle
           ) {
            return "\(wsLabel) · \(email)"
        }
        return preferredAccountIdentityLabel(
            [
                footerAccountLabelOverride,
                provider.accountLabel,
                provider.accountId
            ],
            excluding: headerTitle
        )
    }

    private var compactHeadlineValue: String? {
        guard let primary = provider.headline.primary.nilIfBlank else { return nil }
        if provider.remainingPercent != nil {
            return nil
        }
        return primary
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

    private var statusBadge: some View {
        badge(text: localizedStatusLabel(provider.statusLabel), tint: statusColor)
    }
    
    // MARK: - Helpers
    
    private var accentColor: Color {
        switch provider.providerId {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude": return .purple
        case "cursor": return .green
        case "gemini": return .orange
        case "kimi": return Color(red: 0.09, green: 0.51, blue: 1.0)
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "warp": return .pink
        case "amp": return .teal
        default: return .gray
        }
    }

    private var canActivateProvider: Bool {
        activationManager.canActivateProvider(provider.providerId) && accountEntry != nil
    }

    private var isActiveProviderAccount: Bool {
        guard let entry = accountEntry else { return false }
        return activationManager.isActiveAccount(entry)
    }

    private var canActivateCodex: Bool { canActivateProvider }
    private var isCodexActiveAccount: Bool { isActiveProviderAccount }

    private func activateThisAccount() {
        guard let entry = accountEntry else { return }
        do {
            try activationManager.activateAccount(entry: entry)
        } catch {
            if activationManager.activationResult == nil {
                activationMessage = SensitiveDataRedactor.redactedMessage(for: error)
                showActivationAlert = true
            }
        }
        if let result = activationManager.activationResult {
            switch result {
            case .success(let msg), .failure(let msg):
                activationMessage = msg
                showActivationAlert = true
            }
            activationManager.activationResult = nil
        }
    }

    private func activateThisCodexAccount() { activateThisAccount() }

    private var useMultiWindowLayout: Bool {
        Self.multiWindowProviderIds.contains(provider.providerId)
            && provider.windows.count >= 2
            && provider.windows.contains(where: { $0.remainingPercent != nil })
    }

    /// 采用 Codex 式双窗口（多行进度）布局的服务商：除 Codex 外，Kimi Code 也有
    /// 「5 小时滚动频控 + 7 天/本周」两个窗口，需并排展示而非只显示最紧的那一行。
    private static let multiWindowProviderIds: Set<String> = ["codex", "kimi"]

    private var shouldShowStatusBadge: Bool {
        switch provider.status {
        case .critical, .error, .tracking, .idle:
            return true
        case .healthy, .watch:
            return false
        }
    }

    private var cardBackgroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered ? 0.09 : 0.065)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorderColor: Color {
        if isHovered {
            return accentColor.opacity(colorScheme == .dark ? 0.55 : 0.28)
        }
        return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
    }

    private var cardShadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(isHovered ? 0.35 : 0.2)
        }
        return isHovered ? Color.accentColor.opacity(0.22) : Color.black.opacity(0.05)
    }
    
    private var statusColor: Color { provider.statusColor }

    private func badge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .bold()
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(colorScheme == .dark ? 0.35 : 0.18), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private var quotaIndicatorPlaceholderHeight: CGFloat {
        switch settings.quotaIndicatorStyle {
        case .bar:
            return 24
        case .ring:
            return 92
        case .segments:
            return 50
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

#Preview {
    let sampleProvider = ProviderData(
        id: "copilot",
        providerId: "copilot",
        accountId: nil,
        name: "GitHub Copilot",
        label: "Copilot",
        description: "GitHub Copilot usage",
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
            eyebrow: "Plan · Individual",
            primary: "85%",
            secondary: "remaining in this cycle",
            supporting: "GitHub account"
        ),
        metrics: [],
        windows: [],
        remainingPercent: 85,
        nextResetAt: nil,
        nextResetLabel: nil,
        spotlight: nil,
        models: nil,
        costSummary: nil
    )
    
    ProviderCard(provider: sampleProvider)
        .frame(width: 400, height: 300)
        .padding()
}
