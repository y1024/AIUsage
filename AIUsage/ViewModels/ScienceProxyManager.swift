import Foundation
import Combine
import AppKit
import os.log

// MARK: - Science Proxy Manager
// 编排「Claude Science 代理」轨：一键开始 = 起代理（复用 GlobalProxyRuntime.science）→ 确保虚拟登录
// （ScienceVirtualLogin）→ 准备并启动隔离沙箱（ScienceSandbox）→ 打开浏览器。切换激活节点走进程内
// 热替换上游（复用 Claude 轨 admin 路由），Science 无感、端口不变。
//
// 只做调度：协议转换/上游客户端复用现成 QuotaServer；节点筛选与 env/payload 投影复用
// ClaudeGlobalProxyAdapter（Science 推理即 Anthropic Messages API，等价 Claude Code 走 convert）。
// 与 Claude Code 轨完全独立（独立端口 14402、独立进程、不写 ~/.claude/settings.json）。

private let scienceMgrLog = Logger(subsystem: "com.aiusage.desktop", category: "ScienceProxyManager")

@MainActor
final class ScienceProxyManager: ObservableObject {
    static let shared = ScienceProxyManager()

    private let track: GlobalProxyTrack = .science
    private let adapter = ClaudeGlobalProxyAdapter()
    private var runtime: GlobalProxyRuntime { .science }

    @Published private(set) var config: GlobalProxyConfig
    @Published var operationError: String?
    @Published private(set) var isBusy = false
    /// 沙箱 Science 是否已就绪（/health 探测）。
    @Published private(set) var sandboxHealthy = false

    private init() {
        self.config = GlobalProxyStore.load(track: .science)
    }

    // MARK: - Derived

    var isEnabled: Bool { config.isEnabled }
    var activeNodeId: String? { config.activeNodeId }
    var isProxyRunning: Bool { runtime.isProcessRunning }
    var scienceInstalled: Bool { ScienceSandbox.isInstalled }
    var sandboxHome: String { ScienceSandboxPaths.make().home }
    /// 是否接管真实实例（双击桌面 app 也免登录）。
    var adoptReal: Bool { config.effectiveAdoptReal }
    /// 当前实际监听端口（接管真实实例 = 8765，否则沙箱端口）。
    var listenPort: Int { config.effectiveScienceListenPort }

    /// 可参与的上游节点（Claude 家族节点，与「Claude Code 代理」共享节点池）。
    func availableNodes() -> [GlobalProxyNodeRef] { adapter.availableNodes(config: config) }

    func node(for id: String?) -> GlobalProxyNodeRef? {
        guard let id else { return nil }
        return availableNodes().first { $0.id == id }
    }

    // MARK: - Settings（仅停用态可改）

    func updateSettings(proxyPort: Int, sciencePort: Int, email: String) {
        guard !config.isEnabled else { return }
        config.port = max(1, min(65_535, proxyPort))
        let sp = max(1, min(65_535, sciencePort))
        config.sciencePort = (sp == 8765) ? GlobalProxyConfig.defaultScienceListenPort : sp
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sandboxEmail = trimmed.isEmpty ? GlobalProxyConfig.defaultSandboxEmail : trimmed
        persist()
    }

    /// 切换「接管真实实例」（仅停用态可改）。开启后双击桌面 app 也免登录（独立 daemon + 反代，不碰真实凭证）。
    func setAdoptReal(_ on: Bool) {
        guard !config.isEnabled else { return }
        config.adoptRealInstance = on
        persist()
    }

    /// 更新是否允许局域网访问。仅停用态可改。
    func updateAllowLAN(_ allowLAN: Bool) {
        guard !config.isEnabled else { return }
        config.allowLAN = allowLAN
        persist()
    }

    // MARK: - Start / Stop / Switch

    /// 一键开始：起代理 → 虚拟登录 → 启动沙箱 → （可选）开浏览器。
    func start(activeNodeId nodeId: String, openBrowserOnReady: Bool = true) async {
        guard !isBusy else { return }
        guard scienceInstalled else {
            operationError = ScienceSandboxError.scienceNotInstalled.errorDescription
            return
        }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId), var env = adapter.startEnv(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }
        // Science 与 Claude Code 的关键差异：Science daemon 每次推理都带它自造的虚拟 OAuth Bearer，
        // 而非我们的固定 client key。若代理要求 client key（ANTHROPIC_API_KEY），入站会被判 401，
        // Science 误报「session no longer valid」。因此这里剥掉 client key → 代理对入站鉴权放行、
        // 剥离并忽略 Science 的 Bearer，再注入节点真实上游 key（对齐 CSswitch 的 strip-and-ignore）。
        env.removeValue(forKey: "ANTHROPIC_API_KEY")

        // 与 Claude Code 每节点激活互斥性无关（Science 不写 settings.json），此处不接管任何 CLI 配置。
        // 1) 起代理进程（固定端口，复用 Claude 转换链路）。
        do {
            try await runtime.start(port: config.port, bindHost: config.bindAddress, env: env, nodeId: node.id, nodeName: node.name)
        } catch {
            operationError = error.localizedDescription
            scienceMgrLog.error("Failed to start Science proxy: \(String(describing: error), privacy: .public)")
            return
        }

        // 2) 起 Science：接管真实实例（8765 反代 + 内部 14411 daemon）或隔离沙箱（14410）。
        let proxyPort = config.port
        let adopting = config.effectiveAdoptReal
        // 接管态健康检查内部 daemon 端口（14411）；沙箱态检查沙箱端口。
        let healthPort = adopting ? GlobalProxyConfig.realInstanceInternalPort : config.effectiveSciencePort
        let sandboxListen = config.effectiveSciencePort
        let adoptEmail = config.effectiveSandboxEmail
        do {
            if adopting {
                try await Task.detached(priority: .userInitiated) {
                    // 解耦版：清场（退桌面 app + 腾端口 + 删残留劫持锁）→ 独立 data-dir 起虚拟登录 daemon（内部端口）。
                    // 绝不碰真实 ~/.claude-science 凭证；仅劫持它的 operon.lock（运行期文件，停用即删）。
                    ScienceRealAdopt.prepareForAdopt()
                    try ScienceRealAdopt.startInternalDaemon(proxyPort: proxyPort, email: adoptEmail)
                }.value
            } else {
                let paths = ScienceSandboxPaths.make()
                let email = config.effectiveSandboxEmail
                try await Task.detached(priority: .userInitiated) {
                    try ScienceSandbox.prepare(paths: paths)
                    _ = try ScienceVirtualLogin.ensure(authDir: paths.dataDir, email: email, sandboxRoot: paths.home)
                    try ScienceSandbox.launch(paths: paths, sciencePort: sandboxListen, proxyPort: proxyPort)
                }.value
            }
        } catch {
            runtime.stop()
            operationError = error.localizedDescription
            scienceMgrLog.error("Failed to launch Science: \(String(describing: error), privacy: .public)")
            return
        }

        // 3) 健康检查（Science daemon 起来需要几秒）。
        let healthy = await ScienceSandbox.waitForHealth(sciencePort: healthPort)
        sandboxHealthy = healthy

        // 3b) 接管态：daemon 必须就绪 → 起 8765 反代（bind 成功才算数）→ 劫持 lock → 自探 8765 返回已登录页。
        //     任一步失败：拆反代 + 停内部 daemon + 还原真实登录 + 停代理，明确报错、绝不落激活态（免得又是「假成功」）。
        if adopting {
            guard healthy else {
                await teardownAdopt()
                runtime.stop()
                operationError = AppSettings.shared.t(
                    "The adopted Claude Science daemon didn't become healthy in time.",
                    "被接管的 Claude Science daemon 未能在预期时间内就绪。"
                )
                scienceMgrLog.error("Adopt aborted: internal daemon unhealthy on :\(healthPort)")
                return
            }
            do {
                try await ScienceAuthProxy.shared.start(
                    listenPort: GlobalProxyConfig.realInstancePort,
                    upstreamPort: GlobalProxyConfig.realInstanceInternalPort,
                    dataDir: ScienceRealAdopt.adoptDataDir
                )
            } catch {
                await teardownAdopt()
                runtime.stop()
                operationError = error.localizedDescription
                scienceMgrLog.error("Adopt aborted: auth proxy bind failed: \(String(describing: error), privacy: .public)")
                return
            }
            await Task.detached(priority: .userInitiated) { ScienceRealAdopt.hijackLock() }.value

            // 自探：反代对 GET / 注 cookie 后应返回 200（已登录）。失败即回滚，避免再出现「仍显示登录页」。
            let served = await ScienceAuthProxy.probe(listenPort: GlobalProxyConfig.realInstancePort)
            if !served {
                await teardownAdopt()
                runtime.stop()
                operationError = AppSettings.shared.t(
                    "The login-free proxy on 8765 didn't serve a logged-in page. Aborted and restored your real login.",
                    "8765 免登录反代未能返回已登录页，已中止并还原真实登录。"
                )
                scienceMgrLog.error("Adopt aborted: 8765 self-probe not logged-in")
                return
            }
            scienceMgrLog.info("Adopt verified: 8765 reverse proxy serving logged-in page")
        }

        // 4) 持久化激活态；就绪则开浏览器。
        config.isEnabled = true
        config.activeNodeId = nodeId
        persist()
        scienceMgrLog.info("Science proxy started (proxy=\(proxyPort), adoptReal=\(adopting), healthy=\(healthy))")
        if healthy, openBrowserOnReady {
            openInBrowser()
        }
    }

    /// 接管失败回滚：停 8765 反代 → 停独立 daemon + 删（被劫持的）真实 operon.lock。绝不动真实凭证。
    private func teardownAdopt() async {
        ScienceAuthProxy.shared.stop()
        await Task.detached(priority: .userInitiated) {
            ScienceRealAdopt.stopAdoptedDaemon()
        }.value
        sandboxHealthy = false
    }

    /// 热切换激活上游节点：进程不重启、Science 无感。
    func switchActiveNode(to nodeId: String) async {
        guard !isBusy else { return }
        guard config.isEnabled, runtime.isProcessRunning else {
            await start(activeNodeId: nodeId)
            return
        }
        guard nodeId != config.activeNodeId else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        guard let node = node(for: nodeId), let payload = adapter.switchPayload(config: config, nodeId: nodeId) else {
            operationError = AppSettings.shared.t("Selected node not found.", "未找到所选节点。")
            return
        }
        do {
            try await runtime.switchUpstream(
                payload: payload,
                adminPath: adapter.adminPath(config: config),
                nodeId: node.id,
                nodeName: node.name
            )
            config.activeNodeId = nodeId
            persist()
        } catch {
            operationError = error.localizedDescription
            scienceMgrLog.error("Failed to hot-switch Science node: \(String(describing: error), privacy: .public)")
        }
    }

    /// 停止：停沙箱 Science（只停沙箱 data-dir）+ 停代理进程。绝不影响真实实例 8765。
    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        defer { isBusy = false }

        let adopting = config.effectiveAdoptReal
        let paths = ScienceSandboxPaths.make()
        if adopting {
            ScienceAuthProxy.shared.stop() // 先停 8765 反代
        }
        await Task.detached(priority: .userInitiated) {
            if adopting {
                // 停独立 daemon + 删（被劫持的）真实 operon.lock。绝不动真实凭证。
                ScienceRealAdopt.stopAdoptedDaemon()
            } else {
                try? ScienceSandbox.stop(paths: paths)
            }
        }.value
        runtime.stop()
        sandboxHealthy = false
        config.isEnabled = false
        persist()
        scienceMgrLog.info("Science proxy stopped (adoptReal=\(adopting))")
    }

    // MARK: - Launch Restore

    func restoreOnLaunch() async {
        guard config.isEnabled else { return }
        guard AppSettings.shared.proxyAutoRestoreOnLaunch else { return }
        guard let nodeId = config.activeNodeId, node(for: nodeId) != nil else {
            scienceMgrLog.notice("Science proxy active node missing on launch; disabling")
            config.isEnabled = false
            persist()
            return
        }
        await start(activeNodeId: nodeId, openBrowserOnReady: false)
    }

    // MARK: - Browser / Sandbox utilities

    /// 打开已登录的 Science。
    /// - 接管态：直接开 http://localhost:8765/（反代给每个请求注入会话 cookie → 免登录）。
    /// - 沙箱态：向守护要一个带会话令牌的单次链接（`claude-science url`）再开；失败回退裸地址。
    func openInBrowser() {
        if config.effectiveAdoptReal {
            if let url = URL(string: "http://localhost:\(GlobalProxyConfig.realInstancePort)/") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let paths = ScienceSandboxPaths.make()
        let fallback = "http://127.0.0.1:\(config.effectiveScienceListenPort)"
        Task { @MainActor in
            let link = await Task.detached(priority: .userInitiated) {
                ScienceSandbox.loginURL(paths: paths)
            }.value
            let target = link ?? fallback
            if link == nil {
                scienceMgrLog.notice("claude-science url unavailable; opening bare address")
            }
            guard let url = URL(string: target) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func openSandboxFolder() {
        let path = ScienceSandboxPaths.make().home
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 重置沙箱（仅停用态）：删除沙箱 HOME，下次启动重新克隆运行时并新铸虚拟登录。
    /// 护栏：路径必须落在 ~/.config/aiusage/science-sandbox 之下。
    func resetSandbox() {
        guard !config.isEnabled else { return }
        let home = ScienceSandboxPaths.make().home
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".config/aiusage/science-sandbox")
        let resolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
            operationError = AppSettings.shared.t("Refused: sandbox path is outside the managed directory.", "拒绝：沙箱路径不在受管目录内。")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: home) {
                try FileManager.default.removeItem(atPath: home)
            }
            sandboxHealthy = false
        } catch {
            operationError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func persist() {
        GlobalProxyStore.save(config, track: track)
    }
}
