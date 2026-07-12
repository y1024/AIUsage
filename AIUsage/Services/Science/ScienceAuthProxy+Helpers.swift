import Foundation
import Network
import Darwin

struct ScienceSessionCookie {
    let name: String
    let value: String
    let httpOnly: Bool

    var requestPair: String { "\(name)=\(value)" }

    var clientHeader: String {
        var header = "Set-Cookie: \(requestPair)"
        if httpOnly { header += "; HttpOnly" }
        // The public proxy is plain HTTP on loopback, so an upstream Secure or
        // Domain attribute would prevent the browser from returning the cookie.
        return header + "; SameSite=Strict; Path=/"
    }
}

struct ScienceSessionCookies {
    let items: [ScienceSessionCookie]

    var isEmpty: Bool { items.isEmpty }
    var requestPairs: [String] { items.map(\.requestPair) }
    var clientHeaders: [String] { items.map(\.clientHeader) }

    func preservingUnmanagedClientCookies(_ parts: [String]) -> [String] {
        // Always evict the legacy pair as well as the names minted by the
        // current daemon. This avoids sending an obsolete operon cookie beside
        // a renamed session cookie after a Science upgrade.
        let managedNames = Set(items.map { $0.name.lowercased() })
            .union(["operon_auth", "operon_csrf"])
        return parts.filter { part in
            guard let equals = part.firstIndex(of: "=") else { return true }
            let name = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            return !managedNames.contains(name)
        }
    }
}

struct ScienceHTTPResponse {
    let statusCode: Int
    let headers: [(name: String, value: String)]
    let body: Data

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.name.lowercased() == lower }?.value
    }
}

enum ScienceNonceExchangeMode: String {
    case formPOST = "POST /api/auth/nonce"
    case legacyQueryGET = "GET /?nonce=..."
}

struct ScienceNonceExchangeRequest {
    let mode: ScienceNonceExchangeMode
    let data: Data
}

// MARK: - ScienceAuthProxy 低层辅助（HTTP 解析 / 套接字 IO）
// 单一职责：把「解析请求头、回环 socket 往返、NWConnection 收发与双向对拷」这些机械活从主逻辑里抽离。

// MARK: - Parsed Request

struct ParsedRequest {
    let method: String
    /// 含 query 的原始请求目标（原样转发给上游）。
    let path: String
    let headerPairs: [(name: String, value: String)]

    var pathOnly: String { path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path }

    private func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headerPairs.first { $0.name.lowercased() == lower }?.value
    }

    var contentLength: Int? { header("content-length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    var isWebSocketUpgrade: Bool {
        (header("upgrade")?.lowercased().contains("websocket") ?? false)
    }

    /// 客户端 Cookie 头中的 name=value 片段。
    var cookieParts: [String] {
        guard let cookie = header("cookie") else { return [] }
        return cookie.split(separator: ";").compactMap { part -> String? in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func queryValue(_ key: String) -> String? {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first.map(String.init) == key {
                return kv.count > 1 ? String(kv[1]) : ""
            }
        }
        return nil
    }
}

extension ScienceAuthProxy {
    // MARK: - HTTP 解析

    /// Build both known nonce exchange shapes in compatibility order. Claude
    /// Science 0.1.15 accepts the form POST, while older releases accept the
    /// query GET. A rejected POST does not consume the nonce on legacy builds,
    /// so the same one-time nonce can safely fall back to the GET shape.
    static func nonceExchangeRequests(nonce: String, port: Int) -> [ScienceNonceExchangeRequest] {
        guard let encodedNonce = percentEncodedQueryValue(nonce) else { return [] }

        let origin = "http://127.0.0.1:\(port)"
        let body = Data("nonce=\(encodedNonce)&dest=/".utf8)
        var post = Data(
            "POST /api/auth/nonce HTTP/1.1\r\n".utf8
        )
        post.append(Data("Host: 127.0.0.1:\(port)\r\n".utf8))
        post.append(Data("Accept: application/json\r\n".utf8))
        post.append(Data("Content-Type: application/x-www-form-urlencoded\r\n".utf8))
        post.append(Data("Origin: \(origin)\r\n".utf8))
        post.append(Data("Referer: \(origin)/?nonce=\(encodedNonce)\r\n".utf8))
        post.append(Data("Content-Length: \(body.count)\r\n".utf8))
        post.append(Data("Accept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8))
        post.append(body)

        let legacy = Data((
            "GET /?nonce=\(encodedNonce) HTTP/1.1\r\n" +
            "Host: localhost:\(port)\r\n" +
            "Accept: text/html\r\n" +
            "Accept-Encoding: identity\r\n" +
            "Connection: close\r\n\r\n"
        ).utf8)

        return [
            ScienceNonceExchangeRequest(mode: .formPOST, data: post),
            ScienceNonceExchangeRequest(mode: .legacyQueryGET, data: legacy),
        ]
    }

    static func parseRequestHead(_ data: Data) -> ParsedRequest? {
        guard let text = httpHeadString(data) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var pairs: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            pairs.append((name, value))
        }
        return ParsedRequest(method: method, path: path, headerPairs: pairs)
    }

    /// 首个 \r\n\r\n 之前（含）的头文本。
    static func httpHeadString(_ data: Data) -> String? {
        guard let sep = data.range(of: Data([13, 10, 13, 10])) else {
            return String(data: data, encoding: .utf8)
        }
        return String(data: data.subdata(in: data.startIndex..<sep.lowerBound), encoding: .utf8)
    }

    /// 首个 HTTP 响应体，自动解码 chunked，并遵守 Content-Length。
    static func httpBody(_ data: Data) -> Data? {
        parseHTTPResponse(data)?.body
    }

    static func parseHTTPResponse(_ data: Data) -> ScienceHTTPResponse? {
        let separator = Data([13, 10, 13, 10])
        guard let sep = data.range(of: separator),
              let head = String(
                data: data.subdata(in: data.startIndex..<sep.lowerBound),
                encoding: .utf8
              ) else {
            return nil
        }

        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }

        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        var body = data.subdata(in: sep.upperBound..<data.endIndex)
        let transferEncoding = headers.first {
            $0.name.caseInsensitiveCompare("transfer-encoding") == .orderedSame
        }?.value.lowercased() ?? ""
        if transferEncoding.contains("chunked") {
            guard let decoded = decodeChunkedBody(body) else { return nil }
            body = decoded
        } else if let rawLength = headers.first(where: {
            $0.name.caseInsensitiveCompare("content-length") == .orderedSame
        })?.value, let length = Int(rawLength), length >= 0 {
            guard body.count >= length else { return nil }
            body = body.prefix(length)
        }

        return ScienceHTTPResponse(statusCode: status, headers: headers, body: body)
    }

    private static func decodeChunkedBody(_ body: Data) -> Data? {
        let crlf = Data([13, 10])
        var cursor = body.startIndex
        var decoded = Data()

        while cursor < body.endIndex {
            guard let lineRange = body.range(of: crlf, options: [], in: cursor..<body.endIndex),
                  let sizeLine = String(data: body.subdata(in: cursor..<lineRange.lowerBound), encoding: .ascii)
            else {
                return nil
            }
            let rawSize = sizeLine.split(separator: ";", maxSplits: 1).first ?? ""
            guard let size = Int(rawSize.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return nil
            }
            cursor = lineRange.upperBound
            if size == 0 { return decoded }

            guard let chunkEnd = body.index(cursor, offsetBy: size, limitedBy: body.endIndex),
                  chunkEnd <= body.endIndex else {
                return nil
            }
            decoded.append(body.subdata(in: cursor..<chunkEnd))
            cursor = chunkEnd
            guard let terminatorEnd = body.index(cursor, offsetBy: 2, limitedBy: body.endIndex),
                  terminatorEnd <= body.endIndex,
                  body.subdata(in: cursor..<terminatorEnd) == crlf else {
                return nil
            }
            cursor = terminatorEnd
        }
        return nil
    }

    static func statusCode(_ head: String) -> Int {
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        return parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
    }

    static func headerValue(_ name: String, in head: String) -> String? {
        let lower = name.lowercased()
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased() == lower {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 从响应头里所有 Set-Cookie 行提取指定 cookie 的值。
    static func cookieValue(_ name: String, in head: String) -> String? {
        sessionCookies(in: head).items.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    /// 解析所有 nonce 交换下发的会话 cookie。兼容多行及合并的 Set-Cookie 头，
    /// 并保留 cookie 名称，避免将认证协议硬编码成固定的两枚 cookie。
    static func sessionCookies(in head: String) -> ScienceSessionCookies {
        var result: [ScienceSessionCookie] = []
        for line in head.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("set-cookie:") else { continue }
            let raw = line.dropFirst("set-cookie:".count).trimmingCharacters(in: .whitespaces)
            // Some HTTP stacks combine repeated Set-Cookie fields. Split only
            // at commas followed immediately by another cookie name, not the
            // comma inside an Expires date.
            let normalized = raw.replacingOccurrences(
                of: #",\s*(?=[A-Za-z0-9!#$%&'*+.^_~-]+=)"#,
                with: "\n",
                options: .regularExpression
            )
            for record in normalized.components(separatedBy: "\n") {
                let segments = record.split(separator: ";", omittingEmptySubsequences: true)
                guard let pair = segments.first, let equals = pair.firstIndex(of: "=") else { continue }
                let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
                let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard validCookieName(name), !value.contains("\r"), !value.contains("\n") else { continue }
                let httpOnly = segments.dropFirst().contains {
                    $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("httponly") == .orderedSame
                }
                let cookie = ScienceSessionCookie(name: name, value: value, httpOnly: httpOnly)
                if let existing = result.firstIndex(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    result[existing] = cookie
                } else {
                    result.append(cookie)
                }
            }
        }
        return ScienceSessionCookies(items: result)
    }

    private static func validCookieName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_~")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 兼容 {"nonce":"..." }、嵌套 data.nonce 和返回登录 URL 的新版响应。
    static func nonceValue(from body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body),
           let nonce = nonceValue(in: object), !nonce.isEmpty {
            return nonce
        }
        guard let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return nonceFromURL(text)
    }

    private static func nonceValue(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where key.caseInsensitiveCompare("nonce") == .orderedSame {
                if let nonce = value as? String, !nonce.isEmpty { return nonce }
            }
            for (key, value) in dictionary {
                if key.lowercased().contains("url"), let url = value as? String,
                   let nonce = nonceFromURL(url) {
                    return nonce
                }
                if let nested = nonceValue(in: value) { return nested }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = nonceValue(in: value) { return nested }
            }
        } else if let text = object as? String {
            return nonceFromURL(text)
        }
        return nil
    }

    private static func nonceFromURL(_ text: String) -> String? {
        guard let components = URLComponents(string: text) else { return nil }
        return components.queryItems?.first {
            $0.name.caseInsensitiveCompare("nonce") == .orderedSame
        }?.value
    }

    static func percentEncodedQueryValue(_ value: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// Keep /login redirects on this loopback origin and out of response headers.
    static func safeLocalRedirect(_ rawValue: String?) -> String {
        guard let rawValue,
              let decoded = rawValue.removingPercentEncoding,
              decoded.hasPrefix("/"),
              !decoded.hasPrefix("//"),
              !decoded.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) else {
            return "/"
        }
        return decoded
    }

    /// Diagnostics must never expose nonce/cookie/token values.
    static func redactedText(_ value: String, limit: Int = 180) -> String {
        var text = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let sensitivePattern = #"(?i)(nonce|token|authorization|operon_auth|operon_csrf|api[_-]?key|cookie)(\s*["']?\s*[:=]\s*["']?)[^"',;\s}<]+"#
        text = text.replacingOccurrences(
            of: sensitivePattern,
            with: "$1$2[REDACTED]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"[A-Za-z0-9._~+/=-]{20,}"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
        return String(text.prefix(limit))
    }

    /// 把 Referer 的 scheme://host[:port] 前缀替换为 newOrigin，保留其后的 path/query/fragment。
    static func rewriteRefererOrigin(_ referer: String, to newOrigin: String) -> String {
        guard let schemeEnd = referer.range(of: "://") else { return newOrigin + "/" }
        let afterScheme = referer[schemeEnd.upperBound...]
        // host[:port] 到首个 '/'（或 '?' / '#'）为止即 authority，其后为 path。
        if let pathStart = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            return newOrigin + afterScheme[pathStart...]
        }
        return newOrigin + "/"
    }

    static func plainResponse(status: Int, text: String) -> Data {
        let body = Data(text.utf8)
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 500: reason = "Internal Server Error"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    // MARK: - NWConnection 异步收发

    /// 收到完整请求头（\r\n\r\n）为止；返回 (头含终止符, 头之后已到达的剩余字节)。
    static func recvUntilHeaderEnd(_ conn: NWConnection) async -> (head: Data, leftover: Data)? {
        var acc = Data()
        let terminator = Data([13, 10, 13, 10])
        let maxHeader = 256 * 1024
        while acc.count < maxHeader {
            guard let chunk = await recvChunk(conn), !chunk.isEmpty else {
                return acc.isEmpty ? nil : (acc, Data())
            }
            acc.append(chunk)
            if let sep = acc.range(of: terminator) {
                let head = acc.subdata(in: acc.startIndex..<sep.upperBound)
                let leftover = acc.subdata(in: sep.upperBound..<acc.endIndex)
                return (head, leftover)
            }
        }
        return (acc, Data())
    }

    /// 再精确读取 count 字节（用于按 Content-Length 补齐请求体）。
    static func recvExact(_ conn: NWConnection, count: Int) async -> Data {
        var acc = Data()
        while acc.count < count {
            guard let chunk = await recvChunk(conn), !chunk.isEmpty else { break }
            acc.append(chunk)
        }
        return acc
    }

    static func recvChunk(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
    }

    static func send(_ conn: NWConnection, data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    /// 向上游发一个请求并读满响应（上游 Connection: close → 读到 EOF）。
    static func tcpRoundTrip(host: String, port: Int, request: Data) async -> Data? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        conn.start(queue: .global())
        defer { conn.cancel() }
        await send(conn, data: request)

        var acc = Data()
        let maxSize = 20 * 1024 * 1024
        while acc.count < maxSize {
            let (chunk, done) = await recvChunkWithCompletion(conn)
            if let chunk, !chunk.isEmpty { acc.append(chunk) }
            if done { break }
            if chunk == nil { break }
        }
        return acc.isEmpty ? nil : acc
    }

    static func recvChunkWithCompletion(_ conn: NWConnection) async -> (Data?, Bool) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Data?, Bool), Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                cont.resume(returning: (data, isComplete || error != nil))
            }
        }
    }

    /// 双向对拷（WebSocket 隧道）：从 from 持续读、写到 to，直到 EOF/错误。
    static func pump(from: NWConnection, to: NWConnection) async {
        while true {
            let (chunk, done) = await recvChunkWithCompletion(from)
            if let chunk, !chunk.isEmpty { await send(to, data: chunk) }
            if done || chunk == nil { return }
        }
    }

    // MARK: - POSIX 回环 socket（同步；仅用于铸 cookie 的两次短请求）

    /// Unix 域套接字上发一个 HTTP 请求，读到 EOF，返回原始响应字节。
    static func posixRequestUnix(socketPath: String, request: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        configureSocketTimeouts(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        return writeThenReadAll(fd: fd, request: request)
    }

    /// TCP 回环上发一个 HTTP 请求，读到 EOF，返回原始响应字节。
    static func posixRequestTCP(host: String, port: Int, request: Data) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        configureSocketTimeouts(fd)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        return writeThenReadAll(fd: fd, request: request)
    }

    private static func writeThenReadAll(fd: Int32, request: Data) -> Data? {
        var sent = 0
        let ok = request.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < request.count {
                let n = Darwin.write(fd, base.advanced(by: sent), request.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        guard ok else { return nil }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let maxResponseSize = 2 * 1024 * 1024
        while response.count < maxResponseSize {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 { response.append(contentsOf: buf[0..<n]) } else { break }
        }
        return response.isEmpty ? nil : response
    }

    private static func configureSocketTimeouts(_ fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length)
    }
}
