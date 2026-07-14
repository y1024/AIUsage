import Foundation
import os.log

// MARK: - Science Sandbox（隔离沙箱运行 Claude Science）
// 用【独立 HOME + 独立 data-dir + 独立内部端口】启动一个隔离的 Claude Science，配合虚拟登录
// （ScienceVirtualLogin）与本地复用代理（QuotaServer）。浏览器经 ScienceAuthProxy 的公开端口访问，
// 推理经 ANTHROPIC_BASE_URL 导去代理，全程零真实 Anthropic 凭证。对齐 CSswitch 的 launch/stop
// 脚本，但用原生 Swift 实现，无 node/python。
//
// 铁律护栏（见项目规则 · 与 CSswitch CLAUDE.md 一致）：
//   - 绝不碰真实 ~/.claude-science；data-dir 恒在沙箱 HOME 之下。
//   - 绝不用端口 8765（真实实例保留端口）。
//   - 首次只 APFS 克隆运行时资产（bin/conda/runtime/seed-assets），绝不复制任何真实登录凭证。
//   - encryption.key 的钥匙串镜像账号按【路径哈希】派生，沙箱与真实天然隔离；沙箱用独立空密码钥匙串。

private let sandboxLog = Logger(subsystem: "com.aiusage.desktop", category: "ScienceSandbox")

enum ScienceSandboxError: LocalizedError {
    case scienceNotInstalled
    case refusedRealPort
    case refusedRealDataDir
    case spawnFailed(String)
    case stopFailed(String)
    case healthTimeout

    var errorDescription: String? {
        switch self {
        case .scienceNotInstalled:
            return AppSettings.shared.t(
                "Claude Science is not installed (expected at /Applications/Claude Science.app).",
                "未检测到 Claude Science（应位于 /Applications/Claude Science.app）。"
            )
        case .refusedRealPort:
            return AppSettings.shared.t("Refused: port 8765 is reserved for the real Claude Science instance.", "拒绝：端口 8765 是真实 Claude Science 实例保留端口。")
        case .refusedRealDataDir:
            return AppSettings.shared.t("Refused: the sandbox data directory must not point at the real ~/.claude-science.", "拒绝：沙箱 data-dir 绝不能指向真实 ~/.claude-science。")
        case .spawnFailed(let m):
            return AppSettings.shared.t("Failed to launch the sandbox Claude Science: \(m)", "启动沙箱 Claude Science 失败：\(m)")
        case .stopFailed(let m):
            return AppSettings.shared.t("Failed to stop the sandbox Claude Science: \(m)", "停止沙箱 Claude Science 失败：\(m)")
        case .healthTimeout:
            return AppSettings.shared.t("The sandbox Claude Science did not become healthy in time.", "沙箱 Claude Science 未能在预期时间内就绪。")
        }
    }
}

/// 沙箱各路径（由代理配置与固定布局推导）。
struct ScienceSandboxPaths {
    /// 沙箱 HOME（独立于真实 HOME）。
    let home: String
    /// 沙箱 data-dir（= 沙箱 HOME/.claude-science；虚拟登录写这里）。
    let dataDir: String
    /// 真实凭证目录（只用于护栏比对，绝不写）。
    let realDir: String

    static let scienceBinary = "/Applications/Claude Science.app/Contents/Resources/bin/claude-science"

    static func make(home overrideHome: String? = nil) -> ScienceSandboxPaths {
        let base = overrideHome ?? defaultHome
        return ScienceSandboxPaths(
            home: base,
            dataDir: (base as NSString).appendingPathComponent(".claude-science"),
            realDir: (NSHomeDirectory() as NSString).appendingPathComponent(".claude-science")
        )
    }

    static var defaultHome: String {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/aiusage/science-sandbox/home")
    }
}

enum ScienceSandbox {
    /// 运行时资产（APFS 克隆，不含任何登录凭证）。
    private static let runtimeAssets = ["bin", "conda", "runtime", "seed-assets"]
    private static let clonedMarkerAsset = "bin"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ScienceSandboxPaths.scienceBinary)
    }

    /// 首次准备沙箱：APFS 克隆运行时资产 + 建独立钥匙串。绝不复制真实登录凭证。
    /// 幂等：运行时已克隆则跳过克隆；钥匙串已存在则只确保解锁/默认。
    static func prepare(paths: ScienceSandboxPaths) throws {
        guard isInstalled else { throw ScienceSandboxError.scienceNotInstalled }
        try guardDataDir(paths)

        try? FileManager.default.createDirectory(atPath: paths.dataDir, withIntermediateDirectories: true)

        // —— 运行时资产（APFS 克隆，只拷运行时、不拷真实登录）——
        let markerPath = (paths.dataDir as NSString).appendingPathComponent(clonedMarkerAsset)
        if !FileManager.default.fileExists(atPath: markerPath) {
            sandboxLog.info("First run: cloning Science runtime assets (APFS clone, no credentials)")
            for asset in runtimeAssets {
                let src = (paths.realDir as NSString).appendingPathComponent(asset)
                let dst = (paths.dataDir as NSString).appendingPathComponent(asset)
                guard FileManager.default.fileExists(atPath: src),
                      !FileManager.default.fileExists(atPath: dst) else { continue }
                try cloneDirectory(from: src, to: dst)
            }
        }

        try ensureSandboxKeychain(paths: paths)
    }

    /// 启动沙箱 Science（后台守护）。推理经 ANTHROPIC_BASE_URL 导去本地代理。
    static func launch(paths: ScienceSandboxPaths, sciencePort: Int, proxyPort: Int) throws {
        guard isInstalled else { throw ScienceSandboxError.scienceNotInstalled }
        guard sciencePort != 8765 else { throw ScienceSandboxError.refusedRealPort }
        try guardDataDir(paths)

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = paths.home
        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(proxyPort)"
        // 本地推理直连回环，不经用户系统代理（operon 认小写 no_proxy）。
        env["no_proxy"] = "127.0.0.1,localhost,::1"
        env["NO_PROXY"] = "127.0.0.1,localhost,::1"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ScienceSandboxPaths.scienceBinary)
        proc.arguments = [
            "serve",
            "--data-dir", paths.dataDir,
            "--port", "\(sciencePort)",
            "--no-browser",
            "--no-auto-update",
            "--detached",
        ]
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            throw ScienceSandboxError.spawnFailed(error.localizedDescription)
        }
        // --detached 下 Science 会 daemonize，前台进程很快返回；等它退出拿到派生结果。
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            sandboxLog.error("Science serve exited code=\(proc.terminationStatus): \(out, privacy: .public)")
            // 非 0 未必致命（已有 daemon 时可能报「already running」），交给 health 判定。
        }
    }

    /// 停止沙箱 Science（只停沙箱 data-dir 的守护，绝不影响真实实例 8765）。
    static func stop(paths: ScienceSandboxPaths) throws {
        guard FileManager.default.fileExists(atPath: paths.dataDir) else { return }
        try guardDataDir(paths)

        // The detached daemon can outlive an uninstalled/moved app bundle. In
        // that case the official stop command is unavailable; use the strict
        // managed-lock PID + exact --data-dir guard instead of leaving it behind.
        guard isInstalled else {
            _ = ScienceManagedDaemonStopper.stopFromManagedLock(dataDir: paths.dataDir)
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = paths.home

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ScienceSandboxPaths.scienceBinary)
        proc.arguments = ["stop", "--data-dir", paths.dataDir]
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            let fallback = ScienceManagedDaemonStopper.stopFromManagedLock(dataDir: paths.dataDir)
            if fallback == .refused {
                throw ScienceSandboxError.stopFailed(error.localizedDescription)
            }
            return
        }
        proc.waitUntilExit()
        // `stop` may return before the detached child has fully exited. The
        // same strict guard is safe and idempotent when the lock already went.
        _ = ScienceManagedDaemonStopper.stopFromManagedLock(dataDir: paths.dataDir)
    }

    /// 健康检查：轮询沙箱 Science 的 /health，直至就绪或超时。
    static func waitForHealth(sciencePort: Int, timeout: TimeInterval = 25) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(sciencePort)/health") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            do {
                var request = URLRequest(url: url, timeoutInterval: 2)
                request.httpMethod = "GET"
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    return true
                }
            } catch {
                // 未起来 → 继续轮询
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        } while Date() < deadline
        return false
    }

    // MARK: - Guardrails

    /// 铁律：data-dir 的真实路径绝不等于真实 ~/.claude-science。
    private static func guardDataDir(_ paths: ScienceSandboxPaths) throws {
        let dd = URL(fileURLWithPath: paths.dataDir).resolvingSymlinksInPath().path
        let real = URL(fileURLWithPath: paths.realDir).resolvingSymlinksInPath().path
        if dd == real { throw ScienceSandboxError.refusedRealDataDir }
    }

    // MARK: - Helpers

    /// APFS 克隆一个目录（copy-on-write，快且省空间）；不支持时回退到普通复制。
    private static func cloneDirectory(from src: String, to dst: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/cp")
        proc.arguments = ["-Rc", src, dst] // -c = clonefile（APFS）
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            // 回退：普通递归复制。
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            sandboxLog.notice("APFS clone failed (\(out, privacy: .public)); falling back to copy")
            if !FileManager.default.fileExists(atPath: dst) {
                try FileManager.default.copyItem(atPath: src, toPath: dst)
            }
        }
    }

    /// 沙箱专属钥匙串（消除「找不到钥匙串」弹窗）：在【沙箱 HOME 内】建一个独立、空密码、
    /// 不自动锁的 login.keychain-db，且只在 HOME=沙箱 HOME 的上下文里操作。真实钥匙串零接触。
    private static func ensureSandboxKeychain(paths: ScienceSandboxPaths) throws {
        let kcDir = (paths.home as NSString).appendingPathComponent("Library/Keychains")
        let kc = (kcDir as NSString).appendingPathComponent("login.keychain-db")
        try? FileManager.default.createDirectory(atPath: kcDir, withIntermediateDirectories: true)

        func security(_ args: [String]) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = paths.home
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()
        }

        if !FileManager.default.fileExists(atPath: kc) {
            security(["create-keychain", "-p", "", kc])
        }
        // 每次都确保：加入沙箱搜索表、设默认、解锁、关自动锁（全部仅作用于沙箱 HOME）。
        security(["list-keychains", "-d", "user", "-s", kc])
        security(["default-keychain", "-d", "user", "-s", kc])
        security(["unlock-keychain", "-p", "", kc])
        security(["set-keychain-settings", kc])
    }
}
