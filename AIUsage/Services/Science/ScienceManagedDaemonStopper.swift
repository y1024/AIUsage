import Foundation
import Darwin

/// Last-resort cleanup for a detached AIUsage-managed daemon when the official
/// `claude-science stop` cannot run (binary uninstalled) or is unavailable
/// (crash-leftover from the other mode).
///
/// This is deliberately not a generic process killer: it accepts only the two
/// fixed AIUsage data directories (sandbox and adopt), trusts only their JSON
/// lock PID, and requires the live command line to name both `claude-science`
/// and that exact `--data-dir` argument before sending SIGTERM.
nonisolated enum ScienceManagedDaemonStopper {
    enum Outcome: Equatable {
        case noLock
        case staleLockRemoved
        case refused
        case termSent(exited: Bool)
    }

    static var managedSandboxDataDir: String {
        ((NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/aiusage/science-sandbox/home") as NSString)
            .appendingPathComponent(".claude-science")
    }

    static var managedAdoptDataDir: String {
        ((NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/aiusage/science-adopt/home") as NSString)
            .appendingPathComponent(".claude-science")
    }

    @discardableResult
    static func stopFromManagedLock(dataDir: String) -> Outcome {
        guard isExactManagedDataDir(dataDir) else { return .refused }
        let lockURL = URL(fileURLWithPath: dataDir).appendingPathComponent("operon.lock")
        guard FileManager.default.fileExists(atPath: lockURL.path) else { return .noLock }
        guard (try? lockURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
            .map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true,
              let data = try? Data(contentsOf: lockURL),
              let pid = lockedPID(from: data),
              pid > 1,
              pid != getpid() else {
            return .refused
        }

        guard let command = processCommand(pid: pid) else {
            if processDoesNotExist(pid) {
                removeRuntimeEndpoints(dataDir: dataDir)
                return .staleLockRemoved
            }
            return .refused
        }
        guard commandMatchesManagedDaemon(command, dataDir: dataDir) else {
            return .refused
        }

        guard Darwin.kill(pid, SIGTERM) == 0 else {
            if errno == ESRCH {
                removeRuntimeEndpoints(dataDir: dataDir)
                return .staleLockRemoved
            }
            return .refused
        }

        for _ in 0..<15 {
            if processDoesNotExist(pid) {
                removeRuntimeEndpoints(dataDir: dataDir)
                return .termSent(exited: true)
            }
            usleep(100_000)
        }
        return .termSent(exited: false)
    }

    /// Real operon.lock files store PID as a JSON integer. String/float/bool and
    /// values outside pid_t range fail closed. JSONSerialization is used instead
    /// of JSONDecoder because newer Foundation decoders accept `92207.0` as Int64.
    static func lockedPID(from data: Data) -> pid_t? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["pid"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        let value = number.int64Value
        guard value > 1, value <= Int64(Int32.max) else { return nil }
        return pid_t(value)
    }

    static func commandMatchesManagedDaemon(_ command: String, dataDir: String) -> Bool {
        let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let executableExpression = try? NSRegularExpression(
            pattern: "(?:^|/)claude-science(?=\\s|$)"
        ), executableExpression.firstMatch(in: command, range: fullRange) != nil else {
            return false
        }
        let escaped = NSRegularExpression.escapedPattern(for: dataDir)
        let pattern = "(?:^|\\s)--data-dir(?:\\s+|=)\(escaped)(?=\\s|$)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: command, range: fullRange) != nil
    }

    private static func isExactManagedDataDir(_ dataDir: String) -> Bool {
        let requested = URL(fileURLWithPath: dataDir).standardizedFileURL
        let allowed = [managedSandboxDataDir, managedAdoptDataDir]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard allowed.contains(requested.path) else { return false }

        // A relocated parent (for example symlinked ~/.config) remains inside
        // the user's AIUsage hierarchy. Only the allowlisted dataDir entry
        // itself is forbidden from redirecting to another tree.
        guard FileManager.default.fileExists(atPath: requested.path) else { return true }
        return (try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    private static func processCommand(pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let command = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? nil : command
    }

    private static func processDoesNotExist(_ pid: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }

    private static func removeRuntimeEndpoints(dataDir: String) {
        let manager = FileManager.default
        for name in ["operon.lock", "daemon.sock"] {
            try? manager.removeItem(atPath: (dataDir as NSString).appendingPathComponent(name))
        }
    }
}
