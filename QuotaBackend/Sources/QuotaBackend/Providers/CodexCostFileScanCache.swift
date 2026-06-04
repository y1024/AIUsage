import Foundation

actor CodexCostFileScanCache {
    // v6: Codex JSONL 由“订阅/rate_limits”改为“非代理 token”轨，旧缓存标签必须重解析。
    static let artifactVersion = 6
    var entriesByFile: [String: CodexParsedFile] = [:]
    var hasLoadedDiskCache = false

    func entries(matching fingerprintsByFile: [String: CodexFileFingerprint]) -> [String: CodexParsedFile] {
        loadDiskCacheIfNeeded()

        var matching: [String: CodexParsedFile] = [:]
        for (file, fingerprint) in fingerprintsByFile {
            guard let entry = entriesByFile[file],
                  entry.fingerprint == fingerprint else {
                continue
            }
            matching[file] = entry
        }
        return matching
    }

    func store(_ updates: [String: CodexParsedFile], keeping validFiles: Set<String>) {
        loadDiskCacheIfNeeded()

        entriesByFile = entriesByFile.filter { validFiles.contains($0.key) }
        for (file, entry) in updates {
            entriesByFile[file] = entry
        }
        saveDiskCache()
    }

    func loadDiskCacheIfNeeded() {
        guard !hasLoadedDiskCache else { return }
        hasLoadedDiskCache = true

        let url = Self.cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexCostPersistentCache.self, from: data),
              decoded.version == Self.artifactVersion else {
            entriesByFile = [:]
            return
        }
        entriesByFile = decoded.files
    }

    func saveDiskCache() {
        let url = Self.cacheFileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cache = CodexCostPersistentCache(version: Self.artifactVersion, files: entriesByFile)
            let encoder = JSONEncoder()
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort cache: stale or missing cache should never break token stats.
        }
    }

    static func cacheFileURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("codex-cost-file-cache-v\(artifactVersion).json")
    }
}
