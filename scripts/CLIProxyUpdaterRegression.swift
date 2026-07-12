import CryptoKit
import Darwin
import Foundation

nonisolated private struct NoopSigner: CLIProxyBinarySigning {
    func sign(binaryAt url: URL) throws {}
}

nonisolated private struct NoopValidator: CLIProxyBinaryValidating {
    func validate(binaryAt url: URL, architecture: CLIProxyArchitecture) async throws {}
}

@main
struct CLIProxyUpdaterRegression {
    static func main() async throws {
        try testReleaseSelection()
        try testVersionRules()
        try testRuntimeConfiguration()
        try testCredentialAdapters()
        try await testVersionedInstallAndRollback()
        try testDuplicateBinaryArchiveIsRejected()
        if CommandLine.arguments.contains("--live") {
            try await testLatestOfficialReleaseEndToEnd()
        }
        print("CLIProxy updater regression passed")
    }

    private static func testReleaseSelection() throws {
        let digest = String(repeating: "a", count: 64)
        let json = """
        {
          "tag_name": "v7.2.67",
          "name": "v7.2.67",
          "body": "release notes",
          "prerelease": false,
          "published_at": "2026-07-11T19:29:42Z",
          "assets": [
            {
              "name": "CLIProxyAPI_7.2.67_darwin_aarch64_no-plugin.tar.gz",
              "browser_download_url": "https://example.invalid/no-plugin.tar.gz",
              "digest": "sha256:\(digest)",
              "size": 1
            },
            {
              "name": "CLIProxyAPI_7.2.67_darwin_aarch64.tar.gz",
              "browser_download_url": "https://example.invalid/full.tar.gz",
              "digest": "sha256:\(digest)",
              "size": 123
            },
            {
              "name": "CLIProxyAPI_7.2.67_darwin_amd64.tar.gz",
              "browser_download_url": "https://example.invalid/intel.tar.gz",
              "digest": "sha256:\(digest)",
              "size": 456
            }
          ]
        }
        """
        let release = try CLIProxyReleaseClient.decodeRelease(Data(json.utf8), architecture: .arm64)
        try expect(release.version == "7.2.67", "version prefix was not normalized")
        try expect(release.assetName == "CLIProxyAPI_7.2.67_darwin_aarch64.tar.gz", "full plugin asset was not selected")
        try expect(release.size == 123, "wrong architecture asset selected")
    }

    private static func testVersionRules() throws {
        try expect(CLIProxyVersion.isNewer("7.2.67", than: "7.2.9"), "semantic version comparison failed")
        try expect(CLIProxyVersion.compare("v7.2.67", "7.2.67") == .orderedSame, "v prefix normalization failed")
        try expect(!CLIProxyVersion.isSafePathComponent("../7.2.67"), "path traversal version was accepted")
        try expect(!CLIProxyVersion.isSafePathComponent("7.2.67/evil"), "nested version path was accepted")
    }

    private static func testRuntimeConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsage-CPA-Config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try CLIProxyPaths(root: root)
        let store = CLIProxyConfigStore(paths: paths)
        var settings = CLIProxyGatewaySettings.default
        settings.port = 14_420
        settings.routingStrategy = .fillFirst
        settings.requestRetry = 4
        settings.proxyURL = "http://127.0.0.1:7890/\"quoted"
        settings.enablePlugins = true
        try store.saveSettings(settings)
        try store.writeRuntimeConfig(
            settings: settings,
            secrets: CLIProxySecrets(managementKey: "management-secret", clientAPIKey: "client-secret")
        )
        try expect(store.loadSettings() == settings, "gateway settings did not round-trip")
        let config = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(config.contains("strategy: \"fill-first\""), "routing strategy was not generated")
        try expect(config.contains("request-retry: 4"), "retry count was not generated")
        try expect(config.contains("management-secret"), "management secret was not generated")
        try expect(config.contains("client-secret"), "client key was not generated")
        try expect(config.contains("\\\"quoted"), "YAML string was not escaped")
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.configURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        try expect(permissions == 0o600, "runtime config permissions are not 0600")
    }

    private static func testCredentialAdapters() throws {
        let codex = Data(#"{"tokens":{"access_token":"access","refresh_token":"refresh","id_token":"id","account_id":"account"}}"#.utf8)
        let converted = try CLIProxyCredentialAdapter.convert(
            providerId: "codex",
            credentialId: "credential-1",
            accountLabel: "user@example.com",
            metadata: [:],
            sourceData: codex
        )
        let object = try JSONSerialization.jsonObject(with: converted) as? [String: Any]
        try expect(object?["type"] as? String == "codex", "Codex adapter did not set CPA type")
        try expect(object?["access_token"] as? String == "access", "Codex adapter did not flatten access token")
        try expect(object?["refresh_token"] as? String == "refresh", "Codex adapter did not flatten refresh token")
        try expect(object?["aiusage_credential_id"] as? String == "credential-1", "adapter linkage marker is missing")

        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "gemini",
                credentialId: "credential-2",
                accountLabel: nil,
                metadata: [:],
                sourceData: codex
            )
            throw RegressionFailure("unknown credential adapter was accepted")
        } catch is CLIProxyGatewayError {}

        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "antigravity",
                credentialId: "credential-3",
                accountLabel: nil,
                metadata: [:],
                sourceData: Data(#"{"access_token":"access"}"#.utf8)
            )
            throw RegressionFailure("credential without refresh token was accepted")
        } catch is CLIProxyGatewayError {}
    }

    private static func testVersionedInstallAndRollback() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("AIUsage-CPA-Test-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = try makeArchive(root: root, duplicateBinary: false)
        let digest = try sha256(of: archive)
        let paths = try CLIProxyPaths(root: root.appendingPathComponent("store"))
        let store = CLIProxyBinaryStore(
            paths: paths,
            extractor: CLIProxySecureArchiveExtractor(),
            signer: NoopSigner(),
            validator: NoopValidator()
        )

        let firstRelease = makeRelease(version: "7.2.66", archive: archive, digest: digest)
        _ = try await store.install(downloadedAssetURL: archive, release: firstRelease)
        let currentBeforePromotion = try await store.currentVersion()
        try expect(currentBeforePromotion == nil, "install changed current before promotion")
        _ = try await store.activate(version: firstRelease.version)
        let firstCurrent = try await store.currentVersion()
        try expect(firstCurrent == firstRelease.version, "first promotion failed")

        let invalidRelease = makeRelease(
            version: "7.2.66.1",
            archive: archive,
            digest: String(repeating: "0", count: 64)
        )
        do {
            _ = try await store.install(downloadedAssetURL: archive, release: invalidRelease)
            throw RegressionFailure("checksum mismatch was accepted")
        } catch is CLIProxyGatewayError {
            let currentAfterFailedInstall = try await store.currentVersion()
            try expect(currentAfterFailedInstall == firstRelease.version, "failed install changed the active version")
        }

        let secondRelease = makeRelease(version: "7.2.67", archive: archive, digest: digest)
        _ = try await store.install(downloadedAssetURL: archive, release: secondRelease)
        let previous = try await store.activate(version: secondRelease.version)
        try expect(previous == firstRelease.version, "previous version was not reported")
        let secondCurrent = try await store.currentVersion()
        try expect(secondCurrent == secondRelease.version, "second promotion failed")

        let installed = try await store.installedVersions()
        try expect(installed.count == 2, "versioned storage did not retain rollback version")
        try expect(installed.first(where: { $0.version == secondRelease.version })?.isCurrent == true, "active version flag is wrong")

        _ = try await store.activate(version: firstRelease.version)
        let rolledBackCurrent = try await store.currentVersion()
        try expect(rolledBackCurrent == firstRelease.version, "rollback activation failed")
        try await store.delete(version: secondRelease.version)
        let remainingVersions = try await store.installedVersions()
        try expect(remainingVersions.count == 1, "old version deletion failed")
    }

    private static func testDuplicateBinaryArchiveIsRejected() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("AIUsage-CPA-Duplicate-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = try makeArchive(root: root, duplicateBinary: true)
        let destination = root.appendingPathComponent("output")
        do {
            try CLIProxySecureArchiveExtractor().extractBinary(
                from: archive,
                assetName: archive.lastPathComponent,
                to: destination
            )
            throw RegressionFailure("duplicate CLIProxyAPI archive was accepted")
        } catch is CLIProxyGatewayError {
            // Expected.
        }
    }

    private static func testLatestOfficialReleaseEndToEnd() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("AIUsage-CPA-Live-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let release = try await CLIProxyReleaseClient().latestStableRelease()
        let downloaded = try await CLIProxyAssetDownloader().download(release)
        defer { try? fileManager.removeItem(at: downloaded.cleanupDirectory) }

        let paths = try CLIProxyPaths(root: root)
        let store = CLIProxyBinaryStore(paths: paths)
        _ = try await store.install(downloadedAssetURL: downloaded.fileURL, release: release)
        _ = try await store.activate(version: release.version)
        let current = try await store.currentVersion()
        try expect(current == release.version, "live official release was not activated")
        let binaryURL = try await store.currentBinaryURL()
        try expect(binaryURL != nil, "live official binary is missing")
        guard let binaryURL else { throw RegressionFailure("live binary URL was nil") }

        let port = try availableLoopbackPort()
        let settings = CLIProxyGatewaySettings(
            port: port,
            autoStart: false,
            routingStrategy: .roundRobin,
            requestRetry: 2,
            proxyURL: "",
            enablePlugins: false
        )
        let secrets = CLIProxySecrets(
            managementKey: "live-management-\(UUID().uuidString)",
            clientAPIKey: "live-client-\(UUID().uuidString)"
        )
        try CLIProxyConfigStore(paths: paths).writeRuntimeConfig(settings: settings, secrets: secrets)
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-config", paths.configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForHealth(endpoint.appendingPathComponent("healthz"), process: process)
        let management = CLIProxyManagementClient(
            baseURL: endpoint,
            managementKey: secrets.managementKey,
            clientAPIKey: secrets.clientAPIKey
        )
        let authFiles = try await management.listAuthFiles()
        try expect(authFiles.isEmpty, "fresh live runtime unexpectedly contains auth files")
        let regressionName = "aiusage-regression.json"
        try await management.uploadAuthFile(
            data: Data(#"{"type":"codex","email":"regression@example.com","access_token":"placeholder"}"#.utf8),
            name: regressionName
        )
        var uploaded = try await management.listAuthFiles()
        try expect(uploaded.contains(where: { $0.name == regressionName }), "Management API auth upload was not listed")
        try await management.setDisabled(true, name: regressionName)
        uploaded = try await management.listAuthFiles()
        try expect(uploaded.first(where: { $0.name == regressionName })?.disabled == true, "Management API auth disable failed")
        try await management.deleteAuthFile(name: regressionName)
        uploaded = try await management.listAuthFiles()
        try expect(!uploaded.contains(where: { $0.name == regressionName }), "Management API auth delete failed")
        _ = try await management.availableModels()
        print("Verified official CLIProxyAPI v\(release.version) end to end")
    }

    private static func waitForHealth(_ url: URL, process: Process) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, process.isRunning {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RegressionFailure("live runtime health check failed")
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RegressionFailure("could not create socket") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw RegressionFailure("could not bind socket") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }) == 0 else { throw RegressionFailure("could not read socket port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func makeArchive(root: URL, duplicateBinary: Bool) throws -> URL {
        let fileManager = FileManager.default
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        let primaryDirectory = payload.appendingPathComponent("release", isDirectory: true)
        try fileManager.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
        try Data("test-binary".utf8).write(to: primaryDirectory.appendingPathComponent("CLIProxyAPI"))
        if duplicateBinary {
            let duplicateDirectory = payload.appendingPathComponent("duplicate", isDirectory: true)
            try fileManager.createDirectory(at: duplicateDirectory, withIntermediateDirectories: true)
            try Data("duplicate".utf8).write(to: duplicateDirectory.appendingPathComponent("CLIProxyAPI"))
        }
        let archive = root.appendingPathComponent("CLIProxyAPI_test_darwin_aarch64.tar.gz")
        try run("/usr/bin/tar", ["-czf", archive.path, "-C", payload.path, "."])
        return archive
    }

    private static func makeRelease(version: String, archive: URL, digest: String) -> CLIProxyRelease {
        CLIProxyRelease(
            tagName: "v\(version)",
            version: version,
            assetName: archive.lastPathComponent,
            downloadURL: URL(string: "https://example.invalid/\(archive.lastPathComponent)")!,
            sha256: digest,
            size: (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "command failed: \(executable)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RegressionFailure(message) }
    }
}

nonisolated private struct RegressionFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
