import SwiftUI

// MARK: - Proxy Editor Controls
// 三套代理编辑器共用的现代化选择控件，替换系统 `.segmented` Picker：
// - SelectableCardPicker：接口类型这类「多选项 + 说明」的可选卡片（图标 + 标题 + 副标题）。
// - CapsuleSegmentedPicker：Chat Completions / Responses 这类二/三选一的胶囊分段。
// 同时集中三套代理的品牌色，消除各卡片文件里重复定义的颜色常量。

// MARK: - Brand Palette

enum ProxyBrand {
    static let anthropic = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let openAI = Color(red: 0.29, green: 0.73, blue: 0.56)
    static let codex = Color(red: 0.40, green: 0.52, blue: 0.92)
    static let openCode = Color(red: 0.18, green: 0.83, blue: 0.75)
}

// MARK: - Selectable Card Picker

/// 单张可选卡片的数据模型。`Value` 即绑定的选中值（NodeType / OpenCodeProtocol 等）。
struct SelectableCardOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    init(_ id: Value, title: String, subtitle: String? = nil, systemImage: String, tint: Color) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
    }
}

/// 水平排布的可选卡片组（等宽自适应）。选中卡片用品牌色描边 + 浅底高亮 + 实心勾。
struct SelectableCardPicker<Value: Hashable>: View {
    let options: [SelectableCardOption<Value>]
    @Binding var selection: Value
    var onChange: ((Value) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options) { option in
                card(option)
            }
        }
    }

    private func card(_ option: SelectableCardOption<Value>) -> some View {
        let isSelected = option.id == selection
        return Button {
            guard selection != option.id else { return }
            selection = option.id
            onChange?(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? option.tint : Color.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? option.tint : Color.secondary.opacity(0.35))
                }
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if let subtitle = option.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? option.tint.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? option.tint.opacity(0.75) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Capsule Segmented Picker

/// 胶囊分段的单项。
struct CapsuleSegmentOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String

    init(_ id: Value, title: String) {
        self.id = id
        self.title = title
    }
}

/// 药丸轨道 + 选中段实心填充的分段控件，替换 `.segmented` Picker 的二/三选一场景。
/// 默认按内容收紧（不撑满整行）；`fillWidth = true` 时各段等宽铺满。
struct CapsuleSegmentedPicker<Value: Hashable>: View {
    let options: [CapsuleSegmentOption<Value>]
    @Binding var selection: Value
    var tint: Color = .accentColor
    var fillWidth: Bool = false
    var onChange: ((Value) -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .fixedSize(horizontal: !fillWidth, vertical: false)
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    private func segment(_ option: CapsuleSegmentOption<Value>) -> some View {
        let isSelected = option.id == selection
        return Button {
            guard selection != option.id else { return }
            selection = option.id
            onChange?(option.id)
        } label: {
            Text(option.title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, fillWidth ? 0 : 16)
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? tint : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
