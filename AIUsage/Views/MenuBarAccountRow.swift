import SwiftUI
import QuotaBackend

// MARK: - Account Row (with multi-window quota bars)
// 菜单栏单个账号行：状态点 / 主副标签 / 会员徽章 / 剩余百分比或月费 / 激活切换，
// 以及（非费用类、有窗口时）多窗口配额条。拆出以控制 MenuBarView 文件规模。

struct MenuBarAccountRow: View {
    let entry: ProviderAccountEntry
    let providerId: String
    let accentColor: Color
    @Binding var activationMessage: String?
    @Binding var activationSuccess: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var activationManager: ProviderActivationManager
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var isActive: Bool { activationManager.isActiveAccount(entry) }
    private var canActivate: Bool { activationManager.canActivateProvider(providerId) && !isActive }
    private var remainingPercent: Double? { entry.liveProvider?.remainingPercent }
    private var isCostProvider: Bool { entry.liveProvider?.category == ProviderCategory.localCost }
    private var costMonthUsd: Double? { entry.liveProvider?.costSummary?.month?.usd }
    private var windows: [QuotaWindow] { entry.liveProvider?.windows ?? [] }
    @State private var isWindowsExpanded = false

    private var isPinnedToStatusBar: Bool {
        if isCostProvider {
            return settings.menuBarPinnedCostSourceIds.contains(entry.id)
        }
        return settings.menuBarPinnedQuotaAccountIds.contains(entry.id)
    }

    private var primaryLabel: String {
        if let email = entry.accountEmail, !email.isEmpty { return email }
        if let name = entry.accountDisplayName, !name.isEmpty { return name }
        return entry.providerTitle
    }

    private var secondaryLabel: String? {
        if let note = entry.accountNote?.nilIfBlank {
            return note
        }
        return nil
    }

    private var membershipBadge: String? {
        entry.liveProvider?.membershipLabel?.nilIfBlank
    }

    private var membershipColor: Color {
        membershipBadgeTint(for: membershipBadge)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            accountHeader

            if !isCostProvider && !windows.isEmpty {
                quotaWindowBars
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isPinnedToStatusBar ? accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .onTapGesture { if canActivate { performActivation() } }
        .contextMenu { pinContextMenu }
    }

    private var rowBackground: Color {
        if isPinnedToStatusBar {
            return isHovered
                ? accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10)
                : accentColor.opacity(colorScheme == .dark ? 0.08 : 0.05)
        }
        return isHovered ? Color.primary.opacity(0.06) : Color.clear
    }

    @ViewBuilder
    private var pinContextMenu: some View {
        Button {
            togglePin()
        } label: {
            if isPinnedToStatusBar {
                Label(L("Unpin from Menu Bar", "从菜单栏取消固定"), systemImage: "pin.slash")
            } else {
                Label(L("Pin to Menu Bar", "固定到菜单栏"), systemImage: "pin")
            }
        }
    }

    private func togglePin() {
        if isCostProvider {
            var ids = settings.menuBarPinnedCostSourceIds
            if ids.contains(entry.id) { ids.remove(entry.id) } else { ids.insert(entry.id) }
            settings.menuBarPinnedCostSourceIds = ids
        } else {
            var ids = settings.menuBarPinnedQuotaAccountIds
            if ids.contains(entry.id) { ids.remove(entry.id) } else { ids.insert(entry.id) }
            settings.menuBarPinnedQuotaAccountIds = ids
        }
    }

    // MARK: - Account Header

    private var accountHeader: some View {
        HStack(spacing: 8) {
            if isCostProvider {
                statusDot(color: entry.isConnected ? .orange : .gray)
            } else if remainingPercent == nil {
                if entry.isConnected {
                    statusDot(color: entry.liveProvider?.status == .error ? .orange : .green)
                } else {
                    statusDot(color: .gray)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(primaryLabel)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if let badge = membershipBadge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(membershipColor.opacity(0.85))
                            .clipShape(Capsule())
                    }

                    if isPinnedToStatusBar {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(accentColor.opacity(0.5))
                            .rotationEffect(.degrees(45))
                    }
                }

                if let secondary = secondaryLabel {
                    Text(secondary)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isCostProvider, let usd = costMonthUsd {
                Text(MenuBarHelpers.formatCostCompact(usd))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
            } else if let percent = remainingPercent {
                Text("\(Int(percent))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(MenuBarHelpers.quotaColor(percent))
            }

            if isActive && activationManager.canActivateProvider(providerId) {
                activeBadge
            } else if canActivate {
                switchButton
            }
        }
    }

    // MARK: - Multi-Window Quota Bars

    private static let maxVisibleWindows = 3

    @ViewBuilder
    private var quotaWindowBars: some View {
        let hasOverflow = windows.count > Self.maxVisibleWindows
        let displayWindows = isWindowsExpanded ? windows : Array(windows.prefix(Self.maxVisibleWindows))

        VStack(alignment: .leading, spacing: 3) {
            if isWindowsExpanded {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 2)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(Array(displayWindows.enumerated()), id: \.offset) { _, window in
                        MenuBarQuotaBar(window: window)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(displayWindows.enumerated()), id: \.offset) { _, window in
                        MenuBarQuotaBar(window: window)
                    }
                }
            }

            if hasOverflow {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isWindowsExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isWindowsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                        Text(isWindowsExpanded
                             ? L("Collapse", "收起")
                             : "+\(windows.count - Self.maxVisibleWindows) " + L("more", "更多"))
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Subviews

    private func statusDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .frame(width: 28, height: 28)
    }

    private var activeBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text(L("Active", "活跃"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.12))
        .clipShape(Capsule())
    }

    private var switchButton: some View {
        Button {
            performActivation()
        } label: {
            Text(L("Switch", "切换"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func performActivation() {
        do {
            try activationManager.activateAccount(entry: entry)
            withAnimation(.easeInOut(duration: 0.3)) {
                activationSuccess = true
                activationMessage = L("Switched to ", "已切换至 ") + primaryLabel
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.3)) {
                activationSuccess = false
                activationMessage = L("Switch failed", "切换失败")
            }
        }
    }
}
