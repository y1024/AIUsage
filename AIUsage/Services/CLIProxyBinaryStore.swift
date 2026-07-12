import CryptoKit
import Darwin
import Foundation

nonisolated protocol CLIProxyBinaryExtracting: Sendable {
    func extractBinary(from archiveURL: URL, assetName: String, to destinationURL: URL) throws
}

nonisolated protocol CLIProxyBinarySigning: Sendable {
    func sign(binaryAt url: URL) throws
}

nonisolated protocol CLIProxyBinaryValidating: Sendable {
    func validate(binaryAt url: URL, architecture: CLIProxyArchitecture) async throws
}

nonisolated struct CLIProxySecureArchiveExtractor: CLIProxyBinaryExtracting {
    func extractBinary(from archiveURL: URL, assetName: String, to destinationURL: URL) throws {
        let lowercasedName = assetName.lowercased()
        if lowercasedName.hasSuffix(".tar.gz") || lowercasedName.hasSuffix(".tgz") {
            try extractFromTarGzip(archiveURL, to: destinationURL)
            return
        }
        guard lowercasedName == "cliproxyapi" else {
            throw CLIProxyGatewayError.unsafeArchive("unsupported asset format")
        }
        try FileManager.default.copyItem(at: archiveURL, to: destinationURL)
    }

    private func extractFromTarGzip(_ archiveURL: URL, to destinationURL: URL) throws {
        let listing = try CLIProxyCommand.capture(
            executable: "/usr/bin/tar",
            arguments: ["-tzf", archiveURL.path]
        )
        guard listing.status == 0 else {
            throw CLIProxyGatewayError.extractionFailed(listing.output)
        }

        let entries = listing.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else {
            throw CLIProxyGatewayError.unsafeArchive("archive is empty")
        }
        for entry in entries {
            try validateArchiveEntry(entry)
        }

        let allowedBinaryNames = Set(["cliproxyapi", "cli-proxy-api"])
        let candidates = entries.filter { entry in
            !entry.hasSuffix("/")
                && allowedBinaryNames.contains(URL(fileURLWithPath: entry).lastPathComponent.lowercased())
        }
        guard candidates.count == 1, let binaryEntry = candidates.first else {
            throw CLIProxyGatewayError.unsafeArchive("expected exactly one recognized CLIProxyAPI binary")
        }

        let verbose = try CLIProxyCommand.capture(
            executable: "/usr/bin/tar",
            arguments: ["-tvzf", archiveURL.path, binaryEntry]
        )
        guard verbose.status == 0 else {
            throw CLIProxyGatewayError.extractionFailed(verbose.output)
        }
        guard verbose.output.trimmingCharacters(in: .whitespacesAndNewlines).first == "-" else {
            throw CLIProxyGatewayError.unsafeArchive("CLIProxyAPI entry is not a regular file")
        }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOzf", archiveURL.path, binaryEntry]
        process.standardOutput = outputHandle
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw CLIProxyGatewayError.extractionFailed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "tar extraction failed"
            throw CLIProxyGatewayError.extractionFailed(message)
        }
    }

    private func validateArchiveEntry(_ entry: String) throws {
        guard !entry.hasPrefix("/"), !entry.contains("\0") else {
            throw CLIProxyGatewayError.unsafeArchive("absolute or invalid path")
        }
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }) else {
            throw CLIProxyGatewayError.unsafeArchive("path traversal entry")
        }
    }
}

nonisolated struct CLIProxyAdHocSigner: CLIProxyBinarySigning {
    func sign(binaryAt url: URL) throws {
        let result = try CLIProxyCommand.capture(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--timestamp=none", url.path]
        )
        guard result.status == 0 else {
            throw CLIProxyGatewayError.signingFailed(result.output)
        }
    }
}

nonisolated struct CLIProxyDefaultBinaryValidator: CLIProxyBinaryValidating {
    func validate(binaryAt url: URL, architecture: CLIProxyArchitecture) async throws {
        let architectureResult = try CLIProxyCommand.capture(
            executable: "/usr/bin/lipo",
            arguments: ["-archs", url.path]
        )
        guard architectureResult.status == 0,
              architectureResult.output
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .contains(architecture.lipoToken) else {
            throw CLIProxyGatewayError.incompatibleBinary(
                "expected \(architecture.lipoToken), got \(architectureResult.output)"
            )
        }

        let signatureResult = try CLIProxyCommand.capture(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", url.path]
        )
        guard signatureResult.status == 0 else {
            throw CLIProxyGatewayError.signingFailed(signatureResult.output)
        }

        try await dryRun(binaryAt: url)
    }

    private func dryRun(binaryAt binaryURL: URL) async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AIUsage-CLIProxy-DryRun-\(UUID().uuidString)", isDirectory: true)
        let authDirectory = directory.appendingPathComponent("auth", isDirectory: true)
        let configURL = directory.appendingPathComponent("config.yaml", isDirectory: false)
        let port = try CLIProxyPortReservation.availableLoopbackPort()

        do {
            try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authDirectory.path)
            let config = """
            host: "127.0.0.1"
            port: \(port)
            auth-dir: \(yamlQuoted(authDirectory.path))
            api-keys:
              - "aiusage-dry-run"
            remote-management:
              allow-remote: false
              secret-key: ""
              disable-control-panel: true
            plugins:
              enabled: false
            debug: false
            logging-to-file: false
            usage-statistics-enabled: false
            """
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw CLIProxyGatewayError.dryRunFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-config", configURL.path]
        process.currentDirectoryURL = binaryURL.deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: directory)
            throw CLIProxyGatewayError.dryRunFailed(error.localizedDescription)
        }

        defer {
            terminate(process)
            try? fileManager.removeItem(at: directory)
        }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/healthz")!
        let deadline = Date().addingTimeInterval(10)
        var lastError = "health endpoint did not become ready"
        while Date() < deadline, process.isRunning {
            var request = URLRequest(url: endpoint, timeoutInterval: 0.7)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                lastError = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        if !process.isRunning {
            lastError = "process exited with status \(process.terminationStatus)"
        }
        throw CLIProxyGatewayError.dryRunFailed(lastError)
    }

    private func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

actor CLIProxyBinaryStore {
    private let paths: CLIProxyPaths
    private let fileManager: FileManager
    private let extractor: any CLIProxyBinaryExtracting
    private let signer: any CLIProxyBinarySigning
    private let validator: any CLIProxyBinaryValidating

    init(
        paths: CLIProxyPaths,
        fileManager: FileManager = .default,
        extractor: any CLIProxyBinaryExtracting = CLIProxySecureArchiveExtractor(),
        signer: any CLIProxyBinarySigning = CLIProxyAdHocSigner(),
        validator: any CLIProxyBinaryValidating = CLIProxyDefaultBinaryValidator()
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.extractor = extractor
        self.signer = signer
        self.validator = validator
    }

    func currentVersion() throws -> String? {
        try paths.prepare(fileManager: fileManager)
        let destination: String
        do {
            destination = try fileManager.destinationOfSymbolicLink(atPath: paths.currentSymlink.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        } catch {
            if !fileManager.fileExists(atPath: paths.currentSymlink.path) { return nil }
            throw CLIProxyGatewayError.fileSystem(error.localizedDescription)
        }
        let name = URL(fileURLWithPath: destination).lastPathComponent
        guard name.hasPrefix("v") else { return nil }
        let version = String(name.dropFirst())
        return CLIProxyVersion.isSafePathComponent(version) ? version : nil
    }

    func currentBinaryURL() throws -> URL? {
        guard try currentVersion() != nil else { return nil }
        let binaryURL = paths.currentSymlink.appendingPathComponent(paths.binaryName)
        return fileManager.fileExists(atPath: binaryURL.path) ? binaryURL : nil
    }

    func installedVersions() throws -> [CLIProxyInstalledVersion] {
        try paths.prepare(fileManager: fileManager)
        let current = try currentVersion()
        let contents = try fileManager.contentsOfDirectory(
            at: paths.versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { directory in
            let name = directory.lastPathComponent
            guard name.hasPrefix("v") else { return nil }
            let version = String(name.dropFirst())
            guard CLIProxyVersion.isSafePathComponent(version) else { return nil }
            let binaryURL = directory.appendingPathComponent(paths.binaryName)
            guard fileManager.fileExists(atPath: binaryURL.path) else { return nil }
            let values = try? directory.resourceValues(forKeys: [.creationDateKey])
            return CLIProxyInstalledVersion(
                version: version,
                binaryURL: binaryURL,
                installedAt: values?.creationDate ?? .distantPast,
                isCurrent: version == current
            )
        }
        .sorted { lhs, rhs in
            let comparison = CLIProxyVersion.compare(lhs.version, rhs.version)
            if comparison == .orderedSame { return lhs.installedAt > rhs.installedAt }
            return comparison == .orderedDescending
        }
    }

    func install(
        downloadedAssetURL: URL,
        release: CLIProxyRelease,
        architecture: CLIProxyArchitecture = .current
    ) async throws -> CLIProxyInstalledVersion {
        try paths.prepare(fileManager: fileManager)
        let archiveData = try Data(contentsOf: downloadedAssetURL, options: [.mappedIfSafe])
        let actualDigest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == release.sha256.lowercased() else {
            throw CLIProxyGatewayError.checksumMismatch(expected: release.sha256, actual: actualDigest)
        }

        let finalDirectory = try paths.versionDirectory(release.version)
        let finalBinary = finalDirectory.appendingPathComponent(paths.binaryName)
        if fileManager.fileExists(atPath: finalBinary.path) {
            let current = try currentVersion()
            return CLIProxyInstalledVersion(
                version: release.version,
                binaryURL: finalBinary,
                installedAt: (try? finalDirectory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                isCurrent: current == release.version
            )
        }
        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.removeItem(at: finalDirectory)
        }

        let stagingDirectory = paths.versionsDirectory
            .appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let stagingBinary = stagingDirectory.appendingPathComponent(paths.binaryName)
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
            try extractor.extractBinary(
                from: downloadedAssetURL,
                assetName: release.assetName,
                to: stagingBinary
            )
            let resourceValues = try stagingBinary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true,
                  resourceValues.isSymbolicLink != true,
                  (resourceValues.fileSize ?? 0) > 0 else {
                throw CLIProxyGatewayError.incompatibleBinary("extracted payload is not a regular non-empty file")
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingBinary.path)
            try signer.sign(binaryAt: stagingBinary)
            try await validator.validate(binaryAt: stagingBinary, architecture: architecture)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }

        return CLIProxyInstalledVersion(
            version: release.version,
            binaryURL: finalBinary,
            installedAt: Date(),
            isCurrent: false
        )
    }

    @discardableResult
    func activate(version: String) throws -> String? {
        try paths.prepare(fileManager: fileManager)
        let previous = try currentVersion()
        let versionDirectory = try paths.versionDirectory(version)
        let binaryURL = versionDirectory.appendingPathComponent(paths.binaryName)
        guard fileManager.fileExists(atPath: binaryURL.path) else {
            throw CLIProxyGatewayError.versionNotInstalled(version)
        }

        let temporaryLink = paths.root.appendingPathComponent(".current-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryLink) }
        try fileManager.createSymbolicLink(
            atPath: temporaryLink.path,
            withDestinationPath: "versions/v\(CLIProxyVersion.normalized(version))"
        )
        guard Darwin.rename(temporaryLink.path, paths.currentSymlink.path) == 0 else {
            throw CLIProxyGatewayError.fileSystem(String(cString: strerror(errno)))
        }
        return previous
    }

    func delete(version: String) throws {
        if try currentVersion() == version {
            throw CLIProxyGatewayError.cannotDeleteCurrentVersion
        }
        let directory = try paths.versionDirectory(version)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func cleanup(keeping limit: Int = 3) throws {
        let keepCount = max(limit, 2)
        let versions = try installedVersions()
        let removable = versions.filter { !$0.isCurrent }.dropFirst(max(keepCount - 1, 1))
        for version in removable {
            try? delete(version: version.version)
        }
    }
}

nonisolated private enum CLIProxyCommand {
    struct Result {
        let status: Int32
        let output: String
    }

    static func capture(executable: String, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw CLIProxyGatewayError.fileSystem(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

nonisolated private enum CLIProxyPortReservation {
    static func availableLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CLIProxyGatewayError.dryRunFailed("could not create port reservation socket")
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw CLIProxyGatewayError.dryRunFailed("could not reserve a loopback port")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw CLIProxyGatewayError.dryRunFailed("could not resolve the dry-run port")
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
