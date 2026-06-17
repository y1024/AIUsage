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
// 「API 提供商」列表中的单条目行卡：与 Codex/Claude/OpenCode 节点卡片同一套视觉语言——
// 顶部格式徽章、左侧拖拽把手 + 信息 pills（模型数/默认模型）、名称/baseURL/分发状态行、
// 右侧动作区（编辑 / 立即同步 / 删除），分发后左边缘高亮条。
// 拖拽排序由列表（APIProviderListView）通过 onDragChanged/onDragEnded 跟手让位实现。

struct APIProviderCard: View {
    let provider: APIProvider
    let distributedTargets: Set<ProxyTarget>

    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onEdit: () -> Void = {}
    var onSync: () -> Void = {}
    var onDelete: () -> Void = {}

    private var isDistributed: Bool { !distributedTargets.isEmpty }

    // 格式主题色（与 OpenCode 节点卡片同语言）。
    private static let chatBrand = Color(red: 0.29, green: 0.73, blue: 0.56)
    private static let anthropicBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let responsesBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    private var formatColor: Color {
        switch provider.format {
        case .openAIChatCompletions: return Self.chatBrand
        case .anthropic: return Self.anthropicBrand
        case .openAIResponses: return Self.responsesBrand
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            formatBadge

            HStack(spacing: 10) {
                dragHandle

                infoPills

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text(provider.baseURL.nilIfBlank ?? L("Base URL not set", "未设置 Base URL"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    distributionLine
                }

                Spacer()

                actionButtons
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(cardBackgroundColor)
        )
        .overlay(alignment: .leading) {
            if isDistributed {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 3)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 4, x: 0, y: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(cardBorderColor, lineWidth: isDistributed ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .contextMenu { contextMenu }
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.quaternary)
            .frame(width: 16, height: 28)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { onDragChanged($0.translation.height) }
                    .onEnded { _ in onDragEnded() }
            )
    }

    // MARK: - Info Pills

    private var infoPills: some View {
        VStack(alignment: .trailing, spacing: 4) {
            infoPill(
                icon: "cube.box",
                text: "\(provider.models.count)",
                color: .blue
            )
            .help(L("\(provider.models.count) models", "\(provider.models.count) 个模型"))
            if let dm = provider.effectiveDefaultModel.nilIfBlank {
                infoPill(icon: "star.fill", text: dm, color: .orange)
                    .help(L("Default model", "默认模型"))
            }
        }
        .frame(width: 96, alignment: .trailing)
    }

    private func infoPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Format Badge

    private var formatBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 7, weight: .bold))
            Text(provider.format.badgeName)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(formatColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(formatColor.opacity(0.12)))
        .help(L(
            "API format: \(provider.format.displayName)",
            "接口格式：\(provider.format.displayName)"
        ))
    }

    // MARK: - Distribution Line

    @ViewBuilder
    private var distributionLine: some View {
        if isDistributed {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.green)
                ForEach(ProxyTarget.allCases.filter { distributedTargets.contains($0) }) { target in
                    Text(target.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                        .foregroundStyle(.green)
                }
            }
        } else {
            Text(L("Not distributed", "未分发"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button(action: onSync) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(isDistributed ? .blue : .gray.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!isDistributed)
            .help(L("Re-apply this provider to its linked nodes.", "把本提供商重新应用到所有链接节点。"))

            Button(action: onEdit) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help(L("Edit", "编辑"))

            Button(action: onDelete) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(L("Delete", "删除"))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(action: onEdit) {
            Label(L("Edit", "编辑"), systemImage: "pencil")
        }
        Button(action: onSync) {
            Label(L("Sync Now", "立即同步"), systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!isDistributed)
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label(L("Delete", "删除"), systemImage: "trash")
        }
    }

    // MARK: - Styling

    private var cardBackgroundColor: Color {
        if isDistributed { return Color.accentColor.opacity(0.05) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    private var cardBorderColor: Color {
        if isDistributed { return Color.accentColor.opacity(0.4) }
        return Color.primary.opacity(0.06)
    }
}

// MARK: - Row Height Key
// 测量提供商卡片真实高度，供拖拽让位的阈值/步幅计算（与节点列表同一套手感）。

struct APIProviderRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
