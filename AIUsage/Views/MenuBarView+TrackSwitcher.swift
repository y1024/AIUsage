import SwiftUI
import QuotaBackend

// MARK: - MenuBarView Proxy Track Switcher
// 顶部控制台的 Claude / Codex 轨道切换器（订阅账号 + API 节点，单一互斥激活）。
// 拆出以控制单文件规模；依赖主视图的 proxyVM / appState。

extension MenuBarView {

    func proxyTrackSwitcher(family: ProxyNodeFamily) -> some View {
        let activeId = proxyVM.activatedId(isCodex: family.isCodex)
        let activeNode = proxyVM.configurations.first { $0.id == activeId }
        let familyNodes = proxyVM.configurations.filter { family.contains($0.nodeType) }
        let title = family.isCodex ? "Codex" : "Claude Code"
        let brandAsset = family.isCodex ? "codex" : "claude"
        let accent: Color = family.isCodex
            ? Color(red: 0.40, green: 0.52, blue: 0.92)
            : Color(red: 0.85, green: 0.45, blue: 0.25)

        // Codex 统一切换器：订阅账号（auth.json）与 API 节点（config.toml）单一互斥激活。
        // 订阅顺序沿用代理页的自定义拖拽排序，保持两处一致。
        let subEntries: [ProviderAccountEntry] = family.isCodex
            ? CodexSubscriptionOrderStore.shared.ordered(
                appState.providerAccountGroups.first { $0.providerId == "codex" }?.accounts ?? [])
            : []
        // 全局统一代理（仅 Codex 轨）：启用时常驻代理接管 config.toml，整条轨道由它生效。
        // 此时账号 / 节点的单独激活被互斥拦截，故菜单项禁用、订阅不高亮；生效名取全局激活节点。
        let globalEnabled = family.isCodex && globalProxy.isEnabled
        let globalActiveNode = globalEnabled ? globalProxy.node(for: globalProxy.activeNodeId) : nil

        // 单一激活：代理节点占用 config.toml 时即为生效身份，订阅不再视为 active（防启动期竞态双高亮）。
        let activeSub = (activeNode == nil && !globalEnabled)
            ? subEntries.first { ProviderActivationManager.shared.isActiveAccount($0) }
            : nil
        let isOn = activeNode != nil || activeSub != nil || globalEnabled
        let activeLabel: String = {
            if globalEnabled {
                let name = globalActiveNode?.name ?? L("Global proxy", "全局代理")
                return L("\(name) (Global)", "\(name)（全局）")
            }
            return activeNode?.name ?? activeSub?.accountPrimaryLabel ?? L("Off", "未启用")
        }()

        return Menu {
            if family.isCodex {
                if globalEnabled {
                    Section(L("Global Proxy", "全局代理")) {
                        Text(globalActiveNode.map { L("Active: \($0.name)", "生效中：\($0.name)") }
                             ?? L("Enabled", "已启用"))
                        Text(L("Switch nodes in the proxy page", "请在代理页切换激活节点"))
                    }
                }
                if subEntries.isEmpty && familyNodes.isEmpty {
                    Text(L("No Codex accounts or nodes", "暂无 Codex 账号或节点"))
                }
                if !subEntries.isEmpty {
                    Section(L("Subscription", "订阅账号")) {
                        ForEach(subEntries, id: \.id) { codexSubscriptionMenuItem($0) }
                    }
                    .disabled(globalEnabled)
                }
                if !familyNodes.isEmpty {
                    Section(L("API Nodes", "API 节点")) {
                        ForEach(familyNodes) { proxyNodeMenuItem($0) }
                    }
                    .disabled(globalEnabled)
                }
            } else if familyNodes.isEmpty {
                Text(L("No proxy nodes", "暂无代理节点"))
            } else {
                let anthropicNodes = familyNodes.filter { $0.nodeType == .anthropicDirect }
                let openaiNodes = familyNodes.filter { $0.nodeType == .openaiProxy }
                if !anthropicNodes.isEmpty {
                    Section("Anthropic") {
                        ForEach(anthropicNodes) { proxyNodeMenuItem($0) }
                    }
                }
                if !openaiNodes.isEmpty {
                    Section("OpenAI") {
                        ForEach(openaiNodes) { proxyNodeMenuItem($0) }
                    }
                }
            }

            if isOn {
                Divider()
                // 停止仅作用于 API 代理节点；订阅账号无「关闭」语义（切到别的账号即可）。
                Button {
                    if let activeId {
                        Task { await proxyVM.deactivateConfiguration(activeId) }
                    }
                } label: {
                    Label(L("Deactivate node", "停用当前节点"), systemImage: "stop.circle")
                }
                .disabled(activeId == nil)
            }
        } label: {
            trackSwitcherLabel(
                title: title,
                brandAsset: brandAsset,
                accent: accent,
                isOn: isOn,
                activeLabel: activeLabel
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - OpenCode Track Switcher
    // OpenCode 节点切换器：节点列表（勾选当前生效）+ 停用当前节点（还原 opencode.json）。
    // 与 Claude/Codex 切换器同一套外观；激活/停用委托 OpenCodeNodeStore（代理模式
    // 节点会顺带拉起/回收本地透传进程）。

    func openCodeTrackSwitcher() -> some View {
        let activeNode = openCodeStore.activeNode
        let isOn = activeNode != nil
        let accent = OpenCodeManagementView.brand

        return Menu {
            if openCodeStore.nodes.isEmpty {
                Text(L("No OpenCode nodes", "暂无 OpenCode 节点"))
            } else {
                ForEach(openCodeStore.nodes) { openCodeNodeMenuItem($0) }
            }

            if isOn {
                Divider()
                Button {
                    try? openCodeStore.deactivate()
                } label: {
                    Label(L("Deactivate node", "停用当前节点"), systemImage: "stop.circle")
                }
            }
        } label: {
            trackSwitcherLabel(
                title: "OpenCode",
                brandAsset: "opencode",
                accent: accent,
                isOn: isOn,
                activeLabel: activeNode?.displayName ?? L("Off", "未启用")
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func openCodeNodeMenuItem(_ node: OpenCodeNode) -> some View {
        let isActive = openCodeStore.activeNodeId == node.id
        Button {
            if isActive {
                try? openCodeStore.deactivate()
            } else {
                Task { try? await openCodeStore.activate(node) }
            }
        } label: {
            Label {
                Text(node.displayName)
            } icon: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
            }
        }
        .disabled(openCodeStore.usesJSONC || !node.isComplete)
    }

    // MARK: - Shared Label Chrome

    /// 三个轨道切换器共用的标签外观（品牌图标 + 标题 + 当前生效名）。
    private func trackSwitcherLabel(
        title: String,
        brandAsset: String,
        accent: Color,
        isOn: Bool,
        activeLabel: String
    ) -> some View {
        HStack(spacing: 8) {
            ProviderIconView(brandAsset, size: 16)
                .opacity(isOn ? 1.0 : 0.55)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isOn ? accent : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if isOn {
                        Circle()
                            .fill(Color(red: 0.20, green: 0.84, blue: 0.42))
                            .frame(width: 5, height: 5)
                    }
                }
                Text(activeLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isOn ? accent.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isOn ? accent.opacity(0.30) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    /// Codex 订阅账号菜单项：点击激活（写 auth.json，自动停用代理节点），已激活打勾。
    @ViewBuilder
    private func codexSubscriptionMenuItem(_ entry: ProviderAccountEntry) -> some View {
        // 代理接管 config.toml（每节点代理 或 全局统一代理）时，订阅一律视为未激活（防双高亮）。
        let proxyActive = proxyVM.activatedId(isCodex: true) != nil || globalProxy.isEnabled
        let isActive = !proxyActive && ProviderActivationManager.shared.isActiveAccount(entry)
        Button {
            try? ProviderActivationManager.shared.activateAccount(entry: entry)
        } label: {
            if isActive {
                Label(entry.accountPrimaryLabel, systemImage: "checkmark")
            } else {
                Text(entry.accountPrimaryLabel)
            }
        }
    }

    @ViewBuilder
    private func proxyNodeMenuItem(_ config: ProxyConfiguration) -> some View {
        let isActive = proxyVM.isNodeActivated(config.id)
        Button {
            Task { await proxyVM.toggleActivation(config.id) }
        } label: {
            Label {
                Text(config.name)
            } icon: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
            }
        }
    }
}
