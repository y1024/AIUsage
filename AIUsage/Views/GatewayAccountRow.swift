import SwiftUI

// MARK: - Gateway Account Row（单列紧凑）
// 可用性以「能否拉到该账号模型」为准；同步只保留「从订阅更新」，不做指纹告警。

enum GatewayAccountRowPresentation: Equatable {
    case account
    case loginDetails
    case project
}

struct GatewayAccountRow: View {
    let file: CLIProxyAuthFile
    let identity: CLIProxyAccountIdentity?
    let linkedCandidate: CLIProxyAccountSyncCandidate?
    let isBusy: Bool
    /// 已缓存模型数；`nil` 表示尚未探测。
    var modelCount: Int? = nil
    var modelLoadFailed: Bool = false
    var presentation: GatewayAccountRowPresentation = .account
    let onOpenDetail: () -> Void
    let onRequestSync: (CLIProxyAccountSyncCandidate) -> Void
    let onTestAvailability: () -> Void
    let onSetEnabled: (Bool) -> Void
    let onAddToSubscription: () -> Void
    let onDelete: () -> Void
    /// Codex 等可导入订阅侧的账号为 true。
    var showsAddToSubscription: Bool = false

    private var planText: String? {
        GatewayAccountListLogic.planBadgeText(file: file, identity: identity)
    }

    private var planTint: Color {
        membershipBadgeTint(for: planText)
    }

    private var emailInitial: String {
        let label = primaryLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = label.first else { return "?" }
        return String(first).uppercased()
    }

    private var primaryLabel: String {
        switch presentation {
        case .account:
            return file.displayLabel
        case .loginDetails:
            return L("Sign-in details", "登录信息")
        case .project:
            return file.gatewayProjectDisplayLabel ?? L("Project", "项目")
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            emailAvatar

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    identityChip
                    if let planText {
                        GatewayQuietBadge(text: planText, tint: planTint)
                    }
                    if let modelCount, !modelLoadFailed {
                        GatewayQuietBadge(
                            text: L("\(modelCount) models", "\(modelCount) 模型"),
                            tint: .secondary
                        )
                    }
                }

                if let note = file.gatewayVisibleNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailingStatus

            Toggle("", isOn: Binding(
                get: { !file.disabled },
                set: { onSetEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isBusy)
            .accessibilityLabel(L("Enable account \(primaryLabel)", "启用账号 \(primaryLabel)"))

            moreMenu
        }
        .padding(.leading, presentation == .account ? 12 : 46)
        .padding(.trailing, 12)
        .padding(.vertical, presentation == .account ? 9 : 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(presentation == .account ? 0.018 : 0.010))
        )
        .overlay(alignment: .leading) {
            if presentation == .account {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(planTint.opacity(0.85))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
        .contextMenu { rowContextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: L("Show account details", "查看账号详情"), onOpenDetail)
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button(action: onOpenDetail) {
            Label(L("Account Details", "账号详情"), systemImage: "info.circle")
        }
        Button(action: onTestAvailability) {
            Label(L("Test availability", "测试可用性"), systemImage: "waveform.path.ecg")
        }
        if let linkedCandidate {
            Button {
                onRequestSync(linkedCandidate)
            } label: {
                Label(
                    L("Update from Subscription", "从订阅更新"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
        }
        if showsAddToSubscription {
            Divider()
            Button(action: onAddToSubscription) {
                Label(
                    L("Add to Subscription Accounts", "添加到订阅账号"),
                    systemImage: "person.badge.plus"
                )
            }
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label(L("Remove from CPA", "从 CPA 删除"), systemImage: "trash")
        }
    }

    private var emailAvatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [planTint.opacity(0.28), planTint.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if presentation != .account {
                Image(systemName: presentation == .project ? "folder.fill" : "key.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(planTint)
            } else {
                Text(emailInitial)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(planTint)
            }
        }
        .frame(width: 30, height: 30)
        .overlay {
            if presentation == .account {
                GatewayProviderIcon(providerID: file.gatewayProviderID, size: 14)
                    .offset(x: 10, y: 10)
            }
        }
        .accessibilityHidden(true)
    }

    private var identityChip: some View {
        HStack(spacing: 5) {
            Image(systemName: identitySystemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(planTint.opacity(0.85))
            Text(primaryLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            presentation == .account ? planTint.opacity(0.10) : Color.clear,
            in: Capsule()
        )
    }

    private var identitySystemImage: String {
        switch presentation {
        case .account: "envelope.fill"
        case .loginDetails: "key.fill"
        case .project: "folder.fill"
        }
    }

    private var subtitle: String {
        var parts: [String] = [sourceDescription]
        if modelLoadFailed {
            parts.append(L("Couldn’t load models", "无法获取可用模型"))
        } else if let cooling = coolingCaption {
            parts.append(cooling)
        } else if let statusMessage = file.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !statusMessage.isEmpty,
                  file.gatewayNeedsAttention {
            parts.append(statusMessage)
        }
        if file.success > 0 || file.failed > 0 {
            var req = "✓\(file.success)"
            if file.failed > 0 { req += " ×\(file.failed)" }
            parts.append(req)
        }
        return parts.joined(separator: " · ")
    }

    private var sourceDescription: String {
        switch presentation {
        case .account:
            file.gatewaySourceShortTitle
        case .loginDetails:
            L("Keeps this account signed in", "用于保持此账号登录")
        case .project:
            L("Provided by the CPA plugin", "由 CPA 插件提供")
        }
    }

    private var coolingCaption: String? {
        guard !file.disabled,
              let next = file.nextRetryAfter,
              next > Date() else { return nil }
        let relative = Self.coolingRelativeFormatter.localizedString(for: next, relativeTo: Date())
        return L("Limited \(relative)", "暂时受限 \(relative)")
    }

    private static let coolingRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    @ViewBuilder
    private var trailingStatus: some View {
        // 不显示绿灯「可用」：列模型成功只靠「N 模型」徽章表达连通。
        if file.disabled {
            statusDot(L("Paused", "已停用"), .secondary)
        } else if modelLoadFailed {
            statusDot(L("Sign-in issue", "登录异常"), .orange)
        } else if coolingCaption != nil || file.unavailable {
            statusDot(L("Temporarily limited", "暂时受限"), .orange)
        } else if file.gatewayNeedsAttention {
            statusDot(L("Attention", "异常"), .orange)
        } else if file.gatewayProviderID == "unknown" {
            statusDot(L("Unrecognized", "无法识别"), .orange)
        } else if modelCount == nil {
            statusDot(L("Not checked yet", "尚未检查"), .secondary)
        } else {
            EmptyView()
        }
    }

    private func statusDot(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(text)
    }

    @State private var isMoreHovered = false

    private var moreMenu: some View {
        Menu {
            rowContextMenu
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary.opacity(isMoreHovered ? 1 : 0.55))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isMoreHovered ? 0.08 : 0))
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .onHover { isMoreHovered = $0 }
        .opacity(isBusy ? 0.35 : 1)
        .disabled(isBusy)
        .accessibilityLabel(L("More actions for \(primaryLabel)", "\(primaryLabel) 的更多操作"))
        .help(L("More actions", "更多操作"))
    }
}

// MARK: - Collapsible account summary

/// A compact, human-facing row for providers that expose several project
/// records for one login. Technical records stay hidden until requested.
struct GatewayAccountFamilyRow: View {
    let family: GatewayAccountFamily
    let identity: CLIProxyAccountIdentity?
    let modelErrorNames: Set<String>
    let isExpanded: Bool
    let isBusy: Bool
    let onToggleExpansion: () -> Void
    let onSetEnabled: (Bool) -> Void
    let onOpenDetail: () -> Void
    let onTestAvailability: () -> Void

    private var primaryFile: CLIProxyAuthFile? { family.primaryFile }

    private var planText: String? {
        primaryFile.flatMap { GatewayAccountListLogic.planBadgeText(file: $0, identity: identity) }
    }

    private var tint: Color { membershipBadgeTint(for: planText) }

    private var initial: String {
        family.accountLabel.first.map { String($0).uppercased() } ?? "?"
    }

    private var attentionCount: Int {
        family.files.filter { file in
            GatewayAccountListLogic.fileNeedsAttention(
                file,
                modelLoadFailed: modelErrorNames.contains(file.name.lowercased())
            )
        }.count
    }

    private var coolingCount: Int {
        family.files.filter { file in
            !modelErrorNames.contains(file.name.lowercased())
                && GatewayAccountListLogic.isCooling(file)
        }.count
    }

    private var isPartiallyDisabled: Bool {
        family.files.contains(where: \.disabled) && family.isEnabled
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleExpansion) {
                HStack(spacing: 11) {
                    avatar

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(family.accountLabel)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let planText {
                                GatewayQuietBadge(text: planText, tint: tint)
                            }
                        }
                        Text(projectSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                    familyStatus
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { family.isEnabled },
                set: onSetEnabled
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isBusy)
            .accessibilityLabel(L(
                "Enable account \(family.accountLabel)",
                "启用账号 \(family.accountLabel)"
            ))

            Menu {
                Button(action: onOpenDetail) {
                    Label(L("Account details", "账号详情"), systemImage: "info.circle")
                }
                Button(action: onTestAvailability) {
                    Label(L("Check this account", "检查此账号"), systemImage: "waveform.path.ecg")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .disabled(isBusy)
            .accessibilityLabel(L(
                "More actions for \(family.accountLabel)",
                "\(family.accountLabel) 的更多操作"
            ))
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(isExpanded ? 0.028 : 0.014))
        .accessibilityElement(children: .contain)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initial)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .frame(width: 32, height: 32)
        .overlay {
            if let primaryFile {
                GatewayProviderIcon(providerID: primaryFile.gatewayProviderID, size: 14)
                    .offset(x: 11, y: 11)
            }
        }
        .accessibilityHidden(true)
    }

    private var projectSummary: String {
        if family.projectCount == 1 {
            return L("1 project", "1 个项目")
        }
        return L("\(family.projectCount) projects", "\(family.projectCount) 个项目")
    }

    @ViewBuilder
    private var familyStatus: some View {
        if attentionCount > 0 {
            GatewayQuietBadge(
                text: L("\(attentionCount) need attention", "\(attentionCount) 个需处理"),
                tint: .orange
            )
        } else if coolingCount > 0 {
            GatewayQuietBadge(
                text: L("\(coolingCount) temporarily limited", "\(coolingCount) 个暂时受限"),
                tint: .orange
            )
        } else if !family.isEnabled {
            GatewayQuietBadge(text: L("Paused", "已停用"), tint: .secondary)
        } else if isPartiallyDisabled {
            GatewayQuietBadge(text: L("Partly paused", "部分停用"), tint: .secondary)
        }
    }
}
