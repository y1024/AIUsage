import Foundation
import Network
import Darwin

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

    /// 客户端 Cookie 头里除 operon_auth / operon_csrf 外的其它 cookie（原样保留转发）。
    var otherCookiePairs: [String] {
        guard let cookie = header("cookie") else { return [] }
        return cookie.split(separator: ";").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("operon_auth=") || trimmed.hasPrefix("operon_csrf=") { return nil }
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

    /// 首个 \r\n\r\n 之后的响应体。
    static func httpBody(_ data: Data) -> Data? {
        guard let sep = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        return data.subdata(in: sep.upperBound..<data.endIndex)
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
        let prefix = "\(name)="
        for line in head.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("set-cookie:") else { continue }
            let value = line.dropFirst("set-cookie:".count).trimmingCharacters(in: .whitespaces)
            for seg in value.split(separator: ";") {
                let s = seg.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
            }
        }
        return nil
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
        let head = "HTTP/1.1 \(status) \(status == 502 ? "Bad Gateway" : "OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
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
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 { response.append(contentsOf: buf[0..<n]) } else { break }
        }
        return response.isEmpty ? nil : response
    }
}
