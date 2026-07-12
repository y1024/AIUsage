import SwiftUI

// MARK: - CPA Account Detail Sheet
// 单个 CPA 账号的详情：状态、请求计数、原生身份摘要、账号级模型、
// note/priority 元数据编辑，以及启停与删除入口。数据全部来自 CPA 返回的
// 真实字段，缺失字段显示空态，不做推导。

struct CLIProxyAccountDetailSheet: View {
    let file: CLIProxyAuthFile
    @ObservedObject var manager: CLIProxyGatewayManager
    @Binding var pendingDeletion: CLIProxyAuthFile?
    @Environment(\.dismiss) private var dismiss

    @State private var draftNote: String
    @State private var draftPriority: Int
    @State private var showAllModels = false
    @State private var operationError: String?
    @State private var isUpdating = false
    @State private var isLoadingModels = false

    init(
        file: CLIProxyAuthFile,
        manager: CLIProxyGatewayManager,
        pendingDeletion: Binding<CLIProxyAuthFile?>
    ) {
        self.file = file
        self.manager = manager
        self._pendingDeletion = pendingDeletion
        self._draftNote = State(initialValue: file.note ?? "")
        self._draftPriority = State(initialValue: file.priority ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                GatewayProviderIcon(providerID: file.gatewayProviderID, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentFile.displayLabel).font(.title3.weight(.bold))
                    Text(gatewayAccountIdentitySubtitle(
                        providerID: currentFile.gatewayProviderID,
                        identity: currentIdentity
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let operationError { GatewayErrorBanner(message: operationError) }
                    HStack(spacing: 10) {
                        detailMetric(
                            value: "\(currentFile.success)",
                            title: L("Successful", "成功请求"),
                            icon: "checkmark.circle.fill",
                            tint: .green
                        )
                        detailMetric(
                            value: "\(currentFile.failed)",
                            title: L("Failed", "失败请求"),
                            icon: "xmark.circle.fill",
                            tint: currentFile.failed > 0 ? .orange : .secondary
                        )
                        detailMetric(
                            value: "\(models.count)",
                            title: L("Models", "可用模型"),
                            icon: "square.stack.3d.up.fill",
                            tint: .indigo
                        )
                    }

                    GatewayCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("Account status", "账号状态")).font(.headline)
                            detailRow(L("Status", "状态"), currentFile.disabled ? L("Paused", "已停用") : (currentFile.status ?? L("Ready", "可用")))
                            detailRow(L("Source", "来源"), currentFile.gatewaySourceTitle)
                            if let message = currentFile.statusMessage, !message.isEmpty {
                                detailRow(L("Status detail", "状态详情"), message)
                            }
                            if let plan = currentIdentity?.planDisplayName {
                                detailRow(L("Plan", "套餐"), plan)
                            }
                            if let accountID = currentIdentity?.accountID {
                                detailRow(L("Workspace ID", "工作区 ID"), accountID)
                            }
                            if let projectID = currentIdentity?.projectID {
                                detailRow(L("Project ID", "项目 ID"), projectID)
                            }
                            if let accountType = currentFile.accountType { detailRow(L("Account type", "账号类型"), accountType) }
                            if currentIdentity?.projectID == nil, let projectID = currentFile.projectID {
                                detailRow(L("Project", "项目"), projectID)
                            }
                            if let refreshed = currentFile.lastRefresh {
                                detailRow(L("Last refresh", "上次刷新"), refreshed.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let nextRetry = currentFile.nextRetryAfter {
                                detailRow(L("Next retry", "下次重试"), nextRetry.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }

                    if !currentFile.runtimeOnly {
                        GatewayCard {
                            VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Routing metadata", "路由元数据")).font(.headline)
                                Text(L(
                                    "Priority and notes are stored by CPA; credential tokens are never shown or edited here.",
                                    "优先级和备注由 CPA 保存；此处永远不会显示或编辑凭据 Token。"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("Note", "备注")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    TextField(L("Optional account note", "可选账号备注"), text: $draftNote)
                                        .textFieldStyle(.roundedBorder)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("Priority", "优先级")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Stepper(value: $draftPriority, in: -100...100) {
                                        Text("\(draftPriority)").monospacedDigit().frame(width: 36, alignment: .trailing)
                                    }
                                }
                                .frame(width: 125)
                            }
                                HStack {
                                    Spacer()
                                    Button(L("Save Metadata", "保存元数据")) {
                                        isUpdating = true
                                        operationError = nil
                                        Task {
                                            await manager.updateAuthFile(currentFile, note: draftNote, priority: draftPriority)
                                            operationError = manager.lastError
                                            isUpdating = false
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!metadataChanged || manager.isManagingAccounts || isUpdating)
                                }
                            }
                        }
                    } else {
                        GatewayCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("Provider configuration", "提供商配置")).font(.headline)
                                Text(L(
                                    "This is a CPA runtime provider. Enable/disable and deletion use the provider configuration API; auth-file notes are not applicable.",
                                    "这是 CPA 运行时提供商。启停和删除会使用提供商配置 API，认证文件备注不适用。"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GatewayCard {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L("Models available to this account", "该账号可用模型")).font(.headline)
                                    Text(L("Loaded dynamically from CPA for this credential.", "由 CPA 针对此凭据动态返回。"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    loadModels(force: true)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help(L("Refresh account models", "刷新账号模型"))
                                .accessibilityLabel(L("Refresh models", "刷新模型"))
                            }
                            if let modelError = manager.authFileModelErrors[currentFile.name] {
                                GatewayErrorBanner(message: modelError)
                            } else if isLoadingModels {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(L("Loading account models…", "正在加载账号模型…"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            } else if models.isEmpty {
                                Text(L("CPA reported no models for this account.", "CPA 未返回该账号的可用模型。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                                        HStack {
                                            Image(systemName: "cube").foregroundStyle(.secondary).frame(width: 20)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(model.displayName ?? model.id).font(.callout.weight(.medium))
                                                if model.displayName != nil { Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                            }
                                            Spacer()
                                            if let ownedBy = model.ownedBy { Text(ownedBy).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        .padding(.vertical, 8)
                                        if index < visibleModels.count - 1 { Divider() }
                                    }
                                }
                                if models.count > 8 {
                                    Button(showAllModels ? L("Show Less", "收起") : L("Show All \(models.count)", "显示全部 \(models.count) 个")) {
                                        showAllModels.toggle()
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }

                    GatewayCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("Technical details", "技术详情")).font(.headline)
                            detailRow(L("Provider", "提供商"), currentFile.displayProvider)
                            detailRow(L("CPA auth file", "CPA 认证文件"), currentFile.name)
                            if let authIndex = currentFile.authIndex { detailRow(L("Auth index", "Auth Index"), authIndex) }
                            if let source = currentFile.source { detailRow(L("CPA source", "CPA 来源"), source) }
                            if let size = currentFile.size { detailRow(L("File size", "文件大小"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        }
                    }
                    HStack {
                        Button(currentFile.disabled ? L("Enable Account", "启用账号") : L("Pause Account", "停用账号")) {
                            isUpdating = true
                            operationError = nil
                            Task {
                                await manager.setAuthFile(currentFile, disabled: !currentFile.disabled)
                                operationError = manager.lastError
                                isUpdating = false
                                if operationError == nil { dismiss() }
                            }
                        }
                        .disabled(isUpdating || manager.isManagingAccounts)
                        Spacer()
                        Button(L("Remove from CPA", "从 CPA 删除"), role: .destructive) {
                            dismiss()
                            pendingDeletion = currentFile
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 640,
               minHeight: 440, idealHeight: 540, maxHeight: 600)
        .task { loadModels(force: false) }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailMetric(value: String, title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.headline.monospacedDigit())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private var currentFile: CLIProxyAuthFile {
        manager.authFiles.first { $0.name == file.name } ?? file
    }

    private var currentIdentity: CLIProxyAccountIdentity? { manager.accountIdentity(for: currentFile) }
    private var models: [CLIProxyModel] { manager.models(for: currentFile) }
    private var visibleModels: [CLIProxyModel] { showAllModels ? models : Array(models.prefix(8)) }
    private var metadataChanged: Bool {
        draftNote != (currentFile.note ?? "") || draftPriority != (currentFile.priority ?? 0)
    }

    private func loadModels(force: Bool) {
        isLoadingModels = true
        Task {
            await manager.loadModels(for: currentFile, force: force)
            isLoadingModels = false
        }
    }
}
