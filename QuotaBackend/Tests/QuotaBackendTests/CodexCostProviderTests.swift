import XCTest
import Foundation
@testable import QuotaBackend

// Codex 两轨用量统计测试（与「代理日志 API 轨 + JSONL 订阅轨」架构对齐）：
// - 订阅轨：JSONL 非代理行「仅统计 token、成本恒 0」（订阅制不计费），模型名带 " (Sub)" 标签；
//   token 用量今天之前冻结、今天重算（删本地日志后历史用量不丢）。
// - API 轨：读 proxy-usage-codex 永久归档，成本逐条冻结，模型名带 " (API)" 标签。
// - JSONL 里的代理(API)行被丢弃（避免与代理归档双计）。
final class CodexCostProviderTests: XCTestCase {

    // MARK: - 订阅轨：仅统计 token、成本恒 0 + (Sub) 标签

    func testSubscriptionTrackCountsTokensOnlyAndTagsSub() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()

        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts1 = SharedFormatters.iso8601String(from: now.addingTimeInterval(-60))
        let ts2 = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts1, "payload": ["id": "session-1"]],
            ["type": "turn_context", "timestamp": ts1, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts1, input: 100, cached: 40, output: 20),
            tokenCountLine(ts2, input: 160, cached: 50, output: 70)
        ], to: sessionDir.appendingPathComponent("session-1.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        // net input = 160 - 50(cached) = 110, cacheRead 50, output 70 → total 230
        XCTAssertEqual(usage.extra["overall.totalTokens"]?.value as? Int, 230)
        XCTAssertEqual(usage.source?.type, "codex-two-track")
        XCTAssertEqual(summary.providerId, "codex-cost")
        XCTAssertEqual(summary.category, "local-cost")
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 230)

        let model = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(model.model, "gpt-5.4 (Sub)")
        XCTAssertEqual(model.inputTokens, 110)
        XCTAssertEqual(model.cacheReadTokens, 50)
        XCTAssertEqual(model.outputTokens, 70)

        // 订阅制不计费：成本恒 0，且订阅模型不算「未定价」。
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertEqual(model.estimatedCostUsd, 0)
        XCTAssertEqual(extraInt(usage, "overall.sub.totalTokens"), 230)
        XCTAssertEqual(extraInt(usage, "overall.api.totalTokens"), 0)
        XCTAssertNil(summary.unpricedModels)
    }

    func testSubscriptionTrackHasZeroCostAndIsNeverUnpriced() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "session-sub"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 100, cached: 0, output: 20)
        ], to: sessionDir.appendingPathComponent("session-sub.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        // 订阅轨从不计费 → 成本 0，且不应进入「未定价」集合。
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertNil(summary.unpricedModels)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.model, "gpt-5.4 (Sub)")
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
            ["type": "session_meta", "timestamp": parentTs, "payload": ["id": "parent-session"]],
            ["type": "turn_context", "timestamp": parentTs, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(parentTs, input: 100, cached: 40, output: 20)
        ], to: sessionDir.appendingPathComponent("parent.jsonl"))

        try writeJSONLines([
            ["type": "session_meta", "timestamp": childTs, "payload": [
                "id": "child-session",
                "forked_from_id": "parent-session",
                "timestamp": childTs
            ]],
            ["type": "turn_context", "timestamp": childTs, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(childTs, input: 130, cached: 50, output: 30)
        ], to: sessionDir.appendingPathComponent("child.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 160)
        let breakdown = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(breakdown.model, "gpt-5.4 (Sub)")
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
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "session-model-override"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            [
                "type": "event_msg",
                "timestamp": ts,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": "gpt-5-mini",
                        "total_token_usage": ["input_tokens": 10, "cached_input_tokens": 0, "output_tokens": 5]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("session-model-override.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        let models = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall)
        XCTAssertEqual(models.map(\.model), ["gpt-5-mini (Sub)"])
    }

    func testParsesLastTokenUsageDeltas() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "session-last-token-usage"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            [
                "type": "event_msg",
                "timestamp": ts,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": ["input_tokens": 12, "cached_input_tokens": 4, "output_tokens": 7]
                    ]
                ]
            ]
        ], to: sessionDir.appendingPathComponent("session-last-token-usage.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 19)
        let breakdown = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall?.first)
        XCTAssertEqual(breakdown.inputTokens, 8)
        XCTAssertEqual(breakdown.cacheReadTokens, 4)
        XCTAssertEqual(breakdown.outputTokens, 7)
    }

    // MARK: - 代理(API)行丢弃，避免双计

    func testProxyTaggedJSONLRowsAreExcludedFromSubscriptionTrack() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        // model_provider = aiusage-proxy → 该会话被标为 (API)，应被订阅轨丢弃。
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "proxy-session", "model_provider": "aiusage-proxy"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 100, cached: 0, output: 20)
        ], to: sessionDir.appendingPathComponent("proxy-session.jsonl"))

        // 无代理归档文件 → API 轨为空，订阅轨丢弃 (API) 行后也为空 → 无任何用量。
        let provider = makeProvider(home: tempRoot)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected no_usage_data: proxy-tagged JSONL rows must not feed the subscription track")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "no_usage_data")
        }
    }

    // MARK: - API 轨：读代理归档 + 与订阅轨合并

    func testApiTrackFromProxyArchiveMergesWithSubscriptionTrack() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let todayKey = utcDayKey(now)

        // API 轨：代理归档（成本冻结 0.5），模型 gpt-5.4，今天。
        try writeProxyApiArchive(home: tempRoot, days: [
            todayKey: ["gpt-5.4": [
                "inputTokens": 300, "outputTokens": 100,
                "cacheReadTokens": 0, "cacheCreateTokens": 0,
                "costUSD": 0.5, "requests": 2
            ]]
        ])

        // 订阅轨：JSONL 非代理行仅统计 token（订阅不计费，成本恒 0）。
        let sessionDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "sub-session"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 1_000_000, cached: 0, output: 0)
        ], to: sessionDir.appendingPathComponent("sub-session.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(extraInt(usage, "overall.api.totalTokens"), 400)
        XCTAssertEqual(extraDouble(usage, "overall.api.estimatedCostUsd") ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(extraInt(usage, "overall.sub.totalTokens"), 1_000_000)
        XCTAssertEqual(extraDouble(usage, "overall.sub.estimatedCostUsd") ?? -1, 0.0, accuracy: 1e-9)

        // 合计 token = 两轨之和；合计成本 = 仅 API（订阅不计费）。
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 1_000_400)
        XCTAssertEqual(summary.costSummary?.overall?.usd ?? -1, 0.5, accuracy: 1e-9)

        let models = try XCTUnwrap(summary.costSummary?.modelBreakdownOverall)
        let api = try XCTUnwrap(models.first { $0.model == "gpt-5.4 (API)" })
        XCTAssertEqual(api.totalTokens, 400)
        XCTAssertEqual(api.estimatedCostUsd, 0.5, accuracy: 1e-9)
        let sub = try XCTUnwrap(models.first { $0.model == "gpt-5.4 (Sub)" })
        XCTAssertEqual(sub.totalTokens, 1_000_000)
        XCTAssertEqual(sub.estimatedCostUsd, 0.0, accuracy: 1e-9)
    }

    func testApiTrackZeroCostModelMarkedUnpriced() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let todayKey = utcDayKey(now)
        try writeProxyApiArchive(home: tempRoot, days: [
            todayKey: ["gpt-5.4": [
                "inputTokens": 300, "outputTokens": 100,
                "cacheReadTokens": 0, "cacheCreateTokens": 0,
                "costUSD": 0.0, "requests": 1
            ]]
        ])

        let provider = makeProvider(home: tempRoot)
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 400)
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertEqual(summary.unpricedModels, ["gpt-5.4 (API)"])
    }

    // MARK: - 订阅轨冻结：今天之前冻结、今天重算（删本地日志后历史用量不丢）

    func testSubscriptionPastDayTokensStayFrozenAfterLogDeletion() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)

        // 昨天 1,000,000 net；今天 2,000,000 net。
        let yDir = codexSessionDirectory(in: tempRoot, for: yesterday)
        try FileManager.default.createDirectory(at: yDir, withIntermediateDirectories: true)
        let yts = SharedFormatters.iso8601String(from: yesterday)
        let yesterdayFile = yDir.appendingPathComponent("yesterday.jsonl")
        try writeJSONLines([
            ["type": "session_meta", "timestamp": yts, "payload": ["id": "yesterday-session"]],
            ["type": "turn_context", "timestamp": yts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(yts, input: 1_000_000, cached: 0, output: 0)
        ], to: yesterdayFile)

        let tDir = codexSessionDirectory(in: tempRoot, for: now)
        try FileManager.default.createDirectory(at: tDir, withIntermediateDirectories: true)
        let tts = SharedFormatters.iso8601String(from: now)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": tts, "payload": ["id": "today-session"]],
            ["type": "turn_context", "timestamp": tts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(tts, input: 2_000_000, cached: 0, output: 0)
        ], to: tDir.appendingPathComponent("today.jsonl"))

        // 首跑：昨天 1M、今天 2M、合计 3M（订阅 token；成本恒 0）。
        let provider = makeProvider(home: tempRoot)
        let first = try await provider.fetchUsage()
        let firstSummary = UsageNormalizer.normalize(provider: provider, usage: first)
        XCTAssertEqual(firstSummary.costSummary?.today?.tokens, 2_000_000)
        XCTAssertEqual(firstSummary.costSummary?.overall?.tokens, 3_000_000)
        XCTAssertEqual(firstSummary.costSummary?.overall?.usd, 0)

        // 删除昨天的本地日志后重跑：昨天已冻结进归档 → 历史用量不丢，合计仍含昨天 1M。
        try FileManager.default.removeItem(at: yesterdayFile)
        let second = try await provider.fetchUsage()
        let secondSummary = UsageNormalizer.normalize(provider: provider, usage: second)
        XCTAssertEqual(secondSummary.costSummary?.today?.tokens, 2_000_000)
        XCTAssertEqual(secondSummary.costSummary?.overall?.tokens, 3_000_000)
    }

    func testFullHistoryImportFreezesSubscriptionArchivePerHome() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let oldDate = Date().addingTimeInterval(-60 * 86_400)
        let sessionDir = codexSessionDirectory(in: tempRoot, for: oldDate)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let ts = SharedFormatters.iso8601String(from: oldDate)
        try writeJSONLines([
            ["type": "session_meta", "timestamp": ts, "payload": ["id": "old-session"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.4"]],
            tokenCountLine(ts, input: 42, cached: 0, output: 8)
        ], to: sessionDir.appendingPathComponent("old-session.jsonl"))

        let provider = makeProvider(home: tempRoot)
        let initiallyNeedsImport = await provider.needsFullHistoryImport()
        XCTAssertTrue(initiallyNeedsImport)

        // 另一个 home 的归档相互独立，互不消费全量请求。
        let otherHome = tempRoot.appendingPathComponent("other-home", isDirectory: true)
        let otherProvider = makeProvider(home: otherHome)
        let otherNeedsImport = await otherProvider.needsFullHistoryImport()
        XCTAssertTrue(otherNeedsImport)

        // 首跑触发全量导入：冻结 60 天前的订阅日（窗口外，必须靠全量扫描）。
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.extra["overall.totalTokens"]?.value as? Int, 50)

        let archiveURL = CodexSubscriptionUsageArchiveStore.fileURL(homeDirectory: tempRoot.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        let stillNeedsImport = await provider.needsFullHistoryImport()
        XCTAssertFalse(stillNeedsImport)
    }

    // MARK: - Helpers

    private func makeProvider(home: URL) -> CodexCostProvider {
        CodexCostProvider(
            homeDirectory: home.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: [:]
        )
    }

    private func extraInt(_ usage: ProviderUsage, _ key: String) -> Int? {
        switch usage.extra[key]?.value {
        case let value as Int: return value
        case let value as Double: return Int(value)
        default: return nil
        }
    }

    private func extraDouble(_ usage: ProviderUsage, _ key: String) -> Double? {
        switch usage.extra[key]?.value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        default: return nil
        }
    }

    private func tokenCountLine(_ timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output
                    ]
                ]
            ]
        ]
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-codex-cost-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func codexSessionDirectory(in tempRoot: URL, for date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return tempRoot
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
    }

    private func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeProxyApiArchive(home: URL, days: [String: [String: [String: Any]]]) throws {
        let dir = home.appendingPathComponent(".config/aiusage/usage-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dayDTOs: [String: Any] = [:]
        for (day, models) in days {
            dayDTOs[day] = ["models": models]
        }
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": SharedFormatters.iso8601String(from: Date()),
            "days": dayDTOs
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent("proxy-usage-codex-v1.json"), options: .atomic)
    }
}
