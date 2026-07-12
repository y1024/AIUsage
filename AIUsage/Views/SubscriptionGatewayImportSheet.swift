import SwiftUI
import UniformTypeIdentifiers

// MARK: - Safe Auth Import Center (UI)
// 五阶段导入流程的界面：选择文件 → 本地识别 → 导入预览（脱敏身份、重复与
// 冲突状态、计划动作）→ 冲突逐项确认（默认保留现有，无“全部覆盖”）→
// 批量执行与逐项结果（只允许重试失败项）。识别与规划逻辑见
// CLIProxyAuthImportPlanner，执行见 CLIProxyGatewayManager+Import。

struct SubscriptionGatewayImportSheet: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    let mode: CLIProxyAuthImportSession.Mode
    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: 780,
               minHeight: 440, idealHeight: 560, maxHeight: 660)
        .onDisappear { manager.clearAuthImportSession() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: mode == .general
        ) { result in
            switch result {
            case .success(let urls):
                Task { await manager.prepareAuthImport(from: urls, mode: mode) }
            case .failure:
                break
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 13) {
            if mode == .codexAuthJSON {
                GatewayProviderIcon(providerID: "codex", size: 42)
            } else {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(width: 42, height: 42)
                    .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(mode == .codexAuthJSON
                     ? L("Import a Codex auth.json", "导入 Codex auth.json")
                     : L("Import CPA auth files", "导入 CPA 认证文件"))
                    .font(.title3.weight(.bold))
                Text(mode == .codexAuthJSON
                     ? L(
                        "The raw file is expanded into CPA's schema locally; tokens are never displayed.",
                        "原始文件会在本地展开为 CPA 格式；Token 永远不会显示。"
                     )
                     : L(
                        "Every file is recognized locally and previewed before anything is uploaded.",
                        "所有文件先在本地识别并预览，之后才会上传。"
                     ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Close", "关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(session?.phase == .executing)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if let session {
            sessionList(session)
        } else {
            intro
        }
    }

    private var intro: some View {
        VStack(spacing: 15) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.indigo)
            Text(mode == .codexAuthJSON
                 ? L("Choose the auth.json to convert", "选择要转换的 auth.json")
                 : L("Choose one or more auth JSON files", "选择一个或多个认证 JSON 文件"))
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                introRule(L(
                    "Up to \(CLIProxyAuthImportPlanner.maxBatchCount) files per batch, 5 MB per file, \(CLIProxyAuthImportPlanner.maxBatchBytes / 1_048_576) MB total. Symbolic links are rejected.",
                    "每批最多 \(CLIProxyAuthImportPlanner.maxBatchCount) 个文件；单文件 5 MB，总计 \(CLIProxyAuthImportPlanner.maxBatchBytes / 1_048_576) MB；不接受符号链接。"
                ))
                introRule(L(
                    "Unknown provider types are blocked by default; nothing is guessed.",
                    "未知 Provider 类型默认阻止，不做任何猜测。"
                ))
                introRule(L(
                    "Identical content is skipped; identity conflicts require per-file confirmation. AIUsage-managed copies are never overwritten.",
                    "内容完全相同会跳过；同一账号的冲突需要逐项确认；AIUsage 托管副本不会被覆盖。"
                ))
            }
            .frame(maxWidth: 470, alignment: .leading)
            if let error = manager.lastError {
                GatewayErrorBanner(message: error).frame(maxWidth: 470)
            }
            Button(L("Choose Files…", "选择文件…")) { showFilePicker = true }
                .buttonStyle(.borderedProminent)
                .disabled(!runtime.state.isRunning || manager.isImportingAuthFiles)
            if manager.isImportingAuthFiles { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func introRule(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sessionList(_ session: CLIProxyAuthImportSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.phase == .preview {
                    summaryBanner(session)
                }
                ForEach(session.items) { item in
                    itemRow(item, phase: session.phase)
                }
            }
            .padding(18)
        }
    }

    private func summaryBanner(_ session: CLIProxyAuthImportSession) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "list.clipboard").foregroundStyle(Color.accentColor)
            Text(L(
                "\(session.items.count) file(s) recognized · \(session.actionableCount) will be uploaded. Nothing has been changed yet.",
                "已识别 \(session.items.count) 个文件 · 将上传 \(session.actionableCount) 个。目前尚未做出任何修改。"
            ))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }

    // MARK: - Item rows

    private func itemRow(_ item: CLIProxyAuthImportSession.Item, phase: CLIProxyAuthImportSession.Phase) -> some View {
        HStack(alignment: .top, spacing: 12) {
            GatewayProviderIcon(providerID: item.inspection?.providerType ?? "cliproxyapi", size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusPill(item, phase: phase)
                }
                if let inspection = item.inspection {
                    Text(inspectionSummary(inspection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if inspection.convertedFromCodexCLI || inspection.strippedManagedMarker {
                        HStack(spacing: 6) {
                            if inspection.convertedFromCodexCLI {
                                conversionBadge(L("Converted to CPA schema", "已转换为 CPA 格式"))
                            }
                            if inspection.strippedManagedMarker {
                                conversionBadge(L("AIUsage marker removed", "已移除 AIUsage 托管标记"))
                            }
                        }
                    }
                }
                actionDetail(item, phase: phase)
            }
            Spacer(minLength: 8)
            if phase == .preview, case .confirmReplace = item.action {
                conflictPicker(item)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.055)))
    }

    private func inspectionSummary(_ inspection: CLIProxyAuthImportInspection) -> String {
        var parts = [gatewayProviderDisplayName(inspection.providerType)]
        if let identity = inspection.maskedIdentity { parts.append(identity) }
        if let project = inspection.projectSummary { parts.append(project) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(inspection.byteCount), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func conversionBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.indigo)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.indigo.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private func statusPill(_ item: CLIProxyAuthImportSession.Item, phase: CLIProxyAuthImportSession.Phase) -> some View {
        if let outcome = item.outcome {
            outcomePill(outcome)
        } else if phase == .executing {
            GatewayStatusPill(text: L("Waiting…", "等待中…"), color: .secondary, systemImage: "clock")
        } else {
            actionPill(item)
        }
    }

    @ViewBuilder
    private func actionPill(_ item: CLIProxyAuthImportSession.Item) -> some View {
        switch item.action {
        case .upload(_, let renamedFrom):
            if renamedFrom == nil {
                GatewayStatusPill(text: L("Ready to import", "可以导入"), color: .green, systemImage: "checkmark.circle.fill")
            } else {
                GatewayStatusPill(text: L("Will import renamed", "将重命名导入"), color: .green, systemImage: "pencil.circle.fill")
            }
        case .skipDuplicate:
            GatewayStatusPill(text: L("Exact duplicate · skipped", "完全重复 · 将跳过"), color: .secondary, systemImage: "equal.circle.fill")
        case .confirmReplace:
            GatewayStatusPill(text: L("Same account, different credential", "同一账号 · 凭据不同"), color: .orange, systemImage: "exclamationmark.triangle.fill")
        case .blockedManagedCopy:
            GatewayStatusPill(text: L("Managed copy · protected", "托管副本 · 受保护"), color: .orange, systemImage: "lock.shield.fill")
        case .requiresPlugin:
            GatewayStatusPill(text: L("Requires plugin", "需要插件"), color: .purple, systemImage: "puzzlepiece.extension")
        case .blocked:
            GatewayStatusPill(text: L("Not supported", "不支持"), color: .red, systemImage: "xmark.circle.fill")
        }
    }

    @ViewBuilder
    private func outcomePill(_ outcome: CLIProxyAuthImportItemOutcome) -> some View {
        switch outcome {
        case .imported:
            GatewayStatusPill(text: L("Imported", "已导入"), color: .green, systemImage: "checkmark.circle.fill")
        case .renamedImported:
            GatewayStatusPill(text: L("Imported renamed", "已重命名导入"), color: .green, systemImage: "pencil.circle.fill")
        case .replacedExisting:
            GatewayStatusPill(text: L("Replaced existing", "已覆盖现有"), color: .green, systemImage: "arrow.triangle.2.circlepath")
        case .skippedDuplicate:
            GatewayStatusPill(text: L("Duplicate skipped", "重复已跳过"), color: .secondary, systemImage: "equal.circle.fill")
        case .keptExisting:
            GatewayStatusPill(text: L("Kept existing", "保留现有"), color: .secondary, systemImage: "hand.raised.fill")
        case .blocked:
            GatewayStatusPill(text: L("Not imported", "未导入"), color: .red, systemImage: "xmark.circle.fill")
        case .requiresPlugin:
            GatewayStatusPill(text: L("Requires plugin", "需要插件"), color: .purple, systemImage: "puzzlepiece.extension")
        case .uploadFailed:
            GatewayStatusPill(text: L("Upload failed", "上传失败"), color: .red, systemImage: "exclamationmark.triangle.fill")
        case .verificationPending:
            GatewayStatusPill(text: L("Uploaded · verify later", "已上传 · 待验证"), color: .orange, systemImage: "clock.badge.exclamationmark")
        }
    }

    @ViewBuilder
    private func actionDetail(_ item: CLIProxyAuthImportSession.Item, phase: CLIProxyAuthImportSession.Phase) -> some View {
        Group {
            if let outcome = item.outcome {
                outcomeDetail(outcome)
            } else {
                planDetail(item.action)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func planDetail(_ action: CLIProxyAuthImportAction) -> some View {
        switch action {
        case .upload(let name, let renamedFrom):
            if let renamedFrom {
                Text(L("\(renamedFrom) conflicts with an existing name and will be saved as \(name).",
                       "\(renamedFrom) 与现有名称冲突，将以 \(name) 保存。"))
            } else {
                Text(L("Will be uploaded as \(name).", "将以 \(name) 上传。"))
            }
        case .skipDuplicate(let existingName):
            Text(L("Identical to \(existingName); nothing to do.", "与 \(existingName) 内容完全相同，无需导入。"))
        case .confirmReplace(let existingName):
            Text(L(
                "CPA already has \(existingName) for this account with different credentials. Default keeps the existing file.",
                "CPA 已有该账号的 \(existingName)，但凭据不同。默认保留现有文件。"
            ))
        case .blockedManagedCopy(let existingName):
            Text(L(
                "\(existingName) is an AIUsage-managed copy. Update it from Subscription Accounts instead.",
                "\(existingName) 是 AIUsage 托管副本，请改用订阅账号页面的同步功能更新。"
            ))
        case .requiresPlugin(let hint):
            Text(L(
                "Install and enable the official \(hint) provider plugin, then import again.",
                "请先安装并启用官方 \(hint) Provider 插件，然后重新导入。"
            ))
        case .blocked(let reason):
            Text(reason)
        }
    }

    @ViewBuilder
    private func outcomeDetail(_ outcome: CLIProxyAuthImportItemOutcome) -> some View {
        switch outcome {
        case .imported(let name), .renamedImported(let name), .replacedExisting(let name):
            Text(L("Saved in CPA as \(name).", "已保存到 CPA：\(name)。"))
        case .skippedDuplicate:
            Text(L("Identical content already exists in CPA.", "CPA 中已存在完全相同的内容。"))
        case .keptExisting:
            Text(L("The existing CPA file was kept unchanged.", "已保留 CPA 中的现有文件，未做修改。"))
        case .blocked(let reason):
            Text(reason)
        case .requiresPlugin(let hint):
            Text(L("Install the \(hint) plugin first.", "请先安装 \(hint) 插件。"))
        case .uploadFailed(let message):
            Text(message).foregroundStyle(.orange)
        case .verificationPending(let name):
            Text(L(
                "\(name) was uploaded, but the follow-up verification read failed. Do not import it again; refresh the account list later.",
                "\(name) 已上传成功，但后续验证读取失败。请勿重复导入，稍后刷新账号列表即可。"
            ))
            .foregroundStyle(.orange)
        }
    }

    private func conflictPicker(_ item: CLIProxyAuthImportSession.Item) -> some View {
        Picker(L("Conflict resolution", "冲突处理"), selection: Binding(
            get: { item.conflictChoice },
            set: { manager.setImportConflictChoice(itemID: item.id, choice: $0) }
        )) {
            Text(L("Keep existing", "保留现有")).tag(CLIProxyAuthImportConflictChoice.keepExisting)
            Text(L("Replace", "覆盖现有")).tag(CLIProxyAuthImportConflictChoice.replaceExisting)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if manager.isImportingAuthFiles { ProgressView().controlSize(.small) }
            Spacer()
            if let session {
                switch session.phase {
                case .preview:
                    Button(L("Choose Again…", "重新选择…")) {
                        manager.clearAuthImportSession()
                        showFilePicker = true
                    }
                    .disabled(manager.isImportingAuthFiles)
                    Button(L("Import \(session.actionableCount) File(s)", "开始导入 \(session.actionableCount) 个")) {
                        Task { await manager.executeAuthImport() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.actionableCount == 0 || manager.isImportingAuthFiles)
                case .executing:
                    Text(L("Importing…", "正在导入…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .completed:
                    if session.failedCount > 0 {
                        Button(L("Retry \(session.failedCount) Failed", "重试 \(session.failedCount) 个失败项")) {
                            Task { await manager.retryFailedAuthImports() }
                        }
                        .disabled(manager.isImportingAuthFiles)
                    }
                    Button(L("Done", "完成")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }

    private var session: CLIProxyAuthImportSession? { manager.authImportSession }
}
