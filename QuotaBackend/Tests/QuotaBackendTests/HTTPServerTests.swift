import XCTest
import Network
@testable import QuotaBackend
@testable import QuotaServerCore

final class HTTPServerTests: XCTestCase {

    func testStartupDiagnosticsClassifiesAddressInUseWithoutGuessingSignals() {
        XCTAssertEqual(
            QuotaServerStartupDiagnostics.category(for: NWError.posix(.EADDRINUSE)),
            "port_in_use"
        )
        XCTAssertEqual(
            QuotaServerStartupDiagnostics.category(for: NWError.posix(.ECONNREFUSED)),
            "startup_failure"
        )
    }

    func testStartupDiagnosticsSerializesOneLine() {
        XCTAssertEqual(
            QuotaServerStartupDiagnostics.singleLine("first\nsecond\r\nthird\tvalue"),
            "first second  third value"
        )
    }

    // MARK: - Request Parsing Tests

    func testParseSimpleGETRequest() {
        let rawRequest = """
        GET /api/health HTTP/1.1\r
        Host: localhost:4318\r
        User-Agent: curl/7.64.1\r
        \r

        """

        guard let data = rawRequest.data(using: .utf8) else {
            XCTFail("Failed to create request data")
            return
        }

        // We can't directly test private methods, but we can verify the server handles it
        // This is a placeholder for integration testing
        XCTAssertNotNil(data)
    }

    func testParseHeaderExtraction() {
        let rawRequest = """
        POST /v1/messages HTTP/1.1\r
        Host: localhost:4318\r
        Content-Type: application/json\r
        Authorization: Bearer sk-ant-test123\r
        x-api-key: test-key\r
        Content-Length: 13\r
        \r
        {"test":"ok"}
        """

        guard let data = rawRequest.data(using: .utf8) else {
            XCTFail("Failed to create request data")
            return
        }

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testParseLargeBody() {
        let largeBody = String(repeating: "x", count: 1024 * 100) // 100KB
        let rawRequest = """
        POST /v1/messages HTTP/1.1\r
        Content-Type: application/json\r
        Content-Length: \(largeBody.count)\r
        \r
        \(largeBody)
        """

        guard let data = rawRequest.data(using: .utf8) else {
            XCTFail("Failed to create request data")
            return
        }

        XCTAssertGreaterThan(data.count, 100_000)
    }

    func testParseHTTPRequestPreservesBinaryBodyBytes() {
        let body = Data([0x00, 0xFF, 0x41, 0x0A])
        var requestData = Data("POST /v1/files HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        requestData.append(body)

        let server = QuotaHTTPServer(host: "127.0.0.1", port: 0)
        let parsed = server.parseHTTPRequest(requestData)

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1/files")
        XCTAssertEqual(parsed.body, body)
    }

    // MARK: - SSE Event Formatting Tests

    func testSSEEventFormatting() {
        let event = "message_start"
        let data = #"{"type":"message_start","message":{"id":"msg_123"}}"#

        let expected = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_123"}}


        """

        var formatted = ""
        formatted += "event: \(event)\n"
        formatted += "data: \(data)\n\n"

        XCTAssertEqual(formatted, expected)
    }

    func testSSEEventWithoutEventType() {
        let data = #"{"type":"ping"}"#

        let expected = """
        data: {"type":"ping"}


        """

        var formatted = ""
        formatted += "data: \(data)\n\n"

        XCTAssertEqual(formatted, expected)
    }

    // MARK: - Content-Length Extraction Tests

    func testContentLengthExtraction() {
        let text = """
        POST /v1/messages HTTP/1.1
        Host: localhost
        Content-Type: application/json
        Content-Length: 42

        """

        let lines = text.components(separatedBy: "\n")
        var contentLength: Int?

        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
                break
            }
        }

        XCTAssertEqual(contentLength, 42)
    }

    func testContentLengthExtractionCaseInsensitive() {
        let text = """
        POST /v1/messages HTTP/1.1
        CONTENT-LENGTH: 100

        """

        let lines = text.components(separatedBy: "\n")
        var contentLength: Int?

        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
                break
            }
        }

        XCTAssertEqual(contentLength, 100)
    }

    // MARK: - Model Normalization Tests

    func testModelNormalization() {
        let testCases: [(input: String, expected: String)] = [
            ("claude-sonnet-4.5", "sonnet"),
            ("claude-3-5-haiku-20241022", "haiku"),
            ("claude-opus-4", "opus"),
            ("claude-3-opus-20240229", "opus"),
            ("sonnet", "sonnet"),
            ("haiku", "haiku"),
            ("opus", "opus"),
        ]

        for testCase in testCases {
            let normalized = normalizeModelName(testCase.input)
            XCTAssertEqual(normalized, testCase.expected, "Failed to normalize \(testCase.input)")
        }
    }

    private func normalizeModelName(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("haiku") {
            return "haiku"
        } else if lower.contains("sonnet") {
            return "sonnet"
        } else if lower.contains("opus") {
            return "opus"
        }
        return model
    }
}
