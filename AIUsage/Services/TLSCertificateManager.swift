import Foundation
import os.log

// MARK: - TLS Certificate Manager
// Manages self-signed TLS certificates for the local HTTPS proxy.
// On first enable, generates a self-signed EC P-256 certificate using macOS's
// built-in LibreSSL (`openssl` CLI) and stores it at ~/.config/aiusage/tls/.
// The PKCS12 identity file is loaded by QuotaServer's NWListener for TLS.

@MainActor
final class TLSCertificateManager {
    static let shared = TLSCertificateManager()

    private let tlsDirectory: URL
    private let certPath: URL
    private let keyPath: URL
    private let identityPath: URL
    private static let identityPassword = "aiusage-proxy-tls"
    private let log = Logger(subsystem: "com.aiusage.desktop", category: "TLS")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/aiusage/tls")
        tlsDirectory = dir
        certPath = dir.appendingPathComponent("cert.pem")
        keyPath = dir.appendingPathComponent("key.pem")
        identityPath = dir.appendingPathComponent("identity.p12")
    }

    var identityFilePath: String { identityPath.path }

    var hasValidCertificate: Bool {
        FileManager.default.fileExists(atPath: identityPath.path)
    }

    func ensureCertificate() async throws {
        if hasValidCertificate { return }
        try await generateCertificate()
    }

    // MARK: - Certificate Generation

    private func generateCertificate() async throws {
        try FileManager.default.createDirectory(
            at: tlsDirectory, withIntermediateDirectories: true
        )

        try runProcess(
            executable: "/usr/bin/openssl",
            arguments: [
                "req", "-x509", "-newkey", "ec",
                "-pkeyopt", "ec_paramgen_curve:prime256v1",
                "-keyout", keyPath.path,
                "-out", certPath.path,
                "-days", "3650", "-nodes",
                "-subj", "/CN=AIUsage Local Proxy",
            ],
            errorContext: "generate certificate"
        )

        try runProcess(
            executable: "/usr/bin/openssl",
            arguments: [
                "pkcs12", "-export",
                "-out", identityPath.path,
                "-inkey", keyPath.path,
                "-in", certPath.path,
                "-passout", "pass:\(Self.identityPassword)",
            ],
            errorContext: "export PKCS12 identity"
        )

        log.info("Generated self-signed TLS certificate at \(self.tlsDirectory.path, privacy: .public)")
    }

    private func runProcess(executable: String, arguments: [String], errorContext: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TLSCertificateError.generationFailed(
                "\(errorContext): exit code \(process.terminationStatus)"
            )
        }
    }
}

// MARK: - Error

enum TLSCertificateError: LocalizedError {
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .generationFailed(let reason):
            return "TLS certificate generation failed: \(reason)"
        }
    }
}
