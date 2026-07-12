import Foundation

// The production helper file is compiled beside this harness. A minimal class
// declaration provides the extension target without copying any helper logic.
final class ScienceAuthProxy {}

private enum RegressionFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RegressionFailure.failed(message) }
}

@main
private struct ScienceAuthProxyRegression {
    static func main() throws {
        try testContentLengthResponse()
        try testChunkedNonceResponse()
        try testNonceURLVariants()
        try testSessionCookieParsing()
        try testCookieFiltering()
        try testQueryEncoding()
        try testNonceExchangeRequests()
        try testSafeRedirects()
        try testDiagnosticRedaction()
        if let dataDir = ProcessInfo.processInfo.environment["SCIENCE_AUTH_LIVE_DATA_DIR"],
           let rawPort = ProcessInfo.processInfo.environment["SCIENCE_AUTH_LIVE_PORT"],
           let port = Int(rawPort) {
            try testLiveDaemon(dataDir: dataDir, port: port)
        }
        print("ScienceAuthProxy regression checks passed.")
    }

    private static func testContentLengthResponse() throws {
        let body = Data(#"{"nonce":"plain-nonce"}"#.utf8)
        let raw = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        ) + body
        let response = ScienceAuthProxy.parseHTTPResponse(raw)
        try expect(response?.statusCode == 200, "Content-Length response status was not parsed")
        try expect(response?.body == body, "Content-Length response body was not preserved")
        try expect(ScienceAuthProxy.nonceValue(from: response?.body ?? Data()) == "plain-nonce",
                   "Plain nonce JSON was not parsed")
    }

    private static func testChunkedNonceResponse() throws {
        let body = Data(#"{"data":{"nonce":"chunked-nonce"}}"#.utf8)
        let chunkSize = String(body.count, radix: 16)
        var raw = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n\(chunkSize)\r\n".utf8
        )
        raw.append(body)
        raw.append(Data("\r\n0\r\n\r\n".utf8))
        let response = ScienceAuthProxy.parseHTTPResponse(raw)
        try expect(response?.body == body, "Chunked response body was not decoded")
        try expect(ScienceAuthProxy.nonceValue(from: response?.body ?? Data()) == "chunked-nonce",
                   "Nested nonce JSON was not parsed")
    }

    private static func testNonceURLVariants() throws {
        let body = Data(#"{"login_url":"http://localhost:14411/?nonce=url%2Bnonce"}"#.utf8)
        try expect(ScienceAuthProxy.nonceValue(from: body) == "url+nonce",
                   "Nonce embedded in a login URL was not parsed")
    }

    private static func testSessionCookieParsing() throws {
        let separate = """
        HTTP/1.1 200 OK\r
        Set-Cookie: operon_auth=auth-value; HttpOnly; Path=/\r
        Set-Cookie: operon_csrf=csrf-value; Path=/\r
        \r
        """
        let cookies = ScienceAuthProxy.sessionCookies(in: separate)
        try expect(cookies.items.count == 2, "Separate Set-Cookie headers were not parsed")
        try expect(cookies.items.first(where: { $0.name == "operon_auth" })?.httpOnly == true,
                   "HttpOnly attribute was not preserved")

        let combined = """
        HTTP/1.1 200 OK\r
        Set-Cookie: operon_auth=a; Expires=Wed, 10 Jul 2030 12:00:00 GMT; HttpOnly, science_session=b; Path=/\r
        \r
        """
        let combinedCookies = ScienceAuthProxy.sessionCookies(in: combined)
        try expect(combinedCookies.items.map(\.name) == ["operon_auth", "science_session"],
                   "Combined Set-Cookie header was not split safely")
    }

    private static func testCookieFiltering() throws {
        let cookies = ScienceSessionCookies(items: [
            ScienceSessionCookie(name: "science_session", value: "fresh", httpOnly: true),
            ScienceSessionCookie(name: "science_csrf", value: "csrf", httpOnly: false),
        ])
        let preserved = cookies.preservingUnmanagedClientCookies([
            "theme=dark",
            "science_session=stale",
            "science_csrf=stale",
            "operon_auth=legacy",
            "operon_csrf=legacy",
        ])
        try expect(preserved == ["theme=dark"], "Current and legacy managed cookies were not filtered")
    }

    private static func testQueryEncoding() throws {
        try expect(
            ScienceAuthProxy.percentEncodedQueryValue("a+b&c=d?e%f") == "a%2Bb%26c%3Dd%3Fe%25f",
            "Nonce query value was not safely percent-encoded"
        )
    }

    private static func testNonceExchangeRequests() throws {
        let nonce = "a+b&c=d?e%f\r\nInjected: yes"
        let requests = ScienceAuthProxy.nonceExchangeRequests(nonce: nonce, port: 14411)
        try expect(requests.map(\.mode) == [.formPOST, .legacyQueryGET],
                   "Nonce exchange compatibility order changed")
        try expect(requests.count == 2, "Expected modern and legacy nonce exchange requests")

        let post = String(data: requests[0].data, encoding: .utf8) ?? ""
        let encoded = "a%2Bb%26c%3Dd%3Fe%25f%0D%0AInjected%3A%20yes"
        let body = "nonce=\(encoded)&dest=/"
        try expect(post.hasPrefix("POST /api/auth/nonce HTTP/1.1\r\n"),
                   "Modern exchange must use POST /api/auth/nonce")
        try expect(post.contains("Host: 127.0.0.1:14411\r\n"), "Modern exchange Host is wrong")
        try expect(post.contains("Origin: http://127.0.0.1:14411\r\n"), "Modern exchange Origin is missing")
        try expect(post.contains("Referer: http://127.0.0.1:14411/?nonce=\(encoded)\r\n"),
                   "Modern exchange Referer is missing")
        try expect(post.contains("Content-Type: application/x-www-form-urlencoded\r\n"),
                   "Modern exchange form content type is missing")
        try expect(post.contains("Content-Length: \(body.utf8.count)\r\n"),
                   "Modern exchange Content-Length is wrong")
        try expect(post.hasSuffix("\r\n\r\n\(body)"), "Modern exchange form body is wrong")
        try expect(!post.contains("\r\nInjected: yes"), "Nonce enabled HTTP header injection")

        let legacy = String(data: requests[1].data, encoding: .utf8) ?? ""
        try expect(legacy.hasPrefix("GET /?nonce=\(encoded) HTTP/1.1\r\n"),
                   "Legacy exchange query is wrong")
        try expect(legacy.contains("Host: localhost:14411\r\n"), "Legacy exchange Host changed")
    }

    private static func testSafeRedirects() throws {
        try expect(ScienceAuthProxy.safeLocalRedirect("%2Fworkspace%3Ftab%3D1") == "/workspace?tab=1",
                   "Safe local redirect was not decoded")
        try expect(ScienceAuthProxy.safeLocalRedirect("%2F%2Fevil.example") == "/",
                   "Protocol-relative redirect was not rejected")
        try expect(ScienceAuthProxy.safeLocalRedirect("%2Fok%0D%0AX-Test%3Ayes") == "/",
                   "CRLF redirect was not rejected")
    }

    private static func testDiagnosticRedaction() throws {
        let secret = "very-secret-nonce-value-123456789"
        let redacted = ScienceAuthProxy.redactedText(
            #"{"nonce":"\#(secret)","message":"failed","token":"another-secret-token-123456"}"#
        )
        try expect(!redacted.contains(secret), "Nonce leaked into diagnostic text")
        try expect(!redacted.contains("another-secret-token"), "Token leaked into diagnostic text")
        try expect(redacted.contains("[REDACTED]"), "Diagnostic redaction marker is missing")
    }

    private static func testLiveDaemon(dataDir: String, port: Int) throws {
        let socketPath = (dataDir as NSString).appendingPathComponent("daemon.sock")
        let nonceRequest = Data(
            "POST /nonce HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
        )
        guard let nonceRaw = ScienceAuthProxy.posixRequestUnix(
            socketPath: socketPath,
            request: nonceRequest
        ), let nonceResponse = ScienceAuthProxy.parseHTTPResponse(nonceRaw),
           let nonce = ScienceAuthProxy.nonceValue(from: nonceResponse.body) else {
            throw RegressionFailure.failed("Live daemon nonce exchange failed")
        }
        let requests = ScienceAuthProxy.nonceExchangeRequests(nonce: nonce, port: port)
        for exchange in requests {
            guard let cookieRaw = ScienceAuthProxy.posixRequestTCP(
                host: "127.0.0.1",
                port: port,
                request: exchange.data
            ), let head = ScienceAuthProxy.httpHeadString(cookieRaw) else { continue }
            let cookies = ScienceAuthProxy.sessionCookies(in: head)
            if !cookies.isEmpty {
                print("Live daemon nonce/cookie exchange passed via \(exchange.mode.rawValue) (cookies=\(cookies.items.count)).")
                return
            }
        }
        throw RegressionFailure.failed("Live daemon did not return session cookies")
    }
}
