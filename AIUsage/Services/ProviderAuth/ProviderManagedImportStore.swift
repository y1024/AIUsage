import Foundation
import QuotaBackend

enum ProviderManagedImportStore {
    /// 正式版沿用历史目录；Debug / 测试宿主使用隔离目录，避免共用 AuthImports
    /// 时「孤儿清理」按当前进程 Vault 删掉另一套安装的凭据文件。
    private static let productionRootMarker = "/Library/Application Support/AIUsage/AuthImports/"

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.aiusage.desktop"
    }

    private static var isProductionBundle: Bool {
        bundleID == "com.aiusage.desktop"
    }

    /// 当前进程写入/清理用的根目录标记。
    private static var activeRootMarker: String {
        if isProductionBundle { return productionRootMarker }
        return "/Library/Application Support/AIUsage/AuthImports-\(bundleID)/"
    }

    /// 识别「托管导入」路径时同时接受正式目录与当前隔离目录。
    private static var recognizedRootMarkers: [String] {
        if isProductionBundle { return [productionRootMarker] }
        return [productionRootMarker, activeRootMarker]
    }

    static func isManagedImportPath(_ path: String?) -> Bool {
        guard let path = path?.nilIfBlank else { return false }
        return canonicalManagedPath(path) != nil
    }

    static func primaryManagedImportPath(for credential: AccountCredential) -> String? {
        if credential.authMethod == .authFile,
           let credentialPath = canonicalManagedPath(credential.credential) {
            return credentialPath
        }

        return canonicalManagedPath(credential.metadata["sourcePath"])
    }

    static func managedImportPaths(for credential: AccountCredential) -> Set<String> {
        Set(
            [credential.credential, credential.metadata["sourcePath"]]
                .compactMap { canonicalManagedPath($0) }
        )
    }

    static func reuseManagedImportIfPossible(existingCredential: AccountCredential, incomingCredential: inout AccountCredential) {
        guard incomingCredential.authMethod == .authFile,
              let existingPath = primaryManagedImportPath(for: existingCredential),
              let incomingPath = primaryManagedImportPath(for: incomingCredential),
              existingPath != incomingPath else {
            return
        }

        do {
            try replaceManagedImport(at: existingPath, withContentsOf: incomingPath)
            removeManagedImport(at: incomingPath)
            let preservedLastUsedAt = incomingCredential.lastUsedAt

            if canonicalManagedPath(incomingCredential.credential) != nil {
                incomingCredential = AccountCredential(
                    id: incomingCredential.id,
                    providerId: incomingCredential.providerId,
                    accountLabel: incomingCredential.accountLabel,
                    authMethod: incomingCredential.authMethod,
                    credential: existingPath,
                    metadata: incomingCredential.metadata
                )
                incomingCredential.lastUsedAt = preservedLastUsedAt
            }

            if let sourcePath = incomingCredential.metadata["sourcePath"],
               canonicalManagedPath(sourcePath) == incomingPath {
                incomingCredential.metadata["sourcePath"] = existingPath
            }
        } catch {
            // If artifact reuse fails, keep the newer copied file and let
            // periodic orphan cleanup handle any stale leftovers.
        }
    }

    static func cleanupOrphanedManagedImports(referencedBy credentials: [AccountCredential]) {
        // 只扫描「当前进程自己的写入根」。Debug 绝不能清正式版 AuthImports。
        guard let rootDirectory = try? managedImportsRootDirectory(),
              FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return
        }

        let referencedPaths = Set(credentials.flatMap { managedImportPaths(for: $0) })
        guard !referencedPaths.isEmpty else { return }

        // Vault 与磁盘不同步时 fail closed：缺文件说明路径漂移或另一套安装刚写过，
        // 此时删「未引用」文件极易误伤仍在使用的副本。
        let missingReferenced = referencedPaths.contains { !FileManager.default.fileExists(atPath: $0) }
        if missingReferenced { return }

        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            if !referencedPaths.contains(path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        pruneEmptyDirectories(under: rootDirectory)
    }

    /// 当前进程应写入的 AuthImports 根目录。
    static func managedImportsRootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderName: String
        if isProductionBundle {
            folderName = "AuthImports"
        } else {
            folderName = "AuthImports-\(bundleID)"
        }
        return base
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// 读取补回时同时扫正式目录与当前隔离目录（Debug 仍能看到已恢复的历史文件）。
    static func readableImportRoots() -> [URL] {
        var roots: [URL] = []
        if let active = try? managedImportsRootDirectory() {
            roots.append(active)
        }
        if !isProductionBundle,
           let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
           ) {
            let legacy = base
                .appendingPathComponent("AIUsage", isDirectory: true)
                .appendingPathComponent("AuthImports", isDirectory: true)
            if legacy.path != roots.first?.path {
                roots.append(legacy)
            }
        }
        return roots
    }

    private static func replaceManagedImport(at targetPath: String, withContentsOf sourcePath: String) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: targetURL, options: .atomic)
    }

    private static func removeManagedImport(at path: String) {
        guard let managedPath = canonicalManagedPath(path) else { return }
        // 只允许删除落在当前写入根下的文件；历史共享目录留给正式版自己清理。
        guard managedPath.contains(activeRootMarker) else { return }
        try? FileManager.default.removeItem(atPath: managedPath)
    }

    private static func canonicalManagedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfBlank else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard recognizedRootMarkers.contains(where: { canonical.contains($0) }) else {
            return nil
        }
        return canonical
    }

    private static func pruneEmptyDirectories(under rootDirectory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return
        }

        let directories = enumerator.compactMap { $0 as? URL }
            .sorted { $0.path.count > $1.path.count }

        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  directory != rootDirectory,
                  let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ),
                  contents.isEmpty else {
                continue
            }

            try? FileManager.default.removeItem(at: directory)
        }
    }
}
