import SwiftUI

// MARK: - Gateway Account Row（单列紧凑）
// 标题行：邮箱芯片 + 套餐 badge；副行：短来源与告警。

struct GatewayAccountRow: View {
    let file: CLIProxyAuthFile
    let identity: CLIProxyAccountIdentity?
    let linkedCandidate: CLIProxyAccountSyncCandidate?
    let syncState: CLIProxyAccountSyncState?
    let syncMode: CLIProxyAccountSyncMode?
    let isBusy: Bool
    let onOpenDetail: () -> Void
    let onRequestSync: (CLIProxyAccountSyncCandidate) -> Void
    let onSetEnabled: (Bool) -> Void
    let onSetSyncMode: (CLIProxyAccountSyncCandidate, CLIProxyAccountSyncMode) -> Void
    let onDelete: () -> Void

    private var planText: String? {
        GatewayAccountListLogic.planBadgeText(file: file, identity: identity)
    }

    private var planTint: Color {
        membershipBadgeTint(for: planText)
    }

    private var emailInitial: String {
        let label = file.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = label.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        HStack(spacing: 11) {
            emailAvatar

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    emailChip
                    if let planText {
                        GatewayQuietBadge(text: planText, tint: planTint)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .accessibilityLabel(L("Enable account \(file.displayLabel)", "启用账号 \(file.displayLabel)"))

            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.018))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(planTint.opacity(0.85))
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 2)
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
        if let linkedCandidate {
            Button {
                onRequestSync(linkedCandidate)
            } label: {
                Label(
                    L("Sync from AIUsage", "从 AIUsage 同步"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            Divider()
            syncModeButton(
                title: L("Manual copy", "手动同步副本"),
                selected: syncMode == .manualCopy
            ) {
                onSetSyncMode(linkedCandidate, .manualCopy)
            }
            syncModeButton(
                title: L("Keep updated", "保持单向同步"),
                selected: syncMode == .keepUpdated
            ) {
                onSetSyncMode(linkedCandidate, .keepUpdated)
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
            Text(emailInitial)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(planTint)
        }
        .frame(width: 30, height: 30)
        .overlay {
            GatewayProviderIcon(providerID: file.gatewayProviderID, size: 14)
                .offset(x: 10, y: 10)
        }
        .accessibilityHidden(true)
    }

    private var emailChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(planTint.opacity(0.85))
            Text(file.displayLabel)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(planTint.opacity(0.10), in: Capsule())
    }

    /// 副行只保留短来源 + 必要告警；不展示工作区/项目 ID。
    private var subtitle: String {
        var parts: [String] = [file.gatewaySourceShortTitle]
        if let syncState, GatewayAccountListLogic.syncNeedsAttention(syncState) {
            let label = syncShortLabel(syncState)
            if !label.isEmpty { parts.append(label) }
        }
        if file.success > 0 || file.failed > 0 {
            var req = "✓\(file.success)"
            if file.failed > 0 { req += " ×\(file.failed)" }
            parts.append(req)
        }
        return parts.joined(separator: " · ")
    }

    private func syncShortLabel(_ state: CLIProxyAccountSyncState) -> String {
        switch state {
        case .sourceChanged: return L("Source updated", "源已更新")
        case .cpaChanged: return L("CPA edited", "副本已改")
        case .conflict: return L("Conflict", "冲突")
        case .missing: return L("Missing", "缺失")
        case .notSynced, .current: return ""
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if file.disabled {
            statusDot(L("Paused", "已停用"), .secondary)
        } else if file.gatewayNeedsAttention {
            statusDot(L("Attention", "异常"), .orange)
        } else if file.gatewayProviderID == "unknown" {
            statusDot(L("Unrecognized", "无法识别"), .orange)
        } else if let syncState, GatewayAccountListLogic.syncNeedsAttention(syncState) {
            statusDot(syncShortLabel(syncState), .orange)
        } else {
            statusDot(L("Ready", "可用"), .green)
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
            Button(action: onOpenDetail) {
                Label(L("Account Details", "账号详情"), systemImage: "info.circle")
            }
            if let linkedCandidate {
                Button {
                    onRequestSync(linkedCandidate)
                } label: {
                    Label(
                        L("Sync from AIUsage", "从 AIUsage 同步"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                Divider()
                Section(L("Sync mode", "同步模式")) {
                    syncModeButton(
                        title: L("Manual copy", "手动同步副本"),
                        selected: syncMode == .manualCopy
                    ) {
                        onSetSyncMode(linkedCandidate, .manualCopy)
                    }
                    syncModeButton(
                        title: L("Keep updated", "保持单向同步"),
                        selected: syncMode == .keepUpdated
                    ) {
                        onSetSyncMode(linkedCandidate, .keepUpdated)
                    }
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(L("Remove from CPA", "从 CPA 删除"), systemImage: "trash")
            }
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
        .accessibilityLabel(L("More actions for \(file.displayLabel)", "\(file.displayLabel) 的更多操作"))
        .help(L("More actions", "更多操作"))
    }

    private func syncModeButton(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
    }
}
