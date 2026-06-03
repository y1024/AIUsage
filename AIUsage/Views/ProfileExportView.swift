import SwiftUI

// MARK: - Profile Export View
// Presents a multi-select list of profiles and lets the user choose a destination folder to export.

struct ProfileExportView: View {
    let profiles: [NodeProfile]
    @Binding var selectedIds: Set<String>
    @EnvironmentObject var viewModel: ProxyViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Export Profiles", "导出配置"))
                    .font(.title2.weight(.bold))
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Button(L("Select All", "全选")) {
                            selectedIds = Set(profiles.map(\.id))
                        }
                        .font(.caption)
                        Button(L("Deselect All", "取消全选")) {
                            selectedIds.removeAll()
                        }
                        .font(.caption)
                        Spacer()
                        Text(L("\(selectedIds.count) selected", "已选 \(selectedIds.count) 个"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(profiles) { profile in
                        HStack(spacing: 12) {
                            Image(systemName: selectedIds.contains(profile.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIds.contains(profile.id) ? .blue : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.metadata.name)
                                    .font(.subheadline.weight(.medium))
                                Text(profile.metadata.nodeType.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedIds.contains(profile.id)
                                      ? Color.accentColor.opacity(0.08)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedIds.contains(profile.id) {
                                selectedIds.remove(profile.id)
                            } else {
                                selectedIds.insert(profile.id)
                            }
                        }
                    }
                }
                .padding(20)
            }

            if hasCommonConfigToExport {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(L("Common config is included for each selected family.",
                           "每个所选家族的通用配置将一并导出。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }

            if let exportError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(exportError).font(.caption).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }

            Divider()

            HStack {
                Spacer()
                Button(L("Export...", "导出...")) {
                    performExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIds.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 450, height: 500)
    }

    /// 是否存在可随导出携带的通用配置（任一家族非空）。
    private var hasCommonConfigToExport: Bool {
        let store = viewModel.profileStore
        let claude = !store.globalConfig.settings.isEmpty
        let codex = !store.codexGlobalConfig.tomlText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return claude || codex
    }

    private func performExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Export Here", "导出到此处")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try viewModel.profileStore.exportProfiles(
                    ids: Array(selectedIds),
                    to: url
                )
                DispatchQueue.main.async {
                    exportError = nil
                    dismiss()
                    NSWorkspace.shared.open(url)
                }
            } catch {
                DispatchQueue.main.async {
                    exportError = error.localizedDescription
                }
            }
        }
    }
}
