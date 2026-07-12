import AppKit
import Combine
import Foundation
import QuotaBackend

nonisolated private struct CLIProxySyncCandidateSource: Sendable, Equatable {
    let providerID: String
    let label: String
    let credentialID: String
}

nonisolated private enum CLIProxySyncCandidateEvaluation: Sendable {
    case compatible(identity: CLIProxyAccountIdentity, modifiedAt: Date?)
    case requiresAuthFile
    case unsupportedProvider
    case missingFile
    case conversionFailed(String)
}

nonisolated private struct CLIProxySyncCandidateResult: Sendable {
    let source: CLIProxySyncCandidateSource
    let evaluation: CLIProxySyncCandidateEvaluation
}

nonisolated private struct CLIProxyManagedAuthPayload: Sendable {
    let file: CLIProxyAuthFile
    let data: Data?
    let identity: CLIProxyAccountIdentity
    let destructiveMergeFingerprint: String?
}

nonisolated private struct CLIProxyManagedAuthCacheEntry: Sendable {
    let size: Int64?
    let lastRefresh: Date?
    let updatedAt: Date?
    let modTime: Date?
    let createdAt: Date?
    let identity: CLIProxyAccountIdentity
    let destructiveMergeFingerprint: String?

    func matches(_ file: CLIProxyAuthFile) -> Bool {
        guard lastRefresh != nil || updatedAt != nil || modTime != nil || createdAt != nil else {
            return false
        }
        return size == file.size
            && lastRefresh == file.lastRefresh
            && updatedAt == file.updatedAt
            && modTime == file.modTime
            && createdAt == file.createdAt
    }
}

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
    @Published private(set) var syncCandidates: [CLIProxyAccountSyncCandidate] = []
    @Published private(set) var authFileIdentities: [String: CLIProxyAccountIdentity] = [:]
    @Published private(set) var authDeduplicationConflictCount = 0
    @Published private(set) var syncManifestError: String?
    @Published private(set) var lastImportedAuthFileName: String?

    private let paths: CLIProxyPaths
    private let releaseClient: CLIProxyReleaseClient
    private let downloader: CLIProxyAssetDownloader
    private let binaryStore: CLIProxyBinaryStore
    let runtime: CLIProxyRuntimeController
    private var accountRegistryCancellable: AnyCancellable?
    private var syncCandidateRefreshTask: Task<Void, Never>?
    private var lastSyncCandidateSources: [CLIProxySyncCandidateSource] = []
    private var syncCandidateGeneration = 0
    private var syncManifest = CLIProxyAccountSyncManifest.empty
    private var syncManifestHealthy: Bool { syncManifestError == nil }
    private var managedAuthCache: [String: CLIProxyManagedAuthCacheEntry] = [:]
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
            syncManifestError = error.localizedDescription
            lastError = error.localizedDescription
        }
        refreshDistributionState()
        accountRegistryCancellable = AccountStore.shared.$accountRegistry
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] accounts in
                self?.scheduleSyncCandidateRefresh(
                    sources: Self.syncCandidateSources(from: accounts)
                )
            }
    }

    func refresh(checkRemote: Bool = true) async {
        await reloadInstalledVersions()
        refreshDistributionState()
        await refreshSyncCandidates()
        if runtime.state.isRunning {
            await refreshAccounts(refreshCandidates: false)
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

    func syncCandidate(providerId: String, label: String, credentialId: String) -> CLIProxyAccountSyncCandidate? {
        syncCandidates.first {
            $0.providerId.caseInsensitiveCompare(providerId) == .orderedSame &&
            $0.credentialId.caseInsensitiveCompare(credentialId) == .orderedSame
        }
    }

    func refreshAccounts(refreshCandidates: Bool = true) async {
        if refreshCandidates { await refreshSyncCandidates() }
        guard runtime.state.isRunning, !isManagingAccounts, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        defer { isManagingAccounts = false }
        do {
            retrySyncManifestLoadIfNeeded()
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

    func refreshSyncCandidates() async {
        let sources = Self.syncCandidateSources(from: AccountStore.shared.accountRegistry)
        lastSyncCandidateSources = sources
        syncCandidateRefreshTask?.cancel()
        syncCandidateRefreshTask = nil
        await rebuildSyncCandidates(from: sources)
    }

    private func scheduleSyncCandidateRefresh(sources: [CLIProxySyncCandidateSource]) {
        guard sources != lastSyncCandidateSources else { return }
        lastSyncCandidateSources = sources
        syncCandidateRefreshTask?.cancel()
        syncCandidateRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rebuildSyncCandidates(from: sources)
        }
    }

    private func rebuildSyncCandidates(from sources: [CLIProxySyncCandidateSource]) async {
        syncCandidateGeneration &+= 1
        let generation = syncCandidateGeneration
        let results = await withTaskGroup(
            of: [CLIProxySyncCandidateResult].self,
            returning: [CLIProxySyncCandidateResult].self
        ) { group in
            group.addTask(priority: .userInitiated) {
                var results: [CLIProxySyncCandidateResult] = []
                results.reserveCapacity(sources.count)
                for source in sources {
                    guard !Task.isCancelled else { break }
                    if let result = Self.evaluateSyncCandidate(source) {
                        results.append(result)
                    }
                }
                return results
            }
            return await group.next() ?? []
        }
        guard !Task.isCancelled, generation == syncCandidateGeneration else { return }

        let evaluatedCandidates: [(candidate: CLIProxyAccountSyncCandidate, modifiedAt: Date?)] = results.map { result in
            let compatibility: CLIProxyAccountSyncCandidate.Compatibility
            let accountIdentity: CLIProxyAccountIdentity?
            let modifiedAt: Date?
            switch result.evaluation {
            case .compatible(let identity, let sourceModifiedAt):
                compatibility = .compatible
                accountIdentity = identity
                modifiedAt = sourceModifiedAt
            case .requiresAuthFile:
                compatibility = .unsupported(L(
                    "CPA requires an OAuth auth file for this provider.",
                    "CPA 需要该服务商的 OAuth 凭据文件。"
                ))
                accountIdentity = nil
                modifiedAt = nil
            case .unsupportedProvider:
                compatibility = .unsupported(L(
                    "No verified conversion adapter is available yet.",
                    "目前没有经过验证的格式转换适配器。"
                ))
                accountIdentity = nil
                modifiedAt = nil
            case .missingFile:
                compatibility = .unsupported(L(
                    "The managed credential file is unavailable.",
                    "托管凭据文件当前不可用。"
                ))
                accountIdentity = nil
                modifiedAt = nil
            case .conversionFailed(let message):
                compatibility = .unsupported(message)
                accountIdentity = nil
                modifiedAt = nil
            }
            return (
                CLIProxyAccountSyncCandidate(
                    id: "\(result.source.providerID):\(result.source.credentialID)",
                    providerId: result.source.providerID,
                    label: result.source.label,
                    credentialId: result.source.credentialID,
                    accountIdentity: accountIdentity,
                    compatibility: compatibility
                ),
                modifiedAt
            )
        }

        // Multiple historical credential IDs can point at the same native account.
        // Collapse only strong provider-native identities; weak/email-only identities
        // stay separate so Codex workspaces are never merged by display label.
        var preferredByIdentity: [String: (candidate: CLIProxyAccountSyncCandidate, modifiedAt: Date?)] = [:]
        for evaluated in evaluatedCandidates {
            let identityKey: String
            if let identity = evaluated.candidate.accountIdentity,
               identity.canAutomaticallyMerge {
                identityKey = identity.key
            } else {
                identityKey = evaluated.candidate.id.lowercased()
            }
            guard let existing = preferredByIdentity[identityKey] else {
                preferredByIdentity[identityKey] = evaluated
                continue
            }
            let existingDate = existing.modifiedAt ?? .distantPast
            let candidateDate = evaluated.modifiedAt ?? .distantPast
            if candidateDate > existingDate ||
                (candidateDate == existingDate && evaluated.candidate.credentialId < existing.candidate.credentialId) {
                preferredByIdentity[identityKey] = evaluated
            }
        }

        let candidates = preferredByIdentity.values.map(\.candidate).sorted {
            let providerOrder = $0.providerId.localizedStandardCompare($1.providerId)
            if providerOrder != .orderedSame { return providerOrder == .orderedAscending }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        if candidates != syncCandidates {
            syncCandidates = candidates
        }
    }

    nonisolated private static func syncCandidateSources(
        from accounts: [StoredProviderAccount]
    ) -> [CLIProxySyncCandidateSource] {
        var seen = Set<String>()
        return accounts.compactMap { account in
            guard let credentialID = account.credentialId else { return nil }
            let identity = "\(account.providerId.lowercased()):\(credentialID.lowercased())"
            guard seen.insert(identity).inserted else { return nil }
            return CLIProxySyncCandidateSource(
                providerID: account.providerId,
                label: account.preferredLabel,
                credentialID: credentialID
            )
        }
    }

    nonisolated private static func evaluateSyncCandidate(
        _ source: CLIProxySyncCandidateSource
    ) -> CLIProxySyncCandidateResult? {
        guard let credential = AccountCredentialStore.shared.loadCredential(
            providerId: source.providerID,
            credentialId: source.credentialID
        ) else { return nil }

        let evaluation: CLIProxySyncCandidateEvaluation
        if credential.authMethod != .authFile {
            evaluation = .requiresAuthFile
        } else if !CLIProxyCredentialAdapter.supportedProviderIDs.contains(source.providerID) {
            evaluation = .unsupportedProvider
        } else if !FileManager.default.fileExists(atPath: credential.credential) {
            evaluation = .missingFile
        } else {
            do {
                let sourceData = try Data(
                    contentsOf: URL(fileURLWithPath: credential.credential),
                    options: .mappedIfSafe
                )
                let copiedData = try CLIProxyCredentialAdapter.convert(
                    providerId: credential.providerId,
                    credentialId: credential.id,
                    accountLabel: credential.accountLabel,
                    metadata: credential.metadata,
                    sourceData: sourceData
                )
                let identity = try CLIProxyAccountIdentity.parse(
                    data: copiedData,
                    providerHint: source.providerID
                )
                let modifiedAt = try? URL(fileURLWithPath: credential.credential)
                    .resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                evaluation = .compatible(identity: identity, modifiedAt: modifiedAt)
            } catch {
                evaluation = .conversionFailed(error.localizedDescription)
            }
        }
        return CLIProxySyncCandidateResult(source: source, evaluation: evaluation)
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
        guard syncManifestHealthy,
              !isManagingAccounts,
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
                accountIdentity: managedIdentityKey(for: candidate),
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
        guard syncManifestHealthy else { return }
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
        if let identityKey = managedIdentityKey(for: candidate),
           let digest = identityKey.split(separator: ":").last,
           !digest.isEmpty {
            return "aiusage-\(candidate.providerId)-\(digest.prefix(24)).json"
        }
        let safeID = candidate.credentialId
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .prefix(24)
        return "aiusage-\(candidate.providerId)-\(String(safeID)).json"
    }

    func accountIdentity(for file: CLIProxyAuthFile) -> CLIProxyAccountIdentity? {
        authFileIdentities[file.name.lowercased()]
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
        files = await reconcileManagedAuthCopies(files, using: client)
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

    /// Reconciles only files that AIUsage can prove it created. Provider-native
    /// identity decides which files are duplicates; a second fingerprint gate
    /// requires the same refresh-token lineage and persistent CPA settings before
    /// any destructive action is planned.
    private func reconcileManagedAuthCopies(
        _ files: [CLIProxyAuthFile],
        using client: CLIProxyManagementClient
    ) async -> [CLIProxyAuthFile] {
        let eligibleFiles = files.filter {
            !$0.runtimeOnly && $0.name.lowercased().hasPrefix("aiusage-")
        }
        let eligibleSources = eligibleFiles.map { file in
            let cached = managedAuthCache[file.name.lowercased()].flatMap { entry in
                entry.matches(file) ? entry : nil
            }
            return (file: file, providerHint: file.gatewayProviderID, cached: cached)
        }
        let payloads = await withTaskGroup(
            of: CLIProxyManagedAuthPayload?.self,
            returning: [CLIProxyManagedAuthPayload].self
        ) { group in
            for source in eligibleSources {
                group.addTask {
                    do {
                        let file = source.file
                        if let cached = source.cached {
                            return CLIProxyManagedAuthPayload(
                                file: file,
                                data: nil,
                                identity: cached.identity,
                                destructiveMergeFingerprint: cached.destructiveMergeFingerprint
                            )
                        }
                        let data = try await client.downloadAuthFile(name: file.name)
                        let identity = try CLIProxyAccountIdentity.parse(
                            data: data,
                            providerHint: source.providerHint
                        )
                        let destructiveFingerprint = try CLIProxyManagedAuthSafety
                            .destructiveMergeFingerprint(for: data)
                        return CLIProxyManagedAuthPayload(
                            file: file,
                            data: data,
                            identity: identity,
                            destructiveMergeFingerprint: destructiveFingerprint
                        )
                    } catch {
                        return nil
                    }
                }
            }
            var results: [CLIProxyManagedAuthPayload] = []
            for await payload in group {
                if let payload { results.append(payload) }
            }
            return results.sorted {
                $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending
            }
        }

        var identityByName: [String: CLIProxyAccountIdentity] = [:]
        for payload in payloads {
            let name = payload.file.name.lowercased()
            identityByName[name] = payload.identity
            if payload.file.lastRefresh != nil
                || payload.file.updatedAt != nil
                || payload.file.modTime != nil
                || payload.file.createdAt != nil {
                managedAuthCache[name] = CLIProxyManagedAuthCacheEntry(
                    size: payload.file.size,
                    lastRefresh: payload.file.lastRefresh,
                    updatedAt: payload.file.updatedAt,
                    modTime: payload.file.modTime,
                    createdAt: payload.file.createdAt,
                    identity: payload.identity,
                    destructiveMergeFingerprint: payload.destructiveMergeFingerprint
                )
            } else {
                managedAuthCache[name] = nil
            }
        }
        let eligibleNames = Set(eligibleFiles.map { $0.name.lowercased() })
        managedAuthCache = managedAuthCache.filter { eligibleNames.contains($0.key) }
        authFileIdentities = identityByName

        guard syncManifestHealthy else {
            authDeduplicationConflictCount = 0
            return files
        }

        let trackedNames = Set(syncManifest.records.map { $0.authFileName.lowercased() })
        let copies = payloads.map { payload in
            CLIProxyManagedAuthCopy(
                fileName: payload.file.name,
                identity: payload.identity,
                modifiedAt: managedAuthModifiedAt(payload.file),
                isManifestTracked: trackedNames.contains(payload.file.name.lowercased()),
                destructiveMergeFingerprint: payload.destructiveMergeFingerprint
            )
        }
        let plan = CLIProxyManagedAuthDeduplicator.plan(for: copies)
        var conflictingIdentityKeys = Set(plan.conflictingIdentityKeys)
        var deletedNames = Set<String>()
        var copiesByName: [String: CLIProxyManagedAuthCopy] = [:]
        for (payload, copy) in zip(payloads, copies) {
            copiesByName[payload.file.name.lowercased()] = copy
        }
        var identityByFileName: [String: String] = [:]
        for payload in payloads {
            identityByFileName[payload.file.name.lowercased()] = payload.identity.key
        }
        let duplicateIdentityKeys = Set(plan.duplicateFileNames.compactMap {
            identityByFileName[$0.lowercased()]
        })

        // Old v1 manifests were keyed only by the transient AIUsage credential
        // ID. Enrich true singleton records before source-vault remapping can
        // orphan that link and make the next sync create a second CPA file.
        let manifestBeforeEnrichment = syncManifest
        if enrichSingletonManagedSyncRecords(payloads: payloads, copies: copies) {
            do {
                try saveSyncManifest()
            } catch {
                syncManifest = manifestBeforeEnrichment
                syncRecords = manifestBeforeEnrichment.records
                syncManifestError = error.localizedDescription
                lastError = error.localizedDescription
                return files
            }
        }

        // Singleton accounts need no destructive reconciliation. Restrict the
        // serial revalidation path to identities that actually have duplicates.
        for identityKey in duplicateIdentityKeys.sorted() {
            let expectedFileNames = Set(payloads.compactMap { payload -> String? in
                guard payload.identity.key == identityKey,
                      let copy = copiesByName[payload.file.name.lowercased()],
                      copy.identity.canAutomaticallyMerge,
                      copy.hasStrongOwnership else { return nil }
                return payload.file.name
            })
            guard !expectedFileNames.isEmpty else { continue }

            let originalManifest = syncManifest
            do {
                let outcome = try await reconcileManagedAuthGroup(
                    identityKey: identityKey,
                    expectedFileNames: expectedFileNames,
                    using: client
                )
                let manifestChanged = migrateManagedSyncRecords(
                    payloads: outcome.payloads,
                    plan: outcome.plan
                )
                do {
                    if manifestChanged { try saveSyncManifest() }
                } catch {
                    let restoreFailures = await restoreManagedAuthFiles(
                        outcome.deletedData,
                        using: client
                    )
                    syncManifest = originalManifest
                    syncRecords = originalManifest.records
                    try? saveSyncManifest()
                    let suffix = restoreFailures.isEmpty
                        ? ""
                        : "; rollback failed for \(restoreFailures.joined(separator: ", "))"
                    throw CLIProxyGatewayError.fileSystem(
                        "account sync manifest could not be updated\(suffix): \(error.localizedDescription)"
                    )
                }
                for name in outcome.deletedData.keys {
                    deletedNames.insert(name.lowercased())
                    authFileModels[name] = nil
                    authFileModelErrors[name] = nil
                }
            } catch {
                syncManifest = originalManifest
                syncRecords = originalManifest.records
                conflictingIdentityKeys.insert(identityKey)
                if lastError == nil { lastError = error.localizedDescription }
            }
        }

        authDeduplicationConflictCount = conflictingIdentityKeys.count
        guard !deletedNames.isEmpty else { return files }
        authFileIdentities = authFileIdentities.filter { !deletedNames.contains($0.key) }
        managedAuthCache = managedAuthCache.filter { !deletedNames.contains($0.key) }
        return files.filter { !deletedNames.contains($0.name.lowercased()) }
    }

    /// Re-fetches every managed copy immediately before deletion. The rollback
    /// payload stays in memory only, so refresh credentials are never duplicated
    /// into another on-disk store.
    private func reconcileManagedAuthGroup(
        identityKey: String,
        expectedFileNames: Set<String>,
        using client: CLIProxyManagementClient
    ) async throws -> (
        payloads: [CLIProxyManagedAuthPayload],
        plan: CLIProxyManagedAuthDeduplicationPlan,
        deletedData: [String: Data]
    ) {
        let currentFiles = try await client.listAuthFiles()
        var currentByName: [String: CLIProxyAuthFile] = [:]
        for file in currentFiles {
            let name = file.name.lowercased()
            guard currentByName[name] == nil else {
                throw CLIProxyGatewayError.syncConflict(
                    "CPA returned auth file names that differ only by letter case"
                )
            }
            currentByName[name] = file
        }
        let trackedNames = Set(syncManifest.records.map { $0.authFileName.lowercased() })
        var payloads: [CLIProxyManagedAuthPayload] = []

        for expectedName in expectedFileNames.sorted(by: managedAuthFileNameOrder) {
            guard let file = currentByName[expectedName.lowercased()] else {
                throw CLIProxyGatewayError.syncConflict(
                    "managed CPA auth files changed while duplicate cleanup was running"
                )
            }
            payloads.append(try await managedAuthPayload(file, using: client))
        }

        let copies = payloads.map { payload in
            CLIProxyManagedAuthCopy(
                fileName: payload.file.name,
                identity: payload.identity,
                modifiedAt: managedAuthModifiedAt(payload.file),
                isManifestTracked: trackedNames.contains(payload.file.name.lowercased()),
                destructiveMergeFingerprint: payload.destructiveMergeFingerprint
            )
        }
        let plan = CLIProxyManagedAuthDeduplicator.plan(for: copies)
        guard !plan.conflictingIdentityKeys.contains(identityKey),
              let canonicalName = plan.canonicalFileByIdentity[identityKey] else {
            throw CLIProxyGatewayError.syncConflict(
                "managed CPA auth copies no longer have identical credentials and settings"
            )
        }
        let plannedNames = Set(plan.duplicateFileNames + [canonicalName])
        guard Set(expectedFileNames.map { $0.lowercased() })
            == Set(plannedNames.map { $0.lowercased() }) else {
            throw CLIProxyGatewayError.syncConflict(
                "managed CPA auth ownership changed while duplicate cleanup was running"
            )
        }

        var deletedData: [String: Data] = [:]
        for duplicateName in plan.duplicateFileNames {
            do {
                let canonicalData = try await client.downloadAuthFile(name: canonicalName)
                let duplicateData = try await client.downloadAuthFile(name: duplicateName)
                let canonicalIdentity = try CLIProxyAccountIdentity.parse(data: canonicalData)
                let duplicateIdentity = try CLIProxyAccountIdentity.parse(data: duplicateData)
                let canonicalFingerprint = try CLIProxyManagedAuthSafety
                    .destructiveMergeFingerprint(for: canonicalData)
                let duplicateFingerprint = try CLIProxyManagedAuthSafety
                    .destructiveMergeFingerprint(for: duplicateData)
                let canonicalCopy = CLIProxyManagedAuthCopy(
                    fileName: canonicalName,
                    identity: canonicalIdentity,
                    modifiedAt: nil,
                    isManifestTracked: trackedNames.contains(canonicalName.lowercased()),
                    destructiveMergeFingerprint: canonicalFingerprint
                )
                let duplicateCopy = CLIProxyManagedAuthCopy(
                    fileName: duplicateName,
                    identity: duplicateIdentity,
                    modifiedAt: nil,
                    isManifestTracked: trackedNames.contains(duplicateName.lowercased()),
                    destructiveMergeFingerprint: duplicateFingerprint
                )
                guard canonicalIdentity.canAutomaticallyMerge,
                      duplicateIdentity.canAutomaticallyMerge,
                      canonicalCopy.hasStrongOwnership,
                      duplicateCopy.hasStrongOwnership,
                      canonicalIdentity.key == identityKey,
                      duplicateIdentity.key == identityKey,
                      canonicalFingerprint != nil,
                      canonicalFingerprint == duplicateFingerprint else {
                    throw CLIProxyGatewayError.syncConflict(
                        "managed CPA auth copies changed before deletion"
                    )
                }
                deletedData[duplicateName] = duplicateData
                try await client.deleteAuthFile(name: duplicateName)
            } catch {
                let restoreFailures = await restoreManagedAuthFiles(deletedData, using: client)
                let suffix = restoreFailures.isEmpty
                    ? ""
                    : "; rollback failed for \(restoreFailures.joined(separator: ", "))"
                throw CLIProxyGatewayError.syncConflict(
                    "managed CPA duplicate cleanup stopped safely\(suffix): \(error.localizedDescription)"
                )
            }
        }

        do {
            let canonicalData = try await client.downloadAuthFile(name: canonicalName)
            let canonicalIdentity = try CLIProxyAccountIdentity.parse(data: canonicalData)
            let canonicalFingerprint = try CLIProxyManagedAuthSafety
                .destructiveMergeFingerprint(for: canonicalData)
            guard canonicalIdentity.canAutomaticallyMerge,
                  canonicalIdentity.key == identityKey,
                  canonicalFingerprint != nil,
                  canonicalFingerprint == payloads.first(where: {
                      $0.file.name.caseInsensitiveCompare(canonicalName) == .orderedSame
                  })?.destructiveMergeFingerprint else {
                throw CLIProxyGatewayError.syncConflict(
                    "the canonical CPA auth copy changed during duplicate cleanup"
                )
            }
        } catch {
            let restoreFailures = await restoreManagedAuthFiles(deletedData, using: client)
            let suffix = restoreFailures.isEmpty
                ? ""
                : "; rollback failed for \(restoreFailures.joined(separator: ", "))"
            throw CLIProxyGatewayError.syncConflict(
                "managed CPA duplicate cleanup was rolled back\(suffix): \(error.localizedDescription)"
            )
        }

        return (payloads, plan, deletedData)
    }

    private func managedAuthPayload(
        _ file: CLIProxyAuthFile,
        using client: CLIProxyManagementClient
    ) async throws -> CLIProxyManagedAuthPayload {
        let data = try await client.downloadAuthFile(name: file.name)
        return CLIProxyManagedAuthPayload(
            file: file,
            data: data,
            identity: try CLIProxyAccountIdentity.parse(
                data: data,
                providerHint: file.gatewayProviderID
            ),
            destructiveMergeFingerprint: try CLIProxyManagedAuthSafety
                .destructiveMergeFingerprint(for: data)
        )
    }

    private func restoreManagedAuthFiles(
        _ files: [String: Data],
        using client: CLIProxyManagementClient
    ) async -> [String] {
        var failures: [String] = []
        for name in files.keys.sorted(by: managedAuthFileNameOrder) {
            guard let data = files[name] else { continue }
            do {
                let currentData = try await client.downloadAuthFile(name: name)
                let expectedHash = try CLIProxyJSONFingerprint.hash(data, requireObject: true)
                let currentHash = try CLIProxyJSONFingerprint.hash(currentData, requireObject: true)
                if expectedHash != currentHash { failures.append(name) }
            } catch CLIProxyGatewayError.managementAPI(let status, _) where status == 404 {
                do { try await client.uploadAuthFile(data: data, name: name) }
                catch { failures.append(name) }
            } catch {
                failures.append(name)
            }
        }
        return failures
    }

    private func managedAuthFileNameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        if left != right { return left < right }
        return lhs < rhs
    }

    private func managedAuthModifiedAt(_ file: CLIProxyAuthFile) -> Date? {
        file.lastRefresh ?? file.updatedAt ?? file.modTime ?? file.createdAt
    }

    /// Adds native identity to an existing v1 record only when exactly one CPA
    /// file carries that strong identity. This is metadata-only: no auth payload
    /// is uploaded, deleted, or rewritten.
    @discardableResult
    private func enrichSingletonManagedSyncRecords(
        payloads: [CLIProxyManagedAuthPayload],
        copies: [CLIProxyManagedAuthCopy]
    ) -> Bool {
        let payloadsByIdentity = Dictionary(grouping: payloads, by: { $0.identity.key })
        var copyByName: [String: CLIProxyManagedAuthCopy] = [:]
        for (payload, copy) in zip(payloads, copies) {
            copyByName[payload.file.name.lowercased()] = copy
        }
        var records = syncManifest.records

        for (identityKey, group) in payloadsByIdentity where group.count == 1 {
            guard let payload = group.first,
                  payload.identity.canAutomaticallyMerge,
                  let copy = copyByName[payload.file.name.lowercased()],
                  copy.hasStrongOwnership else { continue }

            let matchingRecords = records.filter {
                $0.providerId.caseInsensitiveCompare(payload.identity.providerID) == .orderedSame &&
                    $0.authFileName.caseInsensitiveCompare(payload.file.name) == .orderedSame
            }
            guard !matchingRecords.isEmpty else { continue }
            guard !records.contains(where: {
                $0.providerId.caseInsensitiveCompare(payload.identity.providerID) != .orderedSame &&
                    $0.authFileName.caseInsensitiveCompare(payload.file.name) == .orderedSame
            }),
            let baseRecord = matchingRecords.max(by: { $0.lastSyncedAt < $1.lastSyncedAt }) else {
                continue
            }
            let keepUpdated = matchingRecords.contains { $0.mode == .keepUpdated }
            let candidate = syncCandidates.first {
                managedIdentityKey(for: $0)?.caseInsensitiveCompare(identityKey) == .orderedSame
            }
            let matchingIDs = Set(matchingRecords.map { $0.id.lowercased() })
            guard !records.contains(where: { record in
                guard !matchingIDs.contains(record.id.lowercased()),
                      record.providerId.caseInsensitiveCompare(payload.identity.providerID) == .orderedSame else {
                    return false
                }
                if let candidate,
                   record.credentialId.caseInsensitiveCompare(candidate.credentialId) == .orderedSame {
                    return true
                }
                return record.accountIdentity?.caseInsensitiveCompare(identityKey) == .orderedSame
            }) else { continue }
            let replacement = CLIProxyAccountSyncRecord(
                providerId: candidate?.providerId ?? baseRecord.providerId,
                credentialId: candidate?.credentialId ?? baseRecord.credentialId,
                authFileName: payload.file.name,
                accountIdentity: identityKey,
                sourceFingerprint: baseRecord.sourceFingerprint,
                lastCopiedFingerprint: baseRecord.lastCopiedFingerprint,
                lastSyncedAt: baseRecord.lastSyncedAt,
                mode: keepUpdated ? .keepUpdated : baseRecord.mode
            )
            records.removeAll { matchingIDs.contains($0.id.lowercased()) }
            records.append(replacement)
        }

        records.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        guard records != syncManifest.records else { return false }
        syncManifest.records = records
        syncRecords = records
        return true
    }

    /// Adds the stable identity to existing v1 records and collapses records only
    /// for groups that passed the model-layer destructive gate. Conflicting groups
    /// remain byte-for-byte represented in the manifest for manual review.
    @discardableResult
    private func migrateManagedSyncRecords(
        payloads: [CLIProxyManagedAuthPayload],
        plan: CLIProxyManagedAuthDeduplicationPlan
    ) -> Bool {
        let conflictingKeys = Set(plan.conflictingIdentityKeys)
        let grouped = Dictionary(grouping: payloads) { $0.identity.key }
        var records = syncManifest.records

        for identityKey in plan.canonicalFileByIdentity.keys.sorted() {
            guard !conflictingKeys.contains(identityKey),
                  let canonicalName = plan.canonicalFileByIdentity[identityKey],
                  let group = grouped[identityKey],
                  let identity = group.first?.identity else { continue }

            let groupNames = Set(group.map { $0.file.name.lowercased() })
            let groupRecords = records.filter {
                groupNames.contains($0.authFileName.lowercased()) ||
                    ($0.providerId.caseInsensitiveCompare(identity.providerID) == .orderedSame &&
                     $0.accountIdentity?.caseInsensitiveCompare(identityKey) == .orderedSame)
            }
            let candidate = syncCandidates.first {
                managedIdentityKey(for: $0)?.caseInsensitiveCompare(identityKey) == .orderedSame
            }
            guard let canonicalPayload = group.first(where: {
                $0.file.name.caseInsensitiveCompare(canonicalName) == .orderedSame
            }),
            let canonicalData = canonicalPayload.data,
            let canonicalCopiedFingerprint = try? CLIProxyJSONFingerprint.hash(
                canonicalData,
                requireObject: true
            ) else { continue }
            guard let replacement = migratedSyncRecord(
                identityKey: identityKey,
                canonicalName: canonicalName,
                canonicalCopiedFingerprint: canonicalCopiedFingerprint,
                candidate: candidate,
                existingRecords: groupRecords
            ) else { continue }

            records.removeAll {
                groupNames.contains($0.authFileName.lowercased()) ||
                    ($0.providerId.caseInsensitiveCompare(identity.providerID) == .orderedSame &&
                     $0.accountIdentity?.caseInsensitiveCompare(identityKey) == .orderedSame)
            }
            records.append(replacement)
        }

        records.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        guard records != syncManifest.records else { return false }
        syncManifest.records = records
        syncRecords = records
        return true
    }

    private func migratedSyncRecord(
        identityKey: String,
        canonicalName: String,
        canonicalCopiedFingerprint: String,
        candidate: CLIProxyAccountSyncCandidate?,
        existingRecords: [CLIProxyAccountSyncRecord]
    ) -> CLIProxyAccountSyncRecord? {
        let canonicalRecord = existingRecords.first {
            $0.authFileName.caseInsensitiveCompare(canonicalName) == .orderedSame
        }
        let baseRecord = canonicalRecord ?? existingRecords.max { $0.lastSyncedAt < $1.lastSyncedAt }
        let keepUpdated = existingRecords.contains { $0.mode == .keepUpdated }

        if let baseRecord {
            return CLIProxyAccountSyncRecord(
                providerId: candidate?.providerId ?? baseRecord.providerId,
                credentialId: candidate?.credentialId ?? baseRecord.credentialId,
                authFileName: canonicalName,
                accountIdentity: identityKey,
                sourceFingerprint: baseRecord.sourceFingerprint,
                lastCopiedFingerprint: canonicalCopiedFingerprint,
                lastSyncedAt: baseRecord.lastSyncedAt,
                mode: keepUpdated ? .keepUpdated : baseRecord.mode
            )
        }

        guard let candidate,
              let credential = AccountCredentialStore.shared.loadCredential(
                  providerId: candidate.providerId,
                  credentialId: candidate.credentialId
              ),
              let sourceData = try? Data(
                  contentsOf: URL(fileURLWithPath: credential.credential),
                  options: .mappedIfSafe
              ),
              let sourceFingerprint = try? CLIProxyJSONFingerprint.hash(sourceData, requireObject: true)
        else { return nil }

        return CLIProxyAccountSyncRecord(
            providerId: candidate.providerId,
            credentialId: candidate.credentialId,
            authFileName: canonicalName,
            accountIdentity: identityKey,
            sourceFingerprint: sourceFingerprint,
            lastCopiedFingerprint: canonicalCopiedFingerprint,
            lastSyncedAt: Date(),
            mode: .manualCopy
        )
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
        // The client already reduced protocol aliases into canonical entries.
        // Keep each API format's route ID intact for the setup detail sheet.
        modelCatalog = snapshot.entries
        unavailableModelProtocols = snapshot.unavailableProtocols
    }

    private static func normalizedModels(_ models: [CLIProxyModel]) -> [CLIProxyModel] {
        var seen = Set<String>()
        return models
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter {
                seen.insert($0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
            }
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
        guard syncManifestHealthy else { return }
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
                        accountIdentity: managedIdentityKey(for: candidate),
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
                    credentialId: candidate.credentialId,
                    authFileName: record.authFileName,
                    accountIdentity: managedIdentityKey(for: candidate) ?? record.accountIdentity,
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

    private func managedIdentityKey(for candidate: CLIProxyAccountSyncCandidate) -> String? {
        guard let identity = candidate.accountIdentity,
              identity.canAutomaticallyMerge else { return nil }
        return identity.key
    }

    private func syncRecord(for candidate: CLIProxyAccountSyncCandidate) -> CLIProxyAccountSyncRecord? {
        if let identityKey = managedIdentityKey(for: candidate),
           let record = syncManifest.records.first(where: {
               $0.providerId.caseInsensitiveCompare(candidate.providerId) == .orderedSame &&
               $0.accountIdentity?.caseInsensitiveCompare(identityKey) == .orderedSame
           }) {
            return record
        }
        return syncManifest.records.first {
            $0.providerId.caseInsensitiveCompare(candidate.providerId) == .orderedSame &&
            $0.credentialId.caseInsensitiveCompare(candidate.credentialId) == .orderedSame
        }
    }

    private func upsertSyncRecord(_ record: CLIProxyAccountSyncRecord) {
        syncManifest.records.removeAll { existing in
            if existing.providerId.caseInsensitiveCompare(record.providerId) == .orderedSame,
               existing.credentialId.caseInsensitiveCompare(record.credentialId) == .orderedSame {
                return true
            }
            if existing.authFileName.caseInsensitiveCompare(record.authFileName) == .orderedSame {
                return true
            }
            if existing.providerId.caseInsensitiveCompare(record.providerId) == .orderedSame,
               let identity = record.accountIdentity,
               existing.accountIdentity?.caseInsensitiveCompare(identity) == .orderedSame {
                return true
            }
            return false
        }
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
        guard syncManifestHealthy else {
            throw CLIProxyGatewayError.fileSystem(
                "account sync manifest is unavailable; existing data was left unchanged"
            )
        }
        var manifest = syncManifest
        manifest.schemaVersion = 1
        manifest = try CLIProxyAccountSyncManifestValidator.validate(manifest)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try paths.prepare()
        try data.write(to: paths.syncManifestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.syncManifestURL.path
        )
        syncManifest = manifest
        syncRecords = manifest.records
    }

    /// A corrupt or temporarily unreadable manifest stays fail-closed, but a
    /// later refresh may recover after the user repairs or removes that file.
    private func retrySyncManifestLoadIfNeeded() {
        guard syncManifestError != nil else { return }
        do {
            try paths.prepare()
            let manifest = try Self.loadSyncManifest(from: paths.syncManifestURL)
            if FileManager.default.fileExists(atPath: paths.syncManifestURL.path) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: paths.syncManifestURL.path
                )
            }
            syncManifest = manifest
            syncRecords = manifest.records
            syncManifestError = nil
        } catch {
            syncManifestError = error.localizedDescription
        }
    }

    private static func loadSyncManifest(from url: URL) throws -> CLIProxyAccountSyncManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > 1_048_576 {
            throw CLIProxyGatewayError.fileSystem("account sync manifest is unexpectedly large")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            CLIProxyAccountSyncManifest.self,
            from: Data(contentsOf: url)
        )
        return try CLIProxyAccountSyncManifestValidator.validate(manifest)
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
