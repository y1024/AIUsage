import SwiftUI

// MARK: - Inheritance Banner
// 链接节点编辑器顶部横幅：提示该节点继承自某「API 提供商」主配置，并提供「重置为继承」
// （丢弃本地覆盖，按主配置当前值整体重写本节点）。

struct InheritanceBanner: View {
    let providerName: String
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Linked to API provider \"\(providerName)\"", "继承自 API 提供商「\(providerName)」"))
                    .font(.caption.weight(.semibold))
                Text(L(
                    "Shared fields follow the provider. Editing one here keeps it local; use Reset to follow the provider again.",
                    "共享字段跟随主配置；在此修改即转为本地覆盖，点「重置为继承」可恢复跟随。"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L("Reset to Inherit", "重置为继承")) { onReset() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
    }
}

// MARK: - API Provider Card
// 「API 提供商」列表中的单卡：展示名称 / 格式 / baseURL / 模型数 / 已分发到哪些代理，
// 提供编辑、立即同步、删除操作。分发状态由 distributedTargets 注入（来自 APIProviderDistributor）。

struct APIProviderCard: View {
    let provider: APIProvider
    let distributedTargets: Set<ProxyTarget>
    let onEdit: () -> Void
    let onSync: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            metaRow
            if !distributedTargets.isEmpty {
                distributionRow
            }
            Divider().opacity(0.4)
            actionRow
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.5 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(provider.baseURL.nilIfBlank ?? L("No Base URL", "未填写 Base URL"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            formatBadge
        }
    }

    private var formatBadge: some View {
        Text(provider.format.badgeName)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            metaItem(icon: "cube.box", text: L("\(provider.models.count) models", "\(provider.models.count) 个模型"))
            if let dm = provider.effectiveDefaultModel.nilIfBlank {
                metaItem(icon: "star", text: dm)
            }
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.caption).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private var distributionRow: some View {
        HStack(spacing: 6) {
            Text(L("Distributed:", "已分发："))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(ProxyTarget.allCases.filter { distributedTargets.contains($0) }) { target in
                Text(target.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.16)))
                    .foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: onEdit) {
                Label(L("Edit", "编辑"), systemImage: "pencil")
            }
            .controlSize(.small)

            Button(action: onSync) {
                Label(L("Sync Now", "立即同步"), systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .disabled(distributedTargets.isEmpty)
            .help(L("Re-apply this provider to its linked nodes.", "把本提供商重新应用到所有链接节点。"))

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Label(L("Delete", "删除"), systemImage: "trash")
            }
            .controlSize(.small)
        }
    }
}
