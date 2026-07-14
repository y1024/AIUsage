import Combine
import Darwin
import Foundation
import os.log

private let cliProxyRuntimeLog = Logger(subsystem: "com.aiusage.desktop", category: "CLIProxyRuntime")

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
    private var cachedSecrets: CLIProxySecrets?
    private var process: Process?
    private var shouldBeRunning = false
    private var restartAttempts = 0
    private var isLoadingSettings = true
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pendingProcessLogs: [String] = []
    private var logFlushTask: Task<Void, Never>?

    private var pidURL: URL { paths.root.appendingPathComponent("runtime.pid.json") }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.normalized.port)")! }
    var detectedLANBaseURLs: [URL] {
        detectedLANBaseURLs(port: settings.normalized.port)
    }
    func detectedLANBaseURLs(port: Int) -> [URL] {
        Self.activePrivateIPv4Addresses().compactMap {
            URL(string: "http://\($0):\(port)")
        }
    }
    var lanBaseURLs: [URL] {
        guard settings.normalized.allowLANAccess else { return [] }
        return detectedLANBaseURLs
    }
    var clientAPIKey: String? { cachedSecrets?.clientAPIKey }
    var managementKey: String? { cachedSecrets?.managementKey }

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
        self.cachedSecrets = secretStore.load()
        try paths.prepare()
        reapOwnedOrphanIfNeeded()
        reapStaleManagedListenerIfNeeded(port: settings.normalized.port)
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

    /// Persist and stabilize the managed config before `current` can move to a
    /// different binary version. This is required even while CPA is stopped:
    /// cleanup may otherwise delete an old version directory that still owns a
    /// relative plugin directory before the next launch can migrate it.
    func stabilizeConfigurationBeforeActivation() throws {
        _ = try writeManagedConfiguration()
    }

    func stopSynchronouslyForTermination() {
        shouldBeRunning = false
        finishPendingProcessLogs()
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            self.process = nil
        }
        // Xcode 强杀 / 未挂上 Process 句柄时，仍按 pid 文件 + 端口回收本机托管 CPA。
        reapOwnedOrphanIfNeeded()
        reapStaleManagedListenerIfNeeded(port: settings.normalized.port)
        state = .stopped
    }

    func runningPortOwner() -> ProxyPortArbiter.Owner? {
        guard state.isRunning else { return nil }
        return ProxyPortArbiter.Owner(
            id: "cliproxyapi-gateway",
            ports: [settings.normalized.port],
            track: "CLIProxyAPI",
            label: L("CPA Gateway", "CPA 网关")
        )
    }

    private func startOnce() async {
        state = .starting
        do {
            guard let binaryURL = try await binaryStore.currentBinaryURL() else {
                throw CLIProxyGatewayError.notInstalled
            }
            let normalized = settings.normalized
            // Debug 重编译 / 上次强退后，外部 CPA 可能仍占端口；启动前再收一次本机托管孤儿。
            reapOwnedOrphanIfNeeded()
            reapStaleManagedListenerIfNeeded(port: normalized.port)
            waitUntilPortFree(normalized.port, bindHost: normalized.bindHost)

            if let conflict = ProxyPortArbiter.conflict(
                forPorts: [normalized.port],
                excluding: "cliproxyapi-gateway"
            ) {
                throw CLIProxyGatewayError.portInUse(
                    conflict.port,
                    "\(conflict.track) / \(conflict.label)"
                )
            }
            guard Self.isIPv4PortAvailable(normalized.port, bindHost: normalized.bindHost) else {
                throw CLIProxyGatewayError.portInUse(normalized.port, "another local process")
            }

            let secrets = try writeManagedConfiguration(settings: normalized)
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["-config", paths.configURL.path]
            process.currentDirectoryURL = binaryURL.deletingLastPathComponent()
            var environment = ProcessInfo.processInfo.environment
            // CPA treats this environment variable as an explicit override
            // that enables remote management. AIUsage always owns management
            // through its separate config key, so never inherit the override.
            environment.removeValue(forKey: "MANAGEMENT_PASSWORD")
            process.environment = environment

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
            finishPendingProcessLogs()
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
        finishPendingProcessLogs()
        clearPIDRecord()
        waitUntilPortFree(settings.normalized.port, bindHost: settings.normalized.bindHost)
        state = .stopped
    }

    private func writeManagedConfiguration(
        settings value: CLIProxyGatewaySettings? = nil
    ) throws -> CLIProxySecrets {
        let secrets = try secretStore.loadOrCreate()
        cachedSecrets = secrets
        try configStore.writeRuntimeConfig(
            settings: (value ?? settings).normalized,
            secrets: secrets
        )
        return secrets
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
            let redacted = Self.redactLog(text, secrets: secrets)
            let lines = redacted.split(whereSeparator: \.isNewline).map(String.init)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.enqueueProcessLogs(lines)
            }
        }
    }

    nonisolated private static func redactLog(_ text: String, secrets: CLIProxySecrets) -> String {
        var redacted = text
            .replacingOccurrences(of: secrets.managementKey, with: "[REDACTED]")
            .replacingOccurrences(of: secrets.clientAPIKey, with: "[REDACTED]")
        let patterns = [
            #"(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|oauth[_-]?code|device[_-]?code|user[_-]?code)\b[\"']?\s*[:=]\s*[\"']?)[^\"'\s,;}]{4,}"#,
            #"(?im)(\b(?:authorization|cookie|set-cookie)\s*:\s*)[^\r\n]+"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "$1[REDACTED]"
            )
        }
        return redacted
    }

    /// CPA can emit several lines per request. Publish them in short batches so
    /// views observing runtime state are not invalidated once for every stdout
    /// line while the gateway is busy.
    private func enqueueProcessLogs(_ lines: [String]) {
        pendingProcessLogs.append(contentsOf: lines.filter { !$0.isEmpty })
        guard !pendingProcessLogs.isEmpty, logFlushTask == nil else { return }
        logFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.flushProcessLogs()
        }
    }

    private func flushProcessLogs() {
        logFlushTask = nil
        guard !pendingProcessLogs.isEmpty else { return }
        recentLogs.append(contentsOf: pendingProcessLogs)
        pendingProcessLogs.removeAll(keepingCapacity: true)
        if recentLogs.count > 200 { recentLogs.removeFirst(recentLogs.count - 200) }
    }

    private func finishPendingProcessLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        flushProcessLogs()
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
        guard record.pid > 1, Darwin.kill(record.pid, 0) == 0 else { return }

        let matchesConfig = record.configPath == paths.configURL.path
            || Self.processCommand(record.pid).contains(paths.configURL.path)
        let binaryPath = Self.processPath(record.pid)
        let matchesBinary = binaryPath == record.binaryPath
            || (binaryPath?.hasPrefix(paths.versionsDirectory.path + "/") == true)
            || record.binaryPath.hasPrefix(paths.versionsDirectory.path + "/")
        // 放宽匹配：pid 文件存在且仍是我们的 versions 二进制 / 仍带本机 config，即回收。
        // （Xcode 强杀后 binary 路径偶发解析不一致，过严会导致端口孤儿留下。）
        guard matchesConfig || matchesBinary else { return }

        cliProxyRuntimeLog.notice("Reaping CPA orphan from pid file pid=\(record.pid, privacy: .public)")
        Self.terminatePid(record.pid)
    }

    /// 按监听端口回收「带本机 -config」的 CLIProxyAPI，覆盖 pid 文件丢失的情况。
    private func reapStaleManagedListenerIfNeeded(port: Int) {
        guard (1...65_535).contains(port) else { return }
        let configPath = paths.configURL.path
        let candidates = Self.pidsListening(on: port).filter { pid in
            pid > 1 && pid != ProcessInfo.processInfo.processIdentifier
        }
        for pid in candidates {
            let command = Self.processCommand(pid)
            let path = Self.processPath(pid) ?? ""
            let looksLikeCPA = path.localizedCaseInsensitiveContains("cliproxy")
                || path.localizedCaseInsensitiveContains("CLIProxyAPI")
                || (path as NSString).lastPathComponent.localizedCaseInsensitiveContains("cliproxy")
            let usesOurConfig = command.contains(configPath)
            let underOurVersions = path.hasPrefix(paths.versionsDirectory.path + "/")
            guard looksLikeCPA, usesOurConfig || underOurVersions else { continue }
            cliProxyRuntimeLog.notice(
                "Reaping stale CPA listener on port \(port, privacy: .public) pid=\(pid, privacy: .public)"
            )
            Self.terminatePid(pid)
        }
    }

    private func waitUntilPortFree(_ port: Int, bindHost: String, attempts: Int = 20) {
        for _ in 0..<attempts {
            if Self.isIPv4PortAvailable(port, bindHost: bindHost) { return }
            usleep(100_000)
        }
    }

    private static func terminatePid(_ pid: Int32) {
        Darwin.kill(pid, SIGTERM)
        for _ in 0..<15 where Darwin.kill(pid, 0) == 0 {
            usleep(100_000)
        }
        if Darwin.kill(pid, 0) == 0 {
            Darwin.kill(pid, SIGKILL)
            for _ in 0..<10 where Darwin.kill(pid, 0) == 0 {
                usleep(50_000)
            }
        }
    }

    private static func pidsListening(on port: Int) -> [Int32] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap { Int32($0) }
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

    private static func isIPv4PortAvailable(_ port: Int, bindHost: String) -> Bool {
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
        address.sin_addr = in_addr(s_addr: inet_addr(bindHost))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func activePrivateIPv4Addresses() -> [String] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var candidates: [(interface: String, address: String)] = []
        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            guard isLocalNetworkIPv4(address) else { continue }
            candidates.append((String(cString: interface.ifa_name), address))
        }

        let preferredInterfaces = ["en0", "en1"]
        return candidates
            .sorted { lhs, rhs in
                let left = preferredInterfaces.firstIndex(of: lhs.interface) ?? preferredInterfaces.count
                let right = preferredInterfaces.firstIndex(of: rhs.interface) ?? preferredInterfaces.count
                return left == right ? lhs.interface < rhs.interface : left < right
            }
            .reduce(into: [String]()) { addresses, candidate in
                if !addresses.contains(candidate.address) { addresses.append(candidate.address) }
            }
    }

    private static func isLocalNetworkIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        // RFC 6598 shared address space is commonly used by VPN/tailnet
        // interfaces. Keep it as an explicit candidate instead of pretending
        // every listed address belongs to a physical LAN.
        if parts[0] == 100, (64...127).contains(parts[1]) { return true }
        return false
    }
}
