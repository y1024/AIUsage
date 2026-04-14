import Foundation
import QuotaBackend

enum ProviderManagedImportStore {
    private static let rootPathComponent = "/Library/Application Support/AIUsage/AuthImports/"

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
        guard let rootDirectory = try? managedImportsRootDirectory(),
              FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return
        }

        let referencedPaths = Set(credentials.flatMap { managedImportPaths(for: $0) })
        guard !referencedPaths.isEmpty else { return }
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

    private static func replaceManagedImport(at targetPath: String, withContentsOf sourcePath: String) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: targetURL, options: .atomic)
    }

    private static func removeManagedImport(at path: String) {
        guard let managedPath = canonicalManagedPath(path) else { return }
        try? FileManager.default.removeItem(atPath: managedPath)
    }

    private static func managedImportsRootDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("AuthImports", isDirectory: true)
    }

    private static func canonicalManagedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfBlank else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return canonical.contains(rootPathComponent) ? canonical : nil
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
