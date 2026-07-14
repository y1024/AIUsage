import SwiftUI

// MARK: - Subscription Account Actions
// 订阅账号隐藏/删除的统一入口：卡片右键、未连接卡、批量栏共用同一套文案与确认语义。

enum SubscriptionAccountActionCopy {
    static var hideTitle: String { L("Hide Account", "隐藏账号") }
    static var deleteTitle: String { L("Delete Account", "删除账号") }
    static var deleteConfirmTitle: String { L("Delete Account", "删除账号") }
    static var deleteButton: String { L("Delete", "删除") }

    static var deleteMessage: String {
        L(
            "Permanently deletes this account from monitoring and removes its Keychain credential if linked. This cannot be restored from Hidden Accounts.",
            "将永久删除该监控账号；若绑定了凭证，也会从钥匙串移除。无法从「已隐藏账号」恢复。"
        )
    }

    static func batchDeleteMessage(count: Int) -> String {
        L(
            "Permanently delete \(count) account(s) from monitoring? Linked Keychain credentials are removed. This cannot be restored from Hidden Accounts.",
            "将永久删除 \(count) 个监控账号；绑定的钥匙串凭证也会移除。无法从「已隐藏账号」恢复。"
        )
    }

    static var hideHelp: String {
        L(
            "Hide from the dashboard. Restore later from Providers → Hidden Accounts.",
            "从仪表盘隐藏；可在「服务商 → 已隐藏账号」恢复。"
        )
    }
}

/// 右键/菜单里的隐藏 + 删除两项（删除只弹出确认，不直接执行）。
struct SubscriptionAccountDestructiveMenuItems: View {
    let onHide: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        Divider()
        Button(action: onHide) {
            Label(SubscriptionAccountActionCopy.hideTitle, systemImage: "eye.slash")
        }
        Button(role: .destructive, action: onRequestDelete) {
            Label(SubscriptionAccountActionCopy.deleteTitle, systemImage: "trash")
        }
    }
}

extension View {
    /// 永久删除确认框；`isPresented` 为 true 时展示。
    func subscriptionAccountDeleteConfirmation(
        isPresented: Binding<Bool>,
        message: String = SubscriptionAccountActionCopy.deleteMessage,
        onDelete: @escaping () -> Void
    ) -> some View {
        alert(
            SubscriptionAccountActionCopy.deleteConfirmTitle,
            isPresented: isPresented
        ) {
            Button(SubscriptionAccountActionCopy.deleteButton, role: .destructive, action: onDelete)
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
