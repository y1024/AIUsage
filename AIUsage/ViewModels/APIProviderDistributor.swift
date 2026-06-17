import Foundation
import SwiftUI
import os.log
import QuotaBackend

// MARK: - API Provider Distributor
// 把「API 提供商」主配置分发到 Codex / Claude / OpenCode 三套代理，并维护「继承 + 局部覆盖」同步：
//   - 分发即生成各代理的「链接节点」（携带 linkedProviderId），按目标去重 upsert。
//   - 主配置变更时，链接节点里未被 overriddenKeys 标记的共享字段跟随同步；代理专属字段本地独立。
//   - 取消分发某代理 = 删除该代理下的链接节点；解除链接 = 链接节点转为普通独立节点。
// Codex/Claude 节点经 ProxyViewModel（落 ~/.config/aiusage/profiles），OpenCode 经 OpenCodeNodeStore。

private let distributorLog = Logger(subsystem: "com.aiusage.desktop", category: "APIProviderDistributor")

@MainActor
final class APIProviderDistributor {
    static let shared = APIProviderDistributor()

    private var proxyVM: ProxyViewModel { ProxyViewModel.shared }
    private var profileStore: NodeProfileStore { NodeProfileStore.shared }
    private var openCodeStore: OpenCodeNodeStore { OpenCodeNodeStore.shared }

    // MARK: - Distribution State

    /// 该主配置当前已在哪些代理生成了链接节点。
    func currentTargets(for providerId: String) -> Set<ProxyTarget> {
        var result: Set<ProxyTarget> = []
        if codexChild(for: providerId) != nil { result.insert(.codex) }
        if claudeChild(for: providerId) != nil { result.insert(.claude) }
        if openCodeChild(for: providerId) != nil { result.insert(.openCode) }
        return result
    }

    // MARK: - Reconcile (distribute / undistribute)

    /// 把主配置的分发集合对齐到 `targets`：被选中且兼容的目标 upsert 链接节点（已存在则同步），
    /// 未选中（或不兼容）的目标若有链接节点则删除。
    func setDistribution(_ provider: APIProvider, targets: Set<ProxyTarget>) async {
        for target in ProxyTarget.allCases {
            let want = targets.contains(target) && target.supports(provider.format)
            if want {
                await upsertChild(provider, target: target)
            } else {
                await removeChild(for: provider.id, target: target)
            }
        }
    }

    /// 主配置内容变更后，把变更同步到所有已存在的链接节点（不改分发集合）。
    func syncFromMaster(_ provider: APIProvider) async {
        for target in currentTargets(for: provider.id) {
            await upsertChild(provider, target: target)
        }
    }

    /// 删除主配置：要么级联删除所有链接节点，要么解除链接（保留为独立节点）。
    func handleProviderDeletion(_ provider: APIProvider, deleteChildren: Bool) async {
        for target in ProxyTarget.allCases {
            if deleteChildren {
                await removeChild(for: provider.id, target: target)
            } else {
                unlinkChild(for: provider.id, target: target)
            }
        }
    }

    // MARK: - Per-target upsert

    private func upsertChild(_ provider: APIProvider, target: ProxyTarget) async {
        switch target {
        case .codex:
            let existing = codexChild(for: provider.id)
            let profile = makeProfile(provider, family: .codex, existing: existing)
            if existing != nil { await proxyVM.updateProfile(profile) } else { proxyVM.addProfile(profile) }
        case .claude:
            let existing = claudeChild(for: provider.id)
            let profile = makeProfile(provider, family: .claude, existing: existing)
            if existing != nil { await proxyVM.updateProfile(profile) } else { proxyVM.addProfile(profile) }
        case .openCode:
            let existing = openCodeChild(for: provider.id)
            let node = makeOpenCodeNode(provider, existing: existing)
            openCodeStore.upsert(node)
        }
    }

    private func removeChild(for providerId: String, target: ProxyTarget) async {
        switch target {
        case .codex:
            if let child = codexChild(for: providerId) { await proxyVM.deleteConfiguration(child.id) }
        case .claude:
            if let child = claudeChild(for: providerId) { await proxyVM.deleteConfiguration(child.id) }
        case .openCode:
            if let child = openCodeChild(for: providerId) { openCodeStore.delete(child) }
        }
    }

    private func unlinkChild(for providerId: String, target: ProxyTarget) {
        switch target {
        case .codex:
            guard var child = codexChild(for: providerId) else { return }
            child.metadata.linkedProviderId = nil
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
            proxyVM.loadConfigurations()
        case .claude:
            guard var child = claudeChild(for: providerId) else { return }
            child.metadata.linkedProviderId = nil
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
            proxyVM.loadConfigurations()
        case .openCode:
            guard var child = openCodeChild(for: providerId) else { return }
            child.linkedProviderId = nil
            child.overriddenKeys = nil
            openCodeStore.upsert(child)
        }
    }

    // MARK: - Child lookup

    private func codexChild(for providerId: String) -> NodeProfile? {
        profileStore.profiles.first { $0.metadata.linkedProviderId == providerId && $0.metadata.nodeType.isCodex }
    }

    private func claudeChild(for providerId: String) -> NodeProfile? {
        profileStore.profiles.first { $0.metadata.linkedProviderId == providerId && !$0.metadata.nodeType.isCodex }
    }

    private func openCodeChild(for providerId: String) -> OpenCodeNode? {
        openCodeStore.nodes.first { $0.linkedProviderId == providerId }
    }

    // MARK: - Mapping: APIProvider → Codex/Claude NodeProfile

    private func makeProfile(_ provider: APIProvider, family: ProxyNodeFamily, existing: NodeProfile?) -> NodeProfile {
        let overridden = existing?.metadata.overriddenKeys ?? []
        func wins(_ key: String) -> Bool { !overridden.contains(key) }

        // 节点类型由格式推导（Codex 恒 codexProxy；Claude：Anthropic→透传直连，OpenAI→转换代理）。
        let nodeType: NodeType
        if family.isCodex {
            nodeType = .codexProxy
        } else {
            nodeType = (provider.format == .anthropic) ? .anthropicDirect : .openaiProxy
        }

        var proxy = existing?.metadata.proxy ?? defaultProxy(for: nodeType)

        // 共享字段：API Key / baseURL（按节点类型落到不同字段）。
        if wins(APIProviderSharedKey.apiKey) {
            switch nodeType {
            case .anthropicDirect: proxy.anthropicAPIKey = provider.apiKey
            case .openaiProxy, .codexProxy: proxy.upstreamAPIKey = provider.apiKey
            }
        }
        if wins(APIProviderSharedKey.baseURL) {
            switch nodeType {
            case .anthropicDirect: proxy.anthropicBaseURL = provider.baseURL
            case .openaiProxy, .codexProxy: proxy.upstreamBaseURL = provider.baseURL
            }
        }

        // 上游接口模式 / 透传开关由格式决定（跟随主配置）。
        switch nodeType {
        case .codexProxy:
            proxy.openAIUpstreamAPI = .responses
        case .openaiProxy:
            proxy.openAIUpstreamAPI = provider.format.openAIUpstreamAPI ?? .chatCompletions
            proxy.usePassthroughProxy = false
        case .anthropicDirect:
            proxy.usePassthroughProxy = true
        }

        // 模型库（共享）。Claude 的大/中/小槽位是本地映射（仅新节点播种、之后保留）；
        // Codex 单模型即 bigModel（codexModel 取自 bigModel.name），属共享字段，始终跟随主配置。
        if wins(APIProviderSharedKey.models) {
            proxy.modelLibrary = provider.models.isEmpty ? nil : provider.models
        }
        if wins(APIProviderSharedKey.defaultModel) {
            let dm = provider.effectiveDefaultModel
            proxy.defaultModel = dm
            if family.isCodex {
                // Codex 运行时改写用的是 codexModel(=bigModel.name)，proxy.defaultModel 对其无效，
                // 故 bigModel 必须始终随主配置同步——否则「立即同步」改不到 Codex 真实上游模型。
                proxy.modelMapping.bigModel.name = dm
                if existing == nil {
                    proxy.modelMapping.middleModel.name = ""
                    proxy.modelMapping.smallModel.name = ""
                }
            } else if existing == nil {
                // 通用上游：新节点三槽位先全部指向默认模型（用户可在节点编辑器按需细分，属本地配置）。
                proxy.modelMapping.bigModel.name = dm
                proxy.modelMapping.middleModel.name = dm
                proxy.modelMapping.smallModel.name = dm
            }
        }
        proxy.syncSlotPricingFromLibrary()

        // 新节点端口避让，避免与现有代理端口直接撞车。
        if existing == nil {
            proxy.port = freePort(preferred: proxy.port)
        }

        var meta = existing?.metadata ?? NodeProfile.Metadata(nodeType: nodeType, proxy: proxy)
        meta.nodeType = nodeType
        meta.proxy = proxy
        meta.linkedProviderId = provider.id
        meta.overriddenKeys = overridden.isEmpty ? nil : overridden
        if wins(APIProviderSharedKey.name) {
            meta.name = provider.displayName
        }

        var profile = NodeProfile(metadata: meta, settings: existing?.settings ?? [:])
        profile.syncEnvFromProxy()
        return profile
    }

    private func defaultProxy(for nodeType: NodeType) -> ProxySettings {
        switch nodeType {
        case .codexProxy: return .defaultCodex
        case .anthropicDirect: return .defaultAnthropic
        case .openaiProxy: return .defaultOpenAI
        }
    }

    // MARK: - Mapping: APIProvider → OpenCodeNode

    private func makeOpenCodeNode(_ provider: APIProvider, existing: OpenCodeNode?) -> OpenCodeNode {
        let overridden = existing?.overriddenKeys ?? []
        func wins(_ key: String) -> Bool { !overridden.contains(key) }

        var node = existing ?? OpenCodeNode()
        node.linkedProviderId = provider.id
        node.overriddenKeys = overridden.isEmpty ? nil : overridden
        // 协议由格式决定（跟随主配置）。
        node.protocolType = provider.format.openCodeProtocol

        if wins(APIProviderSharedKey.name) { node.name = provider.displayName }
        if wins(APIProviderSharedKey.baseURL) { node.baseURL = provider.baseURL }
        if wins(APIProviderSharedKey.apiKey) { node.apiKey = provider.apiKey }
        if wins(APIProviderSharedKey.models) {
            let entries = Self.openCodeEntries(from: provider.models)
            node.modelEntries = entries
            node.pricingCurrency = entries.contains { $0.hasPricing } ? .usd : .none
        }
        if wins(APIProviderSharedKey.defaultModel) {
            node.defaultModel = provider.effectiveDefaultModel
        }

        // 共享生成参数 / 上限（仅 OpenCode 消费，跟随主配置）。
        node.contextLimit = provider.contextLimit
        node.outputLimit = provider.outputLimit
        node.temperature = provider.temperature
        node.topP = provider.topP
        node.maxOutputTokens = provider.maxOutputTokens
        node.frequencyPenalty = provider.frequencyPenalty
        node.presencePenalty = provider.presencePenalty

        return node
    }

    /// MappedModel（可能混合币种）→ OpenCodeModelEntry，统一折算为 USD（OpenCode cost 口径）。
    static func openCodeEntries(from models: [ProxyConfiguration.MappedModel]) -> [OpenCodeModelEntry] {
        models.map { m in
            OpenCodeModelEntry(
                id: m.name,
                priceInputPerMillion: m.pricing.inputPerMillionUSD,
                priceOutputPerMillion: m.pricing.outputPerMillionUSD,
                priceCacheReadPerMillion: m.pricing.cacheReadPerMillionUSD,
                priceCacheWritePerMillion: m.pricing.cacheCreatePerMillionUSD
            )
        }
    }

    // MARK: - Override stamping (called by child editors on save)
    // 子编辑器保存时调用：把链接节点的共享字段与主配置当前值逐项比对，不同即标记为本地覆盖
    // （写入 overriddenKeys），此后主配置同步不再覆盖这些字段。未链接节点清空标记。

    func stampOverrides(_ profile: NodeProfile) -> NodeProfile {
        var p = profile
        guard let masterId = p.metadata.linkedProviderId,
              let master = APIProviderStore.shared.provider(id: masterId) else {
            p.metadata.overriddenKeys = nil
            return p
        }
        var overridden = Set<String>()
        let proxy = p.metadata.proxy
        if p.metadata.name != master.displayName { overridden.insert(APIProviderSharedKey.name) }
        let childBaseURL: String
        let childKey: String
        switch p.metadata.nodeType {
        case .anthropicDirect: childBaseURL = proxy.anthropicBaseURL; childKey = proxy.anthropicAPIKey
        case .openaiProxy, .codexProxy: childBaseURL = proxy.upstreamBaseURL; childKey = proxy.upstreamAPIKey
        }
        if trimmed(childBaseURL) != trimmed(master.baseURL) { overridden.insert(APIProviderSharedKey.baseURL) }
        if childKey != master.apiKey { overridden.insert(APIProviderSharedKey.apiKey) }
        if (proxy.modelLibrary ?? []) != master.models { overridden.insert(APIProviderSharedKey.models) }
        if proxy.defaultModel != master.effectiveDefaultModel { overridden.insert(APIProviderSharedKey.defaultModel) }
        p.metadata.overriddenKeys = overridden.isEmpty ? nil : overridden
        return p
    }

    func stampOverrides(_ node: OpenCodeNode) -> OpenCodeNode {
        var n = node
        guard let masterId = n.linkedProviderId,
              let master = APIProviderStore.shared.provider(id: masterId) else {
            n.overriddenKeys = nil
            return n
        }
        var overridden = Set<String>()
        if n.name != master.displayName { overridden.insert(APIProviderSharedKey.name) }
        if trimmed(n.baseURL) != trimmed(master.baseURL) { overridden.insert(APIProviderSharedKey.baseURL) }
        if n.apiKey != master.apiKey { overridden.insert(APIProviderSharedKey.apiKey) }
        let masterFingerprints = Self.openCodeEntries(from: master.models).map(Self.fingerprint)
        if n.modelEntries.map(Self.fingerprint) != masterFingerprints { overridden.insert(APIProviderSharedKey.models) }
        if n.defaultModel != master.effectiveDefaultModel { overridden.insert(APIProviderSharedKey.defaultModel) }
        n.overriddenKeys = overridden.isEmpty ? nil : overridden
        return n
    }

    /// 模型条目价格指纹（忽略 modalities 等本地装饰，只比对 id + 四项单价）。
    private static func fingerprint(_ e: OpenCodeModelEntry) -> String {
        "\(e.id)|\(e.priceInputPerMillion)|\(e.priceOutputPerMillion)|\(e.priceCacheReadPerMillion)|\(e.priceCacheWritePerMillion)"
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「重置为继承」：清掉该代理下链接节点的本地覆盖标记，并用主配置当前值整体重写。
    func resetToInherit(providerId: String, target: ProxyTarget) async {
        switch target {
        case .codex:
            guard var child = codexChild(for: providerId) else { return }
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
        case .claude:
            guard var child = claudeChild(for: providerId) else { return }
            child.metadata.overriddenKeys = nil
            profileStore.save(child)
        case .openCode:
            guard var child = openCodeChild(for: providerId) else { return }
            child.overriddenKeys = nil
            openCodeStore.upsert(child)
        }
        guard let master = APIProviderStore.shared.provider(id: providerId) else { return }
        await upsertChild(master, target: target)
    }

    // MARK: - Port deconfliction

    /// 为新链接节点挑一个不与现有代理端口（Claude/Codex profiles + OpenCode 节点）直接冲突的端口。
    private func freePort(preferred: Int) -> Int {
        var used = Set<Int>()
        for profile in profileStore.profiles {
            used.insert(profile.metadata.proxy.port)
            if profile.metadata.proxy.enableHTTPS == true {
                used.insert(profile.metadata.proxy.effectiveHTTPSPort)
            }
        }
        for node in openCodeStore.nodes where node.proxyEnabled {
            used.insert(node.proxyPort)
        }
        var port = max(1, min(preferred, 65_534))
        while used.contains(port) && port < 65_534 { port += 1 }
        return port
    }
}
