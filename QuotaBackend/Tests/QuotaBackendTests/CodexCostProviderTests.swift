import XCTest
@testable import QuotaBackend

final class CodexCostProviderTests: XCTestCase {
    func testParsesCodexTokenDeltasIntoCostSummary() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ts1 = SharedFormatters.iso8601String(from: now.addingTimeInterval(-60))
        let ts2 = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            [
                "type": "session_meta",
                "timestamp": ts1,
                "payload": ["id": "session-1"]
            ],
            [
                "type": "turn_context",
                "timestamp": ts1,
                "payload": ["model": "gpt-5.4"]
            ],
            [
                "type": "event_msg",
                "timestamp": ts1,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 100,
                            "cached_input_tokens": 40,
                            "output_tokens": 20
                        ]
                    ]
                ]
            ],
            [
                "type": "event_msg",
                "timestamp": ts2,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 160,
                            "cached_input_tokens": 50,
                            "output_tokens": 70
                        ]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("session-1.jsonl"))

        let provider = CodexCostProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: [:]
        )
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(usage.extra["overall.totalTokens"]?.value as? Int, 230)
        XCTAssertEqual(summary.providerId, "codex-cost")
        XCTAssertEqual(summary.category, "local-cost")
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 230)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.model, "gpt-5.4")
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.inputTokens, 110)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.cacheReadTokens, 50)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.outputTokens, 70)
        XCTAssertEqual(summary.unpricedModels, nil)
    }

    func testSubtractsInheritedTotalsForForkedCodexSessions() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let parentTs = SharedFormatters.iso8601String(from: now.addingTimeInterval(-120))
        let childTs = SharedFormatters.iso8601String(from: now.addingTimeInterval(-60))

        try writeJSONLines([
            [
                "type": "session_meta",
                "timestamp": parentTs,
                "payload": ["id": "parent-session"]
            ],
            [
                "type": "turn_context",
                "timestamp": parentTs,
                "payload": ["model": "gpt-5.4"]
            ],
            [
                "type": "event_msg",
                "timestamp": parentTs,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 100,
                            "cached_input_tokens": 40,
                            "output_tokens": 20
                        ]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("parent.jsonl"))

        try writeJSONLines([
            [
                "type": "session_meta",
                "timestamp": childTs,
                "payload": [
                    "id": "child-session",
                    "forked_from_id": "parent-session",
                    "timestamp": childTs
                ]
            ],
            [
                "type": "turn_context",
                "timestamp": childTs,
                "payload": ["model": "gpt-5.4"]
            ],
            [
                "type": "event_msg",
                "timestamp": childTs,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 130,
                            "cached_input_tokens": 50,
                            "output_tokens": 30
                        ]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("child.jsonl"))

        let provider = CodexCostProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: [:]
        )
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 160)
        let breakdown = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(breakdown.inputTokens, 80)
        XCTAssertEqual(breakdown.cacheReadTokens, 50)
        XCTAssertEqual(breakdown.outputTokens, 30)
    }

    func testTokenCountModelOverridesPreviousTurnContext() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            [
                "type": "session_meta",
                "timestamp": ts,
                "payload": ["id": "session-model-override"]
            ],
            [
                "type": "turn_context",
                "timestamp": ts,
                "payload": ["model": "gpt-5.4"]
            ],
            [
                "type": "event_msg",
                "timestamp": ts,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": "gpt-5-mini",
                        "total_token_usage": [
                            "input_tokens": 10,
                            "cached_input_tokens": 0,
                            "output_tokens": 5
                        ]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("session-model-override.jsonl"))

        let provider = CodexCostProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: [:]
        )
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        let models = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall)
        XCTAssertEqual(models.map(\.model), ["gpt-5-mini"])
    }

    func testParsesLastTokenUsageDeltas() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            [
                "type": "session_meta",
                "timestamp": ts,
                "payload": ["id": "session-last-token-usage"]
            ],
            [
                "type": "turn_context",
                "timestamp": ts,
                "payload": ["model": "gpt-5.4"]
            ],
            [
                "type": "event_msg",
                "timestamp": ts,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 12,
                            "cached_input_tokens": 4,
                            "output_tokens": 7
                        ]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("session-last-token-usage.jsonl"))

        let provider = CodexCostProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: [:]
        )
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 19)
        let breakdown = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(breakdown.inputTokens, 8)
        XCTAssertEqual(breakdown.cacheReadTokens, 4)
        XCTAssertEqual(breakdown.outputTokens, 7)
    }

    func testFullHistoryImportStateUsesCodexHomeScope() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let codexHome = tempRoot.appendingPathComponent("custom-codex-home", isDirectory: true)
        let oldDate = Date().addingTimeInterval(-60 * 86_400)
        let sessionDir = codexSessionDirectory(codexHome: codexHome, for: oldDate)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ts = SharedFormatters.iso8601String(from: oldDate)
        try writeJSONLines([
            [
                "type": "session_meta",
                "timestamp": ts,
                "payload": ["id": "custom-home-session"]
            ],
            [
                "type": "turn_context",
                "timestamp": ts,
                "payload": ["model": "gpt-5.4"]
            ],
            [
                "type": "event_msg",
                "timestamp": ts,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 42,
                            "cached_input_tokens": 0,
                            "output_tokens": 8
                        ]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("custom-home-session.jsonl"))

        let provider = CodexCostProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: ["CODEX_HOME": codexHome.path]
        )

        let initiallyNeedsImport = await provider.needsFullHistoryImport()
        XCTAssertTrue(initiallyNeedsImport)
        await provider.requestFullHistoryImport()

        let otherProvider = CodexCostProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: ["CODEX_HOME": tempRoot.appendingPathComponent("other-codex-home").path]
        )
        do {
            _ = try await otherProvider.fetchUsage()
            XCTFail("Expected missing logs for unrelated Codex home")
        } catch {
            // The unrelated scope should not consume this provider's full-history request.
        }

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.extra["overall.totalTokens"]?.value as? Int, 50)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexUsageArchiveStore.archiveFileURL(scope: codexHome.path).path))
        let stillNeedsImport = await provider.needsFullHistoryImport()
        XCTAssertFalse(stillNeedsImport)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-codex-cost-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func codexSessionDirectory(in tempRoot: URL, for date: Date) -> URL {
        codexSessionDirectory(codexHome: tempRoot.appendingPathComponent(".codex", isDirectory: true), for: date)
    }

    private func codexSessionDirectory(codexHome: URL, for date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
