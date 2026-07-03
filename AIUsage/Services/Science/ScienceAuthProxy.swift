import Foundation
import Network
import os.log

// MARK: - Science Auth Proxy（接管模式下的 8765 反向代理）
// 让【双击 Claude Science.app / 浏览器打开 http://localhost:8765】都免登录。
//
// 背景：Claude Science daemon 用一次性 nonce 换取 operon 会话 cookie（operon_auth / operon_csrf）来鉴权，
// nonce 消费后 cookie 才生效；且 cookie 绑定 daemon 本次启动的签名密钥，daemon 重启即失效。桌面 app 附着到
// 已存在 daemon 时只会打开裸链接 → 落到 /login。本 build 又封死了 require_token=false，无法从配置关闭鉴权。
//
// 方案：真实 daemon 跑在内部端口（14411），本代理占用对外的 8765，做透明反代并给每个请求注入一份【当前有效】
// 的 operon 会话 cookie（自己通过 daemon.sock 铸 nonce → 换 cookie 得来），于是 app/浏览器无论打开 / 还是
// /login 都被判为已登录。daemon 重启导致 cookie 失效时（上游 401 / 302→/login）自动重铸并重试。
//
// 安全边界：仅监听回环（127.0.0.1 + ::1）；只转发到本机内部 daemon；cookie 只在本机内存缓存，不落盘、不进日志。
// 与推理链路（QuotaServer, 14402 端口）完全分离——本代理只管 Science 的 Web/WS 会话鉴权。

private let authProxyLog = Logger(subsystem: "com.aiusage.desktop", category: "ScienceAuthProxy")

final class ScienceAuthProxy: @unchecked Sendable {
    static let shared = ScienceAuthProxy()

    private let stateLock = NSLock()
    private var listeners: [NWListener] = []
    private var _listenPort = 0
    private var _upstreamPort = 0
    private var _dataDir = ""
    private var _cookies: (auth: String, csrf: String)?
    private var _running = false

    private init() {}

    var isRunning: Bool { stateLock.withLock { _running } }

    // MARK: - Lifecycle

    /// 启动反代：占用 listenPort（回环），把流量转发到内部 daemon upstreamPort，用 dataDir/daemon.sock 铸 cookie。
    /// 幂等：已在相同参数上运行则忽略；参数变化则先停再起。
    /// 关键：等主监听（IPv4）真正 bind 到 .ready 才返回；端口被占用等 bind 失败即抛错（不再静默成功）。
    func start(listenPort: Int, upstreamPort: Int, dataDir: String) async throws {
        let alreadyRunning = stateLock.withLock {
            _running && _listenPort == listenPort && _upstreamPort == upstreamPort && _dataDir == dataDir
        }
        if alreadyRunning { return }
        stop()

        stateLock.withLock {
            _listenPort = listenPort
            _upstreamPort = upstreamPort
            _dataDir = dataDir
            _cookies = nil
            _running = true
        }

        // 预铸一份 cookie（失败不致命——首个请求会再兜底重铸）。
        _ = ensureCookies(forceRefresh: true)

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

    /// 只读探活：反代应对 GET / 注入 cookie 后返回 200（已登录）。用于启动后自检与展示。
    static func probe(listenPort: Int, timeout: TimeInterval = 6) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(listenPort)/") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            do {
                var req = URLRequest(url: url, timeoutInterval: 2)
                req.httpMethod = "GET"
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 { return true }
            } catch {
                // 未起来 / 连接被拒 → 继续轮询
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        return false
    }

    func stop() {
        let old = stateLock.withLock { () -> [NWListener] in
            let l = listeners
            listeners = []
            _running = false
            _cookies = nil
            return l
        }
        old.forEach { $0.cancel() }
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

    private var cookies: (auth: String, csrf: String)? { stateLock.withLock { _cookies } }
    private var upstreamPort: Int { stateLock.withLock { _upstreamPort } }
    private var dataDir: String { stateLock.withLock { _dataDir } }

    /// 确保有一份 cookie；forceRefresh 或缺失时重铸。返回当前 cookie（可能为 nil）。
    @discardableResult
    private func ensureCookies(forceRefresh: Bool) -> (auth: String, csrf: String)? {
        if !forceRefresh, let c = cookies { return c }
        guard let nonce = mintNonce() else {
            authProxyLog.error("mint nonce failed")
            return cookies
        }
        guard let fresh = exchangeNonceForCookies(nonce: nonce) else {
            authProxyLog.error("exchange nonce for cookies failed")
            return cookies
        }
        stateLock.withLock { _cookies = fresh }
        return fresh
    }

    /// 通过 daemon 控制套接字（Unix socket）铸一个一次性 nonce：POST /nonce。
    private func mintNonce() -> String? {
        let sock = (dataDir as NSString).appendingPathComponent("daemon.sock")
        let req = "POST /nonce HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        guard let resp = Self.posixRequestUnix(socketPath: sock, request: Data(req.utf8)),
              let body = Self.httpBody(resp),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let nonce = json["nonce"] as? String, !nonce.isEmpty else {
            return nil
        }
        return nonce
    }

    /// 用 nonce 向内部 daemon 换取 operon_auth / operon_csrf：GET /?nonce=<nonce>，解析 Set-Cookie。
    private func exchangeNonceForCookies(nonce: String) -> (auth: String, csrf: String)? {
        let port = upstreamPort
        let req = "GET /?nonce=\(nonce) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        guard let resp = Self.posixRequestTCP(host: "127.0.0.1", port: port, request: Data(req.utf8)),
              let head = Self.httpHeadString(resp) else { return nil }
        guard let auth = Self.cookieValue("operon_auth", in: head),
              let csrf = Self.cookieValue("operon_csrf", in: head) else { return nil }
        return (auth, csrf)
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
            let target = req.queryValue("redirect")?.removingPercentEncoding ?? "/"
            let safeTarget = target.hasPrefix("/") ? target : "/"
            await Self.send(conn, data: redirectResponse(location: safeTarget))
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
        let cookie = ensureCookies(forceRefresh: false)
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
            _ = ensureCookies(forceRefresh: true)
            return await forwardHTTP(req: req, body: body, allowRetry: false)
        }

        return rewriteResponseForClient(resp: resp, head: head, cookie: cookie)
    }

    // MARK: - WebSocket 隧道

    private func handleWebSocket(client: NWConnection, req: ParsedRequest, headData: Data, leftover: Data) async {
        let cookie = ensureCookies(forceRefresh: false)
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
    private func buildUpstreamRequest(req: ParsedRequest, body: Data, cookie: (auth: String, csrf: String)?, websocket: Bool) -> Data {
        var lines = "\(req.method) \(req.path) HTTP/1.1\r\n"
        let port = upstreamPort
        // 内部 daemon 用「同源」校验（CORS + WS）：只放行【自身监听端口】的 origin，
        // 浏览器发来的 origin 是对外的 8765 → 会被判「forbidden origin / origin not allowed」。
        // 故把 Origin / Referer 改写成 daemon 自身 origin，让其视为同源放行。
        let upstreamOrigin = "http://127.0.0.1:\(port)"
        // 原样保留除 host / cookie / origin / referer / connection（普通请求）外的所有头；WS 保留 connection/upgrade。
        for (name, value) in req.headerPairs {
            let lower = name.lowercased()
            if lower == "host" || lower == "cookie" || lower == "origin" || lower == "referer" { continue }
            if !websocket, lower == "connection" { continue }
            lines += "\(name): \(value)\r\n"
        }
        lines += "Host: 127.0.0.1:\(port)\r\n"
        // Origin：浏览器对非 GET / WS 会带；一律改写为 daemon 自身 origin。
        if req.headerPairs.contains(where: { $0.name.lowercased() == "origin" }) || websocket {
            lines += "Origin: \(upstreamOrigin)\r\n"
        }
        // Referer：保留原 path/query，仅替换 origin 前缀。
        if let referer = req.headerPairs.first(where: { $0.name.lowercased() == "referer" })?.value {
            lines += "Referer: \(Self.rewriteRefererOrigin(referer, to: upstreamOrigin))\r\n"
        }
        // 合并 cookie：丢弃客户端可能残留的旧 operon_*，追加当前有效值。
        var cookieParts = req.otherCookiePairs
        if let c = cookie {
            cookieParts.append("operon_auth=\(c.auth)")
            cookieParts.append("operon_csrf=\(c.csrf)")
        }
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
    private func rewriteResponseForClient(resp: Data, head: String, cookie: (auth: String, csrf: String)?) -> Data {
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
        if isHTML, let c = cookie {
            rebuilt += "Set-Cookie: operon_auth=\(c.auth); HttpOnly; SameSite=Strict; Path=/\r\n"
            rebuilt += "Set-Cookie: operon_csrf=\(c.csrf); SameSite=Strict; Path=/\r\n"
        }
        rebuilt += "\r\n"
        var out = Data(rebuilt.utf8)
        out.append(body)
        return out
    }

    private func redirectResponse(location: String) -> Data {
        var s = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n"
        if let c = cookies {
            s += "Set-Cookie: operon_auth=\(c.auth); HttpOnly; SameSite=Strict; Path=/\r\n"
            s += "Set-Cookie: operon_csrf=\(c.csrf); SameSite=Strict; Path=/\r\n"
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

    var errorDescription: String? {
        switch self {
        case .listenFailed(let port):
            return AppSettings.shared.t(
                "Failed to bind the Claude Science auth proxy on port \(port). Is it already in use?",
                "无法在端口 \(port) 启动 Claude Science 鉴权代理，端口可能被占用。"
            )
        }
    }
}
