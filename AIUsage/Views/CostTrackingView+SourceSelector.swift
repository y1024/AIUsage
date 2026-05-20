import SwiftUI

// MARK: - Source Selector
// Renders the pill-style source switcher above the cost-tracking summary.
// Pills are only shown when more than one local cost provider is connected.

extension CostTrackingView {
    // MARK: Derived selection

    /// Resolves the persisted `selectedCostProviderId` to a non-empty id, falling back to the
    /// default selection (the "All Sources" pill when >1 provider, otherwise the single provider).
    /// Kept `internal` so `derivedCostCacheSignature` in the main file can access it.
    var effectiveCostProviderId: String {
        selectedCostProviderId.isEmpty ? defaultCostProviderSelection : selectedCostProviderId
    }

    var defaultCostProviderSelection: String {
        costProviders.count > 1 ? Self.allSourcesId : (costProviders.first?.id ?? "")
    }

    // MARK: View

    @ViewBuilder
    var sourceSelector: some View {
        let providers = costProviders
        if providers.count > 1 {
            let activeId = effectiveCostProviderId
            HStack(spacing: 6) {
                sourcePill(Self.allSourcesId, label: L("All Sources", "综合"), isSelected: activeId == Self.allSourcesId)
                ForEach(providers) { provider in
                    sourcePill(
                        provider.id,
                        label: sourcePillLabel(for: provider, in: providers),
                        isSelected: activeId == provider.id
                    )
                }
                Spacer()
            }
        }
    }

    // MARK: Helpers

    /// Disambiguates pill labels when two providers share the same compact label (e.g. two
    /// connected accounts of the same source) by appending the account hint.
    private func sourcePillLabel(for provider: ProviderData, in providers: [ProviderData]) -> String {
        let sameLabelCount = providers.reduce(0) { $0 + ($1.label == provider.label ? 1 : 0) }
        guard sameLabelCount > 1, let account = provider.accountLabel?.nilIfBlank else {
            return provider.label
        }
        return "\(provider.label) · \(account)"
    }

    private func sourcePill(_ id: String, label: String, isSelected: Bool) -> some View {
        Button {
            selectCostProvider(id)
        } label: {
            Text(label)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(pillFillOpacity) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1),
                            lineWidth: 1
                        )
                )
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// Slightly lift the selected-pill fill in dark mode where the default .15 alpha can wash
    /// out against the window background.
    private var pillFillOpacity: Double {
        colorScheme == .dark ? 0.25 : 0.15
    }

    private func selectCostProvider(_ id: String) {
        selectedCostProviderId = id
        selectedModels.removeAll()
        expandedModels.removeAll()
        chartHoverDate = nil
        if id == Self.allSourcesId {
            refreshAggregateCostSummaryIfNeeded()
        }
        refreshDerivedCostCachesIfNeeded(force: true)
        requestCodexFullHistoryImportIfNeeded()
    }
}
