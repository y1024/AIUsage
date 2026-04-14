import Foundation
import Combine
import QuotaBackend

// MARK: - AccountStore
// Persists multi-provider account registry (SecureAccountVault), normalizes against
// AccountCredentialStore, deduplicates, and reconciles with live ProviderData snapshots.

final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var accountRegistry: [StoredProviderAccount] = []

    /// Base provider ids in UI/catalog order; must match `AppState.providerCatalogItems`.
    private var providerCatalogOrder: [String] = []

    private init() {
        accountRegistry = SecureAccountVault.shared.loadAccounts()
    }

    /// Call once at app launch after `AppState` can supply catalog order (before refresh).
    func bootstrapFromDisk(providerCatalogOrder: [String]) {
        self.providerCatalogOrder = providerCatalogOrder
        bootstrapCredentialIndexFromRegistry()
        normalizePersistedState()
        cleanupManagedCredentialArtifacts()
    }

    func updateProviderCatalogOrder(_ ids: [String]) {
        providerCatalogOrder = ids
    }

    // MARK: - Public account API

    func saveAccount(
        providerId: String,
        email: String,
        displayName: String?,
        note: String? = nil,
        accountId: String? = nil,
        credentialId: String? = nil,
        providerResultId: String? = nil,
        ensureProviderSelected: (String) -> Void
    ) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else { return }

        let now = SharedFormatters.iso8601String(from: Date())
        let credentialSnapshot = credentialId.flatMap {
            credentialAccountSnapshot(providerId: providerId, credentialId: $0)
        }
        let effectiveEmail = credentialSnapshot?.accountHandle ?? normalizedEmail
        let normalizedLookup = effectiveEmail.lowercased()
        let normalizedAccountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialSnapshot?.normalizedAccountId
        let normalizedProviderResultId = providerResultId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialId.map { "\(providerId):cred:\($0)".lowercased() }
        let effectiveDisplayName = displayName?.nilIfBlank ?? credentialSnapshot?.displayName

        if let index = accountRegistry.firstIndex(where: {
            guard $0.providerId == providerId else { return false }
            if let credentialId, $0.credentialId == credentialId { return true }
            if let normalizedProviderResultId, $0.normalizedProviderResultId == normalizedProviderResultId { return true }
            if let normalizedAccountId, $0.normalizedAccountId == normalizedAccountId { return true }
            return $0.normalizedEmail == normalizedLookup
        }) {
            let existing = accountRegistry[index]
            accountRegistry[index] = StoredProviderAccount(
                id: existing.id,
                providerId: existing.providerId,
                email: effectiveEmail,
                displayName: effectiveDisplayName ?? existing.displayName,
                note: note?.nilIfBlank ?? existing.note,
                accountId: normalizedAccountId ?? existing.accountId,
                providerResultId: normalizedProviderResultId ?? existing.providerResultId,
                credentialId: credentialId ?? existing.credentialId,
                createdAt: existing.createdAt,
                lastSeenAt: maxTimestampString(now, existing.lastSeenAt, credentialSnapshot?.validatedAt),
                isHidden: false
            )
        } else {
            accountRegistry.append(
                StoredProviderAccount(
                    id: UUID().uuidString,
                    providerId: providerId,
                    email: effectiveEmail,
                    displayName: effectiveDisplayName,
                    note: note?.nilIfBlank,
                    accountId: normalizedAccountId,
                    providerResultId: normalizedProviderResultId,
                    credentialId: credentialId,
                    createdAt: now,
                    lastSeenAt: maxTimestampString(now, credentialSnapshot?.validatedAt),
                    isHidden: false
                )
            )
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        ensureProviderSelected(providerId)
        persistAccountRegistry()
    }

    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String?,
        providerDisplayTitle: String,
        insertImmediateProviderData: (_ providerId: String, _ credentialId: String, _ accountLabel: String?, _ usage: ProviderUsage) -> Void,
        ensureProviderSelected: (String) -> Void
    ) throws {
        let providerId = credential.providerId
        let accountHandle: String = {
            if let v = usage.accountEmail?.nilIfBlank { return v }
            if let v = usage.accountLogin?.nilIfBlank { return v }
            if let v = usage.accountName?.nilIfBlank { return v }
            if let v = credential.accountLabel?.nilIfBlank { return v }
            if let v = usage.usageAccountId?.nilIfBlank { return v }
            return "\(providerDisplayTitle) Account"
        }()
        let displayName: String? = usage.accountName?.nilIfBlank
            ?? credential.accountLabel?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank
        let accountId: String? = usage.usageAccountId?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank

        var enrichedCredential = credential
        let validatedAt = SharedFormatters.iso8601String(from: Date())
        enrichedCredential.metadata["accountHandle"] = accountHandle
        enrichedCredential.metadata["lastValidatedAt"] = validatedAt
        if let accountEmail = usage.accountEmail?.nilIfBlank {
            enrichedCredential.metadata["accountEmail"] = accountEmail
        }
        if let displayName {
            enrichedCredential.metadata["displayName"] = displayName
        }
        if let accountId {
            enrichedCredential.metadata["accountId"] = accountId
        }
        enrichedCredential.lastUsedAt = validatedAt

        if let existingCredential = existingAuthenticatedCredential(
            providerId: providerId,
            accountHandle: accountHandle,
            accountId: accountId,
            sessionFingerprint: enrichedCredential.metadata["sessionFingerprint"],
            sourceIdentifier: enrichedCredential.metadata["sourceIdentifier"],
            sourceIdentifierIsStable: enrichedCredential.metadata["identityScope"]
                == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue
        ) {
            var mergedMetadata = existingCredential.metadata
            enrichedCredential.metadata.forEach { mergedMetadata[$0.key] = $0.value }
            enrichedCredential = AccountCredential(
                id: existingCredential.id,
                providerId: existingCredential.providerId,
                accountLabel: enrichedCredential.accountLabel ?? existingCredential.accountLabel,
                authMethod: enrichedCredential.authMethod,
                credential: enrichedCredential.credential,
                metadata: mergedMetadata
            )
            enrichedCredential.lastUsedAt = validatedAt
            ProviderManagedImportStore.reuseManagedImportIfPossible(
                existingCredential: existingCredential,
                incomingCredential: &enrichedCredential
            )
        }

        try AccountCredentialStore.shared.saveCredential(enrichedCredential)
        let credentialRemapping = AccountCredentialStore.shared.deduplicateCredentials(for: providerId)
        if !credentialRemapping.isEmpty {
            applyCredentialRemapping(credentialRemapping)
            if let remappedID = credentialRemapping[enrichedCredential.id] {
                let canonicalCredential = AccountCredentialStore.shared
                    .loadCredentials(for: providerId)
                    .first(where: { $0.id == remappedID })
                var rewrittenCanonicalCredential = AccountCredential(
                    id: remappedID,
                    providerId: enrichedCredential.providerId,
                    accountLabel: enrichedCredential.accountLabel,
                    authMethod: enrichedCredential.authMethod,
                    credential: enrichedCredential.credential,
                    metadata: enrichedCredential.metadata
                )
                rewrittenCanonicalCredential.lastUsedAt = validatedAt
                if let canonicalCredential {
                    ProviderManagedImportStore.reuseManagedImportIfPossible(
                        existingCredential: canonicalCredential,
                        incomingCredential: &rewrittenCanonicalCredential
                    )
                }
                try AccountCredentialStore.shared.saveCredential(rewrittenCanonicalCredential)
                enrichedCredential = rewrittenCanonicalCredential
            }
        }

        saveAccount(
            providerId: providerId,
            email: accountHandle,
            displayName: displayName,
            note: note,
            accountId: accountId,
            credentialId: enrichedCredential.id,
            providerResultId: "\(providerId):cred:\(enrichedCredential.id)",
            ensureProviderSelected: ensureProviderSelected
        )

        insertImmediateProviderData(
            providerId,
            enrichedCredential.id,
            enrichedCredential.accountLabel ?? accountHandle,
            usage
        )
    }

    func updateAccountNote(
        for entry: ProviderAccountEntry,
        note: String?,
        onProviderActivated: (String) -> Void
    ) {
        let now = SharedFormatters.iso8601String(from: Date())

        if let index = bestStoredAccountIndex(for: entry) {
            accountRegistry[index].note = note?.nilIfBlank
            accountRegistry[index].isHidden = false
            accountRegistry[index].providerResultId = entry.liveProvider?.id ?? accountRegistry[index].providerResultId
            accountRegistry[index].accountId = entry.liveProvider?.accountId ?? accountRegistry[index].accountId
            accountRegistry[index].lastSeenAt = entry.liveProvider == nil ? accountRegistry[index].lastSeenAt : now
        } else if let created = makeStoredAccount(
            from: entry,
            note: note?.nilIfBlank,
            isHidden: false,
            lastSeenAt: entry.liveProvider == nil ? nil : now
        ) {
            accountRegistry.append(created)
        } else {
            return
        }

        onProviderActivated(entry.providerId)
        persistAccountRegistry()
    }

    func restoreAccount(_ storedAccountId: String, onRestored: (String) -> Void) {
        guard let index = accountRegistry.firstIndex(where: { $0.id == storedAccountId }) else { return }
        accountRegistry[index].isHidden = false
        persistAccountRegistry()
        onRestored(accountRegistry[index].providerId)
    }

    func deleteAccount(
        _ entry: ProviderAccountEntry,
        onPostRegistryDelete: () -> Void
    ) {
        let matchedCredentials = matchingCredentialsImpl(for: entry)
        for credential in matchedCredentials {
            AccountCredentialStore.shared.deleteCredential(credential)
        }

        let matchingIndices = matchingStoredAccountIndices(for: entry)
        if !matchingIndices.isEmpty {
            for index in matchingIndices {
                var updated = accountRegistry[index]
                updated.note = nil
                updated.credentialId = nil
                updated.providerResultId = entry.liveProvider?.id ?? updated.providerResultId
                updated.accountId = entry.liveProvider?.accountId ?? updated.accountId
                updated.isHidden = true
                updated.lastSeenAt = maxTimestampString(
                    SharedFormatters.iso8601String(from: Date()),
                    updated.lastSeenAt
                )
                accountRegistry[index] = updated
            }
        } else if let hiddenEntry = makeStoredAccount(
            from: entry,
            note: nil,
            isHidden: true,
            lastSeenAt: SharedFormatters.iso8601String(from: Date())
        ) {
            accountRegistry.append(hiddenEntry)
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()

        onPostRegistryDelete()

        cleanupManagedCredentialArtifacts()
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountRegistry.first(where: { !$0.isHidden && storedAccountMatchesLive($0, provider: provider) })?.note?.nilIfBlank
    }

    /// Credentials that plausibly belong to this account entry (used for CLI path resolution, etc.).
    func matchingCredentials(for entry: ProviderAccountEntry) -> [AccountCredential] {
        matchingCredentialsImpl(for: entry)
    }

    func hiddenAccounts() -> [StoredProviderAccount] {
        let providerOrder = providerCatalogOrder
        return accountRegistry
            .filter(\.isHidden)
            .sorted {
                if $0.providerId != $1.providerId {
                    let lhsIndex = providerOrder.firstIndex(of: $0.providerId) ?? Int.max
                    let rhsIndex = providerOrder.firstIndex(of: $1.providerId) ?? Int.max
                    return lhsIndex < rhsIndex
                }
                return $0.preferredLabel.localizedCaseInsensitiveCompare($1.preferredLabel) == .orderedAscending
            }
    }

    func reconcileAccountRegistry(with providers: [ProviderData]) {
        var didChange = false
        let now = SharedFormatters.iso8601String(from: Date())
        var reservedStoredIDs = Set<String>()
        let allowUnseenCredentialFallback = providers.count == 1
        let orderedProviders = providers.sorted { lhs, rhs in
            let lhsCredentialBacked = extractCredentialId(from: lhs.id) != nil
            let rhsCredentialBacked = extractCredentialId(from: rhs.id) != nil
            if lhsCredentialBacked != rhsCredentialBacked {
                return lhsCredentialBacked && !rhsCredentialBacked
            }
            return providerSort(lhs, rhs)
        }

        for provider in orderedProviders {
            let label = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                ?? provider.label.nilIfBlank

            guard let label else {
                continue
            }

            let inferredCredentialId = extractCredentialId(from: provider.id)

            if let hiddenIndex = accountRegistry.firstIndex(where: {
                !$0.id.isEmpty && !reservedStoredIDs.contains($0.id) && $0.isHidden && storedAccountMatchesLive($0, provider: provider)
            }) {
                var hidden = accountRegistry[hiddenIndex]
                if hidden.providerResultId != provider.id {
                    hidden.providerResultId = provider.id
                    didChange = true
                }
                if hidden.accountId != provider.accountId {
                    hidden.accountId = provider.accountId
                    didChange = true
                }
                if hidden.credentialId == nil, let inferredCredentialId {
                    hidden.credentialId = inferredCredentialId
                    didChange = true
                }
                if hidden.lastSeenAt != now {
                    hidden.lastSeenAt = now
                    didChange = true
                }
                accountRegistry[hiddenIndex] = hidden
                reservedStoredIDs.insert(hidden.id)
                continue
            }

            if let index = bestStoredAccountIndex(
                for: provider,
                excluding: reservedStoredIDs,
                allowUnseenCredentialFallback: allowUnseenCredentialFallback
            ) {
                var updated = accountRegistry[index]
                if updated.email != label {
                    updated.email = label
                    didChange = true
                }
                if updated.accountId != provider.accountId {
                    updated.accountId = provider.accountId
                    didChange = true
                }
                if updated.providerResultId != provider.id {
                    updated.providerResultId = provider.id
                    didChange = true
                }
                if updated.credentialId == nil, let inferredCredentialId {
                    updated.credentialId = inferredCredentialId
                    didChange = true
                }
                if updated.lastSeenAt != now {
                    updated.lastSeenAt = now
                    didChange = true
                }
                if updated.isHidden {
                    updated.isHidden = false
                    didChange = true
                }
                accountRegistry[index] = updated
                reservedStoredIDs.insert(updated.id)
            } else {
                let normalizedNewEmail = label.lowercased()
                let normalizedNewAccountId = provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
                if let dupeIndex = accountRegistry.firstIndex(where: {
                    $0.providerId == provider.baseProviderId && !$0.isHidden && (
                        $0.normalizedEmail == normalizedNewEmail ||
                        (normalizedNewAccountId != nil && $0.normalizedAccountId == normalizedNewAccountId)
                    )
                }) {
                    var existing = accountRegistry[dupeIndex]
                    if existing.providerResultId != provider.id {
                        existing.providerResultId = provider.id
                        didChange = true
                    }
                    if existing.accountId != provider.accountId {
                        existing.accountId = provider.accountId
                        didChange = true
                    }
                    if existing.credentialId == nil, let inferredCredentialId {
                        existing.credentialId = inferredCredentialId
                        didChange = true
                    }
                    if existing.lastSeenAt != now {
                        existing.lastSeenAt = now
                        didChange = true
                    }
                    accountRegistry[dupeIndex] = existing
                    reservedStoredIDs.insert(existing.id)
                } else {
                    let stored = StoredProviderAccount(
                        id: UUID().uuidString,
                        providerId: provider.baseProviderId,
                        email: label,
                        displayName: nil,
                        note: nil,
                        accountId: provider.accountId,
                        providerResultId: provider.id,
                        credentialId: inferredCredentialId,
                        createdAt: now,
                        lastSeenAt: now,
                        isHidden: false
                    )
                    accountRegistry.append(stored)
                    reservedStoredIDs.insert(stored.id)
                    didChange = true
                }
            }
        }

        let beforeDedup = accountRegistry.count
        deduplicateAccountRegistry()
        if accountRegistry.count != beforeDedup {
            didChange = true
        }

        if didChange {
            persistAccountRegistry()
        }
    }

    func hasHiddenRegistryMatch(providerId: String, normalizedEmail: String?, normalizedAccountId: String?) -> Bool {
        accountRegistry.contains { stored in
            guard stored.providerId == providerId, stored.isHidden else { return false }
            if let normalizedAccountId,
               stored.normalizedAccountId == normalizedAccountId {
                return true
            }
            if let normalizedEmail,
               stored.normalizedEmail == normalizedEmail {
                return true
            }
            return false
        }
    }

    /// Whether `stored` refers to the same logical account as live `provider` data.
    func matchesStoredWithLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        storedAccountMatchesLive(stored, provider: provider)
    }

    // MARK: - Private — persistence & normalization

    private func normalizePersistedState() {
        bootstrapCredentialIndexFromRegistry()
        let credentialRemapping = AccountCredentialStore.shared.deduplicateCredentials()
        var didChange = applyCredentialRemapping(credentialRemapping)
        if normalizeAccountRegistryAgainstCredentials() {
            didChange = true
        }

        let beforeDedup = accountRegistry.count
        deduplicateAccountRegistry()
        if accountRegistry.count != beforeDedup {
            didChange = true
        }

        if didChange {
            persistAccountRegistry()
        }

        cleanupManagedCredentialArtifacts()
    }

    @discardableResult
    private func applyCredentialRemapping(_ remappedCredentialIDs: [String: String]) -> Bool {
        guard !remappedCredentialIDs.isEmpty else { return false }

        var didChange = false
        for index in accountRegistry.indices {
            var updated = accountRegistry[index]

            if let credentialId = updated.credentialId,
               let canonicalID = remappedCredentialIDs[credentialId],
               canonicalID != credentialId {
                updated.credentialId = canonicalID
                didChange = true
            }

            if let providerResultId = updated.providerResultId,
               let resultCredentialId = extractCredentialId(from: providerResultId),
               let canonicalID = remappedCredentialIDs[resultCredentialId],
               canonicalID != resultCredentialId {
                updated.providerResultId = "\(updated.providerId):cred:\(canonicalID)"
                didChange = true
            }

            accountRegistry[index] = updated
        }

        return didChange
    }

    private func normalizedAccountLookupValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    private func existingAuthenticatedCredential(
        providerId: String,
        accountHandle: String,
        accountId: String?,
        sessionFingerprint: String?,
        sourceIdentifier: String?,
        sourceIdentifierIsStable: Bool
    ) -> AccountCredential? {
        let normalizedHandle = normalizedAccountLookupValue(accountHandle)
        let normalizedAccountId = normalizedAccountLookupValue(accountId)
        let normalizedFingerprint = normalizedAccountLookupValue(sessionFingerprint)
        let normalizedSourceIdentifier = normalizedAccountLookupValue(sourceIdentifier)

        return AccountCredentialStore.shared.loadCredentials(for: providerId).first { credential in
            if sourceIdentifierIsStable,
               let normalizedSourceIdentifier,
               credential.metadata["identityScope"] == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue,
               normalizedAccountLookupValue(credential.metadata["sourceIdentifier"]) == normalizedSourceIdentifier {
                return true
            }

            if let normalizedFingerprint,
               normalizedAccountLookupValue(credential.metadata["sessionFingerprint"]) == normalizedFingerprint {
                return true
            }

            if let normalizedAccountId,
               normalizedAccountLookupValue(credential.metadata["accountId"]) == normalizedAccountId {
                return true
            }

            return normalizedAccountLookupValue(
                credential.metadata["accountEmail"]
                    ?? credential.metadata["accountHandle"]
                    ?? credential.accountLabel
            ) == normalizedHandle
        }
    }

    private func extractCredentialId(from providerDataId: String) -> String? {
        guard let range = providerDataId.range(of: ":cred:") else { return nil }
        return String(providerDataId[range.upperBound...]).nilIfBlank
    }

    private struct CredentialAccountSnapshot {
        let accountHandle: String?
        let displayName: String?
        let accountId: String?
        let validatedAt: String?

        var normalizedAccountId: String? {
            accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
        }
    }

    private func credentialAccountSnapshot(providerId: String, credentialId: String) -> CredentialAccountSnapshot? {
        guard let credential = AccountCredentialStore.shared
            .loadCredential(providerId: providerId, credentialId: credentialId) else {
            return nil
        }

        return CredentialAccountSnapshot(
            accountHandle: credential.metadata["accountEmail"]?.nilIfBlank
                ?? credential.metadata["accountHandle"]?.nilIfBlank
                ?? credential.accountLabel?.nilIfBlank,
            displayName: credential.metadata["displayName"]?.nilIfBlank,
            accountId: credential.metadata["accountId"]?.nilIfBlank,
            validatedAt: credential.metadata["lastValidatedAt"]?.nilIfBlank
                ?? credential.lastUsedAt?.nilIfBlank
        )
    }

    @discardableResult
    private func normalizeAccountRegistryAgainstCredentials() -> Bool {
        let allCredentials = AccountCredentialStore.shared.loadAllCredentials()
        let credentialLookup = Dictionary(uniqueKeysWithValues: allCredentials.map { ($0.id, $0) })
        let credentialsByProvider = Dictionary(grouping: allCredentials, by: \.providerId)
        var didChange = false

        for index in accountRegistry.indices {
            var account = accountRegistry[index]
            var resolvedCredentialId = account.credentialId?.nilIfBlank

            if resolvedCredentialId == nil,
               let resultCredentialId = account.providerResultId.flatMap(extractCredentialId),
               let credential = credentialLookup[resultCredentialId],
               credential.providerId == account.providerId {
                resolvedCredentialId = credential.id
                account.credentialId = credential.id
                didChange = true
            }

            if resolvedCredentialId == nil,
               let matchedCredential = bestCredentialMatch(
                for: account,
                candidates: credentialsByProvider[account.providerId] ?? []
               ) {
                resolvedCredentialId = matchedCredential.id
                account.credentialId = matchedCredential.id
                didChange = true
            }

            guard let credentialId = resolvedCredentialId else { continue }
            guard let credential = credentialLookup[credentialId] else {
                accountRegistry[index] = account
                continue
            }

            guard credential.providerId == account.providerId else { continue }

            let accountHandle = credential.metadata["accountEmail"]?.nilIfBlank
                ?? credential.metadata["accountHandle"]?.nilIfBlank
                ?? credential.accountLabel?.nilIfBlank
            let displayName = credential.metadata["displayName"]?.nilIfBlank
            let accountId = credential.metadata["accountId"]?.nilIfBlank
            let validatedAt = credential.metadata["lastValidatedAt"]?.nilIfBlank
                ?? credential.lastUsedAt?.nilIfBlank
            let expectedResultId = "\(account.providerId):cred:\(credential.id)"

            if let accountHandle, account.email != accountHandle {
                account.email = accountHandle
                didChange = true
            }
            if let displayName, account.displayName != displayName {
                account.displayName = displayName
                didChange = true
            }
            if let accountId, account.accountId != accountId {
                account.accountId = accountId
                didChange = true
            }
            if account.providerResultId != expectedResultId {
                account.providerResultId = expectedResultId
                didChange = true
            }
            let normalizedSeenAt = maxTimestampString(account.lastSeenAt, validatedAt)
            if account.lastSeenAt != normalizedSeenAt {
                account.lastSeenAt = normalizedSeenAt
                didChange = true
            }

            accountRegistry[index] = account
        }

        return didChange
    }

    private func bootstrapCredentialIndexFromRegistry() {
        let references = Set(
            accountRegistry.flatMap { account -> [AccountCredentialReference] in
                var refs: [AccountCredentialReference] = []
                if let credentialId = account.credentialId?.nilIfBlank {
                    refs.append(AccountCredentialReference(providerId: account.providerId, credentialId: credentialId))
                }
                if let providerResultCredentialId = account.providerResultId.flatMap(extractCredentialId) {
                    refs.append(AccountCredentialReference(providerId: account.providerId, credentialId: providerResultCredentialId))
                }
                return refs
            }
        )
        AccountCredentialStore.shared.bootstrapCredentialIndex(references: Array(references))
    }

    private func bestCredentialMatch(
        for account: StoredProviderAccount,
        candidates: [AccountCredential]
    ) -> AccountCredential? {
        let normalizedAccountId = account.normalizedAccountId
        if let normalizedAccountId,
           let accountIDMatch = candidates.first(where: {
               normalizedAccountLookupValue($0.metadata["accountId"]) == normalizedAccountId
           }) {
            return accountIDMatch
        }

        if !account.normalizedEmail.isEmpty,
           let emailMatch = candidates.first(where: {
               normalizedAccountLookupValue(
                   $0.metadata["accountEmail"]
                       ?? $0.metadata["accountHandle"]
                       ?? $0.accountLabel
               ) == account.normalizedEmail
           }) {
            return emailMatch
        }

        return nil
    }

    private func deduplicateAccountRegistry() {
        let credentialLookup = Dictionary(
            uniqueKeysWithValues: AccountCredentialStore.shared.loadAllCredentials().map { ($0.id, $0) }
        )
        var seen: [String: Int] = [:]
        var indicesToRemove: [Int] = []

        for (index, account) in accountRegistry.enumerated() {
            let key = storedAccountIdentityKey(account)
            if let existingIndex = seen[key] {
                let existing = accountRegistry[existingIndex]
                let keepExisting = shouldPreferStoredAccount(existing, over: account, credentialLookup: credentialLookup)

                if keepExisting {
                    accountRegistry[existingIndex] = mergedStoredAccount(
                        preferred: existing,
                        secondary: account,
                        credentialLookup: credentialLookup
                    )
                    indicesToRemove.append(index)
                } else {
                    accountRegistry[index] = mergedStoredAccount(
                        preferred: account,
                        secondary: existing,
                        credentialLookup: credentialLookup
                    )
                    indicesToRemove.append(existingIndex)
                    seen[key] = index
                }
            } else {
                seen[key] = index
            }
        }

        if !indicesToRemove.isEmpty {
            for index in indicesToRemove.sorted(by: >) {
                accountRegistry.remove(at: index)
            }
        }
    }

    private func storedAccountIdentityKey(_ account: StoredProviderAccount) -> String {
        let providerId = account.providerId.lowercased()
        if let accountId = account.normalizedAccountId {
            return "\(providerId):account:\(accountId)"
        }
        if !account.normalizedEmail.isEmpty {
            return "\(providerId):email:\(account.normalizedEmail)"
        }
        if let credentialId = account.credentialId?.lowercased().nilIfBlank {
            return "\(providerId):cred:\(credentialId)"
        }
        return "\(providerId):stored:\(account.id.lowercased())"
    }

    private func shouldPreferStoredAccount(
        _ lhs: StoredProviderAccount,
        over rhs: StoredProviderAccount,
        credentialLookup: [String: AccountCredential]
    ) -> Bool {
        if lhs.isHidden != rhs.isHidden {
            return !lhs.isHidden
        }

        let lhsHasCredential = lhs.credentialId.flatMap { credentialLookup[$0] } != nil
        let rhsHasCredential = rhs.credentialId.flatMap { credentialLookup[$0] } != nil
        if lhsHasCredential != rhsHasCredential {
            return lhsHasCredential
        }

        let lhsCredentialBound = extractCredentialId(from: lhs.providerResultId ?? "") != nil
        let rhsCredentialBound = extractCredentialId(from: rhs.providerResultId ?? "") != nil
        if lhsCredentialBound != rhsCredentialBound {
            return lhsCredentialBound
        }

        let lhsSeen = parseISO8601(lhs.lastSeenAt ?? "") ?? .distantPast
        let rhsSeen = parseISO8601(rhs.lastSeenAt ?? "") ?? .distantPast
        if lhsSeen != rhsSeen {
            return lhsSeen > rhsSeen
        }

        let lhsCreated = parseISO8601(lhs.createdAt) ?? .distantPast
        let rhsCreated = parseISO8601(rhs.createdAt) ?? .distantPast
        if lhsCreated != rhsCreated {
            return lhsCreated > rhsCreated
        }

        return lhs.id < rhs.id
    }

    private func mergedStoredAccount(
        preferred: StoredProviderAccount,
        secondary: StoredProviderAccount,
        credentialLookup: [String: AccountCredential]
    ) -> StoredProviderAccount {
        var merged = preferred

        if merged.displayName?.nilIfBlank == nil {
            merged.displayName = secondary.displayName?.nilIfBlank
        }
        if merged.note?.nilIfBlank == nil {
            merged.note = secondary.note?.nilIfBlank
        }
        if merged.accountId?.nilIfBlank == nil {
            merged.accountId = secondary.accountId?.nilIfBlank
        }
        if merged.credentialId?.nilIfBlank == nil,
           let fallbackCredentialId = secondary.credentialId?.nilIfBlank,
           credentialLookup[fallbackCredentialId] != nil {
            merged.credentialId = fallbackCredentialId
        }
        if merged.providerResultId?.nilIfBlank == nil {
            merged.providerResultId = secondary.providerResultId?.nilIfBlank
        }
        merged.lastSeenAt = maxTimestampString(preferred.lastSeenAt, secondary.lastSeenAt)
        merged.isHidden = preferred.isHidden && secondary.isHidden
        return merged
    }

    private func maxTimestampString(_ values: String?...) -> String? {
        values
            .compactMap { $0?.nilIfBlank }
            .max {
                (parseISO8601($0) ?? .distantPast) < (parseISO8601($1) ?? .distantPast)
            }
    }

    private func bestStoredAccountIndex(
        for provider: ProviderData,
        excluding reservedStoredIDs: Set<String>,
        allowUnseenCredentialFallback: Bool
    ) -> Int? {
        if let exactIndex = accountRegistry.firstIndex(where: {
            !reservedStoredIDs.contains($0.id) && !$0.isHidden && storedAccountMatchesLive($0, provider: provider)
        }) {
            return exactIndex
        }

        guard allowUnseenCredentialFallback,
              extractCredentialId(from: provider.id) != nil else {
            return nil
        }

        let fallbackCandidates = accountRegistry.enumerated().filter { _, stored in
            !reservedStoredIDs.contains(stored.id) &&
            stored.providerId == provider.baseProviderId &&
            !stored.isHidden &&
            stored.credentialId != nil &&
            stored.lastSeenAt == nil
        }

        guard fallbackCandidates.count == 1 else { return nil }
        return fallbackCandidates[0].offset
    }

    private func storedAccountMatchesLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        guard stored.providerId == provider.baseProviderId else { return false }

        if let credentialId = stored.credentialId?.nilIfBlank {
            let expectedId = "\(stored.providerId):cred:\(credentialId)"
            if provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(expectedId) == .orderedSame {
                return true
            }
        }

        if let storedResultId = stored.normalizedProviderResultId {
            let liveId = provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if storedResultId == liveId {
                return true
            }
            if liveId.hasPrefix(storedResultId + ":") || storedResultId.hasPrefix(liveId + ":") {
                return true
            }
        }

        if let storedAccountId = stored.normalizedAccountId,
           let liveAccountId = normalizedLiveAccountID(for: provider),
           storedAccountId == liveAccountId {
            return true
        }

        if let liveEmail = normalizedAccountIdentifier(for: provider),
           stored.normalizedEmail == liveEmail {
            return true
        }

        return false
    }

    private func bestStoredAccountIndex(for entry: ProviderAccountEntry) -> Int? {
        if let storedID = entry.storedAccount?.id,
           let exactIndex = accountRegistry.firstIndex(where: { $0.id == storedID }) {
            return exactIndex
        }

        if let liveProvider = entry.liveProvider,
           let liveIndex = accountRegistry.firstIndex(where: { storedAccountMatchesLive($0, provider: liveProvider) }) {
            return liveIndex
        }

        let normalizedTokens = Set([
            entry.accountEmail?.lowercased().nilIfBlank,
            entry.accountDisplayName?.lowercased().nilIfBlank,
            entry.liveProvider?.accountId?.lowercased().nilIfBlank,
            entry.storedAccount?.normalizedEmail,
            entry.storedAccount?.normalizedAccountId
        ].compactMap { $0 })

        guard !normalizedTokens.isEmpty else { return nil }
        return accountRegistry.firstIndex { stored in
            guard stored.providerId == entry.providerId else { return false }
            return normalizedTokens.contains(stored.normalizedEmail)
                || (stored.normalizedAccountId.map(normalizedTokens.contains) ?? false)
        }
    }

    private func makeStoredAccount(
        from entry: ProviderAccountEntry,
        note: String?,
        isHidden: Bool,
        lastSeenAt: String?
    ) -> StoredProviderAccount? {
        let now = SharedFormatters.iso8601String(from: Date())
        let label = entry.accountEmail?.nilIfBlank
            ?? entry.accountDisplayName?.nilIfBlank
            ?? entry.liveProvider?.accountId?.nilIfBlank
            ?? entry.storedAccount?.email.nilIfBlank
            ?? entry.providerTitle.nilIfBlank

        guard let label else { return nil }

        return StoredProviderAccount(
            id: entry.storedAccount?.id ?? UUID().uuidString,
            providerId: entry.providerId,
            email: label,
            displayName: entry.storedAccount?.displayName?.nilIfBlank ?? entry.accountDisplayName?.nilIfBlank,
            note: note,
            accountId: entry.liveProvider?.accountId?.nilIfBlank ?? entry.storedAccount?.accountId,
            providerResultId: entry.liveProvider?.id ?? entry.storedAccount?.providerResultId,
            credentialId: entry.storedAccount?.credentialId,
            createdAt: entry.storedAccount?.createdAt ?? now,
            lastSeenAt: lastSeenAt ?? entry.storedAccount?.lastSeenAt,
            isHidden: isHidden
        )
    }

    private func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    private func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        guard let raw = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    private func matchingCredentialsImpl(for entry: ProviderAccountEntry) -> [AccountCredential] {
        if let credentialId = entry.storedAccount?.credentialId?.nilIfBlank,
           let directMatch = AccountCredentialStore.shared.loadCredential(
            providerId: entry.providerId,
            credentialId: credentialId
           ) {
            return [directMatch]
        }

        let credentials = AccountCredentialStore.shared.loadCredentials(for: entry.providerId)
        let identityTokens = accountIdentityTokens(for: entry)
        guard !identityTokens.isEmpty else { return [] }
        return credentials.filter { credential in
            let credentialTokens = Set([
                credential.metadata["accountId"]?.lowercased().nilIfBlank,
                credential.metadata["accountEmail"]?.lowercased().nilIfBlank,
                credential.metadata["accountHandle"]?.lowercased().nilIfBlank,
                credential.accountLabel?.lowercased().nilIfBlank
            ].compactMap { $0 })
            return !identityTokens.isDisjoint(with: credentialTokens)
        }
    }

    private func matchingStoredAccountIndices(for entry: ProviderAccountEntry) -> [Int] {
        var indices = Set<Int>()

        if let storedId = entry.storedAccount?.id,
           let exactIndex = accountRegistry.firstIndex(where: { $0.id == storedId }) {
            indices.insert(exactIndex)
        }

        if let liveProvider = entry.liveProvider {
            for (index, stored) in accountRegistry.enumerated() where storedAccountMatchesLive(stored, provider: liveProvider) {
                indices.insert(index)
            }
        }

        let identityTokens = accountIdentityTokens(for: entry)
        if !identityTokens.isEmpty {
            for (index, stored) in accountRegistry.enumerated() where stored.providerId == entry.providerId {
                let storedTokens = Set([
                    stored.normalizedEmail.nilIfBlank,
                    stored.normalizedAccountId,
                    stored.displayName?.lowercased().nilIfBlank,
                    stored.credentialId?.lowercased().nilIfBlank
                ].compactMap { $0 })
                if !identityTokens.isDisjoint(with: storedTokens) {
                    indices.insert(index)
                }
            }
        }

        return indices.sorted()
    }

    private func accountIdentityTokens(for entry: ProviderAccountEntry) -> Set<String> {
        Set([
            entry.storedAccount?.normalizedEmail.nilIfBlank,
            entry.storedAccount?.normalizedAccountId,
            entry.storedAccount?.displayName?.lowercased().nilIfBlank,
            entry.storedAccount?.credentialId?.lowercased().nilIfBlank,
            entry.accountEmail?.lowercased().nilIfBlank,
            entry.accountDisplayName?.lowercased().nilIfBlank,
            entry.liveProvider?.accountId?.lowercased().nilIfBlank,
            entry.liveProvider?.accountLabel?.lowercased().nilIfBlank
        ].compactMap { $0 })
    }

    private func persistAccountRegistry() {
        try? SecureAccountVault.shared.saveAccounts(accountRegistry)
    }

    private func cleanupManagedCredentialArtifacts() {
        let credentials = AccountCredentialStore.shared.loadAllCredentials()
        guard !credentials.isEmpty else { return }
        ProviderManagedImportStore.cleanupOrphanedManagedImports(referencedBy: credentials)
    }

    private func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        let providerOrder = providerCatalogOrder
        let lhsProviderIndex = providerOrder.firstIndex(of: lhs.baseProviderId) ?? Int.max
        let rhsProviderIndex = providerOrder.firstIndex(of: rhs.baseProviderId) ?? Int.max

        if lhsProviderIndex != rhsProviderIndex {
            return lhsProviderIndex < rhsProviderIndex
        }

        let lhsIdentity = (lhs.accountLabel ?? lhs.accountId ?? lhs.id).lowercased()
        let rhsIdentity = (rhs.accountLabel ?? rhs.accountId ?? rhs.id).lowercased()
        return lhsIdentity.localizedCaseInsensitiveCompare(rhsIdentity) == .orderedAscending
    }
}
