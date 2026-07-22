import Foundation

/// Defines which managed-auth directory one app bundle may read and mutate.
///
/// Production keeps the historical `AuthImports` directory. Debug and test
/// hosts get a bundle-specific directory, may discover production imports for
/// recovery, but can never mutate those production files.
public struct ManagedAuthImportBoundary: Sendable, Equatable {
    public static let productionBundleIdentifier = "com.aiusage.desktop"

    public let bundleIdentifier: String
    public let applicationSupportDirectory: URL

    public init(bundleIdentifier: String, applicationSupportDirectory: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var isProductionBundle: Bool {
        bundleIdentifier == Self.productionBundleIdentifier
    }

    public var productionRootURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("AuthImports", isDirectory: true)
    }

    public var activeRootURL: URL {
        guard !isProductionBundle else { return productionRootURL }
        return applicationSupportDirectory
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("AuthImports-\(bundleIdentifier)", isDirectory: true)
    }

    public var readableRootURLs: [URL] {
        isProductionBundle ? [productionRootURL] : [activeRootURL, productionRootURL]
    }

    /// Returns a canonical path only when it belongs to a root this bundle may read.
    public func readableManagedPath(_ rawPath: String) -> String? {
        canonicalManagedPath(rawPath, roots: readableRootURLs)
    }

    /// Returns a canonical path only when this bundle is allowed to mutate it.
    public func writableManagedPath(_ rawPath: String) -> String? {
        canonicalManagedPath(rawPath, roots: [activeRootURL])
    }

    /// A Debug build must never be emitted with the production bundle identifier.
    public static func isBundleIdentityValid(
        bundleIdentifier: String,
        isDebugBuild: Bool
    ) -> Bool {
        !isDebugBuild || bundleIdentifier != productionBundleIdentifier
    }

    private func canonicalManagedPath(_ rawPath: String, roots: [URL]) -> String? {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard roots.contains(where: { Self.contains(candidate, under: $0) }) else {
            return nil
        }
        return candidate.path
    }

    private static func contains(_ candidate: URL, under root: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
