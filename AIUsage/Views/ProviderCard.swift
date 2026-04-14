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
                        if isActiveProviderAccount {
                            badge(text: t("Active", "当前"), tint: .green)
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
                        Label(t("Activate", "激活"), systemImage: "bolt.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(accentColor)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
                    .help(t("Set as active CLI account", "设为当前 CLI 账号"))
                }

                Button {
                    Task {
                        if let refreshAction {
                            await refreshAction()
                        } else {
                            await appState.refreshProviderCardNow(provider)
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
                .help(t("Refresh only this account", "只刷新这个账号"))

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
                Label(t("Open Details", "查看详情"), systemImage: "doc.text.magnifyingglass")
            }

            Button {
                Task {
                    if let refreshAction {
                        await refreshAction()
                    } else {
                        await appState.refreshProviderCardNow(provider)
                    }
                }
            } label: {
                Label(t("Refresh This Account", "刷新此账号"), systemImage: "arrow.clockwise")
            }

            if canActivateProvider {
                Divider()
                if isActiveProviderAccount {
                    Label(t("Active Account", "当前账号"), systemImage: "checkmark.circle.fill")
                } else {
                    Button {
                        activateThisAccount()
                    } label: {
                        Label(t("Set as Active Account", "设为当前账号"), systemImage: "bolt.fill")
                    }
                }
            }

            if let account = footerAccountLabel {
                Button {
                    copyToPasteboard(account)
                } label: {
                    Label(t("Copy Account", "复制账号"), systemImage: "doc.on.doc")
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
        .alert(t("Account Switch", "账号切换"), isPresented: $showActivationAlert) {
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
        preferredAccountIdentityLabel(
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
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "warp": return .pink
        case "amp": return .teal
        default: return .gray
        }
    }

    private var canActivateProvider: Bool {
        appState.canActivateProvider(provider.providerId) && accountEntry != nil
    }

    private var isActiveProviderAccount: Bool {
        guard let entry = accountEntry else { return false }
        return appState.isActiveAccount(entry)
    }

    private var canActivateCodex: Bool { canActivateProvider }
    private var isCodexActiveAccount: Bool { isActiveProviderAccount }

    private func activateThisAccount() {
        guard let entry = accountEntry else { return }
        do {
            try appState.activateAccount(entry: entry)
        } catch {
            if appState.activationResult == nil {
                activationMessage = SensitiveDataRedactor.redactedMessage(for: error)
                showActivationAlert = true
            }
        }
        if let result = appState.activationResult {
            switch result {
            case .success(let msg), .failure(let msg):
                activationMessage = msg
                showActivationAlert = true
            }
            appState.activationResult = nil
        }
    }

    private func activateThisCodexAccount() { activateThisAccount() }

    private var useMultiWindowLayout: Bool {
        provider.providerId == "codex"
            && provider.windows.count >= 2
            && provider.windows.contains(where: { $0.remainingPercent != nil })
    }

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
        switch appState.quotaIndicatorStyle {
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

// MARK: - Multi-Window Quota View (Codex dual progress)

struct MultiWindowQuotaView: View {
    let windows: [QuotaWindow]
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private func windowLabel(_ label: String) -> String {
        guard appState.language == "zh" else { return label }
        switch label {
        case "5h Window":      return "5小时剩余"
        case "Weekly Window":  return "7天剩余"
        case "Code Review":    return "代码审查"
        default:               return label
        }
    }

    var body: some View {
        switch appState.quotaIndicatorStyle {
        case .bar:
            barLayout
        case .ring:
            ringLayout
        case .segments:
            segmentsLayout
        }
    }

    // MARK: - Bar Layout

    private var barLayout: some View {
        VStack(spacing: 10) {
            ForEach(windows.prefix(2)) { window in
                MultiWindowBarRow(window: window, label: windowLabel(window.label), accentColor: accentColor)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Ring Layout

    private var ringLayout: some View {
        HStack(spacing: 20) {
            ForEach(windows.prefix(2)) { window in
                MultiWindowRingItem(window: window, label: windowLabel(window.label), accentColor: accentColor)
                    .environmentObject(appState)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Segments Layout

    private var segmentsLayout: some View {
        VStack(spacing: 10) {
            ForEach(windows.prefix(2)) { window in
                MultiWindowSegmentsRow(window: window, label: windowLabel(window.label), accentColor: accentColor)
                    .environmentObject(appState)
            }
        }
    }
}

// MARK: - Bar Row

private struct MultiWindowBarRow: View {
    let window: QuotaWindow
    let label: String
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var clampedRemaining: Double {
        min(max(window.remainingPercent ?? 0, 0), 100)
    }

    private var displayPercent: Double {
        appState.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...: return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...: return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:    return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    private var gradientColors: [Color] {
        switch clampedRemaining {
        case 70...: return [Color(red: 0.37, green: 0.94, blue: 0.62), Color(red: 0.11, green: 0.74, blue: 0.39)]
        case 35...: return [Color(red: 1.00, green: 0.84, blue: 0.34), Color(red: 0.96, green: 0.56, blue: 0.17)]
        default:    return [Color(red: 1.00, green: 0.54, blue: 0.28), Color(red: 0.90, green: 0.20, blue: 0.29)]
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(displayText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))

                if let resetText = compactResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(resetHighlightColor)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(trackColor)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(borderColor, lineWidth: 1))

                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geometry.size.width * (displayPercent / 100), displayPercent > 0 ? 8 : 0))
                        .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 6, x: 0, y: 2)
                }
            }
            .frame(height: 8)
        }
    }

    private var compactResetText: String? {
        guard let resetAt = window.resetAt,
              let date = parseISO8601(resetAt) else { return nil }
        let remaining = max(0, Int(date.timeIntervalSinceNow))
        if remaining == 0 { return appState.language == "zh" ? "即将刷新" : "soon" }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    private var resetHighlightColor: Color {
        guard let resetAt = window.resetAt,
              let date = parseISO8601(resetAt) else { return .secondary }
        let remaining = Int(date.timeIntervalSinceNow)
        if remaining < 3_600 { return .red }
        if remaining < 21_600 { return .orange }
        return .secondary
    }

    private func parseISO8601(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }
}

// MARK: - Ring Item

private struct MultiWindowRingItem: View {
    let window: QuotaWindow
    let label: String
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var clampedRemaining: Double {
        min(max(window.remainingPercent ?? 0, 0), 100)
    }

    private var displayPercent: Double {
        appState.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var gradientColors: [Color] {
        switch clampedRemaining {
        case 70...: return [Color(red: 0.37, green: 0.94, blue: 0.62), Color(red: 0.11, green: 0.74, blue: 0.39)]
        case 35...: return [Color(red: 1.00, green: 0.84, blue: 0.34), Color(red: 0.96, green: 0.56, blue: 0.17)]
        default:    return [Color(red: 1.00, green: 0.54, blue: 0.28), Color(red: 0.90, green: 0.20, blue: 0.29)]
        }
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...: return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...: return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:    return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(colorScheme == .dark ? 0.08 : 0.06))
                Circle()
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: displayPercent / 100)
                    .stroke(
                        AngularGradient(colors: [
                            gradientColors.first?.opacity(0.45) ?? riskColor.opacity(0.45),
                            gradientColors.first ?? riskColor,
                            gradientColors.last ?? riskColor,
                            gradientColors.last?.opacity(0.45) ?? riskColor.opacity(0.45)
                        ], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text(displayText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .frame(width: 62, height: 62)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let resetText = compactResetText {
                Text(resetText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(resetHighlightColor)
            }
        }
    }

    private var compactResetText: String? {
        guard let resetAt = window.resetAt,
              let date = parseISO8601(resetAt) else { return nil }
        let remaining = max(0, Int(date.timeIntervalSinceNow))
        if remaining == 0 { return appState.language == "zh" ? "即将刷新" : "soon" }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    private var resetHighlightColor: Color {
        guard let resetAt = window.resetAt,
              let date = parseISO8601(resetAt) else { return .secondary }
        let remaining = Int(date.timeIntervalSinceNow)
        if remaining < 3_600 { return .red }
        if remaining < 21_600 { return .orange }
        return .secondary
    }

    private func parseISO8601(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }
}

// MARK: - Segments Row

private struct MultiWindowSegmentsRow: View {
    let window: QuotaWindow
    let label: String
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private let segmentHeights: [CGFloat] = [10, 13, 17, 22, 28, 32, 32, 28, 22, 17, 13, 10]

    private var clampedRemaining: Double {
        min(max(window.remainingPercent ?? 0, 0), 100)
    }

    private var displayPercent: Double {
        appState.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var gradientColors: [Color] {
        switch clampedRemaining {
        case 70...: return [Color(red: 0.37, green: 0.94, blue: 0.62), Color(red: 0.11, green: 0.74, blue: 0.39)]
        case 35...: return [Color(red: 1.00, green: 0.84, blue: 0.34), Color(red: 0.96, green: 0.56, blue: 0.17)]
        default:    return [Color(red: 1.00, green: 0.54, blue: 0.28), Color(red: 0.90, green: 0.20, blue: 0.29)]
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...: return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...: return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:    return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                if let resetText = compactResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(resetHighlightColor)
                }
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(segmentHeights.enumerated()), id: \.offset) { index, height in
                    segmentView(at: index, height: height)
                }
            }
            .frame(height: 36)
        }
    }

    private var compactResetText: String? {
        guard let resetAt = window.resetAt,
              let date = parseISO8601(resetAt) else { return nil }
        let remaining = max(0, Int(date.timeIntervalSinceNow))
        if remaining == 0 { return appState.language == "zh" ? "即将刷新" : "soon" }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    private var resetHighlightColor: Color {
        guard let resetAt = window.resetAt,
              let date = parseISO8601(resetAt) else { return .secondary }
        let remaining = Int(date.timeIntervalSinceNow)
        if remaining < 3_600 { return .red }
        if remaining < 21_600 { return .orange }
        return .secondary
    }

    private func parseISO8601(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }

    private func segmentView(at index: Int, height: CGFloat) -> some View {
        let ratio = segmentFillRatio(for: index)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4)
                .fill(trackColor)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 1))
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                .frame(height: max(height * ratio, ratio > 0 ? 6 : 0))
                .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 3, x: 0, y: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .bottom)
    }

    private func segmentFillRatio(for index: Int) -> CGFloat {
        let count = Double(segmentHeights.count)
        let start = (Double(index) / count) * 100
        let end = (Double(index + 1) / count) * 100
        if displayPercent >= end { return 1 }
        if displayPercent <= start { return 0 }
        return CGFloat(min(max((displayPercent - start) / (end - start), 0), 1))
    }
}

struct QuotaIndicatorView: View {
    let remainingPercent: Double
    let accentColor: Color
    var resetAt: String?

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private let segmentHeights: [CGFloat] = [14, 18, 24, 32, 40, 48, 48, 40, 32, 24, 18, 14]

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var clampedRemaining: Double {
        min(max(remainingPercent, 0), 100)
    }

    private var displayPercent: Double {
        appState.quotaIndicatorMetric == .remaining ? clampedRemaining : 100 - clampedRemaining
    }

    private var metricLabel: String {
        appState.quotaIndicatorMetric == .remaining ? t("Remaining", "剩余") : t("Used", "已用")
    }

    private var inlineResetText: String? {
        guard let resetAt, let date = parseResetDate(resetAt) else { return nil }
        let remaining = max(0, Int(date.timeIntervalSinceNow))
        if remaining == 0 { return appState.language == "zh" ? "即将刷新" : "soon" }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }

    private var inlineResetColor: Color {
        guard let resetAt, let date = parseResetDate(resetAt) else { return .secondary }
        let remaining = Int(date.timeIntervalSinceNow)
        if remaining < 3_600 { return .red }
        if remaining < 21_600 { return .orange }
        return .secondary
    }

    private func parseResetDate(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }

    private var riskColor: Color {
        switch clampedRemaining {
        case 70...:
            return Color(red: 0.15, green: 0.78, blue: 0.40)
        case 35...:
            return Color(red: 0.96, green: 0.64, blue: 0.18)
        default:
            return Color(red: 0.92, green: 0.25, blue: 0.28)
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var semanticGradientColors: [Color] {
        switch clampedRemaining {
        case 70...:
            return [
                Color(red: 0.37, green: 0.94, blue: 0.62),
                Color(red: 0.11, green: 0.74, blue: 0.39)
            ]
        case 35...:
            return [
                Color(red: 1.00, green: 0.84, blue: 0.34),
                Color(red: 0.96, green: 0.56, blue: 0.17)
            ]
        default:
            return [
                Color(red: 1.00, green: 0.54, blue: 0.28),
                Color(red: 0.90, green: 0.20, blue: 0.29)
            ]
        }
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            colors: semanticGradientColors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var ringGradient: AngularGradient {
        AngularGradient(
            colors: [
                semanticGradientColors.first?.opacity(0.45) ?? riskColor.opacity(0.45),
                semanticGradientColors.first ?? riskColor,
                semanticGradientColors.last ?? riskColor,
                semanticGradientColors.last?.opacity(0.45) ?? riskColor.opacity(0.45)
            ],
            center: .center
        )
    }

    private var valueGradient: LinearGradient {
        LinearGradient(
            colors: semanticGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var displayText: String {
        let rounded = (displayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    var body: some View {
        switch appState.quotaIndicatorStyle {
        case .bar:
            barStyle
        case .ring:
            ringStyle
        case .segments:
            segmentsStyle
        }
    }

    private var barStyle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metricLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(displayText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(valueGradient)

                if let resetText = inlineResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(inlineResetColor)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(trackColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(borderColor, lineWidth: 1)
                        )

                    RoundedRectangle(cornerRadius: 8)
                        .fill(meterGradient)
                        .frame(width: max(geometry.size.width * (displayPercent / 100), displayPercent > 0 ? 12 : 0))
                        .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 10, x: 0, y: 4)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18))
                        .frame(width: max(geometry.size.width * (displayPercent / 100), displayPercent > 0 ? 12 : 0), height: 5)
                        .padding(.top, 1.5)
                }
            }
            .frame(height: 12)
        }
    }

    private var ringStyle: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(colorScheme == .dark ? 0.08 : 0.06))

                Circle()
                    .stroke(trackColor, lineWidth: 10)

                Circle()
                    .trim(from: 0, to: displayPercent / 100)
                    .stroke(ringGradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.32 : 0.15), radius: 8, x: 0, y: 4)

                VStack(spacing: 1) {
                    Text(displayText)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(valueGradient)
                    Text(metricLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80, height: 80)

            if let resetText = inlineResetText {
                Text(resetText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(inlineResetColor)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var segmentsStyle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metricLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(displayText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(valueGradient)

                if let resetText = inlineResetText {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(inlineResetColor)
                }
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(segmentHeights.enumerated()), id: \.offset) { index, height in
                    segment(at: index, height: height)
                }
            }
            .frame(height: 52)
        }
    }

    private func segment(at index: Int, height: CGFloat) -> some View {
        let ratio = segmentFillRatio(for: index)

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5)
                .fill(trackColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(borderColor, lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 5)
                .fill(meterGradient)
                .frame(height: max(height * ratio, ratio > 0 ? 8 : 0))
                .shadow(color: riskColor.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 4, x: 0, y: 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .bottom)
    }

    private func segmentFillRatio(for index: Int) -> CGFloat {
        let count = Double(segmentHeights.count)
        let start = (Double(index) / count) * 100
        let end = (Double(index + 1) / count) * 100

        if displayPercent >= end {
            return 1
        }
        if displayPercent <= start {
            return 0
        }

        let partial = (displayPercent - start) / (end - start)
        return CGFloat(min(max(partial, 0), 1))
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

struct ResetCountdownView: View {
    let resetAt: String
    let accentColor: Color

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var resetDate: Date? {
        Self.parseISO8601(resetAt)
    }

    var body: some View {
        if let resetDate {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let snapshot = countdownSnapshot(to: resetDate, now: context.date)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(t("Next reset", "下次刷新"), systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(accentColor)

                        Spacer()

                        Text(absoluteResetText(resetDate))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        CountdownUnitView(value: snapshot.days, unit: t("D", "天"), accentColor: accentColor, emphasized: snapshot.days > 0)
                        CountdownUnitView(value: snapshot.hours, unit: t("H", "时"), accentColor: accentColor, emphasized: snapshot.days == 0 && snapshot.hours > 0)
                        CountdownUnitView(value: snapshot.minutes, unit: t("M", "分"), accentColor: accentColor, emphasized: snapshot.days == 0 && snapshot.hours == 0)

                        Spacer(minLength: 8)

                        Text(snapshot.primaryLabel(language: appState.language))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(snapshot.highlightColor)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(backgroundGradient)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(borderColor(for: snapshot), lineWidth: 1)
                )
            }
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10),
                Color.white.opacity(colorScheme == .dark ? 0.02 : 0.45)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func borderColor(for snapshot: CountdownSnapshot) -> Color {
        snapshot.highlightColor.opacity(colorScheme == .dark ? 0.34 : 0.18)
    }

    private func absoluteResetText(_ date: Date) -> String {
        let locale = Locale(identifier: appState.language == "zh" ? "zh_CN" : "en_US")
        let format = appState.language == "zh" ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return DateFormat.formatter(format, timeZone: .current, locale: locale).string(from: date)
    }

    private func countdownSnapshot(to target: Date, now: Date) -> CountdownSnapshot {
        let remaining = max(0, Int(target.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = max(0, (remaining % 3_600) / 60)
        return CountdownSnapshot(days: days, hours: hours, minutes: minutes, totalSeconds: remaining)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }
}

private struct CountdownUnitView: View {
    let value: Int
    let unit: String
    let accentColor: Color
    let emphasized: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%02d", value))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasized ? Color.primary : .primary.opacity(0.9))

            Text(unit)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 46)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tileBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tileBorder, lineWidth: 1)
        )
    }

    private var tileBackground: Color {
        if emphasized {
            return accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
        return colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.55)
    }

    private var tileBorder: Color {
        if emphasized {
            return accentColor.opacity(colorScheme == .dark ? 0.40 : 0.2)
        }
        return colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
}

private struct CountdownSnapshot {
    let days: Int
    let hours: Int
    let minutes: Int
    let totalSeconds: Int

    var highlightColor: Color {
        switch totalSeconds {
        case ..<3_600:
            return .red
        case ..<21_600:
            return .orange
        default:
            return .green
        }
    }

    func primaryLabel(language: String) -> String {
        if totalSeconds == 0 {
            return language == "zh" ? "即将刷新" : "Refreshing soon"
        }
        if days > 0 {
            return language == "zh" ? "\(days)天 \(hours)小时" : "\(days)d \(hours)h"
        }
        if hours > 0 {
            return language == "zh" ? "\(hours)小时 \(minutes)分钟" : "\(hours)h \(minutes)m"
        }
        return language == "zh" ? "\(max(1, minutes))分钟内" : "within \(max(1, minutes))m"
    }
}
