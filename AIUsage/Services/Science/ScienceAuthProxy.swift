import Foundation
import Network
import os.log

// MARK: - Science Auth / Catalog Proxy（两种模式共用的公开反向代理）
// 沙箱模式监听用户配置的公开端口；接管模式监听 8765。两者都注入本地会话并直接提供当前模型目录。
//
// 背景：Claude Science daemon 用一次性 nonce 换取 operon 会话 cookie（operon_auth / operon_csrf）来鉴权，
// nonce 消费后 cookie 才生效；且 cookie 绑定 daemon 本次启动的签名密钥，daemon 重启即失效。桌面 app 附着到
// 已存在 daemon 时只会打开裸链接 → 落到 /login。本 build 又封死了 require_token=false，无法从配置关闭鉴权。
//
// 方案：daemon 只跑内部端口（接管 14411 / 沙箱 14412），本代理占用公开端口，做透明反代并给每个请求
// 注入一份【当前有效】的 operon 会话 cookie（自己通过 daemon.sock 铸 nonce → 换 cookie 得来），于是浏览器
// 无论打开 / 还是 /login 都被判为已登录。daemon 重启导致 cookie 失效时自动重铸并重试。
//
// 安全边界：仅监听回环（127.0.0.1 + ::1）；只转发到本机内部 daemon；cookie 只在本机内存缓存，不落盘、不进日志。
// 与推理链路（QuotaServer, 14402 端口）完全分离——本代理只管 Science 的 Web/WS 会话鉴权。

private let authProxyLog = Logger(subsystem: "com.aiusage.desktop", category: "ScienceAuthProxy")

struct ScienceAuthProbeResult {
    let succeeded: Bool
    let statusCode: Int?
    let location: String?
    let contentType: String?
    let bodyPrefix: String?
    let transportError: String?

    var summary: String {
        var parts: [String] = []
        if let statusCode { parts.append("status=\(statusCode)") }
        if let location, !location.isEmpty { parts.append("location=\(location)") }
        if let contentType, !contentType.isEmpty { parts.append("content-type=\(contentType)") }
        if let bodyPrefix, !bodyPrefix.isEmpty { parts.append("body=\(bodyPrefix)") }
        if let transportError, !transportError.isEmpty { parts.append("error=\(transportError)") }
        return parts.isEmpty ? "no response details" : parts.joined(separator: ", ")
    }
}

private struct ScienceAuthFailure: Error {
    enum Stage: String {
        case mintNonce = "mint-nonce"
        case exchangeCookies = "exchange-cookies"
    }

    let stage: Stage
    let reason: String
    let statusCode: Int?
    let location: String?
    let contentType: String?
    let bodyPrefix: String?

    var summary: String {
        var parts = ["stage=\(stage.rawValue)", "reason=\(reason)"]
        if let statusCode { parts.append("status=\(statusCode)") }
        if let location, !location.isEmpty { parts.append("location=\(location)") }
        if let contentType, !contentType.isEmpty { parts.append("content-type=\(contentType)") }
        if let bodyPrefix, !bodyPrefix.isEmpty { parts.append("body=\(bodyPrefix)") }
        return parts.joined(separator: ", ")
    }
}

final class ScienceAuthProxy: @unchecked Sendable {
    static let shared = ScienceAuthProxy()

    private let stateLock = NSLock()
    private var listeners: [NWListener] = []
    private var _listenPort = 0
    private var _upstreamPort = 0
    private var _dataDir = ""
    private var _cookies: ScienceSessionCookies?
    private var _lastAuthFailure: ScienceAuthFailure?
    private var _modelCatalog: ScienceModelCatalog?
    private var _running = false

    private init() {}

    var isRunning: Bool { stateLock.withLock { _running } }

    // MARK: - Lifecycle

    /// 启动反代：占用 listenPort（回环），把流量转发到内部 daemon upstreamPort，用 dataDir/daemon.sock 铸 cookie。
    /// 幂等：已在相同参数上运行则忽略；参数变化则先停再起。
    /// 关键：等主监听（IPv4）真正 bind 到 .ready 才返回；端口被占用等 bind 失败即抛错（不再静默成功）。
    func start(
        listenPort: Int,
        upstreamPort: Int,
        dataDir: String,
        modelCatalog: ScienceModelCatalog? = nil
    ) async throws {
        let alreadyRunning = stateLock.withLock {
            _running && _listenPort == listenPort && _upstreamPort == upstreamPort && _dataDir == dataDir
        }
        if alreadyRunning {
            stateLock.withLock { _modelCatalog = modelCatalog }
            return
        }
        stop()

        stateLock.withLock {
            _listenPort = listenPort
            _upstreamPort = upstreamPort
            _dataDir = dataDir
            _cookies = nil
            _lastAuthFailure = nil
            _modelCatalog = modelCatalog
            _running = true
        }

        // 先确认 nonce → cookie 链路真实可用，再占 8765 和劫持真实 lock。
        // 新版 daemon 的 HTTP 头/响应格式若变化，会在这里给出脱敏诊断，
        // 不再拖到最后只报一个模糊的 8765 自探失败。
        guard await bootstrapSession(timeout: 8) else {
            let details = stateLock.withLock {
                _lastAuthFailure?.summary ?? "no authentication response"
            }
            stateLock.withLock { _running = false }
            throw ScienceAuthProxyError.sessionBootstrapFailed(details: details)
        }

        var started: [NWListener] = []
        do {
            // 主监听（IPv4）必须 bind 成功，否则接管无意义 → 抛错让上层清理并报错。
            started.append(try await makeReadyListener(host: "127.0.0.1", port: listenPort))
        } catch {
            stateLock.withLock { _running = false }
            authProxyLog.error("ScienceAuthProxy bind :\(listenPort) failed: \(error.localizedDescription, privacy: .public)")
            throw ScienceAuthProxyError.listenFailed(port: listenPort)
        }
        // IPv6 尽力而为（部分环境无 ::1，不致命）。
        if let v6 = try? await makeReadyListener(host: "::1", port: listenPort) {
            started.append(v6)
        }
        stateLock.withLock { listeners = started }
        authProxyLog.info("ScienceAuthProxy listening on :\(listenPort) → 127.0.0.1:\(upstreamPort)")
    }

    /// 只读探活：不跟随重定向，返回脱敏的状态/Location/Content-Type/正文摘要。
    func probe(listenPort: Int, timeout: TimeInterval = 6) async -> ScienceAuthProbeResult {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ScienceAuthProbeResult(
            succeeded: false,
            statusCode: nil,
            location: nil,
            contentType: nil,
            bodyPrefix: nil,
            transportError: "proxy did not respond"
        )
        repeat {
            let request = Data(
                "GET / HTTP/1.1\r\nHost: localhost:\(listenPort)\r\nAccept: text/html\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8
            )
            if let raw = await Self.tcpRoundTrip(host: "127.0.0.1", port: listenPort, request: request),
               let response = Self.parseHTTPResponse(raw) {
                let location = response.header("location").map { Self.redactedText($0) }
                let contentType = response.header("content-type")
                let bodyPrefix = String(data: response.body.prefix(512), encoding: .utf8)
                    .map { Self.redactedText($0) }
                last = ScienceAuthProbeResult(
                    succeeded: response.statusCode == 200,
                    statusCode: response.statusCode,
                    location: location,
                    contentType: contentType,
                    bodyPrefix: response.statusCode == 200 ? nil : bodyPrefix,
                    transportError: nil
                )
                if last.succeeded { return last }
            } else {
                last = ScienceAuthProbeResult(
                    succeeded: false,
                    statusCode: nil,
                    location: nil,
                    contentType: nil,
                    bodyPrefix: nil,
                    transportError: "connection failed or malformed HTTP response"
                )
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        return last
    }

    func stop() {
        let old = stateLock.withLock { () -> [NWListener] in
            let l = listeners
            listeners = []
            _running = false
            _cookies = nil
            _lastAuthFailure = nil
            _modelCatalog = nil
            return l
        }
        old.forEach { $0.cancel() }
    }

    /// Hot-swap only the UI catalog. The daemon, auth session and listener stay
    /// alive; the next settings-page request observes the new node immediately.
    func updateModelCatalog(_ catalog: ScienceModelCatalog?) {
        stateLock.withLock { _modelCatalog = catalog }
    }

    /// 建监听并等待其到达 .ready（或 .failed 抛错）后才返回，确保「返回即已 bind」。
    private func makeReadyListener(host: String, port: Int) async throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ScienceAuthProxyError.listenFailed(port: port)
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            Task { await self.handleClient(conn) }
        }

        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let err):
                    if once.claim() { cont.resume(throwing: err) }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: ScienceAuthProxyError.listenFailed(port: port)) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        // bind 成功后：状态处理器降级为只记录后续故障。
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                authProxyLog.error("listener(\(host)) failed after ready: \(err.localizedDescription, privacy: .public)")
            }
        }
        return listener
    }

    // MARK: - Cookie 铸造（nonce → operon 会话 cookie）

    private var cookies: ScienceSessionCookies? { stateLock.withLock { _cookies } }
    private var modelCatalog: ScienceModelCatalog? { stateLock.withLock { _modelCatalog } }
    private var upstreamPort: Int { stateLock.withLock { _upstreamPort } }
    private var dataDir: String { stateLock.withLock { _dataDir } }

    private func bootstrapSession(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ensureCookies(forceRefresh: true) != nil { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        return false
    }

    /// 确保有一份 cookie；forceRefresh 或缺失时重铸。失败信息只保存脱敏摘要。
    @discardableResult
    private func ensureCookies(forceRefresh: Bool) -> ScienceSessionCookies? {
        if !forceRefresh, let c = cookies { return c }
        let nonce: String
        switch mintNonce() {
        case .success(let value):
            nonce = value
        case .failure(let failure):
            stateLock.withLock { _lastAuthFailure = failure }
            authProxyLog.error("\(failure.summary, privacy: .public)")
            return forceRefresh ? nil : cookies
        }
        switch exchangeNonceForCookies(nonce: nonce) {
        case .success(let fresh):
            stateLock.withLock {
                _cookies = fresh
                _lastAuthFailure = nil
            }
            authProxyLog.info("Science session cookie bootstrap succeeded (count=\(fresh.items.count))")
            return fresh
        case .failure(let failure):
            stateLock.withLock { _lastAuthFailure = failure }
            authProxyLog.error("\(failure.summary, privacy: .public)")
            return forceRefresh ? nil : cookies
        }
    }

    /// 通过 daemon 控制套接字（Unix socket）铸一个一次性 nonce：POST /nonce。
    private func mintNonce() -> Result<String, ScienceAuthFailure> {
        let sock = (dataDir as NSString).appendingPathComponent("daemon.sock")
        let req = "POST /nonce HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        guard let raw = Self.posixRequestUnix(socketPath: sock, request: Data(req.utf8)) else {
            return nonceCLIFallback(after: ScienceAuthFailure(
                stage: .mintNonce,
                reason: "daemon.sock unavailable or timed out",
                statusCode: nil,
                location: nil,
                contentType: nil,
                bodyPrefix: nil
            ))
        }
        guard let response = Self.parseHTTPResponse(raw) else {
            return nonceCLIFallback(after: ScienceAuthFailure(
                stage: .mintNonce,
                reason: "malformed HTTP response",
                statusCode: nil,
                location: nil,
                contentType: nil,
                bodyPrefix: nil
            ))
        }
        guard (200..<300).contains(response.statusCode) else {
            return nonceCLIFallback(after: failure(
                stage: .mintNonce,
                reason: "HTTP request rejected",
                response: response
            ))
        }
        guard let nonce = Self.nonceValue(from: response.body), !nonce.isEmpty else {
            return nonceCLIFallback(after: failure(
                stage: .mintNonce,
                reason: "response did not contain a nonce",
                response: response
            ))
        }
        return .success(nonce)
    }

    /// 官方 CLI 是版本化的兼容边界；私有 /nonce 响应变化时，用它获取同一 data-dir 的单次链接。
    private func nonceCLIFallback(after failure: ScienceAuthFailure) -> Result<String, ScienceAuthFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ScienceSandboxPaths.scienceBinary)
        process.arguments = ["url", "--data-dir", dataDir]
        var environment = ProcessInfo.processInfo.environment
        environment["no_proxy"] = "127.0.0.1,localhost,::1"
        environment["NO_PROXY"] = "127.0.0.1,localhost,::1"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(failure)
        }
        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return .failure(failure)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let nonce = Self.nonceValue(from: data), !nonce.isEmpty else {
            return .failure(failure)
        }
        authProxyLog.info("Science nonce CLI fallback succeeded")
        return .success(nonce)
    }

    /// 用 nonce 向内部 daemon 换取当前版本下发的会话 cookie。
    private func exchangeNonceForCookies(nonce: String) -> Result<ScienceSessionCookies, ScienceAuthFailure> {
        let port = upstreamPort
        let requests = Self.nonceExchangeRequests(nonce: nonce, port: port)
        guard !requests.isEmpty else {
            return .failure(ScienceAuthFailure(
                stage: .exchangeCookies,
                reason: "nonce could not be URL-encoded",
                statusCode: nil,
                location: nil,
                contentType: nil,
                bodyPrefix: nil
            ))
        }

        var attemptDetails: [String] = []
        var lastResponse: ScienceHTTPResponse?
        for exchange in requests {
            guard let raw = Self.posixRequestTCP(
                host: "127.0.0.1",
                port: port,
                request: exchange.data
            ) else {
                attemptDetails.append("\(exchange.mode.rawValue): transport-error")
                continue
            }
            guard let response = Self.parseHTTPResponse(raw),
                  let head = Self.httpHeadString(raw) else {
                attemptDetails.append("\(exchange.mode.rawValue): malformed-response")
                continue
            }
            let fresh = Self.sessionCookies(in: head)
            var details = ["\(exchange.mode.rawValue): status=\(response.statusCode)"]
            if let location = response.header("location") {
                details.append("location=\(Self.redactedText(location))")
            }
            if let contentType = response.header("content-type") {
                details.append("content-type=\(Self.redactedText(contentType))")
            }
            var cookieNames = fresh.items.prefix(8).map { String($0.name.prefix(40)) }.sorted()
            if fresh.items.count > cookieNames.count { cookieNames.append("...") }
            details.append("cookie-names=[\(cookieNames.joined(separator: ","))]")
            attemptDetails.append(details.joined(separator: " "))

            let hasSessionCookie = fresh.items.contains {
                let name = $0.name.lowercased()
                return name == "operon_auth" || name.contains("auth") || name.contains("session") || name.contains("token")
            }
            if !fresh.isEmpty, hasSessionCookie {
                authProxyLog.info("Science cookie exchange succeeded via \(exchange.mode.rawValue, privacy: .public)")
                return .success(fresh)
            }
            lastResponse = response
        }

        let reason = "no recognizable session cookie; attempts=\(attemptDetails.joined(separator: " | "))"
        if let lastResponse {
            return .failure(failure(
                stage: .exchangeCookies,
                reason: reason,
                response: lastResponse
            ))
        }
        return .failure(ScienceAuthFailure(
            stage: .exchangeCookies,
            reason: reason,
            statusCode: nil,
            location: nil,
            contentType: nil,
            bodyPrefix: nil
        ))
    }

    private func failure(
        stage: ScienceAuthFailure.Stage,
        reason: String,
        response: ScienceHTTPResponse
    ) -> ScienceAuthFailure {
        let body = String(data: response.body.prefix(512), encoding: .utf8)
            .map { Self.redactedText($0) }
        return ScienceAuthFailure(
            stage: stage,
            reason: reason,
            statusCode: response.statusCode,
            location: response.header("location").map { Self.redactedText($0) },
            contentType: response.header("content-type"),
            bodyPrefix: body
        )
    }

    // MARK: - 每连接处理

    private func handleClient(_ conn: NWConnection) async {
        conn.start(queue: .global())
        defer { conn.cancel() }

        guard let (headData, leftover) = await Self.recvUntilHeaderEnd(conn) else { return }
        guard let req = Self.parseRequestHead(headData) else { return }

        // WebSocket 升级：透明隧道（注 cookie 后原样对接双向字节流）。
        if req.isWebSocketUpgrade {
            await handleWebSocket(client: conn, req: req, headData: headData, leftover: leftover)
            return
        }

        // /login → 直接 302 到 redirect 目标（默认 /）：浏览器随后带上我们下发的 cookie 请求 / → 已登录。
        if req.pathOnly == "/login" || req.pathOnly.hasPrefix("/login/") {
            let target = Self.safeLocalRedirect(req.queryValue("redirect"))
            await Self.send(conn, data: redirectResponse(location: target))
            return
        }

        // The model catalog contains no credentials and is sourced only from
        // the active AIUsage node. Intercept the final Science API rather than
        // its internal upstream fetch so node switches bypass daemon caches.
        if req.method == "GET", req.pathOnly == "/api/models", let catalog = modelCatalog {
            await Self.send(conn, data: Self.modelCatalogResponse(catalog))
            return
        }

        // 读取请求体（若有 Content-Length）。
        var body = leftover
        if let len = req.contentLength, body.count < len {
            body.append(await Self.recvExact(conn, count: len - body.count))
        }

        // 转发（上游 401 / 302→/login 视为会话失效 → 重铸 cookie 重试一次）。
        let respData = await forwardHTTP(req: req, body: body, allowRetry: true)
        await Self.send(conn, data: respData)
    }

    /// 普通 HTTP 转发：重写头（注 cookie / Host），上游 Connection: close 读满响应，按需给浏览器补 Set-Cookie。
    private func forwardHTTP(req: ParsedRequest, body: Data, allowRetry: Bool) async -> Data {
        guard let cookie = ensureCookies(forceRefresh: false) else {
            let details = stateLock.withLock { _lastAuthFailure?.summary ?? "no session cookie" }
            return Self.plainResponse(
                status: 503,
                text: "Science authentication unavailable (\(details))"
            )
        }
        let port = upstreamPort
        let upstreamReq = buildUpstreamRequest(req: req, body: body, cookie: cookie, websocket: false)

        guard let resp = await Self.tcpRoundTrip(host: "127.0.0.1", port: port, request: upstreamReq),
              let head = Self.httpHeadString(resp) else {
            return Self.plainResponse(status: 502, text: "Science daemon unreachable")
        }

        // 会话失效检测：401，或 3xx 重定向到 /login。
        let status = Self.statusCode(head)
        let location = Self.headerValue("location", in: head) ?? ""
        let sessionInvalid = status == 401 || ((300..<400).contains(status) && location.contains("/login"))
        if sessionInvalid, allowRetry {
            guard ensureCookies(forceRefresh: true) != nil else {
                let details = stateLock.withLock { _lastAuthFailure?.summary ?? "session refresh failed" }
                return Self.plainResponse(
                    status: 503,
                    text: "Science authentication refresh failed (\(details))"
                )
            }
            return await forwardHTTP(req: req, body: body, allowRetry: false)
        }

        return rewriteResponseForClient(resp: resp, head: head, cookie: cookie)
    }

    // MARK: - WebSocket 隧道

    private func handleWebSocket(client: NWConnection, req: ParsedRequest, headData: Data, leftover: Data) async {
        guard let cookie = ensureCookies(forceRefresh: false) else {
            await Self.send(client, data: Self.plainResponse(
                status: 503,
                text: "Science authentication unavailable"
            ))
            return
        }
        let port = upstreamPort
        let upgradeHead = buildUpstreamRequest(req: req, body: Data(), cookie: cookie, websocket: true)

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let upstream = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        upstream.start(queue: .global())
        defer { upstream.cancel() }

        await Self.send(upstream, data: upgradeHead)
        if !leftover.isEmpty { await Self.send(upstream, data: leftover) }

        // 双向对拷，直到任一端关闭。
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(from: client, to: upstream) }
            group.addTask { await Self.pump(from: upstream, to: client) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - 头重写

    /// 构造发往内部 daemon 的请求字节：保留原头，重写 Host / Origin / Referer、注入 operon cookie，普通请求强制 Connection: close。
    private func buildUpstreamRequest(req: ParsedRequest, body: Data, cookie: ScienceSessionCookies, websocket: Bool) -> Data {
        var lines = "\(req.method) \(req.path) HTTP/1.1\r\n"
        let port = upstreamPort
        // 内部 daemon 用「同源」校验（CORS + WS）：只放行【自身监听端口】的 origin，
        // 浏览器发来的 origin 是公开反代端口 → 会被判「forbidden origin / origin not allowed」。
        // 故把 Origin / Referer 改写成 daemon 自身 origin，让其视为同源放行。
        let upstreamOrigin = "http://localhost:\(port)"
        // 原样保留除 host / cookie / origin / referer / connection（普通请求）外的所有头；WS 保留 connection/upgrade。
        for (name, value) in req.headerPairs {
            let lower = name.lowercased()
            if lower == "host" || lower == "cookie" || lower == "origin" || lower == "referer" { continue }
            if !websocket, lower == "connection" { continue }
            lines += "\(name): \(value)\r\n"
        }
        lines += "Host: localhost:\(port)\r\n"
        // Origin：浏览器对非 GET / WS 会带；一律改写为 daemon 自身 origin。
        if req.headerPairs.contains(where: { $0.name.lowercased() == "origin" }) || websocket {
            lines += "Origin: \(upstreamOrigin)\r\n"
        }
        // Referer：保留原 path/query，仅替换 origin 前缀。
        if let referer = req.headerPairs.first(where: { $0.name.lowercased() == "referer" })?.value {
            lines += "Referer: \(Self.rewriteRefererOrigin(referer, to: upstreamOrigin))\r\n"
        }
        // 合并 cookie：丢弃客户端可能残留的旧 operon_*，追加当前有效值。
        var cookieParts = cookie.preservingUnmanagedClientCookies(req.cookieParts)
        cookieParts.append(contentsOf: cookie.requestPairs)
        if !cookieParts.isEmpty {
            lines += "Cookie: \(cookieParts.joined(separator: "; "))\r\n"
        }
        if !websocket {
            lines += "Connection: close\r\n"
        }
        lines += "\r\n"
        var data = Data(lines.utf8)
        data.append(body)
        return data
    }

    /// 重写上游响应给浏览器：强制 Connection: close；对 text/html 响应追加 Set-Cookie，让 SPA 能读到 csrf 发 x-operon-csrf。
    private func rewriteResponseForClient(resp: Data, head: String, cookie: ScienceSessionCookies) -> Data {
        guard let sep = resp.range(of: Data([13, 10, 13, 10])) else { return resp }
        let body = resp.subdata(in: sep.upperBound..<resp.endIndex)

        let contentType = Self.headerValue("content-type", in: head) ?? ""
        let isHTML = contentType.lowercased().contains("text/html")

        var rebuilt = ""
        let headLines = head.components(separatedBy: "\r\n")
        for (i, line) in headLines.enumerated() {
            if i == 0 { rebuilt += line + "\r\n"; continue } // 状态行
            let lower = line.lowercased()
            if lower.hasPrefix("connection:") { continue }
            rebuilt += line + "\r\n"
        }
        rebuilt += "Connection: close\r\n"
        if isHTML {
            for header in cookie.clientHeaders {
                rebuilt += header + "\r\n"
            }
        }
        rebuilt += "\r\n"
        var out = Data(rebuilt.utf8)
        out.append(body)
        return out
    }

    private func redirectResponse(location: String) -> Data {
        var s = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n"
        if let c = cookies {
            for header in c.clientHeaders {
                s += header + "\r\n"
            }
        }
        s += "Content-Length: 0\r\nConnection: close\r\n\r\n"
        return Data(s.utf8)
    }
}

// MARK: - ResumeOnce（确保 continuation 只被恢复一次）

/// NWListener 状态可能多次回调；用它保证对应 continuation 只 resume 一次，避免崩溃。
private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Errors

enum ScienceAuthProxyError: LocalizedError {
    case listenFailed(port: Int)
    case sessionBootstrapFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .listenFailed(let port):
            return AppSettings.shared.t(
                "Failed to bind the Claude Science auth proxy on port \(port). Is it already in use?",
                "无法在端口 \(port) 启动 Claude Science 鉴权代理，端口可能被占用。"
            )
        case .sessionBootstrapFailed(let details):
            return AppSettings.shared.t(
                "Claude Science login session bootstrap failed (\(details)).",
                "Claude Science 登录会话初始化失败（\(details)）。"
            )
        }
    }
}
