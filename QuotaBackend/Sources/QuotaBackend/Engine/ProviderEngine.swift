import Foundation
import os.log

private let engineLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderEngine")

// MARK: - Provider Engine
// Orchestrates concurrent fetching of all providers and normalization.
// Supports multi-account providers that return results for each account in parallel.

public actor ProviderEngine {
    static let timeoutSeconds: Double = 15

    public init() {}

    // MARK: - Fetch All

    public func fetchAll(ids: [String]? = nil) async -> DashboardSnapshot {
        let providers: [any ProviderFetcher]
        if let ids {
            providers = ProviderRegistry.providers(for: ids)
        } else {
            providers = ProviderRegistry.allProviders()
        }
        let generatedAt = SharedFormatters.iso8601String(from: Date())

        let results: [ProviderResult] = await withTaskGroup(of: [ProviderResult].self) { group in
            for provider in providers {
                group.addTask {
                    await self.fetchAllResults(for: provider)
                }
            }
            var collected: [ProviderResult] = []
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            // Restore original ordering: group by providerId, maintain order within groups
            let providerOrder = providers.map(\.id)
            return collected.sorted { lhs, rhs in
                let lhsIdx = providerOrder.firstIndex(of: lhs.providerId) ?? Int.max
                let rhsIdx = providerOrder.firstIndex(of: rhs.providerId) ?? Int.max
                if lhsIdx != rhsIdx { return lhsIdx < rhsIdx }
                return lhs.id < rhs.id
            }
        }

        let summaries = results.compactMap { $0.summary }
        let overview = UsageNormalizer.createDashboardOverview(summaries: summaries, generatedAt: generatedAt)

        return DashboardSnapshot(generatedAt: generatedAt, overview: overview, providers: results)
    }

    // MARK: - Fetch Single

    public func fetchSingle(id: String) async -> ProviderResult? {
        guard let provider = ProviderRegistry.provider(for: id) else { return nil }
        return await fetchOne(provider: provider)
    }

    // MARK: - Fetch Single Account (for multi-account providers)

    public func fetchMultiAccountProvider(id: String) async -> [ProviderResult]? {
        guard let provider = ProviderRegistry.provider(for: id) else { return nil }
        return await fetchAllResults(for: provider)
    }

    // MARK: - Fetch For Specific Credential

    public func fetchForCredential(providerId: String, credentialId: String) async -> ProviderResult? {
        guard let provider = ProviderRegistry.provider(for: providerId),
              let credentialProvider = provider as? any CredentialAcceptingProvider,
              let credential = AccountCredentialStore.shared.loadCredential(
                providerId: providerId,
                credentialId: credentialId
              ) else { return nil }
        return await fetchWithCredential(provider: provider, credentialProvider: credentialProvider, credential: credential)
    }

    // MARK: - Internal: Single Account Fetch

    private func fetchAllResults(for provider: any ProviderFetcher) async -> [ProviderResult] {
        let isMultiAccount = provider is MultiAccountProviderFetcher
        let hasCredentials: Bool
        if let credentialProvider = provider as? CredentialAcceptingProvider {
            let creds = AccountCredentialStore.shared.loadCredentials(for: provider.id)
            hasCredentials = creds.contains { credentialProvider.supportedAuthMethods.contains($0.authMethod) }
        } else {
            hasCredentials = false
        }

        if hasCredentials && !isMultiAccount {
            let results = await fetchCredentialBackedResults(for: provider)
            return results.isEmpty ? [await fetchOne(provider: provider)] : results
        }

        if hasCredentials && isMultiAccount {
            async let automaticResults = fetchAutomaticResults(for: provider)
            async let credentialResults = fetchCredentialBackedResults(for: provider)
            let resolvedCredentialResults = await credentialResults
            let successfulCredentialKeys = Set(
                resolvedCredentialResults
                    .filter(\.ok)
                    .map { identityKey(for: $0, providerId: provider.id) }
            )
            let filteredAutomaticResults = (await automaticResults).filter { result in
                !successfulCredentialKeys.contains(identityKey(for: result, providerId: provider.id))
            }
            let merged = mergeResults(
                automatic: filteredAutomaticResults,
                credentialBacked: resolvedCredentialResults,
                provider: provider
            )
            return merged.isEmpty ? [await fetchOne(provider: provider)] : merged
        }

        return await fetchAutomaticResults(for: provider)
    }

    private func fetchAutomaticResults(for provider: any ProviderFetcher) async -> [ProviderResult] {
        if let multiProvider = provider as? MultiAccountProviderFetcher {
            return await fetchMultiAccount(provider: multiProvider)
        }
        return [await fetchOne(provider: provider)]
    }

    private func fetchOne(provider: any ProviderFetcher) async -> ProviderResult {
        let start = Date()
        do {
            let usage = try await withTimeout(seconds: Self.timeoutSeconds) {
                try await provider.fetchUsage()
            }
            let elapsed = Date().timeIntervalSince(start)
            engineLog.debug("✓ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms")
            let autoId = "\(provider.id):auto:\(usage.usageAccountId ?? "default")"
            var summary = UsageNormalizer.normalize(provider: provider, usage: usage)
            summary.id = autoId
            return ProviderResult(id: autoId, providerId: provider.id, accountId: usage.usageAccountId, ok: true, usage: usage, summary: summary)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            let redactedError = SensitiveDataRedactor.redactedDescription(for: error)
            engineLog.warning("✗ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms - \(redactedError)")
            let autoId = "\(provider.id):auto:default"
            var summary = UsageNormalizer.errorSummary(provider: provider, error: error)
            summary.id = autoId
            return ProviderResult(id: autoId, providerId: provider.id, ok: false, summary: summary, error: redactedError)
        }
    }

    // MARK: - Internal: Multi-Account Fetch

    private func fetchCredentialBackedResults(for provider: any ProviderFetcher) async -> [ProviderResult] {
        guard let credentialProvider = provider as? CredentialAcceptingProvider else {
            return []
        }

        let credentials = AccountCredentialStore.shared
            .loadCredentials(for: provider.id)
            .filter { credentialProvider.supportedAuthMethods.contains($0.authMethod) }

        guard !credentials.isEmpty else { return [] }

        return await withTaskGroup(of: ProviderResult.self) { group in
            for credential in credentials {
                group.addTask {
                    await self.fetchWithCredential(provider: provider, credentialProvider: credentialProvider, credential: credential)
                }
            }

            var results: [ProviderResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func fetchWithCredential(
        provider: any ProviderFetcher,
        credentialProvider: any CredentialAcceptingProvider,
        credential: AccountCredential
    ) async -> ProviderResult {
        let label = credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let fallbackAccountId = resolveAccountIdFromCredential(credential) ?? label ?? credential.id
        let uniqueId = "\(provider.id):cred:\(credential.id)"

        do {
            let usage = try await performCredentialFetch(credentialProvider: credentialProvider, credential: credential, label: label, fallbackAccountId: fallbackAccountId)
            return buildCredentialSuccess(provider: provider, usage: usage, credential: credential, uniqueId: uniqueId, label: label)
        } catch {
            let redactedError = SensitiveDataRedactor.redactedDescription(for: error)
            engineLog.warning("\(provider.id) credential-backed fetch failed: \(redactedError)")
            if let refreshed = await refreshFromSourceAndRetry(
                provider: provider, credentialProvider: credentialProvider, credential: credential,
                uniqueId: uniqueId, label: label, fallbackAccountId: fallbackAccountId
            ) {
                return refreshed
            }

            var summary = UsageNormalizer.errorSummary(provider: provider, error: error)
            summary.id = uniqueId
            summary.providerId = provider.id
            summary.accountId = fallbackAccountId
            summary.accountLabel = label

            return ProviderResult(
                id: uniqueId,
                providerId: provider.id,
                accountId: fallbackAccountId,
                ok: false,
                summary: summary,
                error: redactedError
            )
        }
    }

    private func performCredentialFetch(
        credentialProvider: any CredentialAcceptingProvider,
        credential: AccountCredential,
        label: String?,
        fallbackAccountId: String
    ) async throws -> ProviderUsage {
        var usage = try await withTimeout(seconds: Self.timeoutSeconds) {
            try await credentialProvider.fetchUsage(with: credential)
        }
        if usage.accountEmail?.nilIfBlank == nil { usage.accountEmail = label }
        if usage.accountName?.nilIfBlank == nil { usage.accountName = label }
        if usage.usageAccountId?.nilIfBlank == nil { usage.usageAccountId = fallbackAccountId }
        usage.extra["credentialId"] = AnyCodable(credential.id)
        return usage
    }

    private func buildCredentialSuccess(
        provider: any ProviderFetcher,
        usage: ProviderUsage,
        credential: AccountCredential,
        uniqueId: String,
        label: String?
    ) -> ProviderResult {
        AccountCredentialStore.shared.updateLastUsed(credential)

        var summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        summary.id = uniqueId
        summary.providerId = provider.id
        summary.accountId = usage.usageAccountId
        if summary.accountLabel?.nilIfBlank == nil {
            summary.accountLabel = label
        }

        return ProviderResult(
            id: uniqueId,
            providerId: provider.id,
            accountId: usage.usageAccountId,
            ok: true,
            usage: usage,
            summary: summary
        )
    }

    private func refreshFromSourceAndRetry(
        provider: any ProviderFetcher,
        credentialProvider: any CredentialAcceptingProvider,
        credential: AccountCredential,
        uniqueId: String,
        label: String?,
        fallbackAccountId: String
    ) async -> ProviderResult? {
        guard credential.authMethod == .authFile else { return nil }
        guard provider.id != "codex", provider.id != "gemini", provider.id != "kiro" else { return nil }
        let sourcePath = credential.metadata["sourcePath"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sourcePath.isEmpty else { return nil }

        let sourceExpanded = NSString(string: sourcePath).expandingTildeInPath
        let credentialPath = NSString(string: credential.credential).expandingTildeInPath

        guard sourceExpanded != credentialPath,
              FileManager.default.fileExists(atPath: sourceExpanded),
              let sourceData = FileManager.default.contents(atPath: sourceExpanded) else {
            return nil
        }
        let copiedData = FileManager.default.contents(atPath: credentialPath)
        guard sourceData != copiedData else { return nil }

        do {
            try sourceData.write(to: URL(fileURLWithPath: credentialPath), options: .atomic)
        } catch {
            return nil
        }

        guard let usage = try? await performCredentialFetch(
            credentialProvider: credentialProvider, credential: credential,
            label: label, fallbackAccountId: fallbackAccountId
        ) else {
            return nil
        }

        return buildCredentialSuccess(
            provider: provider, usage: usage, credential: credential,
            uniqueId: uniqueId, label: label
        )
    }

    private func resolveAccountIdFromCredential(_ credential: AccountCredential) -> String? {
        if let metadataId = credential.metadata["accountId"]?.nilIfBlank {
            return metadataId
        }
        guard credential.authMethod == .authFile else { return nil }
        let path = NSString(string: credential.credential).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        return (tokens["account_id"] as? String)?.nilIfBlank
            ?? (tokens["accountId"] as? String)?.nilIfBlank
            ?? (json["account_id"] as? String)?.nilIfBlank
            ?? (json["accountId"] as? String)?.nilIfBlank
    }

    private func fetchMultiAccount(provider: MultiAccountProviderFetcher) async -> [ProviderResult] {
        let start = Date()
        let accountResults = await withTimeout(seconds: Self.timeoutSeconds * 2) {
            await provider.fetchAllAccounts()
        } ?? []

        if accountResults.isEmpty {
            let elapsed = Date().timeIntervalSince(start)
            engineLog.warning("✗ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms - no accounts found")
            let summary = UsageNormalizer.errorSummary(
                provider: provider,
                error: ProviderError("not_logged_in", "No accounts found for \(provider.displayName)")
            )
            return [ProviderResult(id: provider.id, ok: false, summary: summary, error: "No accounts found")]
        }

        let elapsed = Date().timeIntervalSince(start)
        engineLog.debug("✓ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms [\(accountResults.count) accounts]")

        let results = accountResults.map { fetchResult in
            let acctId: String = fetchResult.accountId
            let uniqueId = "\(provider.id):auto:\(acctId)"
            switch fetchResult.result {
            case .success(let rawUsage):
                var usage = rawUsage
                usage.usageAccountId = acctId
                var summary = UsageNormalizer.normalize(provider: provider, usage: usage)
                summary.id = uniqueId
                summary.providerId = provider.id
                summary.accountId = acctId
                return ProviderResult(
                    id: uniqueId,
                    providerId: provider.id,
                    accountId: acctId,
                    ok: true,
                    usage: usage,
                    summary: summary
                )
            case .failure(let error):
                var summary = UsageNormalizer.errorSummary(provider: provider, error: error)
                summary.id = uniqueId
                summary.providerId = provider.id
                summary.accountId = acctId
                if let label = fetchResult.accountLabel {
                    summary.accountLabel = label
                }
                return ProviderResult(
                    id: uniqueId,
                    providerId: provider.id,
                    accountId: acctId,
                    ok: false,
                    summary: summary,
                    error: SensitiveDataRedactor.redactedDescription(for: error)
                )
            }
        }

        let deduplicated = mergeResults(
            automatic: results,
            credentialBacked: [],
            provider: provider
        )

        if deduplicated.count != results.count {
            engineLog.debug("\(provider.id): deduplicated \(results.count - deduplicated.count) duplicate account result(s)")
        }

        return deduplicated
    }

    private func mergeResults(
        automatic: [ProviderResult],
        credentialBacked: [ProviderResult],
        provider: any ProviderFetcher
    ) -> [ProviderResult] {
        var mergedByKey: [String: ProviderResult] = [:]
        var orderedKeys: [String] = []
        let shouldDropGenericAutomaticError = !credentialBacked.isEmpty

        for result in automatic + credentialBacked {
            if shouldDropGenericAutomaticError && isGenericAvailabilityError(result, providerId: provider.id) {
                continue
            }

            let key = identityKey(for: result, providerId: provider.id)
            if let existing = mergedByKey[key] {
                if shouldPrefer(result, over: existing) {
                    mergedByKey[key] = result
                }
            } else {
                mergedByKey[key] = result
                orderedKeys.append(key)
            }
        }

        let autoAccountIds = Set(automatic.compactMap {
            normalizedIdentity($0.resultAccountId)
                ?? normalizedIdentity($0.summary?.accountId)
                ?? normalizedIdentity($0.usage?.usageAccountId)
        })

        return orderedKeys.compactMap { key -> ProviderResult? in
            guard let result = mergedByKey[key] else { return nil }
            if result.ok { return result }
            guard result.id.contains(":cred:"), !autoAccountIds.isEmpty else { return result }
            let resultAccountId = normalizedIdentity(result.resultAccountId)
                ?? normalizedIdentity(result.summary?.accountId)
                ?? normalizedIdentity(result.usage?.usageAccountId)
            if let resultAccountId, autoAccountIds.contains(resultAccountId) { return result }
            let msg = (result.error ?? "").lowercased()
            if msg.contains("unauthorized") || msg.contains("invalid or expired")
                || msg.contains("not_logged_in") || msg.contains("missing_token") {
                return nil
            }
            return result
        }
    }

    private func identityKey(for result: ProviderResult, providerId: String) -> String {
        if let accountId = normalizedIdentity(result.resultAccountId)
            ?? normalizedIdentity(result.summary?.accountId)
            ?? normalizedIdentity(result.usage?.usageAccountId) {
            return "\(providerId):id:\(accountId)"
        }

        if let label = normalizedIdentity(result.summary?.accountLabel)
            ?? normalizedIdentity(result.usage?.accountEmail)
            ?? normalizedIdentity(result.usage?.accountLogin)
            ?? normalizedIdentity(result.usage?.accountName) {
            return "\(providerId):label:\(label)"
        }

        return "\(providerId):generic:\(result.id)"
    }

    private func normalizedIdentity(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfBlank
    }

    private func isGenericAvailabilityError(_ result: ProviderResult, providerId: String) -> Bool {
        guard !result.ok,
              result.providerId == providerId,
              normalizedIdentity(result.resultAccountId) == nil,
              normalizedIdentity(result.summary?.accountId) == nil,
              normalizedIdentity(result.summary?.accountLabel) == nil,
              normalizedIdentity(result.usage?.accountEmail) == nil else {
            return false
        }

        let message = (result.error ?? result.summary?.headline.secondary ?? "").lowercased()
        return message.contains("no accounts found")
            || message.contains("not logged in")
            || message.contains("not_logged_in")
            || message.contains("no valid")
    }

    private func shouldPrefer(_ candidate: ProviderResult, over existing: ProviderResult) -> Bool {
        if candidate.ok != existing.ok {
            return candidate.ok
        }

        let candidateScore = detailScore(for: candidate)
        let existingScore = detailScore(for: existing)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }

        return candidate.id < existing.id
    }

    private func detailScore(for result: ProviderResult) -> Int {
        var score = 0
        if normalizedIdentity(result.resultAccountId) != nil || normalizedIdentity(result.summary?.accountId) != nil {
            score += 2
        }
        if normalizedIdentity(result.summary?.accountLabel) != nil
            || normalizedIdentity(result.usage?.accountEmail) != nil
            || normalizedIdentity(result.usage?.accountName) != nil {
            score += 1
        }
        return score
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Timeout Helpers

func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ProviderError("timeout", "Operation timed out after \(Int(seconds))s")
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw ProviderError("timeout", "Operation ended without a result.")
        }
        group.cancelAll()
        return result
    }
}

func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        if let result = await group.next() ?? nil {
            group.cancelAll()
            return result
        }
        group.cancelAll()
        return nil
    }
}
