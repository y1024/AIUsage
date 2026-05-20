import Foundation
import os.log

private let codexArchiveLog = Logger(subsystem: "com.aiusage.quotabackend", category: "CodexCostArchive")

actor CodexUsageArchiveStore {
    static let artifactVersion = 2
    static let defaultScopeID = "default"
    var archives: [String: CodexUsageArchive] = [:]
    var loadedScopes: Set<String> = []
    var fullHistoryImportRequests: Set<String> = []

    func requestFullHistoryImport(scope: String) {
        fullHistoryImportRequests.insert(scope)
    }

    func needsFullHistoryImport(scope: String) -> Bool {
        let archive = loadArchiveIfNeeded(scope: scope)
        return archive.fullHistoryImportedAt == nil
    }

    func consumeFullHistoryImportRequest(scope: String) -> Bool {
        let archive = loadArchiveIfNeeded(scope: scope)
        guard archive.fullHistoryImportedAt == nil else {
            fullHistoryImportRequests.remove(scope)
            return false
        }
        return fullHistoryImportRequests.remove(scope) != nil
    }

    func merge(
        scope: String,
        days: [String: CodexAggregateBucket],
        completedFullHistoryImport: Bool
    ) -> CodexUsageArchiveState {
        var archive = loadArchiveIfNeeded(scope: scope)

        var changed = false
        for (day, bucket) in days {
            guard bucket.usageRows > 0 else { continue }
            archive.days[day] = bucket
            changed = true
        }

        if completedFullHistoryImport {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
            changed = true
        }

        if changed {
            archive.updatedAt = SharedFormatters.iso8601String(from: Date())
            archives[scope] = archive
            saveDiskArchive(scope: scope, archive: archive)
        } else {
            archives[scope] = archive
        }

        return CodexUsageArchiveState(days: archive.days)
    }

    func loadArchiveIfNeeded(scope: String) -> CodexUsageArchive {
        if let archive = archives[scope], loadedScopes.contains(scope) {
            return archive
        }
        loadedScopes.insert(scope)

        let url = Self.archiveFileURL(scope: scope)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexUsageArchive.self, from: data),
              decoded.version == Self.artifactVersion else {
            let archive = CodexUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
            archives[scope] = archive
            return archive
        }
        archives[scope] = decoded
        return decoded
    }

    func saveDiskArchive(scope: String, archive: CodexUsageArchive) {
        let url = Self.archiveFileURL(scope: scope)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            let data = try encoder.encode(archive)
            try data.write(to: url, options: .atomic)
        } catch {
            codexArchiveLog.warning("Failed to save Codex usage archive: \(String(describing: error), privacy: .public)")
        }
    }

    static func archiveFileURL(scope: String) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let filename = scope == Self.defaultScopeID
            ? "codex-cost-usage-archive-v\(artifactVersion).json"
            : "codex-cost-usage-archive-v\(artifactVersion)-\(scopeHash(scope)).json"
        return root
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent(filename)
    }

    static func scopeHash(_ scope: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in scope.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
