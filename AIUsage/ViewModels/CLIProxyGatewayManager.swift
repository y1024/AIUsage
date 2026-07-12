import AppKit
import Combine
import Foundation
import QuotaBackend

@MainActor
final class CLIProxyGatewayManager: ObservableObject {
    static let shared: CLIProxyGatewayManager = {
        do {
            return CLIProxyGatewayManager(paths: try CLIProxyPaths())
        } catch {
            preconditionFailure("CLIProxyAPI storage is unavailable: \(error.localizedDescription)")
        }
    }()

    @Published private(set) var operation: CLIProxyGatewayOperation = .idle
    @Published private(set) var currentVersion: String?
    @Published private(set) var installedVersions: [CLIProxyInstalledVersion] = []
    @Published private(set) var latestRelease: CLIProxyRelease?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var authFiles: [CLIProxyAuthFile] = []
    @Published private(set) var availableModels: [CLIProxyModel] = []
    @Published private(set) var modelCatalog: [CLIProxyModelCatalogEntry] = []
    @Published private(set) var unavailableModelProtocols: Set<CLIProxyModelProtocol> = []
    @Published private(set) var isRefreshingModels = false
    @Published private(set) var modelCatalogError: String?
    @Published private(set) var modelCatalogUpdatedAt: Date?
    @Published private(set) var authFileModels: [String: [CLIProxyModel]] = [:]
    @Published private(set) var authFileModelErrors: [String: String] = [:]
    @Published private(set) var isManagingAccounts = false
    @Published private(set) var oauthProvider: CLIProxyOAuthProvider?
    @Published private(set) var oauthStatusMessage: String?
    @Published private(set) var oauthSession: CLIProxyOAuthSession?
    @Published private(set) var oauthFlowState: CLIProxyOAuthFlowState = .idle
    @Published private(set) var currentDistributionTargets: Set<ProxyTarget> = []
    @Published private(set) var managedProviderExists = false
    @Published private(set) var isApplyingDistribution = false
    @Published private(set) var pluginsEnabled = false
    @Published private(set) var providerPlugins: [CLIProxyPlugin] = []
    @Published private(set) var providerPluginStore: [CLIProxyPluginStoreEntry] = []
    @Published private(set) var openAICompatibleProviders: [CLIProxyOpenAICompatibleProvider] = []
    @Published private(set) var isManagingPlugins = false
    @Published private(set) var pluginError: String?
    @Published private(set) var oauthPlugin: CLIProxyPlugin?
    @Published private(set) var accountSyncStates: [String: CLIProxyAccountSyncState] = [:]
    @Published private(set) var syncRecords: [CLIProxyAccountSyncRecord] = []
    @Published private(set) var lastImportedAuthFileName: String?

    private let paths: CLIProxyPaths
    private let releaseClient: CLIProxyReleaseClient
    private let downloader: CLIProxyAssetDownloader
    private let binaryStore: CLIProxyBinaryStore
    let runtime: CLIProxyRuntimeController
    private var syncCandidateCache: [String: CLIProxyAccountSyncCandidate] = [:]
    private var syncManifest = CLIProxyAccountSyncManifest.empty
    private var activeOAuthOperationID: UUID?
    private var activeOAuthState: String?
    private var modelCatalogRefreshTask: Task<Void, Never>?
    private var modelCatalogRefreshID: UUID?
    private var modelCatalogRuntimePID: Int32?

    static let maxAuthFileImportBytes = 5 * 1_048_576

    var hasUpdate: Bool {
        guard let currentVersion, let latestRelease else { return false }
        return CLIProxyVersion.isNewer(latestRelease.version, than: currentVersion)
    }

    var isInstalled: Bool { currentVersion != nil }

    init(
        paths: CLIProxyPaths,
        releaseClient: CLIProxyReleaseClient = CLIProxyReleaseClient(),
        downloader: CLIProxyAssetDownloader = CLIProxyAssetDownloader(),
        binaryStore: CLIProxyBinaryStore? = nil,
        runtime: CLIProxyRuntimeController? = nil
    ) {
        self.paths = paths
        self.releaseClient = releaseClient
        self.downloader = downloader
        self.binaryStore = binaryStore ?? CLIProxyBinaryStore(paths: paths)
        self.runtime = runtime ?? CLIProxyRuntimeController.shared
        do {
            try paths.prepare()
            syncManifest = try Self.loadSyncManifest(from: paths.syncManifestURL)
            syncRecords = syncManifest.records
            if FileManager.default.fileExists(atPath: paths.syncManifestURL.path) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: paths.syncManifestURL.path
                )
            }
        } catch {
            lastError = error.localizedDescription
        }
        refreshDistributionState()
    }

    func refresh(checkRemote: Bool = true) async {
        await reloadInstalledVersions()
        refreshDistributionState()
        if runtime.state.isRunning {
            await refreshAccounts()
            await refreshProviderPlugins(includeStore: false)
        }
        guard checkRemote else { return }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard !operation.isBusy else { return }
        operation = .checking
        lastError = nil
        defer { operation = .idle }
        do {
            latestRelease = try await releaseClient.latestStableRelease()
            lastCheckedAt = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func installOrUpdateLatest() async {
        guard !operation.isBusy else { return }
        lastError = nil
        do {
            let release: CLIProxyRelease
            if let latestRelease {
                release = latestRelease
            } else {
                operation = .checking
                release = try await releaseClient.latestStableRelease()
                self.latestRelease = release
                lastCheckedAt = Date()
            }

            if currentVersion == release.version {
                operation = .idle
                return
            }

            if installedVersions.contains(where: { $0.version == release.version }) {
                operation = .activating(version: release.version)
                try await activateWithRuntimeRollback(version: release.version)
                try? await binaryStore.cleanup(keeping: 3)
                await reloadInstalledVersions()
                operation = .idle
                return
            }

            operation = .downloading(version: release.version)
            let downloaded = try await downloader.download(release)
            defer { try? FileManager.default.removeItem(at: downloaded.cleanupDirectory) }

            operation = .verifying(version: release.version)
            _ = try await binaryStore.install(
                downloadedAssetURL: downloaded.fileURL,
                release: release
            )

            operation = .activating(version: release.version)
            try await activateWithRuntimeRollback(version: release.version)
            try? await binaryStore.cleanup(keeping: 3)
            await reloadInstalledVersions()
            operation = .idle
        } catch {
            operation = .idle
            lastError = error.localizedDescription
            await reloadInstalledVersions()
        }
    }

    func activate(_ version: CLIProxyInstalledVersion) async {
        guard !operation.isBusy, !version.isCurrent else { return }
        operation = .activating(version: version.version)
        lastError = nil
        do {
            try await activateWithRuntimeRollback(version: version.version)
            await reloadInstalledVersions()
        } catch {
            lastError = error.localizedDescription
        }
        operation = .idle
    }

    func delete(_ version: CLIProxyInstalledVersion) async {
        guard !operation.isBusy, !version.isCurrent else { return }
        lastError = nil
        do {
            try await binaryStore.delete(version: version.version)
            await reloadInstalledVersions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.root])
    }

    func openThirdPartyNotices() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }

    var syncCandidates: [CLIProxyAccountSyncCandidate] {
        AccountStore.shared.accountRegistry.compactMap { account in
            guard let credentialId = account.credentialId else { return nil }
            return syncCandidate(
                providerId: account.providerId,
                label: account.preferredLabel,
                credentialId: credentialId
            )
        }
    }

    func syncCandidate(providerId: String, label: String, credentialId: String) -> CLIProxyAccountSyncCandidate? {
        guard let credential = AccountCredentialStore.shared.loadCredential(
            providerId: providerId,
            credentialId: credentialId
        ) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: credential.credential)
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(providerId)|\(credentialId)|\(label)|\(modifiedAt)"
        if let cached = syncCandidateCache[cacheKey] { return cached }
        let compatibility: CLIProxyAccountSyncCandidate.Compatibility
        if credential.authMethod != .authFile {
            compatibility = .unsupported(L("CPA requires an OAuth auth file for this provider.", "CPA 需要该服务商的 OAuth 凭据文件。"))
        } else if !CLIProxyCredentialAdapter.supportedProviderIDs.contains(providerId) {
            compatibility = .unsupported(L("No verified conversion adapter is available yet.", "目前没有经过验证的格式转换适配器。"))
        } else if !FileManager.default.fileExists(atPath: credential.credential) {
            compatibility = .unsupported(L("The managed credential file is unavailable.", "托管凭据文件当前不可用。"))
        } else {
            do {
                let sourceData = try Data(contentsOf: URL(fileURLWithPath: credential.credential), options: .mappedIfSafe)
                _ = try convertedAuthFile(credential, sourceData: sourceData)
                compatibility = .compatible
            } catch {
                compatibility = .unsupported(error.localizedDescription)
            }
        }
        let candidate = CLIProxyAccountSyncCandidate(
            id: "\(providerId):\(credentialId)",
            providerId: providerId,
            label: label,
            credentialId: credentialId,
            compatibility: compatibility
        )
        if syncCandidateCache.count > 200 { syncCandidateCache.removeAll(keepingCapacity: true) }
        syncCandidateCache[cacheKey] = candidate
        return candidate
    }

    func refreshAccounts() async {
        guard runtime.state.isRunning, !isManagingAccounts, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        defer { isManagingAccounts = false }
        do {
            async let files = loadAuthPool(using: client)
            async let catalogRefresh: Void = refreshModelCatalog(using: client)
            authFiles = try await files
            await catalogRefresh
            let validNames = Set(authFiles.map(\.name))
            authFileModels = authFileModels.filter { validNames.contains($0.key) }
            authFileModelErrors = authFileModelErrors.filter { validNames.contains($0.key) }
            await refreshSyncStates(using: client, allowKeepUpdated: true)
            await reconcileManagedDistributionIfNeeded()
        } catch { lastError = error.localizedDescription }
    }

    /// Refresh only the public model catalog. The overview polls this lightweight
    /// endpoint while visible so account/plugin changes appear without running a
    /// full credential reconciliation pass every time.
    func refreshAvailableModels() async {
        guard runtime.state.isRunning,
              let client = managementClient() else { return }
        await refreshModelCatalog(using: client)
    }

    func models(for file: CLIProxyAuthFile) -> [CLIProxyModel] {
        authFileModels[file.name] ?? []
    }

    func loadModels(for file: CLIProxyAuthFile, force: Bool = false) async {
        if file.isOpenAICompatibleRuntime,
           let provider = openAICompatibleProvider(named: file.displayLabel) {
            authFileModels[file.name] = Self.models(for: provider)
            authFileModelErrors[file.name] = nil
            return
        }
        guard force || authFileModels[file.name] == nil,
              let client = managementClient() else { return }
        authFileModelErrors[file.name] = nil
        do {
            authFileModels[file.name] = Self.normalizedModels(try await client.models(forAuthFile: file.name))
        } catch {
            authFileModelErrors[file.name] = error.localizedDescription
        }
    }

    func setAuthFile(_ file: CLIProxyAuthFile, disabled: Bool) async {
        guard !isManagingAccounts, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        do {
            if file.isOpenAICompatibleRuntime {
                try await client.setOpenAICompatibleProviderDisabled(name: file.displayLabel, disabled: disabled)
                await runtime.restart()
                guard runtime.state.isRunning, let refreshedClient = managementClient() else {
                    throw CLIProxyGatewayError.process("CPA did not restart after updating the provider")
                }
                authFiles = try await loadAuthPool(using: refreshedClient)
                await refreshModelCatalogAndDistribution(using: refreshedClient)
            } else {
                try await client.setDisabled(disabled, name: file.name)
                authFiles = try await loadAuthPool(using: client)
                await refreshModelCatalogAndDistribution(using: client)
            }
        } catch { lastError = error.localizedDescription }
        isManagingAccounts = false
    }

    func updateAuthFileMetadata(_ file: CLIProxyAuthFile, note: String, priority: Int) async {
        guard !isManagingAccounts, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        defer { isManagingAccounts = false }
        do {
            guard !file.runtimeOnly else {
                throw CLIProxyGatewayError.configuration(
                    L("Runtime providers do not support auth-file notes or priority editing here.", "运行时提供商不支持在此编辑认证文件备注或优先级。")
                )
            }
            try await client.patchAuthFileFields(name: file.name, note: note, priority: priority)
            authFiles = try await loadAuthPool(using: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateAuthFile(_ file: CLIProxyAuthFile, note: String?, priority: Int?) async {
        await updateAuthFileMetadata(
            file,
            note: note ?? file.note ?? "",
            priority: priority ?? file.priority ?? 0
        )
    }

    func deleteAuthFile(_ file: CLIProxyAuthFile) async {
        guard !isManagingAccounts, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        do {
            var activeClient = client
            if file.runtimeOnly,
               file.isOpenAICompatibleRuntime,
               let providerName = file.label?.nilIfBlank {
                try await client.deleteOpenAICompatibleProvider(name: providerName)
                await runtime.restart()
                guard runtime.state.isRunning, let refreshedClient = managementClient() else {
                    throw CLIProxyGatewayError.process("CPA did not restart after removing the provider")
                }
                activeClient = refreshedClient
            } else {
                try await client.deleteAuthFile(name: file.name)
            }
            if file.runtimeOnly { try? await Task.sleep(for: .milliseconds(300)) }
            let removedRecordIDs = removeSyncRecords(authFileName: file.name)
            do { try saveSyncManifest() }
            catch { lastError = error.localizedDescription }
            removedRecordIDs.forEach { accountSyncStates[$0] = .notSynced }
            authFileModels[file.name] = nil
            authFileModelErrors[file.name] = nil
            authFiles = try await loadAuthPool(using: activeClient)
            await refreshModelCatalogAndDistribution(using: activeClient)
        } catch { lastError = error.localizedDescription }
        isManagingAccounts = false
    }

    func importAuthFile(from url: URL) async {
        guard !isManagingAccounts, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        lastImportedAuthFileName = nil
        defer { isManagingAccounts = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Self.readImportableAuthFile(at: url)
            let currentFiles = try await client.listAuthFiles()
            let name = Self.uniqueAuthFileName(
                preferred: url.lastPathComponent,
                existing: Set(currentFiles.map { $0.name.lowercased() })
            )
            try await client.uploadAuthFile(data: data, name: name)
            lastImportedAuthFileName = name
            authFiles = try await loadAuthPool(using: client)
            if let imported = authFiles.first(where: { $0.name == name }) {
                await loadModels(for: imported, force: true)
            }
            await refreshModelCatalogAndDistribution(using: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addOpenAICompatibleProvider(
        name: String,
        baseURL: String,
        apiKey: String,
        modelIDs: [String],
        prefix: String,
        priority: Int
    ) async {
        guard !isManagingAccounts, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        defer { isManagingAccounts = false }
        do {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
                throw CLIProxyGatewayError.configuration("provider name is required and must be at most 80 characters")
            }
            let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: normalizedBaseURL),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw CLIProxyGatewayError.configuration("a valid HTTP or HTTPS base URL is required")
            }
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else {
                throw CLIProxyGatewayError.configuration("API key is required")
            }
            var seen = Set<String>()
            let models = modelIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !models.isEmpty else {
                throw CLIProxyGatewayError.configuration("at least one upstream model is required")
            }
            let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = CLIProxyOpenAICompatibleProvider(
                name: normalizedName,
                priority: min(max(priority, -100), 100),
                disabled: false,
                prefix: normalizedPrefix,
                baseURL: normalizedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                apiKeyEntries: [.init(apiKey: normalizedKey, proxyURL: nil)],
                models: models.map { .init(name: $0, alias: "", forceMapping: false) },
                headers: nil,
                disableCooling: false
            )
            try await client.addOpenAICompatibleProvider(provider)
            await runtime.restart()
            guard runtime.state.isRunning, let refreshedClient = managementClient() else {
                throw CLIProxyGatewayError.process("CPA did not restart after adding the provider")
            }
            authFiles = try await loadAuthPool(using: refreshedClient)
            await refreshModelCatalogAndDistribution(using: refreshedClient)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshProviderPlugins(includeStore: Bool = true) async {
        guard runtime.state.isRunning, !isManagingPlugins, let client = managementClient() else { return }
        isManagingPlugins = true
        pluginError = nil
        defer { isManagingPlugins = false }
        do {
            try await loadProviderPluginState(using: client, includeStore: includeStore)
        } catch {
            pluginError = error.localizedDescription
        }
    }

    func installProviderPlugin(_ entry: CLIProxyPluginStoreEntry) async {
        guard runtime.state.isRunning, !isManagingPlugins, !isManagingAccounts else { return }
        isManagingPlugins = true
        pluginError = nil
        defer { isManagingPlugins = false }
        do {
            if !runtime.settings.enablePlugins {
                var settings = runtime.settings
                settings.enablePlugins = true
                await runtime.applySettings(settings)
                guard runtime.state.isRunning else {
                    throw CLIProxyGatewayError.process("CPA did not restart after enabling plugins")
                }
            }
            guard let client = managementClient() else { return }
            _ = try await client.installPlugin(id: entry.id, sourceID: entry.sourceID)
            try await client.setPluginEnabled(id: entry.id, enabled: true)
            await runtime.restart()
            guard runtime.state.isRunning else {
                throw CLIProxyGatewayError.process("CPA did not restart after installing the provider plugin")
            }
            guard let refreshedClient = managementClient() else { return }
            try await loadProviderPluginState(using: refreshedClient, includeStore: true)
            await refreshAccounts()
        } catch {
            pluginError = error.localizedDescription
        }
    }

    func setProviderPlugin(_ plugin: CLIProxyPlugin, enabled: Bool) async {
        guard runtime.state.isRunning, !isManagingPlugins, !isManagingAccounts,
              let client = managementClient() else { return }
        isManagingPlugins = true
        pluginError = nil
        defer { isManagingPlugins = false }
        do {
            try await client.setPluginEnabled(id: plugin.id, enabled: enabled)
            await runtime.restart()
            guard runtime.state.isRunning else {
                throw CLIProxyGatewayError.process("CPA did not restart after changing the provider plugin")
            }
            guard let refreshedClient = managementClient() else { return }
            try await loadProviderPluginState(using: refreshedClient, includeStore: true)
            await refreshAccounts()
        } catch {
            pluginError = error.localizedDescription
        }
    }

    func syncAccount(
        _ candidate: CLIProxyAccountSyncCandidate,
        mode: CLIProxyAccountSyncMode? = nil,
        forceOverwriteCPA: Bool = false
    ) async {
        guard !isManagingAccounts,
              case .compatible = candidate.compatibility,
              let client = managementClient(),
              let credential = AccountCredentialStore.shared.loadCredential(
                providerId: candidate.providerId,
                credentialId: candidate.credentialId
              ) else { return }
        isManagingAccounts = true
        lastError = nil
        defer { isManagingAccounts = false }
        do {
            let evaluation = try await evaluateSyncState(
                candidate: candidate,
                credential: credential,
                client: client
            )
            if !forceOverwriteCPA && (evaluation.state == .cpaChanged || evaluation.state == .conflict) {
                throw CLIProxyGatewayError.syncConflict(
                    L(
                        "The CPA copy has local changes. Review it before replacing the file.",
                        "CPA 副本已有本地修改，请确认后再覆盖。"
                    )
                )
            }
            let name = evaluation.authFileName
            let data = evaluation.copiedData
            let effectiveMode = mode ?? syncRecord(for: candidate)?.mode ?? .manualCopy
            try await client.uploadAuthFile(data: data, name: name)
            let record = CLIProxyAccountSyncRecord(
                providerId: candidate.providerId,
                credentialId: candidate.credentialId,
                authFileName: name,
                sourceFingerprint: evaluation.sourceFingerprint,
                lastCopiedFingerprint: evaluation.copiedFingerprint,
                lastSyncedAt: Date(),
                mode: effectiveMode
            )
            upsertSyncRecord(record)
            try saveSyncManifest()
            authFiles = try await loadAuthPool(using: client)
            accountSyncStates[candidate.id] = .current
            if let synced = authFiles.first(where: { $0.name == name }) {
                await loadModels(for: synced, force: true)
            }
            await refreshModelCatalogAndDistribution(using: client)
        } catch { lastError = error.localizedDescription }
    }

    func setSyncMode(_ candidate: CLIProxyAccountSyncCandidate, mode: CLIProxyAccountSyncMode) async {
        guard var record = syncRecord(for: candidate) else {
            await syncAccount(candidate, mode: mode)
            return
        }
        record.mode = mode
        upsertSyncRecord(record)
        do {
            try saveSyncManifest()
            if mode == .keepUpdated, accountSyncStates[candidate.id] == .sourceChanged {
                await syncAccount(candidate, mode: mode)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func authFileName(for candidate: CLIProxyAccountSyncCandidate) -> String {
        let safeID = candidate.credentialId
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .prefix(24)
        return "aiusage-\(candidate.providerId)-\(String(safeID)).json"
    }

    func isSynced(_ candidate: CLIProxyAccountSyncCandidate) -> Bool {
        let name = syncRecord(for: candidate)?.authFileName ?? authFileName(for: candidate)
        return authFiles.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func syncState(for candidate: CLIProxyAccountSyncCandidate) -> CLIProxyAccountSyncState {
        accountSyncStates[candidate.id] ?? (isSynced(candidate) ? .current : .notSynced)
    }

    func syncStatus(for candidate: CLIProxyAccountSyncCandidate) -> CLIProxyAccountSyncState {
        syncState(for: candidate)
    }

    func syncMode(for candidate: CLIProxyAccountSyncCandidate) -> CLIProxyAccountSyncMode? {
        syncRecord(for: candidate)?.mode
    }

    func beginOAuth(_ provider: CLIProxyOAuthProvider) async {
        guard !isManagingAccounts, !oauthFlowState.isActive, let client = managementClient() else { return }
        let operationID = UUID()
        activeOAuthOperationID = operationID
        activeOAuthState = nil
        isManagingAccounts = true
        lastError = nil
        oauthProvider = provider
        oauthPlugin = nil
        oauthSession = nil
        oauthFlowState = .starting(provider)
        oauthStatusMessage = L("Starting sign-in…", "正在启动登录…")
        defer {
            if activeOAuthOperationID == operationID {
                activeOAuthOperationID = nil
                activeOAuthState = nil
                oauthProvider = nil
                oauthPlugin = nil
                isManagingAccounts = false
            }
        }
        do {
            let oauth = try await client.beginOAuth(provider)
            guard activeOAuthOperationID == operationID else {
                try? await client.cancelOAuth(state: oauth.state)
                return
            }
            activeOAuthState = oauth.state
            oauthSession = oauth
            oauthFlowState = .waiting(provider, oauth)
            oauthStatusMessage = oauth.isDeviceFlow
                ? L("Enter the device code to continue.", "请输入设备码以继续。")
                : L("Waiting for sign-in…", "等待登录…")
            NSWorkspace.shared.open(oauth.url)
            let timeout = TimeInterval(max(30, min(oauth.expiresIn ?? 300, 900)) + 10)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                guard activeOAuthOperationID == operationID else { return }
                let status = try await client.oauthStatus(state: oauth.state)
                let normalizedStatus = status.status.lowercased()
                if normalizedStatus == "ok" || normalizedStatus == "success" {
                    oauthStatusMessage = L("Account connected.", "账号已连接。")
                    authFiles = try await loadAuthPool(using: client)
                    availableModels = Self.normalizedModels((try? await client.availableModels()) ?? availableModels)
                    await refreshSyncStates(using: client, allowKeepUpdated: true)
                    await reconcileManagedDistributionIfNeeded()
                    oauthFlowState = .succeeded(provider)
                    oauthSession = nil
                    oauthProvider = nil
                    return
                }
                if normalizedStatus == "error" || normalizedStatus == "failed" {
                    throw CLIProxyGatewayError.invalidResponse(status.error ?? "OAuth failed")
                }
            }
            try? await client.cancelOAuth(state: oauth.state)
            throw CLIProxyGatewayError.network("OAuth timed out")
        } catch is CancellationError {
            if let state = activeOAuthState { try? await client.cancelOAuth(state: state) }
            guard activeOAuthOperationID == operationID else { return }
            oauthFlowState = .cancelled(provider)
            oauthStatusMessage = L("Sign-in cancelled.", "登录已取消。")
            oauthSession = nil
        } catch {
            if let state = activeOAuthState { try? await client.cancelOAuth(state: state) }
            guard activeOAuthOperationID == operationID else { return }
            lastError = error.localizedDescription
            oauthStatusMessage = L("Sign-in failed.", "登录失败。")
            oauthFlowState = .failed(provider, error.localizedDescription)
            oauthSession = nil
        }
    }

    func beginPluginOAuth(_ plugin: CLIProxyPlugin) async {
        guard plugin.supportsOAuth, plugin.effectiveEnabled,
              !isManagingAccounts, !oauthFlowState.isActive, let client = managementClient() else { return }
        let operationID = UUID()
        activeOAuthOperationID = operationID
        activeOAuthState = nil
        isManagingAccounts = true
        lastError = nil
        oauthProvider = nil
        oauthPlugin = plugin
        oauthSession = nil
        oauthFlowState = .pluginStarting(plugin.displayName)
        oauthStatusMessage = L("Starting sign-in…", "正在启动登录…")
        defer {
            if activeOAuthOperationID == operationID {
                activeOAuthOperationID = nil
                activeOAuthState = nil
                oauthProvider = nil
                oauthPlugin = nil
                isManagingAccounts = false
            }
        }
        do {
            let oauth = try await client.beginPluginOAuth(providerID: plugin.providerID)
            guard activeOAuthOperationID == operationID else { return }
            activeOAuthState = oauth.state
            oauthSession = oauth
            oauthFlowState = .pluginWaiting(plugin.displayName, oauth)
            oauthStatusMessage = oauth.isDeviceFlow
                ? L("Enter the device code to continue.", "请输入设备码以继续。")
                : L("Waiting for sign-in…", "等待登录…")
            NSWorkspace.shared.open(oauth.url)
            let timeout = TimeInterval(max(30, min(oauth.expiresIn ?? 300, 900)) + 10)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                guard activeOAuthOperationID == operationID else { return }
                let status = try await client.oauthStatus(state: oauth.state)
                let normalizedStatus = status.status.lowercased()
                if normalizedStatus == "ok" || normalizedStatus == "success" {
                    oauthStatusMessage = L("Account connected.", "账号已连接。")
                    authFiles = try await loadAuthPool(using: client)
                    availableModels = Self.normalizedModels((try? await client.availableModels()) ?? availableModels)
                    await refreshSyncStates(using: client, allowKeepUpdated: true)
                    await reconcileManagedDistributionIfNeeded()
                    oauthFlowState = .pluginSucceeded(plugin.displayName)
                    oauthSession = nil
                    oauthPlugin = nil
                    return
                }
                if normalizedStatus == "error" || normalizedStatus == "failed" {
                    throw CLIProxyGatewayError.invalidResponse(status.error ?? "OAuth failed")
                }
            }
            try? await client.cancelOAuth(state: oauth.state)
            throw CLIProxyGatewayError.network("OAuth timed out")
        } catch is CancellationError {
            if let state = activeOAuthState { try? await client.cancelOAuth(state: state) }
            guard activeOAuthOperationID == operationID else { return }
            oauthFlowState = .cancelled(nil)
            oauthStatusMessage = L("Sign-in cancelled.", "登录已取消。")
            oauthSession = nil
        } catch {
            if let state = activeOAuthState { try? await client.cancelOAuth(state: state) }
            guard activeOAuthOperationID == operationID else { return }
            lastError = error.localizedDescription
            oauthStatusMessage = L("Sign-in failed.", "登录失败。")
            oauthFlowState = .pluginFailed(plugin.displayName, error.localizedDescription)
            oauthSession = nil
        }
    }

    func cancelOAuth() async {
        guard oauthFlowState.isActive else { return }
        let provider = oauthProvider
        let state = activeOAuthState
        activeOAuthOperationID = nil
        activeOAuthState = nil
        oauthProvider = nil
        oauthPlugin = nil
        oauthSession = nil
        oauthFlowState = .cancelled(provider)
        oauthStatusMessage = L("Sign-in cancelled.", "登录已取消。")
        isManagingAccounts = false
        guard let state, let client = managementClient() else { return }
        do {
            try await client.cancelOAuth(state: state)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func upsertManagedProvider(targets: Set<ProxyTarget>) async {
        guard runtime.state.isRunning,
              !isApplyingDistribution,
              let clientKey = runtime.clientAPIKey else { return }
        isApplyingDistribution = true
        defer { isApplyingDistribution = false }
        lastError = nil
        do {
            let models: [CLIProxyModel]
            if availableModels.isEmpty, let client = managementClient() {
                models = Self.normalizedModels(try await client.availableModels())
                availableModels = models
            } else { models = availableModels }
            let mapped = models.map { ProxyConfiguration.MappedModel(name: $0.id) }
            guard !mapped.isEmpty else {
                throw CLIProxyGatewayError.invalidResponse("CPA did not report any available models")
            }
            let existing = APIProviderStore.shared.provider(id: Self.managedProviderID)
            let provider = APIProvider(
                id: Self.managedProviderID,
                name: L("CPA Gateway", "CPA 网关"),
                baseURL: runtime.baseURL.appendingPathComponent("v1").absoluteString,
                apiKey: clientKey,
                format: .openAIResponses,
                models: mapped,
                defaultModel: existing?.defaultModel.nilIfBlank ?? mapped[0].name,
                createdAt: existing?.createdAt ?? Date(),
                lastUsedAt: existing?.lastUsedAt,
                sortOrder: existing?.sortOrder ?? Int.max
            )
            let saved = APIProviderStore.shared.upsert(provider)
            await APIProviderDistributor.shared.setDistribution(saved, targets: targets)
            refreshDistributionState()
        } catch {
            lastError = error.localizedDescription
            refreshDistributionState()
        }
    }

    static let managedProviderID = "aiusage.cliproxyapi.gateway"

    func refreshDistributionState() {
        managedProviderExists = APIProviderStore.shared.provider(id: Self.managedProviderID) != nil
        currentDistributionTargets = managedProviderExists
            ? APIProviderDistributor.shared.currentTargets(for: Self.managedProviderID)
            : []
    }

    private func loadAuthPool(using client: CLIProxyManagementClient) async throws -> [CLIProxyAuthFile] {
        async let filesTask = client.listAuthFiles()
        async let providersTask = client.listOpenAICompatibleProviders()
        var files = try await filesTask
        let providers = (try? await providersTask) ?? openAICompatibleProviders
        openAICompatibleProviders = providers

        for provider in providers {
            let existing = files.first { file in
                file.isOpenAICompatibleRuntime
                    && file.displayLabel.caseInsensitiveCompare(provider.name) == .orderedSame
            }
            let models = Self.models(for: provider)
            if let existing {
                if authFileModels[existing.name] == nil { authFileModels[existing.name] = models }
            } else {
                let synthetic = CLIProxyAuthFile(openAICompatible: provider)
                files.append(synthetic)
                authFileModels[synthetic.name] = models
            }
        }
        return files.sorted {
            let providerOrder = $0.displayProvider.localizedStandardCompare($1.displayProvider)
            if providerOrder != .orderedSame { return providerOrder == .orderedAscending }
            return $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending
        }
    }

    private func loadProviderPluginState(
        using client: CLIProxyManagementClient,
        includeStore: Bool
    ) async throws {
        let installed = try await client.listPlugins()
        pluginsEnabled = installed.enabled
        providerPlugins = installed.plugins
            .filter(\.supportsOAuth)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if includeStore {
            let store = try await client.listPluginStore()
            pluginsEnabled = store.enabled
            providerPluginStore = store.plugins
                .filter(\.isProvider)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func openAICompatibleProvider(named name: String) -> CLIProxyOpenAICompatibleProvider? {
        openAICompatibleProviders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func models(for provider: CLIProxyOpenAICompatibleProvider) -> [CLIProxyModel] {
        normalizedModels(provider.models.map { model in
            let id = model.alias.nilIfBlank ?? model.name
            return CLIProxyModel(
                id: id,
                displayName: id == model.name ? nil : model.name,
                type: "openai-compatible",
                ownedBy: provider.name
            )
        })
    }

    private func reconcileManagedDistributionIfNeeded() async {
        refreshDistributionState()
        guard managedProviderExists else { return }
        let targets = currentDistributionTargets
        await upsertManagedProvider(targets: targets)
    }

    private func refreshModelCatalogAndDistribution(using client: CLIProxyManagementClient) async {
        await refreshModelCatalog(using: client)
        await reconcileManagedDistributionIfNeeded()
    }

    /// All account actions and the overview poll share one in-flight catalog
    /// request. The unstructured task is intentionally owned by the manager so
    /// leaving the Overview page cannot cancel the request and publish a false
    /// network error while another account operation is awaiting the same data.
    private func refreshModelCatalog(using client: CLIProxyManagementClient) async {
        let runtimePID: Int32?
        if case .running(let pid) = runtime.state { runtimePID = pid }
        else { runtimePID = nil }

        if let active = modelCatalogRefreshTask {
            if modelCatalogRuntimePID == runtimePID {
                await active.value
                return
            }
            // A restarted CPA is a different catalog source even when it uses
            // the same loopback URL and keys. Do not reuse the old process's
            // in-flight response.
            active.cancel()
        }

        let refreshID = UUID()
        modelCatalogRefreshID = refreshID
        modelCatalogRuntimePID = runtimePID
        isRefreshingModels = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.modelCatalogRefreshID == refreshID {
                    self.modelCatalogRefreshTask = nil
                    self.modelCatalogRefreshID = nil
                    self.modelCatalogRuntimePID = nil
                    self.isRefreshingModels = false
                }
            }
            do {
                self.applyModelCatalog(try await client.modelCatalog())
                self.modelCatalogError = nil
                self.modelCatalogUpdatedAt = Date()
            } catch is CancellationError {
                // Cancellation is a lifecycle event, not a catalog failure.
            } catch {
                // Keep the last successful catalog instead of presenting a
                // transient loopback failure as a real zero-model result.
                if !Task.isCancelled, self.runtime.state.isRunning {
                    self.modelCatalogError = error.localizedDescription
                }
            }
        }
        modelCatalogRefreshTask = task
        await task.value
    }

    private func applyModelCatalog(_ snapshot: CLIProxyModelCatalogSnapshot) {
        availableModels = Self.normalizedModels(snapshot.openAIModels)

        var protocolsByID: [String: Set<CLIProxyModelProtocol>] = [:]
        for entry in snapshot.entries {
            protocolsByID[entry.model.id.lowercased(), default: []].formUnion(entry.protocols)
        }
        modelCatalog = Self.normalizedModels(snapshot.entries.map(\.model)).map { model in
            CLIProxyModelCatalogEntry(
                model: model,
                protocols: protocolsByID[model.id.lowercased(), default: []]
            )
        }
        unavailableModelProtocols = snapshot.unavailableProtocols
    }

    private static func normalizedModels(_ models: [CLIProxyModel]) -> [CLIProxyModel] {
        var seen = Set<String>()
        return models
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func reloadInstalledVersions() async {
        do {
            currentVersion = try await binaryStore.currentVersion()
            installedVersions = try await binaryStore.installedVersions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func activateWithRuntimeRollback(version: String) async throws {
        let wasRunning = runtime.state.isRunning
        let previous = try await binaryStore.currentVersion()
        if wasRunning { await runtime.stop() }
        do {
            try runtime.stabilizeConfigurationBeforeActivation()
            _ = try await binaryStore.activate(version: version)
            if wasRunning {
                await runtime.start()
                if case .failed(let reason) = runtime.state {
                    throw CLIProxyGatewayError.process(reason)
                }
                await refreshAccounts()
            }
        } catch {
            if let previous, previous != version {
                _ = try? await binaryStore.activate(version: previous)
            }
            if wasRunning { await runtime.start() }
            throw error
        }
    }

    private func managementClient() -> CLIProxyManagementClient? {
        guard let managementKey = runtime.managementKey,
              let clientKey = runtime.clientAPIKey else {
            lastError = CLIProxyGatewayError.secretStorage("gateway keys are unavailable").localizedDescription
            return nil
        }
        return CLIProxyManagementClient(
            baseURL: runtime.baseURL,
            managementKey: managementKey,
            clientAPIKey: clientKey
        )
    }

    private struct SyncEvaluation {
        let state: CLIProxyAccountSyncState
        let sourceFingerprint: String
        let copiedFingerprint: String
        let copiedData: Data
        let authFileName: String
        let canAdoptExistingCopy: Bool
    }

    private func refreshSyncStates(
        using client: CLIProxyManagementClient,
        allowKeepUpdated: Bool
    ) async {
        var states: [String: CLIProxyAccountSyncState] = [:]
        var manifestChanged = false

        for candidate in syncCandidates {
            guard case .compatible = candidate.compatibility,
                  let credential = AccountCredentialStore.shared.loadCredential(
                    providerId: candidate.providerId,
                    credentialId: candidate.credentialId
                  ) else {
                states[candidate.id] = .notSynced
                continue
            }
            do {
                let evaluation = try await evaluateSyncState(
                    candidate: candidate,
                    credential: credential,
                    client: client
                )
                states[candidate.id] = evaluation.state

                if evaluation.canAdoptExistingCopy {
                    let adopted = CLIProxyAccountSyncRecord(
                        providerId: candidate.providerId,
                        credentialId: candidate.credentialId,
                        authFileName: evaluation.authFileName,
                        sourceFingerprint: evaluation.sourceFingerprint,
                        lastCopiedFingerprint: evaluation.copiedFingerprint,
                        lastSyncedAt: Date(),
                        mode: .manualCopy
                    )
                    upsertSyncRecord(adopted)
                    manifestChanged = true
                }

                guard allowKeepUpdated,
                      evaluation.state == .sourceChanged,
                      let record = syncRecord(for: candidate),
                      record.mode == .keepUpdated else { continue }

                try await client.uploadAuthFile(data: evaluation.copiedData, name: record.authFileName)
                let updated = CLIProxyAccountSyncRecord(
                    providerId: record.providerId,
                    credentialId: record.credentialId,
                    authFileName: record.authFileName,
                    sourceFingerprint: evaluation.sourceFingerprint,
                    lastCopiedFingerprint: evaluation.copiedFingerprint,
                    lastSyncedAt: Date(),
                    mode: .keepUpdated
                )
                upsertSyncRecord(updated)
                authFileModels[record.authFileName] = nil
                authFileModelErrors[record.authFileName] = nil
                states[candidate.id] = .current
                manifestChanged = true
            } catch {
                states[candidate.id] = accountSyncStates[candidate.id] ?? .notSynced
                if lastError == nil { lastError = error.localizedDescription }
            }
        }

        accountSyncStates = states
        if manifestChanged {
            do { try saveSyncManifest() }
            catch { lastError = error.localizedDescription }
        }
    }

    private func evaluateSyncState(
        candidate: CLIProxyAccountSyncCandidate,
        credential: AccountCredential,
        client: CLIProxyManagementClient
    ) async throws -> SyncEvaluation {
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: credential.credential), options: .mappedIfSafe)
        let sourceFingerprint = try CLIProxyJSONFingerprint.hash(sourceData, requireObject: true)
        let copiedData = try convertedAuthFile(credential, sourceData: sourceData)
        let copiedFingerprint = try CLIProxyJSONFingerprint.hash(copiedData, requireObject: true)
        let record = syncRecord(for: candidate)
        let name = record?.authFileName ?? authFileName(for: candidate)

        let cpaData: Data?
        do {
            cpaData = try await client.downloadAuthFile(name: name)
        } catch CLIProxyGatewayError.managementAPI(let status, _) where status == 404 {
            cpaData = nil
        }

        guard let cpaData else {
            return SyncEvaluation(
                state: record == nil ? .notSynced : .missing,
                sourceFingerprint: sourceFingerprint,
                copiedFingerprint: copiedFingerprint,
                copiedData: copiedData,
                authFileName: name,
                canAdoptExistingCopy: false
            )
        }

        let cpaFingerprint = try CLIProxyJSONFingerprint.hash(cpaData, requireObject: true)
        guard let record else {
            let matches = cpaFingerprint == copiedFingerprint
            return SyncEvaluation(
                state: matches ? .current : .conflict,
                sourceFingerprint: sourceFingerprint,
                copiedFingerprint: copiedFingerprint,
                copiedData: copiedData,
                authFileName: name,
                canAdoptExistingCopy: matches
            )
        }

        let sourceChanged = sourceFingerprint != record.sourceFingerprint
        let cpaChanged = cpaFingerprint != record.lastCopiedFingerprint
        let state: CLIProxyAccountSyncState
        switch (sourceChanged, cpaChanged) {
        case (false, false): state = .current
        case (true, false): state = .sourceChanged
        case (false, true): state = .cpaChanged
        case (true, true): state = .conflict
        }
        return SyncEvaluation(
            state: state,
            sourceFingerprint: sourceFingerprint,
            copiedFingerprint: copiedFingerprint,
            copiedData: copiedData,
            authFileName: name,
            canAdoptExistingCopy: false
        )
    }

    private func syncRecord(for candidate: CLIProxyAccountSyncCandidate) -> CLIProxyAccountSyncRecord? {
        syncManifest.records.first {
            $0.providerId == candidate.providerId && $0.credentialId == candidate.credentialId
        }
    }

    private func upsertSyncRecord(_ record: CLIProxyAccountSyncRecord) {
        syncManifest.records.removeAll { $0.id == record.id }
        syncManifest.records.append(record)
        syncManifest.records.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        syncRecords = syncManifest.records
    }

    @discardableResult
    private func removeSyncRecords(authFileName: String) -> [String] {
        let removed = syncManifest.records
            .filter { $0.authFileName.caseInsensitiveCompare(authFileName) == .orderedSame }
            .map(\.id)
        syncManifest.records.removeAll { $0.authFileName.caseInsensitiveCompare(authFileName) == .orderedSame }
        syncRecords = syncManifest.records
        return removed
    }

    private func saveSyncManifest() throws {
        syncManifest.schemaVersion = 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(syncManifest)
        try paths.prepare()
        try data.write(to: paths.syncManifestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.syncManifestURL.path
        )
        syncRecords = syncManifest.records
    }

    private static func loadSyncManifest(from url: URL) throws -> CLIProxyAccountSyncManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 1_048_576 {
            throw CLIProxyGatewayError.fileSystem("account sync manifest is unexpectedly large")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(CLIProxyAccountSyncManifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1 else {
            throw CLIProxyGatewayError.fileSystem("unsupported account sync manifest version")
        }
        var seen = Set<String>()
        manifest.records = manifest.records.filter { record in
            guard seen.insert(record.id).inserted,
                  isValidFingerprint(record.sourceFingerprint),
                  isValidFingerprint(record.lastCopiedFingerprint),
                  isSafeAuthFileName(record.authFileName) else { return false }
            return true
        }
        return manifest
    }

    private static func readImportableAuthFile(at url: URL) throws -> Data {
        guard url.pathExtension.caseInsensitiveCompare("json") == .orderedSame else {
            throw CLIProxyGatewayError.invalidAuthFile("only .json files can be imported")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CLIProxyGatewayError.invalidAuthFile("the selected item must be a regular file")
        }
        guard let size = values.fileSize else {
            throw CLIProxyGatewayError.invalidAuthFile("the selected file size could not be verified")
        }
        guard size <= maxAuthFileImportBytes else {
            throw CLIProxyGatewayError.authFileTooLarge(maxBytes: maxAuthFileImportBytes)
        }
        guard size > 0 else {
            throw CLIProxyGatewayError.invalidAuthFile("the selected file is empty")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxAuthFileImportBytes else {
            throw CLIProxyGatewayError.authFileTooLarge(maxBytes: maxAuthFileImportBytes)
        }
        do {
            return try CLIProxyJSONFingerprint.canonicalData(data, requireObject: true)
        } catch {
            throw CLIProxyGatewayError.invalidAuthFile(error.localizedDescription)
        }
    }

    private static func uniqueAuthFileName(preferred: String, existing: Set<String>) -> String {
        var clean = URL(fileURLWithPath: preferred).lastPathComponent
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        clean = String(clean.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? Character("-") : Character($0)
        })
        if clean.isEmpty { clean = "auth.json" }
        if URL(fileURLWithPath: clean).pathExtension.caseInsensitiveCompare("json") != .orderedSame {
            clean += ".json"
        }
        var trimmedStem = String(clean.dropLast(5))
        while trimmedStem.utf8.count > 220 { trimmedStem.removeLast() }
        if trimmedStem.isEmpty { trimmedStem = "auth" }
        clean = trimmedStem + ".json"
        if !existing.contains(clean.lowercased()) { return clean }

        let stem = String(clean.dropLast(5))
        for suffix in 2...9_999 {
            let candidate = "\(stem)-\(suffix).json"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return "auth-\(UUID().uuidString).json"
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func isSafeAuthFileName(_ value: String) -> Bool {
        !value.isEmpty && value.lowercased().hasSuffix(".json") &&
            value == URL(fileURLWithPath: value).lastPathComponent && !value.contains("\\")
    }

    private func convertedAuthFile(_ credential: AccountCredential, sourceData: Data) throws -> Data {
        guard credential.authMethod == .authFile else {
            throw CLIProxyGatewayError.unsupportedAccount("credential is not an auth file")
        }
        return try CLIProxyCredentialAdapter.convert(
            providerId: credential.providerId,
            credentialId: credential.id,
            accountLabel: credential.accountLabel,
            metadata: credential.metadata,
            sourceData: sourceData
        )
    }
}
