import SwiftUI

// MARK: - Subscription App Scope Control
// 订阅账号页的「当前应用」选择器：一颗胶囊 + 弹出纵向坞，替代横向滑动 chip 条。
// 鼠标友好、应用再多也不横滑；与 GatewayCapsuleFilterBar 状态筛选正交。

struct SubscriptionAppScopeOption: Identifiable, Equatable {
    let id: String
    let title: String
    let providerId: String?
    let accountCount: Int

    static func all(accountCount: Int) -> SubscriptionAppScopeOption {
        SubscriptionAppScopeOption(
            id: "all",
            title: L("All Apps", "全部应用"),
            providerId: nil,
            accountCount: accountCount
        )
    }
}

struct SubscriptionAppScopeControl: View {
    let options: [SubscriptionAppScopeOption]
    @Binding var selection: String
    @State private var isPresented = false
    @State private var query = ""

    private var selectedOption: SubscriptionAppScopeOption {
        options.first(where: { $0.id == selection }) ?? options.first ?? .all(accountCount: 0)
    }

    private var filteredOptions: [SubscriptionAppScopeOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                scopeIcon(for: selectedOption, size: 16)
                Text(selectedOption.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if selectedOption.accountCount > 0 {
                    Text("\(selectedOption.accountCount)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
                .frame(width: 280)
                .padding(10)
        }
        .accessibilityLabel(L("Filter by app", "按应用筛选"))
        .accessibilityValue(selectedOption.title)
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if options.count > 6 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(L("Search apps", "搜索应用"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredOptions) { option in
                        scopeRow(option)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func scopeRow(_ option: SubscriptionAppScopeOption) -> some View {
        let selected = selection == option.id
        return Button {
            selection = option.id
            isPresented = false
            query = ""
        } label: {
            HStack(spacing: 10) {
                scopeIcon(for: option, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(L("\(option.accountCount) accounts", "\(option.accountCount) 个账号"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.body)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func scopeIcon(for option: SubscriptionAppScopeOption, size: CGFloat) -> some View {
        if let providerId = option.providerId {
            ProviderIconView(providerId, size: size)
                .clipShape(RoundedRectangle(cornerRadius: size > 18 ? 6 : 4, style: .continuous))
                .frame(width: size, height: size)
        } else {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: size > 18 ? 6 : 4, style: .continuous))
        }
    }
}
