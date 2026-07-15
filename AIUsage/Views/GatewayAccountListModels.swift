import Foundation
import SwiftUI

// MARK: - Gateway Account List Models
// 账号中心列表的筛选、分组与派生计数。与具体行 UI 解耦，便于 AccountsView 保持编排职责。

enum GatewayAccountFilter: String, CaseIterable, Hashable {
    case all
    case ready
    case cooling
    case attention
    case paused
    case fromAIUsage

    var title: String {
        switch self {
        case .all: L("All", "全部")
        case .ready: L("Available", "可用")
        case .cooling: L("Temporarily limited", "暂时受限")
        case .attention: L("Attention", "异常")
        case .paused: L("Paused", "已停用")
        case .fromAIUsage: L("From Subscription", "来自订阅")
        }
    }
}

struct GatewayAccountGroup: Identifiable, Equatable {
    let providerID: String
    let files: [CLIProxyAuthFile]
    var id: String { providerID }
}

/// One human login and the project records synthesized for it by CPA.
/// The list presents this as one account while preserving every underlying
/// auth-file record for routing and per-project controls.
struct GatewayAccountFamily: Identifiable, Equatable {
    let id: String
    let accountLabel: String
    let files: [CLIProxyAuthFile]
    let showsProjectHierarchy: Bool

    var loginFiles: [CLIProxyAuthFile] { files.filter { !$0.runtimeOnly } }
    var projectFiles: [CLIProxyAuthFile] { files.filter(\.runtimeOnly) }
    var primaryFile: CLIProxyAuthFile? { loginFiles.first ?? files.first }
    var projectCount: Int { projectFiles.count }
    var isEnabled: Bool { files.contains { !$0.disabled } }
}

enum GatewayAccountListLogic {
    /// 列表「异常」：凭据/网关自身问题，或模型探测失败。不同步指纹漂移。
    static func fileNeedsAttention(
        _ file: CLIProxyAuthFile,
        modelLoadFailed: Bool = false
    ) -> Bool {
        if modelLoadFailed { return true }
        // Cooling is a temporary routing state with its own filter/status; do
        // not also count it as a credential problem.
        if isCooling(file) { return false }
        if file.gatewayNeedsAttention { return true }
        if file.gatewayProviderID == "unknown" { return true }
        return false
    }

    /// 「连通」= 列模型成功，且未停用/未冷却（不声称一定能跑满请求）。
    static func isReachable(
        _ file: CLIProxyAuthFile,
        modelCount: Int?,
        modelLoadFailed: Bool
    ) -> Bool {
        guard !file.disabled else { return false }
        if isCooling(file) { return false }
        if fileNeedsAttention(file, modelLoadFailed: modelLoadFailed) { return false }
        return modelCount != nil
    }

    static func isCooling(_ file: CLIProxyAuthFile) -> Bool {
        guard !file.disabled else { return false }
        if file.unavailable { return true }
        if let next = file.nextRetryAfter, next > Date() { return true }
        return false
    }

    static func filteredGroups(
        authFiles: [CLIProxyAuthFile],
        query: String,
        filter: GatewayAccountFilter,
        modelCountsByAuthFileName: [String: Int] = [:],
        modelErrorsByAuthFileName: Set<String> = []
    ) -> [GatewayAccountGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let files = authFiles.filter { file in
            let searchText = [
                file.displayLabel,
                file.gatewayAccountDisplayLabel,
                file.gatewayProjectDisplayLabel ?? "",
                file.projectID ?? "",
                file.displayProvider,
                file.name,
                file.note ?? "",
            ]
                .joined(separator: " ").lowercased()
            let matchesSearch = normalizedQuery.isEmpty || searchText.contains(normalizedQuery)
            guard matchesSearch else { return false }
            let key = file.name.lowercased()
            let failed = modelErrorsByAuthFileName.contains(key)
            let count = modelCountsByAuthFileName[key]
            switch filter {
            case .all: return true
            case .ready: return isReachable(file, modelCount: count, modelLoadFailed: failed)
            case .cooling: return !failed && isCooling(file)
            case .attention: return fileNeedsAttention(file, modelLoadFailed: failed)
            case .paused: return file.disabled
            case .fromAIUsage: return file.name.lowercased().hasPrefix("aiusage-")
            }
        }
        return Dictionary(grouping: files, by: \.gatewayProviderID)
            .map { GatewayAccountGroup(providerID: $0.key, files: $0.value) }
            .sorted {
                gatewayProviderDisplayName($0.providerID)
                    .localizedStandardCompare(gatewayProviderDisplayName($1.providerID)) == .orderedAscending
            }
    }

    /// Groups project-expanded plugin records by their real login identity.
    /// Providers without project-scoped runtime records retain one family per
    /// auth file, so existing Codex/Claude/etc. behavior is unchanged.
    static func accountFamilies(in group: GatewayAccountGroup) -> [GatewayAccountFamily] {
        let hasProjectRuntime = group.files.contains {
            $0.runtimeOnly && $0.gatewayProjectDisplayLabel != nil
        }
        guard hasProjectRuntime else {
            return group.files.map { file in
                GatewayAccountFamily(
                    id: "\(group.providerID):file:\(file.id)",
                    accountLabel: file.gatewayAccountDisplayLabel,
                    files: [file],
                    showsProjectHierarchy: false
                )
            }
        }

        let grouped = Dictionary(grouping: group.files) { file in
            file.gatewayAccountDisplayLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        return grouped.map { accountKey, files in
            let orderedFiles = files.sorted { lhs, rhs in
                if lhs.runtimeOnly != rhs.runtimeOnly { return !lhs.runtimeOnly }
                let left = lhs.gatewayProjectDisplayLabel ?? lhs.displayLabel
                let right = rhs.gatewayProjectDisplayLabel ?? rhs.displayLabel
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            let showsHierarchy = orderedFiles.contains {
                $0.runtimeOnly && $0.gatewayProjectDisplayLabel != nil
            }
            return GatewayAccountFamily(
                id: "\(group.providerID):account:\(accountKey)",
                accountLabel: orderedFiles.first?.gatewayAccountDisplayLabel ?? accountKey,
                files: orderedFiles,
                showsProjectHierarchy: showsHierarchy
            )
        }
        .sorted {
            $0.accountLabel.localizedStandardCompare($1.accountLabel) == .orderedAscending
        }
    }

    /// All human-facing accounts across providers. Project records belonging
    /// to the same login count once, matching what the user actually added.
    static func accountFamilies(in files: [CLIProxyAuthFile]) -> [GatewayAccountFamily] {
        Dictionary(grouping: files, by: \.gatewayProviderID)
            .flatMap { providerID, providerFiles in
                accountFamilies(in: GatewayAccountGroup(providerID: providerID, files: providerFiles))
            }
    }

    static func linkedCandidateByAuthFileName(
        manager: CLIProxyGatewayManager
    ) -> [String: CLIProxyAccountSyncCandidate] {
        let candidatesByIdentity = manager.syncCandidates.reduce(
            into: [String: CLIProxyAccountSyncCandidate]()
        ) { result, candidate in
            result["\(candidate.providerId.lowercased()):\(candidate.credentialId.lowercased())"] = candidate
        }
        var result: [String: CLIProxyAccountSyncCandidate] = [:]
        for record in manager.syncRecords {
            let identity = "\(record.providerId.lowercased()):\(record.credentialId.lowercased())"
            if let candidate = candidatesByIdentity[identity] {
                result[record.authFileName.lowercased()] = candidate
            }
        }
        for candidate in manager.syncCandidates {
            let fileName = manager.authFileName(for: candidate).lowercased()
            if result[fileName] == nil { result[fileName] = candidate }
        }
        return result
    }

    static func modelCountsByAuthFileName(manager: CLIProxyGatewayManager) -> [String: Int] {
        manager.authFiles.reduce(into: [String: Int]()) { result, file in
            if let count = manager.cachedModelCount(for: file) {
                result[file.name.lowercased()] = count
            }
        }
    }

    static func modelErrorNames(manager: CLIProxyGatewayManager) -> Set<String> {
        Set(manager.authFileModelErrors.keys.map { $0.lowercased() })
    }

    static func reachableAccountCount(
        in files: [CLIProxyAuthFile],
        modelCountsByAuthFileName: [String: Int] = [:],
        modelErrorsByAuthFileName: Set<String> = []
    ) -> Int {
        accountFamilies(in: files).filter { family in
            family.files.contains { file in
                isReachable(
                    file,
                    modelCount: modelCountsByAuthFileName[file.name.lowercased()],
                    modelLoadFailed: modelErrorsByAuthFileName.contains(file.name.lowercased())
                )
            }
        }.count
    }

    static func coolingAccountCount(
        in files: [CLIProxyAuthFile],
        modelErrorsByAuthFileName: Set<String> = []
    ) -> Int {
        accountFamilies(in: files).filter { family in
            family.files.contains { file in
                !modelErrorsByAuthFileName.contains(file.name.lowercased()) && isCooling(file)
            }
        }.count
    }

    static func pausedAccountCount(in files: [CLIProxyAuthFile]) -> Int {
        accountFamilies(in: files).filter { family in
            family.files.allSatisfy(\.disabled)
        }.count
    }

    static func attentionAccountCount(
        in files: [CLIProxyAuthFile],
        deduplicationConflicts: Int,
        hasSyncManifestError: Bool,
        modelErrorsByAuthFileName: Set<String> = []
    ) -> Int {
        accountFamilies(in: files).filter { family in
            family.files.contains { file in
                fileNeedsAttention(
                    file,
                    modelLoadFailed: modelErrorsByAuthFileName.contains(file.name.lowercased())
                )
            }
        }.count
            + deduplicationConflicts
            + (hasSyncManifestError ? 1 : 0)
    }

    static func managedAccountCount(in files: [CLIProxyAuthFile]) -> Int {
        accountFamilies(in: files).filter { family in
            family.files.contains { $0.name.lowercased().hasPrefix("aiusage-") }
        }.count
    }

    static func unsyncedCandidateCount(manager: CLIProxyGatewayManager) -> Int {
        manager.syncCandidates.filter { candidate in
            guard case .compatible = candidate.compatibility else { return false }
            return !manager.isSynced(candidate)
        }.count
    }

    /// 套餐 / 账号类型轻量标签文案（列表 badge 用）。
    static func planBadgeText(
        file: CLIProxyAuthFile,
        identity: CLIProxyAccountIdentity?
    ) -> String? {
        let technicalTypes = ["oauth", "runtime", "plugin", "credential", "auth"]
        if let plan = identity?.planDisplayName, !plan.isEmpty {
            return technicalTypes.contains(plan.lowercased()) ? nil : plan
        }
        if let type = file.accountType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !type.isEmpty {
            if technicalTypes.contains(type.lowercased()) { return nil }
            if ["openai-compatible", "openai_compatible"].contains(type.lowercased()) {
                return "OpenAI Compatible"
            }
            return type.capitalized
        }
        return nil
    }

}

enum GatewayAccountNote {
    /// 过滤系统自动写入的备注；用户备注原样返回。
    static func visible(_ raw: String?) -> String? {
        guard let note = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        let normalized = note.lowercased()
        if normalized == "synced from aiusage" || normalized == "来自 aiusage 的同步副本" {
            return nil
        }
        return note
    }
}

extension CLIProxyAuthFile {
    /// The real login identity used as the parent label for project-expanded
    /// provider records.
    var gatewayAccountDisplayLabel: String {
        for candidate in [email, account] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        if let value = label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            if let separator = value.range(of: " / ") {
                let accountPart = String(value[..<separator.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !accountPart.isEmpty { return accountPart }
            }
            return value
        }
        return name
    }

    /// Project or runtime discriminator returned by CPA. Gemini CLI normally
    /// supplies `project_id`; older plugin responses embed it in `label`.
    var gatewayProjectDisplayLabel: String? {
        if let value = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        guard let value = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        for accountLabel in [email, account].compactMap({ $0 }) {
            let prefix = "\(accountLabel) / "
            if value.lowercased().hasPrefix(prefix.lowercased()) {
                let projectPart = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !projectPart.isEmpty { return projectPart }
            }
        }
        return runtimeOnly && value.caseInsensitiveCompare(gatewayAccountDisplayLabel) != .orderedSame
            ? value
            : nil
    }

    var gatewayVisibleNote: String? {
        GatewayAccountNote.visible(note)
    }
}
