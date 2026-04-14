import Combine
import Foundation
import QuotaBackend

private final class WeakCodexCoordinatorBox: @unchecked Sendable {
    weak var value: CodexLoginCoordinator?

    init(_ value: CodexLoginCoordinator) {
        self.value = value
    }
}

@MainActor
final class CodexLoginCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case launching
        case waitingForBrowser
        case waitingForCompletion
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var authURL: URL?
    @Published private(set) var callbackURL: URL?
    @Published private(set) var outputSummary: String?
    @Published private(set) var importedAuthFileURL: URL?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var outputBuffer = ""
    private var didSeeAuthURL = false
    private var sessionDirectoryURL: URL?
    private var completionTask: Task<Void, Never>?
    private var hasCompletedLogin = false
    private var loginStartedAt: Date?
    private var baselineCandidateSignatures: Set<String> = []

    var isRunning: Bool {
        switch phase {
        case .launching, .waitingForBrowser, .waitingForCompletion:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    func start() {
        cancel()

        phase = .launching
        authURL = nil
        callbackURL = nil
        outputSummary = nil
        importedAuthFileURL = nil
        outputBuffer = ""
        didSeeAuthURL = false
        hasCompletedLogin = false
        loginStartedAt = Date()
        baselineCandidateSignatures = Set(ProviderAuthManager.codexCandidates().map(Self.candidateSignature(for:)))
        completionTask?.cancel()
        completionTask = nil

        let fileManager = FileManager.default
        let sessionDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-codex-login-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Failed to prepare a secure Codex login session: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return
        }

        sessionDirectoryURL = sessionDirectory

        guard let codexExecutable = aiusageResolvedExecutable(named: "codex") else {
            cleanup(removeArtifacts: true)
            phase = .failed("AIUsage could not find the Codex CLI. Install `@openai/codex` first.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", codexExecutable, "login"]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = sessionDirectory.path
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = [
            environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            aiusageDefaultCLIPath()
        ]
        .compactMap { $0 }
        .joined(separator: ":")
        process.environment = environment

        let weakBox = WeakCodexCoordinatorBox(self)

        pipe.fileHandleForReading.readabilityHandler = { [weak weakBox] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                weakBox?.value?.consumeOutput(text)
            }
        }

        process.terminationHandler = { [weak weakBox] terminated in
            DispatchQueue.main.async {
                weakBox?.value?.finish(status: terminated.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = pipe
            outputSummary = "Codex login started."
            beginWaitingForAuthFile()
        } catch {
            cleanup(removeArtifacts: true)
            phase = .failed("Failed to start Codex login: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    func cancel() {
        completionTask?.cancel()
        completionTask = nil
        hasCompletedLogin = false
        loginStartedAt = nil
        baselineCandidateSignatures = []
        if let process, process.isRunning {
            process.terminate()
        }
        cleanup(removeArtifacts: true)
        phase = .idle
    }

    func discardImportedSession() {
        cleanup(removeArtifacts: true)
    }

    private func consumeOutput(_ text: String) {
        outputBuffer += text
        let sanitized = Self.sanitizedOutput(outputBuffer)

        if callbackURL == nil {
            callbackURL = Self.firstURL(in: sanitized, matchingHost: "localhost")
        }

        if let callbackURL, Self.isSuccessfulCallbackURL(callbackURL) {
            phase = .waitingForCompletion
            outputSummary = "Codex login approved. Finalizing account…"
            beginWaitingForAuthFile()
        }

        if authURL == nil {
            authURL = Self.firstURL(in: sanitized, matchingHost: "auth.openai.com")
        }

        if authURL != nil {
            if !didSeeAuthURL {
                phase = .waitingForBrowser
                didSeeAuthURL = true
            } else {
                phase = .waitingForCompletion
            }
        }

        if let summary = Self.humanSummary(from: sanitized) {
            outputSummary = summary
        }
    }

    func noteBrowserNavigation(_ url: URL) {
        callbackURL = url

        guard Self.isSuccessfulCallbackURL(url) else { return }

        phase = .waitingForCompletion
        outputSummary = "Codex login approved. Finalizing account…"
        beginWaitingForAuthFile()
    }

    private func finish(status: Int32) {
        completionTask?.cancel()
        completionTask = nil

        if hasCompletedLogin {
            cleanup(removeArtifacts: false)
            return
        }

        let sanitized = Self.sanitizedOutput(outputBuffer)
        let authFileURL = currentAuthFileURL()
        cleanup(removeArtifacts: status == 0 && authFileURL != nil ? false : true)

        if status == 0 {
            guard let authFileURL else {
                if let callbackURL, Self.isSuccessfulCallbackURL(callbackURL) {
                    phase = .waitingForCompletion
                    outputSummary = "Codex login approved. Finalizing account…"
                    beginWaitingForAuthFileAfterExit()
                    return
                }

                phase = .failed("Codex login finished, but AIUsage could not find the new auth file.")
                outputSummary = Self.humanSummary(from: sanitized)
                    ?? "Codex login finished, but no auth file was produced."
                return
            }
            importedAuthFileURL = authFileURL
            phase = .succeeded
            outputSummary = Self.humanSummary(from: sanitized) ?? "Codex login completed."
            return
        }

        if let callbackURL, Self.isSuccessfulCallbackURL(callbackURL) {
            phase = .waitingForCompletion
            outputSummary = "Codex login approved. Finalizing account…"
            beginWaitingForAuthFileAfterExit()
            return
        }

        let message = Self.failureMessage(from: sanitized)
            ?? "Codex login exited before authentication completed."
        phase = .failed(message)
        outputSummary = message
    }

    private func beginWaitingForAuthFile() {
        guard completionTask == nil, !hasCompletedLogin else { return }

        completionTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }

                if let authFileURL = self.currentAuthFileURL() {
                    self.completeLogin(with: authFileURL)
                    return
                }
            }
        }
    }

    private func beginWaitingForAuthFileAfterExit() {
        guard completionTask == nil, !hasCompletedLogin else { return }

        completionTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }

                if let authFileURL = self.currentAuthFileURL() {
                    self.completeLogin(with: authFileURL)
                    return
                }
            }

            self.phase = .failed("Codex login finished, but AIUsage still could not find the new auth file.")
            self.outputSummary = "Codex login finished, but the refreshed auth file never appeared."
        }
    }

    private func currentAuthFileURL() -> URL? {
        if let isolatedAuthFile = Self.locateAuthFile(in: sessionDirectoryURL) {
            return isolatedAuthFile
        }

        guard let loginStartedAt else { return nil }
        let threshold = loginStartedAt.addingTimeInterval(-1)
        let defaultPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath

        let candidates = ProviderAuthManager.codexCandidates()
            .filter { candidate in
                if !baselineCandidateSignatures.contains(Self.candidateSignature(for: candidate)) {
                    return true
                }
                return (candidate.modifiedAt ?? .distantPast) >= threshold
            }
            .sorted { lhs, rhs in
                if lhs.sourcePath == defaultPath, rhs.sourcePath != defaultPath { return true }
                if rhs.sourcePath == defaultPath, lhs.sourcePath != defaultPath { return false }
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }

        guard let sourcePath = candidates.first?.sourcePath?.nilIfBlank else { return nil }
        return URL(fileURLWithPath: sourcePath)
    }

    private func completeLogin(with authFileURL: URL) {
        guard !hasCompletedLogin else { return }

        hasCompletedLogin = true
        importedAuthFileURL = authFileURL
        phase = .succeeded
        outputSummary = outputSummary ?? "Codex login completed."

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil

        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func cleanup(removeArtifacts: Bool) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil
        if removeArtifacts, let sessionDirectoryURL {
            try? FileManager.default.removeItem(at: sessionDirectoryURL)
            self.sessionDirectoryURL = nil
            importedAuthFileURL = nil
        }
    }

    private static func sanitizedOutput(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{8}", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("^D") }
            .joined(separator: "\n")
    }

    private static func firstURL(in text: String, matchingHost host: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector
            .matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first(where: { $0.host?.contains(host) == true })
    }

    private static func humanSummary(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains("Starting local login server") }) {
            return line
        }
        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains("If your browser did not open") }) {
            return line
        }
        return lines.last
    }

    private static func failureMessage(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        return lines.last(where: { !$0.isEmpty })
    }

    private static func isSuccessfulCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.contains("localhost") || host.contains("127.0.0.1") else {
            return false
        }

        let path = url.path.lowercased()
        if path.contains("success") || path.contains("callback") {
            return true
        }

        let queryNames = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            $0.name.lowercased()
        })
        return queryNames.contains("id_token")
            || queryNames.contains("access_token")
            || queryNames.contains("code")
    }

    private static func locateAuthFile(in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let fileManager = FileManager.default

        let directFile = directory.appendingPathComponent("auth.json")
        if fileManager.fileExists(atPath: directFile.path) {
            return directFile
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "auth.json" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }

    private static func candidateSignature(for candidate: ProviderAuthCandidate) -> String {
        [
            candidate.sourcePath ?? candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            String(Int(candidate.modifiedAt?.timeIntervalSince1970 ?? 0))
        ].joined(separator: "|")
    }

    var startedAt: Date? {
        loginStartedAt
    }
}
