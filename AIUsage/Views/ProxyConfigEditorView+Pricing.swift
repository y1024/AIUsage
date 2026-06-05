import SwiftUI
import QuotaBackend

// MARK: - ProxyConfigEditorView: Model Pricing Sub-section
// 模型定价子区（输入/输出/缓存单价），从 ProxyConfigEditorView 抽离。
extension ProxyConfigEditorView {
    var modelPricingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Pricing", "定价")).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    applyCacheAutoFill()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text(L("Auto-fill Cache (1.25× / 0.1×)", "自动填充缓存（1.25×/0.1×）"))
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help(L(
                    "Set cache-write = 1.25× input and cache-read = 0.1× input for all three models.",
                    "按输入价格自动计算三个模型的缓存写入（×1.25）与缓存读取（×0.1）单价。"
                ))
                Picker("", selection: $pricingCurrency) {
                    Text("USD ($)").tag(ProxyConfiguration.PricingCurrency.usd)
                    Text("CNY (¥)").tag(ProxyConfiguration.PricingCurrency.cny)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: pricingCurrency) { _, newCurrency in
                    profile.metadata.proxy.modelMapping.bigModel.pricing.currency = newCurrency
                    profile.metadata.proxy.modelMapping.middleModel.pricing.currency = newCurrency
                    profile.metadata.proxy.modelMapping.smallModel.pricing.currency = newCurrency
                }
            }

            if profile.metadata.nodeType == .anthropicDirect {
                Text(L("This node uses the pricing here for spend statistics. In Anthropic passthrough mode, you only need to configure this once.",
                       "这个节点会直接使用这里的价格做消费统计。在 Anthropic 透传模式下，只需要配置这一处。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text(L(
                "Anthropic bills cache writes at ~1.25× input and cache reads at ~0.1× input (5-minute TTL). Adjust per upstream if your provider differs.",
                "Anthropic 的缓存写入约为输入价格的 1.25×，缓存读取约为 0.1×（5 分钟 TTL）。如上游计费方式不同可自行调整。"
            ))
            .font(.caption2).foregroundStyle(.tertiary)

            HStack(spacing: 0) {
                Text("").frame(width: 56, alignment: .trailing)
                Spacer().frame(width: 10)
                Text(L("Input", "输入")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Output", "输出")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Cache Write", "缓存写入")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Cache Read", "缓存读取")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("/ M tokens", "/ 百万")).frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)

            pricingRow(label: "Opus", pricing: $profile.metadata.proxy.modelMapping.bigModel.pricing)
            pricingRow(label: "Sonnet", pricing: $profile.metadata.proxy.modelMapping.middleModel.pricing)
            pricingRow(label: "Haiku", pricing: $profile.metadata.proxy.modelMapping.smallModel.pricing)
        }
    }

    private func applyCacheAutoFill() {
        func fill(_ p: inout ProxyConfiguration.ModelPricing) {
            guard p.inputPerMillion > 0 else { return }
            p.cacheCreatePerMillion = p.inputPerMillion * ProxyConfiguration.ModelPricing.defaultCacheWriteMultiplier
            p.cacheReadPerMillion = p.inputPerMillion * ProxyConfiguration.ModelPricing.defaultCacheReadMultiplier
        }
        fill(&profile.metadata.proxy.modelMapping.bigModel.pricing)
        fill(&profile.metadata.proxy.modelMapping.middleModel.pricing)
        fill(&profile.metadata.proxy.modelMapping.smallModel.pricing)
    }

    private func pricingRow(label: String, pricing: Binding<ProxyConfiguration.ModelPricing>) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            Spacer().frame(width: 10)
            TextField("0", value: pricing.inputPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 6)
            TextField("0", value: pricing.outputPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 6)
            TextField("0", value: pricing.cacheCreatePerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 6)
            TextField("0", value: pricing.cacheReadPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
            Spacer().frame(width: 64)
        }
    }
}
