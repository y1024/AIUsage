import Foundation
import SwiftUI

// MARK: - Gateway Account List Models
// 账号中心列表的筛选、分组与派生计数。与具体行 UI 解耦，便于 AccountsView 保持编排职责。

enum GatewayAccountFilter: String, CaseIterable, Hashable {
    case all
    case ready
    case attention
    case paused
    case fromAIUsage

    var title: String {
        switch self {
        case .all: L("All", "全部")
        case .ready: L("Ready", "可用")
        case .attention: L("Attention", "异常")
        case .paused: L("Paused", "已停用")
        case .fromAIUsage: L("From AIUsage", "来自 AIUsage")
        }
    }
}

struct GatewayAccountGroup: Identifiable, Equatable {
    let providerID: String
    let files: [CLIProxyAuthFile]
    var id: String { providerID }
}

enum GatewayAccountListLogic {
    static func fileNeedsAttention(
        _ file: CLIProxyAuthFile,
        syncState: CLIProxyAccountSyncState? = nil
    ) -> Bool {
        if file.gatewayNeedsAttention { return true }
        if file.gatewayProviderID == "unknown" { return true }
        if let syncState, syncNeedsAttention(syncState) { return true }
        return false
    }

    static func filteredGroups(
        authFiles: [CLIProxyAuthFile],
        query: String,
        filter: GatewayAccountFilter,
        syncStatesByAuthFileName: [String: CLIProxyAccountSyncState] = [:]
    ) -> [GatewayAccountGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let files = authFiles.filter { file in
            let searchText = [file.displayLabel, file.displayProvider, file.name, file.note ?? ""]
                .joined(separator: " ").lowercased()
            let matchesSearch = normalizedQuery.isEmpty || searchText.contains(normalizedQuery)
            guard matchesSearch else { return false }
            let syncState = syncStatesByAuthFileName[file.name.lowercased()]
            switch filter {
            case .all: return true
            case .ready: return !file.disabled && !fileNeedsAttention(file, syncState: syncState)
            case .attention: return fileNeedsAttention(file, syncState: syncState)
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

    static func syncStatesByAuthFileName(manager: CLIProxyGatewayManager) -> [String: CLIProxyAccountSyncState] {
        let linked = linkedCandidateByAuthFileName(manager: manager)
        var result: [String: CLIProxyAccountSyncState] = [:]
        for (fileName, candidate) in linked {
            result[fileName] = manager.syncState(for: candidate)
        }
        return result
    }

    static func readyCount(
        in files: [CLIProxyAuthFile],
        syncStatesByAuthFileName: [String: CLIProxyAccountSyncState] = [:]
    ) -> Int {
        files.filter {
            !$0.disabled && !fileNeedsAttention($0, syncState: syncStatesByAuthFileName[$0.name.lowercased()])
        }.count
    }

    static func attentionCount(
        in files: [CLIProxyAuthFile],
        deduplicationConflicts: Int,
        hasSyncManifestError: Bool,
        syncStatesByAuthFileName: [String: CLIProxyAccountSyncState] = [:]
    ) -> Int {
        files.filter {
            fileNeedsAttention($0, syncState: syncStatesByAuthFileName[$0.name.lowercased()])
        }.count
            + deduplicationConflicts
            + (hasSyncManifestError ? 1 : 0)
    }

    static func managedCopyCount(in files: [CLIProxyAuthFile]) -> Int {
        files.filter { $0.name.lowercased().hasPrefix("aiusage-") }.count
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
        if let plan = identity?.planDisplayName, !plan.isEmpty { return plan }
        if let type = file.accountType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !type.isEmpty {
            return type.capitalized
        }
        return nil
    }

    /// 同步态是否需要在列表露出（最新态静默，避免双 pill 噪音）。
    static func syncNeedsAttention(_ state: CLIProxyAccountSyncState) -> Bool {
        switch state {
        case .current, .notSynced: return false
        case .sourceChanged, .cpaChanged, .conflict, .missing: return true
        }
    }
}

extension CLIProxyAuthFile {
    var gatewayVisibleNote: String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        let normalized = note.lowercased()
        if normalized == "synced from aiusage" || normalized == "来自 aiusage 的同步副本" {
            return nil
        }
        return note
    }
}
