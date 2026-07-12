import Combine
import Darwin
import Foundation

@MainActor
final class CLIProxyRuntimeController: ObservableObject {
    static let shared: CLIProxyRuntimeController = {
        do { return try CLIProxyRuntimeController(paths: CLIProxyPaths()) }
        catch { preconditionFailure("CLIProxyAPI runtime storage is unavailable: \(error.localizedDescription)") }
    }()

    @Published private(set) var state: CLIProxyRuntimeState = .stopped
    @Published private(set) var recentLogs: [String] = []
    @Published var settings: CLIProxyGatewaySettings {
        didSet {
            guard !isLoadingSettings else { return }
            do { try configStore.saveSettings(settings) }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    private struct PIDRecord: Codable {
        let pid: Int32
        let binaryPath: String
        let configPath: String
    }

    private let paths: CLIProxyPaths
    private let binaryStore: CLIProxyBinaryStore
    private let configStore: CLIProxyConfigStore
    private let secretStore: CLIProxySecretStore
    private var process: Process?
    private var shouldBeRunning = false
    private var restartAttempts = 0
    private var isLoadingSettings = true
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var pidURL: URL { paths.root.appendingPathComponent("runtime.pid.json") }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.normalized.port)")! }
    var clientAPIKey: String? { secretStore.load()?.clientAPIKey }
    var managementKey: String? { secretStore.load()?.managementKey }

    init(
        paths: CLIProxyPaths,
        binaryStore: CLIProxyBinaryStore? = nil,
        configStore: CLIProxyConfigStore? = nil,
        secretStore: CLIProxySecretStore = CLIProxySecretStore()
    ) throws {
        self.paths = paths
        self.binaryStore = binaryStore ?? CLIProxyBinaryStore(paths: paths)
        self.configStore = configStore ?? CLIProxyConfigStore(paths: paths)
        self.secretStore = secretStore
        self.settings = (configStore ?? CLIProxyConfigStore(paths: paths)).loadSettings()
        try paths.prepare()
        reapOwnedOrphanIfNeeded()
        isLoadingSettings = false
    }

    func start() async {
        guard !state.isRunning, !state.isTransitioning else { return }
        shouldBeRunning = true
        restartAttempts = 0
        await startOnce()
    }

    func startIfConfigured() async {
        guard settings.autoStart else { return }
        await start()
    }

    func stop() async {
        shouldBeRunning = false
        restartAttempts = 0
        await stopOwnedProcess()
    }

    func restart() async {
        shouldBeRunning = true
        restartAttempts = 0
        await stopOwnedProcess()
        await startOnce()
    }

    func applySettings(_ value: CLIProxyGatewaySettings) async {
        settings = value.normalized
        guard state.isRunning else { return }
        await restart()
    }

    func stopSynchronouslyForTermination() {
        shouldBeRunning = false
        guard let process, process.isRunning else {
            clearPIDRecord()
            return
        }
        process.terminationHandler = nil
        process.terminate()
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        clearPIDRecord()
        self.process = nil
        state = .stopped
    }

    func runningPortOwner() -> ProxyPortArbiter.Owner? {
        guard state.isRunning else { return nil }
        return ProxyPortArbiter.Owner(
            id: "cliproxyapi-gateway",
            ports: [settings.normalized.port],
            track: "CLIProxyAPI",
            label: L("Subscription Gateway", "订阅网关")
        )
    }

    private func startOnce() async {
        state = .starting
        do {
            guard let binaryURL = try await binaryStore.currentBinaryURL() else {
                throw CLIProxyGatewayError.notInstalled
            }
            let normalized = settings.normalized
            if let conflict = ProxyPortArbiter.conflict(
                forPorts: [normalized.port],
                excluding: "cliproxyapi-gateway"
            ) {
                throw CLIProxyGatewayError.portInUse(
                    conflict.port,
                    "\(conflict.track) / \(conflict.label)"
                )
            }
            guard Self.isLoopbackPortAvailable(normalized.port) else {
                throw CLIProxyGatewayError.portInUse(normalized.port, "another local process")
            }

            let secrets = try secretStore.loadOrCreate()
            try configStore.writeRuntimeConfig(settings: normalized, secrets: secrets)
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["-config", paths.configURL.path]
            process.currentDirectoryURL = binaryURL.deletingLastPathComponent()

            let output = Pipe()
            let errors = Pipe()
            stdoutPipe = output
            stderrPipe = errors
            process.standardOutput = output
            process.standardError = errors
            attachLogReader(output.fileHandleForReading, secrets: secrets)
            attachLogReader(errors.fileHandleForReading, secrets: secrets)

            try process.run()
            self.process = process
            try writePIDRecord(process: process, binaryURL: binaryURL)
            try await waitUntilHealthy(process: process)
            guard process.isRunning else {
                throw CLIProxyGatewayError.process("process exited after the health check")
            }
            process.terminationHandler = { [weak self, weak process] _ in
                Task { @MainActor [weak self, weak process] in
                    guard let self, self.process === process else { return }
                    self.handleUnexpectedExit(status: process?.terminationStatus ?? -1)
                }
            }
            restartAttempts = 0
            state = .running(pid: process.processIdentifier)
        } catch {
            if let process, process.isRunning {
                process.terminationHandler = nil
                process.terminate()
            }
            self.process = nil
            clearPIDRecord()
            state = .failed(error.localizedDescription)
            appendLog("[AIUsage] \(error.localizedDescription)")
        }
    }

    private func stopOwnedProcess() async {
        guard let process else {
            clearPIDRecord()
            state = .stopped
            return
        }
        state = .stopping
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        self.process = nil
        clearPIDRecord()
        state = .stopped
    }

    private func handleUnexpectedExit(status: Int32) {
        process = nil
        clearPIDRecord()
        guard shouldBeRunning else {
            state = .stopped
            return
        }
        appendLog("[AIUsage] CPA exited unexpectedly (status \(status)).")
        guard restartAttempts < 3 else {
            state = .failed("CLIProxyAPI exited repeatedly; automatic restart stopped.")
            return
        }
        restartAttempts += 1
        state = .starting
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(self?.restartAttempts ?? 1)))
            guard let self, self.shouldBeRunning else { return }
            await self.startOnce()
        }
    }

    private func waitUntilHealthy(process: Process) async throws {
        let endpoint = baseURL.appendingPathComponent("healthz")
        let deadline = Date().addingTimeInterval(12)
        var lastError = "health endpoint did not become ready"
        while Date() < deadline, process.isRunning {
            var request = URLRequest(url: endpoint, timeoutInterval: 0.8)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch { lastError = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(200))
        }
        if !process.isRunning { lastError = "process exited with status \(process.terminationStatus)" }
        throw CLIProxyGatewayError.process(lastError)
    }

    private func attachLogReader(_ handle: FileHandle, secrets: CLIProxySecrets) {
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let redacted = text
                .replacingOccurrences(of: secrets.managementKey, with: "[REDACTED]")
                .replacingOccurrences(of: secrets.clientAPIKey, with: "[REDACTED]")
            Task { @MainActor [weak self] in
                redacted.split(whereSeparator: \.isNewline).forEach { self?.appendLog(String($0)) }
            }
        }
    }

    private func appendLog(_ line: String) {
        guard !line.isEmpty else { return }
        recentLogs.append(line)
        if recentLogs.count > 200 { recentLogs.removeFirst(recentLogs.count - 200) }
    }

    private func writePIDRecord(process: Process, binaryURL: URL) throws {
        let record = PIDRecord(
            pid: process.processIdentifier,
            binaryPath: binaryURL.resolvingSymlinksInPath().path,
            configPath: paths.configURL.path
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: pidURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidURL.path)
    }

    private func clearPIDRecord() {
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func reapOwnedOrphanIfNeeded() {
        guard let data = FileManager.default.contents(atPath: pidURL.path),
              let record = try? JSONDecoder().decode(PIDRecord.self, from: data) else {
            clearPIDRecord()
            return
        }
        defer { clearPIDRecord() }
        guard record.pid > 1, Darwin.kill(record.pid, 0) == 0,
              record.configPath == paths.configURL.path,
              record.binaryPath.hasPrefix(paths.versionsDirectory.path + "/"),
              Self.processPath(record.pid) == record.binaryPath,
              Self.processCommand(record.pid).contains("-config \(record.configPath)") else { return }
        Darwin.kill(record.pid, SIGTERM)
        for _ in 0..<10 where Darwin.kill(record.pid, 0) == 0 {
            usleep(100_000)
        }
        if Darwin.kill(record.pid, 0) == 0 { Darwin.kill(record.pid, SIGKILL) }
    }

    private static func processPath(_ pid: Int32) -> String? {
        // Equivalent to PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro is not imported by Swift.
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processCommand(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isLoopbackPortAvailable(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
