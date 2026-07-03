import Foundation
import os.log

// MARK: - Science Real-Instance Adoption（接管真实实例 · 路径②A-解耦版）
// 让【真实桌面 app（双击 Claude Science.app）与浏览器打开 http://localhost:8765】都免登录。
//
// 关键教训（上一版为何仍显示登录页）：
//   桌面 app 的启动器是个**守护进程**，会不断把自己的 `claude-science serve` 拉起去抢默认端口 8765；
//   且旧版内部 daemon 与桌面 app **共用同一 data-dir** `~/.claude-science`，桌面 app 一跑 `stop` 就把我们的
//   内部 daemon 一起杀了 → 8765 反代丢上游 → 桌面 app 自己的 daemon 顶上 8765 开出登录页。
//
// 解耦版架构：
//   1. 内部 daemon 跑在**独立 data-dir**（~/.config/aiusage/science-adopt，铸本地虚拟登录），内部端口 14411，
//      env 注入 ANTHROPIC_BASE_URL=本地推理代理(14402) → 推理走第三方。**绝不碰真实 ~/.claude-science 凭证**。
//      于是桌面 app 对 `~/.claude-science` 的任何 stop 都杀不到我们（data-dir 不同）。
//   2. 反代 ScienceAuthProxy 牢牢占住对外的 8765（回环），把流量转发到 14411 并注入当前有效 operon cookie。
//      桌面 app 启动器发现 8765 被占，自身 daemon bind 失败 → 打印「successor daemon detected — staying up」
//      并让位，转而打开 http://localhost:8765 → 命中反代 → 免登录。
//   3. 劫持 `~/.claude-science/operon.lock`：port→8765、sock→独立 daemon 的 sock、pid→内部 daemon 真实 pid。
//      让双击 app 直接附着：桌面 app 启动器读锁发现 pid 是**活着的 claude-science 进程** → 判定
//      「successor daemon detected — staying up」，不再自己抢 8765、不弹「failed to start」，转而用锁里的
//      sock 铸 nonce 打开 http://localhost:8765/?nonce=… → 命中反代 → 免登录。
//      operon.lock 是**运行期状态文件**（非凭证），停用时删除还原，全程不动真实登录凭证。
//
//   关键教训②（这次 “app 仍 failed to start” 的根因）：早前 hijackLock 写的是占位 pid=1，桌面 app 的
//   successor 检测（`pidIsOperonDaemon`）只认活着的 claude-science 进程，pid=1 是 launchd → 判定无 successor →
//   弹「daemon exited (status 1) / failed to start」。改写真实内部 pid 后实测：app 记录 “successor daemon
//   detected — staying up” 并留存、自动开带 nonce 的已登录页。（代价：`claude-science stop` 会顺着锁杀到内部
//   daemon，但双击启动流程不调用 stop；真被 stop 掉由健康检查兜底重启，可接受。）
//
// 护栏：只写 `~/.claude-science/operon.lock` 这一个运行期文件（可删还原）；内部 daemon/虚拟登录只落在
// 独立 adopt 目录；端口兜底只杀 claude-science 进程；绝不写系统全局环境变量。

private let adoptLog = Logger(subsystem: "com.aiusage.desktop", category: "ScienceRealAdopt")

enum ScienceRealAdoptError: LocalizedError {
    case daemonStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .daemonStartFailed(let m):
            return AppSettings.shared.t("Failed to start the adopted Claude Science daemon: \(m)", "启动被接管的 Claude Science daemon 失败：\(m)")
        }
    }
}

enum ScienceRealAdopt {
    /// 真实凭证目录（= 桌面 app 默认 data-dir）。只用于劫持它的 operon.lock，绝不写其凭证。
    static var realDir: String { (NSHomeDirectory() as NSString).appendingPathComponent(".claude-science") }

    /// 接管专用独立 HOME（与真实实例、14410 沙箱都隔离）。
    static var adoptHome: String { (NSHomeDirectory() as NSString).appendingPathComponent(".config/aiusage/science-adopt/home") }
    /// 接管专用路径集（内部 daemon 与虚拟登录都落这里）。
    static func adoptPaths() -> ScienceSandboxPaths { ScienceSandboxPaths.make(home: adoptHome) }

    /// 真实 daemon 内部监听端口（反代把 8765 转发到这里）。
    static var internalPort: Int { GlobalProxyConfig.realInstanceInternalPort }
    /// 对外端口（反代占用；operon.lock 被改写成它）。
    static var publicPort: Int { GlobalProxyConfig.realInstancePort }
    /// 独立 daemon 的 data-dir（反代据此铸 nonce/cookie）。
    static var adoptDataDir: String { adoptPaths().dataDir }

    private static var realLockPath: String { (realDir as NSString).appendingPathComponent("operon.lock") }
    private static var adoptLockPath: String { (adoptDataDir as NSString).appendingPathComponent("operon.lock") }
    private static let appPath = "/Applications/Claude Science.app"

    // MARK: - 生命周期

    /// 接管准备：退出桌面 app、腾空对外/内部端口（含无 lockfile 的孤儿 daemon）、清掉残留劫持锁。
    static func prepareForAdopt() {
        quitDesktopApp()
        freePortIfClaudeScience(publicPort)   // 8765（反代要占）
        freePortIfClaudeScience(internalPort) // 14411（内部 daemon 要占）
        try? FileManager.default.removeItem(atPath: realLockPath) // 只删运行期锁，不碰凭证
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// 在独立 data-dir 上、内部端口 14411 起虚拟登录的 daemon：env 注入 ANTHROPIC_BASE_URL=本地推理代理。
    /// 复用沙箱链路（APFS 克隆运行时 + 铸虚拟登录 + serve），只是端口用 14411、账号用 adopt 假邮箱。
    static func startInternalDaemon(proxyPort: Int, email: String) throws {
        let paths = adoptPaths()
        do {
            try ScienceSandbox.prepare(paths: paths)
            _ = try ScienceVirtualLogin.ensure(authDir: paths.dataDir, email: email, sandboxRoot: paths.home)
            try ScienceSandbox.launch(paths: paths, sciencePort: internalPort, proxyPort: proxyPort)
        } catch {
            throw ScienceRealAdoptError.daemonStartFailed(error.localizedDescription)
        }
    }

    /// 劫持 `~/.claude-science/operon.lock`：port→8765、sock→独立 daemon sock、pid→内部 daemon 真实 pid。
    /// 让双击桌面 app 的 successor 检测（只认活着的 claude-science 进程）判定「staying up」→ 不抢 8765、不弹错、
    /// 用锁里的 sock 铸 nonce 打开已登录页命中反代。若拿不到真实 pid，退回沿用独立 daemon 锁里的 pid。
    static func hijackLock() {
        let fm = FileManager.default
        // 以独立 daemon 自己写的锁为模板（拿 version/started_at/pid），改写对外字段。
        var json: [String: Any] = [:]
        if let data = fm.contents(atPath: adoptLockPath),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = obj
        }
        json["port"] = publicPort
        json["sock"] = (adoptDataDir as NSString).appendingPathComponent("daemon.sock")
        // 用监听内部端口的 claude-science 真实 pid：桌面 app 据此识别「已有 daemon 在跑」而让位。
        if let livePid = internalDaemonPID() {
            json["pid"] = livePid
        }
        guard let out = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? createRealDirIfNeeded()
        try? out.write(to: URL(fileURLWithPath: realLockPath), options: .atomic)
        adoptLog.info("Hijacked real operon.lock → port \(publicPort), pid=\(json["pid"] as? Int ?? -1)")
    }

    /// 查监听内部端口(14411)的 claude-science 进程 pid（供劫持锁写入，触发桌面 app 的 successor 让位）。
    private static func internalDaemonPID() -> Int? {
        let out = runCapturing("/usr/sbin/lsof", ["-ti", "tcp:\(internalPort)", "-sTCP:LISTEN"])
        for token in out.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
            guard let pid = Int(token) else { continue }
            let cmd = runCapturing("/bin/ps", ["-p", String(pid), "-o", "command="])
            if cmd.contains("claude-science") { return pid }
        }
        return nil
    }

    /// 停用接管：退出桌面 app + 停独立 daemon + 兜底腾空内部端口 + 删除劫持锁。绝不动真实凭证。
    static func stopAdoptedDaemon() {
        quitDesktopApp()
        try? ScienceSandbox.stop(paths: adoptPaths())
        freePortIfClaudeScience(internalPort)
        try? FileManager.default.removeItem(atPath: realLockPath)
    }

    // MARK: - Helpers

    private static func createRealDirIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: realDir) {
            try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        }
    }

    private static func quitDesktopApp() {
        run("/usr/bin/osascript", ["-e", "tell application \"Claude Science\" to quit"])
    }

    /// 腾空指定端口：仅当占用者是 claude-science 进程时才杀（护栏：绝不误杀其它本地服务）。
    /// 用于清掉「无 lockfile、`claude-science stop` 找不到」的孤儿 daemon。
    private static func freePortIfClaudeScience(_ port: Int) {
        let pidsOut = runCapturing("/usr/sbin/lsof", ["-ti", "tcp:\(port)", "-sTCP:LISTEN"])
        let pids = pidsOut.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).map(String.init)
        for pid in pids where !pid.isEmpty {
            let cmd = runCapturing("/bin/ps", ["-p", pid, "-o", "command="])
            guard cmd.contains("claude-science") else { continue }
            run("/bin/kill", ["-TERM", pid])
            adoptLog.info("Freed port \(port): terminated claude-science pid \(pid)")
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// 运行命令并捕获 stdout（用于探端口占用者 pid / 进程名）。失败返回空串。
    private static func runCapturing(_ launchPath: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
