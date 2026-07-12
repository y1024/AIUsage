import Foundation

nonisolated final class CLIProxyReleaseClient: @unchecked Sendable {
    static let repository = "router-for-me/CLIProxyAPI"

    private let session: URLSession
    private let apiBaseURL: URL

    init(
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.github.com")!
    ) {
        self.session = session
        self.apiBaseURL = apiBaseURL
    }

    func latestStableRelease(
        architecture: CLIProxyArchitecture = .current
    ) async throws -> CLIProxyRelease {
        let endpoint = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(Self.repository)
            .appendingPathComponent("releases")
            .appendingPathComponent("latest")
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage-CLIProxy-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CLIProxyGatewayError.network(error.localizedDescription)
        }
        try Self.validate(response: response)

        let release: CLIProxyGitHubRelease
        do {
            release = try Self.decoder.decode(CLIProxyGitHubRelease.self, from: data)
        } catch {
            throw CLIProxyGatewayError.invalidRelease(error.localizedDescription)
        }

        guard let selected = CLIProxyRelease(githubRelease: release, architecture: architecture) else {
            if release.hasFullMacOSAsset(for: architecture) {
                throw CLIProxyGatewayError.missingDigest
            }
            throw CLIProxyGatewayError.incompatibleAsset
        }
        return selected
    }

    static func decodeRelease(
        _ data: Data,
        architecture: CLIProxyArchitecture
    ) throws -> CLIProxyRelease {
        let githubRelease = try decoder.decode(CLIProxyGitHubRelease.self, from: data)
        guard let release = CLIProxyRelease(githubRelease: githubRelease, architecture: architecture) else {
            throw CLIProxyGatewayError.incompatibleAsset
        }
        return release
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    fileprivate static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyGatewayError.network("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CLIProxyGatewayError.invalidHTTPStatus(http.statusCode)
        }
    }
}

nonisolated struct CLIProxyDownloadedAsset: Sendable {
    let fileURL: URL
    let cleanupDirectory: URL
}

nonisolated final class CLIProxyAssetDownloader: @unchecked Sendable {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func download(_ release: CLIProxyRelease) async throws -> CLIProxyDownloadedAsset {
        var request = URLRequest(url: release.downloadURL, timeoutInterval: 300)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage-CLIProxy-Updater", forHTTPHeaderField: "User-Agent")

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw CLIProxyGatewayError.network(error.localizedDescription)
        }
        try CLIProxyReleaseClient.validate(response: response)

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AIUsage-CLIProxy-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(release.assetName, isDirectory: false)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fileManager.moveItem(at: temporaryURL, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw CLIProxyGatewayError.fileSystem(error.localizedDescription)
        }
        return CLIProxyDownloadedAsset(fileURL: destination, cleanupDirectory: directory)
    }
}
