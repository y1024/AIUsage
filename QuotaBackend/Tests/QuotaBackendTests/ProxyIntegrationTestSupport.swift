import Foundation
import Network
import Darwin

struct CapturedHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

struct MockHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let bodyChunks: [Data]
    let chunkDelayNanoseconds: UInt64

    init(
        status: Int = 200,
        headers: [String: String] = [:],
        body: String,
        chunkDelayNanoseconds: UInt64 = 0
    ) {
        self.status = status
        self.headers = headers
        self.bodyChunks = [Data(body.utf8)]
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    init(
        status: Int = 200,
        headers: [String: String] = [:],
        bodyChunks: [String],
        chunkDelayNanoseconds: UInt64 = 0
    ) {
        self.status = status
        self.headers = headers
        self.bodyChunks = bodyChunks.map { Data($0.utf8) }
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    init(
        status: Int = 200,
        headers: [String: String] = [:],
        bodyData: Data,
        chunkDelayNanoseconds: UInt64 = 0
    ) {
        self.status = status
        self.headers = headers
        self.bodyChunks = [bodyData]
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    init(
        status: Int = 200,
        headers: [String: String] = [:],
        bodyDataChunks: [Data],
        chunkDelayNanoseconds: UInt64 = 0
    ) {
        self.status = status
        self.headers = headers
        self.bodyChunks = bodyDataChunks
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    var body: String {
        String(data: bodyData, encoding: .utf8) ?? ""
    }

    var bodyData: Data {
        bodyChunks.reduce(into: Data()) { partialResult, chunk in
            partialResult.append(chunk)
        }
    }

    static func json(
        status: Int = 200,
        object: Any,
        headers: [String: String] = [:]
    ) throws -> MockHTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let body = String(data: data, encoding: .utf8) ?? "{}"
        return MockHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"].merging(headers, uniquingKeysWith: { _, new in new }),
            body: body
        )
    }
}

actor MockHTTPRecorder {
    private var requests: [CapturedHTTPRequest] = []

    func append(_ request: CapturedHTTPRequest) {
        requests.append(request)
    }

    func allRequests() -> [CapturedHTTPRequest] {
        requests
    }
}

final class MockHTTPServer {
    typealias Handler = @Sendable (CapturedHTTPRequest) async throws -> MockHTTPResponse

    let host: String
    let port: Int

    private let handler: Handler
    private let recorder = MockHTTPRecorder()
    private let lifecycleQueue = DispatchQueue(label: "com.aiusage.tests.mock-http-server")
    private var listener: NWListener?

    init(
        host: String = "127.0.0.1",
        port: Int,
        handler: @escaping Handler
    ) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() async throws {
        let isRunning = lifecycleQueue.sync { self.listener != nil }
        if isRunning {
            return
        }

        final class ListenerStartState: @unchecked Sendable {
            private let lock = NSLock()
            private var hasResolved = false

            func resolve(
                continuation: CheckedContinuation<Void, Error>,
                result: Result<Void, Error>
            ) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResolved else { return }
                hasResolved = true
                continuation.resume(with: result)
            }
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleConnection(connection)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startState = ListenerStartState()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    startState.resolve(continuation: continuation, result: .success(()))
                case .failed(let error):
                    startState.resolve(continuation: continuation, result: .failure(error))
                case .cancelled:
                    startState.resolve(continuation: continuation, result: .failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        lifecycleQueue.sync {
            self.listener = listener
        }
    }

    func stop() {
        let listener = lifecycleQueue.sync { () -> NWListener? in
            let current = self.listener
            self.listener = nil
            return current
        }
        listener?.cancel()
    }

    func baseURL() -> URL {
        URL(string: "http://\(host):\(port)")!
    }

    func recordedRequests() async -> [CapturedHTTPRequest] {
        await recorder.allRequests()
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global())
        guard let data = await receiveData(connection) else {
            connection.cancel()
            return
        }

        let request = parseHTTPRequest(data)
        await recorder.append(request)

        do {
            let response = try await handler(request)
            await sendResponse(connection, response: response)
        } catch {
            let response = MockHTTPResponse(
                status: 500,
                headers: ["Content-Type": "application/json"],
                body: "{\"error\":\"\(error.localizedDescription)\"}"
            )
            await sendResponse(connection, response: response)
        }

        connection.cancel()
    }

    private func sendResponse(_ connection: NWConnection, response: MockHTTPResponse) async {
        var headers = response.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = "\(response.bodyData.count)"
        }
        if headers["Connection"] == nil {
            headers["Connection"] = "close"
        }

        let headerText = buildHeaderText(status: response.status, headers: headers)
        await send(connection: connection, data: Data(headerText.utf8))

        for chunk in response.bodyChunks {
            await send(connection: connection, data: chunk)
            if response.chunkDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: response.chunkDelayNanoseconds)
            }
        }
    }

    private func send(connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func buildHeaderText(status: Int, headers: [String: String]) -> String {
        var text = "HTTP/1.1 \(status) \(httpStatusText(status))\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        return text
    }

    private func httpStatusText(_ code: Int) -> String {
        [
            200: "OK",
            400: "Bad Request",
            401: "Unauthorized",
            404: "Not Found",
            500: "Internal Server Error",
            502: "Bad Gateway",
        ][code] ?? "OK"
    }

    private func receiveData(_ connection: NWConnection) async -> Data? {
        let maxSize = 2 * 1024 * 1024
        var accumulated = Data()

        while accumulated.count < maxSize {
            guard let chunk = await receiveChunk(connection) else {
                break
            }
            accumulated.append(chunk)

            guard let text = String(data: accumulated, encoding: .utf8),
                  text.contains("\r\n\r\n") else {
                continue
            }

            if let contentLength = extractContentLength(from: text),
               let headerRange = text.range(of: "\r\n\r\n") {
                let headerBytes = text.distance(from: text.startIndex, to: headerRange.upperBound)
                let bodyBytes = accumulated.count - headerBytes
                if bodyBytes >= contentLength {
                    break
                }
            } else {
                break
            }
        }

        return accumulated.isEmpty ? nil : accumulated
    }

    private func receiveChunk(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isComplete, _ in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func extractContentLength(from text: String) -> Int? {
        for line in text.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    private func parseHTTPRequest(_ data: Data) -> CapturedHTTPRequest {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.indices.contains(0) ? parts[0] : "GET"
        let path = parts.indices.contains(1) ? parts[1] : "/"

        var headers: [String: String] = [:]
        var bodyStartIndex = 0
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            if index > 0, let separator = line.firstIndex(of: ":") {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyText = lines.dropFirst(bodyStartIndex).joined(separator: "\r\n")
        let body = bodyText.data(using: .utf8) ?? Data()

        return CapturedHTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

// 端口分配避开 macOS 临时端口范围（49152–65535）。
// 旧实现 bind 端口 0 拿临时端口后立即 close，再交给 NWListener 重新绑定；
// 窗口期内该端口可能被 URLSession 出站连接的临时端口分配抢占，
// 导致随机用例偶发 "Address already in use"。
// 现在从 20000–31999 顺序分配（随机基址起步），并用真实 bind 探测可用性。
private enum TestPortAllocator {
    private static let lock = NSLock()
    private static let lowerBound = 20000
    private static let upperBound = 32000
    private static var nextPort = Int.random(in: lowerBound..<upperBound)

    static func nextCandidate() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if nextPort >= upperBound { nextPort = lowerBound }
        let port = nextPort
        nextPort += 1
        return port
    }
}

func findFreePort() throws -> Int {
    for _ in 0..<128 {
        let candidate = TestPortAllocator.nextCandidate()
        if isPortBindable(candidate) {
            return candidate
        }
    }
    throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EADDRINUSE),
        userInfo: [NSLocalizedDescriptionKey: "findFreePort: no bindable port after 128 attempts"]
    )
}

private func isPortBindable(_ port: Int) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port)).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return bindResult == 0
}
