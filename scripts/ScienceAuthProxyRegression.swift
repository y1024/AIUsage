import Foundation
import SQLite3

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
        try testEndpointPlans()
        try testModelCatalogResponse()
        try testSelectionNormalization()
        try testManagedDaemonGuard()
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

    private static func testEndpointPlans() throws {
        let reserved = Set([8765, 14411, 14412])
        let sandbox = ScienceProxyEndpointPlan(
            mode: .sandbox,
            publicPort: 14410,
            daemonPort: 14412,
            dataDir: "/tmp/aiusage-science-sandbox"
        )
        let adopt = ScienceProxyEndpointPlan(
            mode: .adopt,
            publicPort: 8765,
            daemonPort: 14411,
            dataDir: "/tmp/aiusage-science-adopt"
        )

        try expect(!sandbox.adopting, "Sandbox endpoint plan was marked as adopt")
        try expect(adopt.adopting, "Adopt endpoint plan lost its mode")
        try expect(sandbox.validationIssue(proxyPort: 14402, reservedPorts: reserved) == nil,
                   "Default sandbox endpoint plan has a collision")
        try expect(adopt.validationIssue(proxyPort: 14402, reservedPorts: reserved) == nil,
                   "Default adopt endpoint plan has a collision")
        try expect(sandbox.validationIssue(proxyPort: 14410, reservedPorts: reserved) == .duplicatePort,
                   "Proxy/public duplicate was not rejected")

        let reservedPublic = ScienceProxyEndpointPlan(
            mode: .sandbox,
            publicPort: 14411,
            daemonPort: 14412,
            dataDir: sandbox.dataDir
        )
        try expect(reservedPublic.validationIssue(proxyPort: 14402, reservedPorts: reserved) == .reservedPort,
                   "Sandbox public port was allowed to occupy an internal port")
        try expect(sandbox.validationIssue(proxyPort: 14412, reservedPorts: reserved) == .duplicatePort,
                   "Proxy/internal duplicate was not rejected before reserved-port handling")
    }

    private static func testModelCatalogResponse() throws {
        let catalog = ScienceModelCatalog(
            nodeID: "node-1",
            nodeName: "Lab node",
            models: [
                .init(
                    id: "claude-opus-4-8",
                    upstreamModel: "glm-5.2",
                    displayName: "glm-5.2",
                    description: "Lab node · $1.2 input / $4.1 output per 1M",
                    overflow: false
                ),
                .init(
                    id: "claude-aiusage-v1-codex-auto-review-test",
                    upstreamModel: "codex-auto-review",
                    displayName: "\u{2060}codex-auto-review",
                    description: "Lab node",
                    overflow: false
                ),
            ],
            defaultModelID: "claude-opus-4-8",
            defaultUpstreamModel: "glm-5.2"
        )
        let raw = ScienceAuthProxy.modelCatalogResponse(catalog)
        let response = try unwrap(ScienceAuthProxy.parseHTTPResponse(raw), "Catalog response was malformed")
        try expect(response.statusCode == 200, "Catalog response status was not 200")
        try expect(response.header("cache-control") == "no-store", "Catalog response must not be browser-cached")
        let object = try unwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            "Catalog response JSON was malformed"
        )
        try expect(object["default_model_id"] as? String == catalog.defaultModelID,
                   "Catalog default alias was not preserved")
        try expect(object["fetch_error"] == nil, "Successful catalog response included fetch_error")
        let providers = try unwrap(object["models"] as? [String: Any], "Catalog providers were missing")
        let models = try unwrap(providers["anthropic"] as? [[String: Any]], "Anthropic catalog was missing")
        let presentedName = try unwrap(models.first?["name"] as? String, "Catalog model name was missing")
        try expect(presentedName == "glm-5.2", "Safe raw upstream display name was not preserved")
        let guardedName = try unwrap(models.last?["name"] as? String, "Guarded catalog name was missing")
        try expect(guardedName == "\u{2060}codex-auto-review",
                   "Lowercase kebab model name was not protected from Science's Internal mask")
        try expect(catalog.models.last?.upstreamModel == "codex-auto-review",
                   "Presentation guard contaminated the raw catalog model id")

        // A node hot-switch replaces the final /api/models snapshot rather than
        // merging old entries. This is the cache-bypass contract used by both
        // sandbox and adopt public proxies.
        let switched = ScienceModelCatalog(
            nodeID: "node-2",
            nodeName: "New node",
            models: [
                .init(
                    id: "claude-opus-4-8",
                    upstreamModel: "new-default",
                    displayName: "new-default",
                    description: "New node",
                    overflow: false
                ),
            ],
            defaultModelID: "claude-opus-4-8",
            defaultUpstreamModel: "new-default"
        )
        let switchedRaw = ScienceAuthProxy.modelCatalogResponse(switched)
        let switchedResponse = try unwrap(
            ScienceAuthProxy.parseHTTPResponse(switchedRaw),
            "Switched catalog response was malformed"
        )
        let switchedObject = try unwrap(
            try JSONSerialization.jsonObject(with: switchedResponse.body) as? [String: Any],
            "Switched catalog JSON was malformed"
        )
        let switchedProviders = try unwrap(
            switchedObject["models"] as? [String: Any],
            "Switched catalog providers were missing"
        )
        let switchedModels = try unwrap(
            switchedProviders["anthropic"] as? [[String: Any]],
            "Switched Anthropic catalog was missing"
        )
        try expect(switchedModels.map { $0["name"] as? String } == ["new-default"],
                   "Hot-switched catalog leaked entries from the previous node")
    }

    private static func testSelectionNormalization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("science-selection-regression-\(UUID().uuidString)", isDirectory: true)
        let dataDir = root.appendingPathComponent("managed/.claude-science", isDirectory: true)
        let supportedDB = dataDir.appendingPathComponent("orgs/supported/operon-cli.db")
        let unknownTriggerDB = dataDir.appendingPathComponent("orgs/unknown-trigger/operon-cli.db")
        try FileManager.default.createDirectory(
            at: supportedDB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unknownTriggerDB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let currentAlias = "claude-aiusage-v1-current-111"
        let staleAliasA = "claude-aiusage-v1-old-222"
        let staleAliasB = "claude-aiusage-v1-old-333"
        let schema = """
            CREATE TABLE frames (
                id TEXT PRIMARY KEY NOT NULL,
                model TEXT,
                root_frame_id TEXT,
                root_seq INTEGER NOT NULL DEFAULT 0
            );
            """
        try executeSQLite(supportedDB.path, sql: schema + """
            INSERT INTO frames VALUES ('root', '\(staleAliasA)', NULL, 0);
            INSERT INTO frames VALUES ('child-a', '\(staleAliasB)', 'root', 7);
            INSERT INTO frames VALUES ('child-current', '\(currentAlias)', 'root', 8);
            INSERT INTO frames VALUES ('child-native', 'glm-5.2-native', 'root', 9);
            INSERT INTO frames VALUES ('child-default', 'claude-opus-4-8', 'root', 10);
            CREATE TRIGGER trg_frames_root_seq_ins AFTER INSERT ON frames
            WHEN NEW.root_frame_id IS NOT NULL
            BEGIN
              UPDATE frames SET root_seq = (
                SELECT COALESCE(MAX(root_seq), 0) + 1 FROM frames
                WHERE root_frame_id = NEW.root_frame_id
              ) WHERE id = NEW.id;
            END;
            CREATE TRIGGER trg_frames_root_seq_upd AFTER UPDATE ON frames
            WHEN NEW.root_frame_id IS NOT NULL AND NEW.root_seq IS OLD.root_seq
            BEGIN
              UPDATE frames SET root_seq = (
                SELECT COALESCE(MAX(root_seq), 0) + 1 FROM frames
                WHERE root_frame_id = NEW.root_frame_id
              ) WHERE id = NEW.id;
            END;
            """)

        try executeSQLite(unknownTriggerDB.path, sql: schema + """
            INSERT INTO frames VALUES ('unknown', '\(staleAliasA)', NULL, 0);
            CREATE TRIGGER unexpected_model_update AFTER UPDATE OF model ON frames
            BEGIN
              UPDATE frames SET root_seq = root_seq + 100 WHERE id = NEW.id;
            END;
            """)

        let before = try frameSnapshot(supportedDB.path)
        let result = try ScienceSelectionNormalizer.normalize(
            dataDir: dataDir.path,
            currentModelIDs: [ScienceSelectionNormalizer.persistentDefaultSelectionID, currentAlias],
            managedDataDirs: [dataDir.path]
        )
        try expect(result.databaseCount == 2, "Selection normalizer did not discover both org databases")
        try expect(result.skippedSchemaCount == 1, "Unknown frame trigger was not rejected fail-closed")
        try expect(result.normalizedFrameCount == 2, "Stale alias frame count was wrong")

        let after = try frameSnapshot(supportedDB.path)
        try expect(after["root"]?.model == ScienceSelectionNormalizer.persistentDefaultSelectionID,
                   "Stale root selection was not normalized")
        try expect(after["child-a"]?.model == ScienceSelectionNormalizer.persistentDefaultSelectionID,
                   "Stale child selection was not normalized")
        try expect(after["child-current"]?.model == currentAlias,
                   "Current transport alias was rewritten")
        try expect(after["child-native"]?.model == "glm-5.2-native",
                   "Raw/native model ID was rewritten")
        try expect(after["child-default"]?.model == ScienceSelectionNormalizer.persistentDefaultSelectionID,
                   "Persistent default selection changed")
        try expect(
            before.mapValues(\.rootSeq) == after.mapValues(\.rootSeq),
            "frames.root_seq changed while normalizing model aliases"
        )
        let unknownTriggerSnapshot = try frameSnapshot(unknownTriggerDB.path)
        try expect(unknownTriggerSnapshot["unknown"]?.model == staleAliasA,
                   "Database with an unknown UPDATE trigger was mutated")

        let second = try ScienceSelectionNormalizer.normalize(
            dataDir: dataDir.path,
            currentModelIDs: [ScienceSelectionNormalizer.persistentDefaultSelectionID, currentAlias],
            managedDataDirs: [dataDir.path]
        )
        try expect(second.normalizedFrameCount == 0, "Selection normalization was not idempotent")

        do {
            _ = try ScienceSelectionNormalizer.normalize(
                dataDir: root.appendingPathComponent("unmanaged").path,
                currentModelIDs: [],
                managedDataDirs: [dataDir.path]
            )
            throw RegressionFailure.failed("Unmanaged data directory was accepted")
        } catch is ScienceSelectionNormalizer.NormalizationError {
            // Expected: the production guard never reaches a non-AIUsage tree.
        }

        let externalDataDir = root.appendingPathComponent("external/.claude-science", isDirectory: true)
        let externalDB = externalDataDir.appendingPathComponent("orgs/external/operon-cli.db")
        try FileManager.default.createDirectory(
            at: externalDB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try executeSQLite(externalDB.path, sql: schema + """
            INSERT INTO frames VALUES ('external', '\(staleAliasA)', NULL, 0);
            """)
        let symlinkedDataDir = root.appendingPathComponent("managed-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkedDataDir,
            withDestinationURL: externalDataDir
        )
        do {
            _ = try ScienceSelectionNormalizer.normalize(
                dataDir: symlinkedDataDir.path,
                currentModelIDs: [],
                managedDataDirs: [symlinkedDataDir.path]
            )
            throw RegressionFailure.failed("Symlinked managed data directory was accepted")
        } catch is ScienceSelectionNormalizer.NormalizationError {
            // Expected: an allowed-looking root may not redirect elsewhere.
        }
        let externalSnapshot = try frameSnapshot(externalDB.path)
        try expect(externalSnapshot["external"]?.model == staleAliasA,
                   "Symlink escape mutated an external Claude Science database")
    }

    private static func testManagedDaemonGuard() throws {
        let numericLock = Data(#"{"pid":92207,"port":14412}"#.utf8)
        try expect(ScienceManagedDaemonStopper.lockedPID(from: numericLock) == 92_207,
                   "Real JSON-number operon.lock PID was not parsed")
        try expect(
            ScienceManagedDaemonStopper.lockedPID(from: Data(#"{"pid":"92207"}"#.utf8)) == nil,
            "String lock PID was accepted"
        )
        try expect(
            ScienceManagedDaemonStopper.lockedPID(from: Data(#"{"pid":true}"#.utf8)) == nil,
            "Boolean lock PID was accepted"
        )
        try expect(
            ScienceManagedDaemonStopper.lockedPID(from: Data(#"{"pid":4.5}"#.utf8)) == nil,
            "Fractional lock PID was accepted"
        )
        try expect(
            ScienceManagedDaemonStopper.lockedPID(from: Data(#"{"pid":92207.0}"#.utf8)) == nil,
            "Floating-point JSON lock PID was accepted"
        )
        try expect(
            ScienceManagedDaemonStopper.lockedPID(from: Data(#"{"pid":1}"#.utf8)) == nil,
            "Unsafe lock PID was accepted"
        )

        let dataDir = "/Users/test account/.config/aiusage/science-sandbox/home/.claude-science"
        let executable = "/Applications/Claude Science.app/Contents/Resources/bin/claude-science"
        try expect(
            ScienceManagedDaemonStopper.commandMatchesManagedDaemon(
                "\(executable) serve --data-dir \(dataDir) --port 14412 --_daemon-child",
                dataDir: dataDir
            ),
            "Exact separate --data-dir daemon command was rejected"
        )
        try expect(
            ScienceManagedDaemonStopper.commandMatchesManagedDaemon(
                "\(executable) serve --data-dir=\(dataDir) --port 14412",
                dataDir: dataDir
            ),
            "Exact equals-style --data-dir daemon command was rejected"
        )
        try expect(
            !ScienceManagedDaemonStopper.commandMatchesManagedDaemon(
                "\(executable) serve --data-dir \(dataDir)-other --port 14412",
                dataDir: dataDir
            ),
            "Prefix-only data directory match was accepted"
        )
        try expect(
            !ScienceManagedDaemonStopper.commandMatchesManagedDaemon(
                "\(executable) serve --data-dir /tmp/unmanaged --port 14412",
                dataDir: dataDir
            ),
            "Different data directory was accepted"
        )
        try expect(
            !ScienceManagedDaemonStopper.commandMatchesManagedDaemon(
                "/tmp/not-science serve --data-dir \(dataDir)",
                dataDir: dataDir
            ),
            "Non-Claude-Science process was accepted"
        )
    }

    private struct FrameSnapshot: Equatable {
        let model: String?
        let rootSeq: Int64
    }

    private static func executeSQLite(_ path: String, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw RegressionFailure.failed("Could not create regression SQLite database")
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(errorMessage)
            throw RegressionFailure.failed(message)
        }
    }

    private static func frameSnapshot(_ path: String) throws -> [String: FrameSnapshot] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw RegressionFailure.failed("Could not open regression SQLite database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id, model, root_seq FROM frames", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RegressionFailure.failed("Could not query regression frames")
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: FrameSnapshot] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let model = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            result[String(cString: idText)] = FrameSnapshot(
                model: model,
                rootSeq: sqlite3_column_int64(statement, 2)
            )
        }
        return result
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw RegressionFailure.failed(message) }
        return value
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
