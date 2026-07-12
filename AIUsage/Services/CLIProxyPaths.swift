import Foundation

nonisolated struct CLIProxyPaths: Sendable {
    let root: URL

    init(root: URL? = nil, fileManager: FileManager = .default) throws {
        if let root {
            self.root = root.standardizedFileURL
            return
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CLIProxyGatewayError.fileSystem("Application Support directory is unavailable.")
        }
        self.root = applicationSupport
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("CLIProxyAPI", isDirectory: true)
    }

    var versionsDirectory: URL { root.appendingPathComponent("versions", isDirectory: true) }
    var currentSymlink: URL { root.appendingPathComponent("current", isDirectory: false) }
    var authDirectory: URL { root.appendingPathComponent("auth", isDirectory: true) }
    var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var configURL: URL { root.appendingPathComponent("config.yaml", isDirectory: false) }
    var stateURL: URL { root.appendingPathComponent("state.json", isDirectory: false) }
    var binaryName: String { "CLIProxyAPI" }

    func versionDirectory(_ version: String) throws -> URL {
        guard CLIProxyVersion.isSafePathComponent(version) else {
            throw CLIProxyGatewayError.invalidRelease("unsafe version path component")
        }
        return versionsDirectory.appendingPathComponent("v\(CLIProxyVersion.normalized(version))", isDirectory: true)
    }

    func binaryURL(version: String) throws -> URL {
        try versionDirectory(version).appendingPathComponent(binaryName, isDirectory: false)
    }

    func prepare(fileManager: FileManager = .default) throws {
        for directory in [root, versionsDirectory, authDirectory, logsDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}
