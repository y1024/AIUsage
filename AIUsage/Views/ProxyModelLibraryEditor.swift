import SwiftUI

// MARK: - Proxy Model Library Editor
// Claude / Codex 节点编辑器共用的「模型库」组件（与 OpenCode 编辑器的模型列表同构）：
// 获取模型 → 勾选批量添加 → 每模型一行独立定价（输入/输出/缓存写/缓存读）。
// 模型库是节点定价的唯一来源（计价查询：库精确 → 槽位精确 → 家族回退），
// 槽位/默认模型从库中点选即可切换，无需重填名称与价格。

struct ProxyModelLibraryEditor: View {
    @Binding var library: [ProxyConfiguration.MappedModel]
    @Binding var currency: ProxyConfiguration.PricingCurrency
    @ObservedObject var modelFetch: ModelFetchState

    /// 行包装：模型名可编辑，不能充当 ForEach 身份（打字即重建行、丢焦点），
    /// 故用稳定 UUID 行号（与 OpenCode 编辑器同一套做法）。
    private struct Row: Identifiable {
        let id = UUID()
        var model: ProxyConfiguration.MappedModel
    }

    @State private var rows: [Row]

    init(
        library: Binding<[ProxyConfiguration.MappedModel]>,
        currency: Binding<ProxyConfiguration.PricingCurrency>,
        modelFetch: ModelFetchState
    ) {
        _library = library
        _currency = currency
        _modelFetch = ObservedObject(wrappedValue: modelFetch)
        _rows = State(initialValue: library.wrappedValue.map { Row(model: $0) })
    }

    /// 行内容 → 库条目（去空白、去重、保持顺序）。
    private var parsedLibrary: [ProxyConfiguration.MappedModel] {
        var seen = Set<String>()
        return rows.compactMap { row in
            var model = row.model
            model.name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.name.isEmpty, seen.insert(model.name).inserted else { return nil }
            return model
        }
    }

    private var existingNames: Set<String> {
        Set(rows.map { $0.model.name.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Model Library & Pricing", "模型库与定价")).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    autoFillCache()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text(L("Auto-fill Cache (1.25× / 0.1×)", "自动填充缓存（1.25×/0.1×）"))
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help(L(
                    "Set cache-write = 1.25× input and cache-read = 0.1× input for every model with an input price.",
                    "为所有已填输入价的模型按 ×1.25 / ×0.1 计算缓存写入与读取单价。"
                ))
                CapsuleSegmentedPicker(
                    options: [
                        CapsuleSegmentOption(ProxyConfiguration.PricingCurrency.usd, title: "USD ($)"),
                        CapsuleSegmentOption(ProxyConfiguration.PricingCurrency.cny, title: "CNY (¥)")
                    ],
                    selection: $currency
                )
            }

            FetchedModelAppendList(
                state: modelFetch,
                existingModels: existingNames,
                onAppend: { appendModels([$0]) },
                onAppendAll: { appendModels($0) }
            )

            if !rows.isEmpty {
                columnHeaders
                ForEach($rows) { $row in
                    rowView($row)
                }
            }

            Button {
                rows.append(Row(model: .init(name: "", pricing: emptyPricing)))
            } label: {
                Label(L("Add Model", "添加模型"), systemImage: "plus.circle")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)

            Text(L(
                "Prices are per million tokens. Pick slot / default models from this library below or on the node card — no retyping names or prices when switching.",
                "单价为每百万 token。下方槽位/默认模型可直接从库中点选，节点卡片上也能随时切换，无需重填名称与价格。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: rowsFingerprint) { _, _ in
            library = parsedLibrary
        }
        .onChange(of: currency) { _, newCurrency in
            for index in rows.indices {
                rows[index].model.pricing.currency = newCurrency
            }
            library = parsedLibrary
        }
    }

    /// 行内容指纹：任一名称/价格变化即回写绑定（rows 含 UUID，不能直接做 Equatable 比较源）。
    private var rowsFingerprint: [String] {
        rows.map { row in
            let p = row.model.pricing
            return "\(row.model.name)|\(p.inputPerMillion)|\(p.outputPerMillion)|\(p.cacheCreatePerMillion)|\(p.cacheReadPerMillion)"
        }
    }

    private var emptyPricing: ProxyConfiguration.ModelPricing {
        ProxyConfiguration.ModelPricing(currency: currency)
    }

    // MARK: - Subviews

    private var columnHeaders: some View {
        HStack(spacing: 6) {
            Text(L("Model", "模型")).frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(L("Input", "输入"))
                Text(L("Output", "输出"))
                Text(L("Cache W", "缓存写"))
                Text(L("Cache R", "缓存读"))
            }
            .frame(width: 64, alignment: .leading)
            Spacer().frame(width: 20)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    }

    private func rowView(_ row: Binding<Row>) -> some View {
        HStack(spacing: 6) {
            TextField("gpt-5.5", text: row.model.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity)
                .autocorrectionDisabled()

            priceField(row.model.pricing.inputPerMillion)
            priceField(row.model.pricing.outputPerMillion)
            priceField(row.model.pricing.cacheCreatePerMillion)
            priceField(row.model.pricing.cacheReadPerMillion)

            Button {
                rows.removeAll { $0.id == row.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help(L("Remove model", "移除模型"))
        }
    }

    private func priceField(_ value: Binding<Double>) -> some View {
        TextField("0", value: value, format: .number.precision(.fractionLength(0...4)))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 64)
    }

    // MARK: - Actions

    private func appendModels(_ names: [String]) {
        let existing = existingNames
        for name in names where !existing.contains(name) && !name.isEmpty {
            rows.append(Row(model: .init(name: name, pricing: emptyPricing)))
        }
    }

    private func autoFillCache() {
        for index in rows.indices where rows[index].model.pricing.inputPerMillion > 0 {
            let input = rows[index].model.pricing.inputPerMillion
            rows[index].model.pricing.cacheCreatePerMillion = input * ProxyConfiguration.ModelPricing.defaultCacheWriteMultiplier
            rows[index].model.pricing.cacheReadPerMillion = input * ProxyConfiguration.ModelPricing.defaultCacheReadMultiplier
        }
    }
}

// MARK: - Library Slot Picker
// 槽位/默认模型输入框旁的「从模型库选择」下拉，点选即填，与手输互不排斥。

struct ModelLibrarySlotPicker: View {
    @Binding var selection: String
    let library: [ProxyConfiguration.MappedModel]

    var body: some View {
        if !library.isEmpty {
            Menu {
                ForEach(library, id: \.name) { model in
                    Button {
                        selection = model.name
                    } label: {
                        if model.name == selection {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "books.vertical")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help(L("Pick from model library", "从模型库选择"))
        }
    }
}
