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
    @Published private(set) var isManagingAccounts = false
    @Published private(set) var oauthProvider: CLIProxyOAuthProvider?
    @Published private(set) var oauthStatusMessage: String?

    private let paths: CLIProxyPaths
    private let releaseClient: CLIProxyReleaseClient
    private let downloader: CLIProxyAssetDownloader
    private let binaryStore: CLIProxyBinaryStore
    let runtime: CLIProxyRuntimeController
    private var syncCandidateCache: [String: CLIProxyAccountSyncCandidate] = [:]

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
    }

    func refresh(checkRemote: Bool = true) async {
        await reloadInstalledVersions()
        if runtime.state.isRunning { await refreshAccounts() }
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
                _ = try convertedAuthFile(credential)
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
        guard runtime.state.isRunning, let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        defer { isManagingAccounts = false }
        do {
            async let files = client.listAuthFiles()
            async let models = client.availableModels()
            authFiles = try await files
            availableModels = Self.normalizedModels((try? await models) ?? [])
        } catch { lastError = error.localizedDescription }
    }

    func setAuthFile(_ file: CLIProxyAuthFile, disabled: Bool) async {
        guard let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        do {
            try await client.setDisabled(disabled, name: file.name)
            authFiles = try await client.listAuthFiles()
        } catch { lastError = error.localizedDescription }
        isManagingAccounts = false
    }

    func deleteAuthFile(_ file: CLIProxyAuthFile) async {
        guard let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        do {
            try await client.deleteAuthFile(name: file.name)
            authFiles = try await client.listAuthFiles()
        } catch { lastError = error.localizedDescription }
        isManagingAccounts = false
    }

    func syncAccount(_ candidate: CLIProxyAccountSyncCandidate) async {
        guard case .compatible = candidate.compatibility,
              let client = managementClient(),
              let credential = AccountCredentialStore.shared.loadCredential(
                providerId: candidate.providerId,
                credentialId: candidate.credentialId
              ) else { return }
        isManagingAccounts = true
        lastError = nil
        defer { isManagingAccounts = false }
        do {
            let data = try convertedAuthFile(credential)
            let name = authFileName(for: candidate)
            try await client.uploadAuthFile(data: data, name: name)
            authFiles = try await client.listAuthFiles()
        } catch { lastError = error.localizedDescription }
    }

    func authFileName(for candidate: CLIProxyAccountSyncCandidate) -> String {
        let safeID = candidate.credentialId
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .prefix(24)
        return "aiusage-\(candidate.providerId)-\(String(safeID)).json"
    }

    func isSynced(_ candidate: CLIProxyAccountSyncCandidate) -> Bool {
        authFiles.contains { $0.name == authFileName(for: candidate) }
    }

    func beginOAuth(_ provider: CLIProxyOAuthProvider) async {
        guard let client = managementClient() else { return }
        isManagingAccounts = true
        lastError = nil
        oauthProvider = provider
        oauthStatusMessage = L("Waiting for sign-in…", "等待登录…")
        do {
            let oauth = try await client.beginOAuth(provider)
            NSWorkspace.shared.open(oauth.url)
            let deadline = Date().addingTimeInterval(310)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                let status = try await client.oauthStatus(state: oauth.state)
                if status.status == "ok" {
                    oauthStatusMessage = L("Account connected.", "账号已连接。")
                    authFiles = try await client.listAuthFiles()
                    availableModels = Self.normalizedModels((try? await client.availableModels()) ?? availableModels)
                    oauthProvider = nil
                    isManagingAccounts = false
                    return
                }
                if status.status == "error" {
                    throw CLIProxyGatewayError.invalidResponse(status.error ?? "OAuth failed")
                }
            }
            try? await client.cancelOAuth(state: oauth.state)
            throw CLIProxyGatewayError.network("OAuth timed out")
        } catch {
            lastError = error.localizedDescription
            oauthStatusMessage = nil
            oauthProvider = nil
        }
        isManagingAccounts = false
    }

    func upsertManagedProvider(targets: Set<ProxyTarget>) async {
        guard runtime.state.isRunning, let clientKey = runtime.clientAPIKey else { return }
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
                name: L("CPA Subscription Gateway", "CPA 订阅网关"),
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
        } catch { lastError = error.localizedDescription }
    }

    static let managedProviderID = "aiusage.cliproxyapi.gateway"

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
            _ = try await binaryStore.activate(version: version)
            if wasRunning {
                await runtime.start()
                if case .failed(let reason) = runtime.state {
                    throw CLIProxyGatewayError.process(reason)
                }
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

    private func convertedAuthFile(_ credential: AccountCredential) throws -> Data {
        guard credential.authMethod == .authFile else {
            throw CLIProxyGatewayError.unsupportedAccount("credential is not an auth file")
        }
        let source = URL(fileURLWithPath: credential.credential)
        return try CLIProxyCredentialAdapter.convert(
            providerId: credential.providerId,
            credentialId: credential.id,
            accountLabel: credential.accountLabel,
            metadata: credential.metadata,
            sourceData: try Data(contentsOf: source)
        )
    }
}
