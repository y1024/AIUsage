import XCTest
import Foundation
@testable import QuotaBackend

final class ClaudeProviderProxyArchiveTests: XCTestCase {
    func testZeroCostWithResolvedPricingIsNotUnpriced() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let todayKey = utcDayKey(Date())
        try writeClaudeArchive(home: tempRoot, days: [
            todayKey: ["claude-sonnet": [
                "inputTokens": 300,
                "outputTokens": 100,
                "cacheReadTokens": 20,
                "cacheCreateTokens": 10,
                "costUSD": 0.0,
                "requests": 1,
                "pricingResolvedRequests": 1
            ]]
        ])

        let provider = ClaudeProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(usage.label, "Claude")
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 430)
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertNil(summary.unpricedModels)
    }

    func testZeroCostWithoutResolvedPricingIsUnpriced() async throws {
        let tempRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let todayKey = utcDayKey(Date())
        try writeClaudeArchive(home: tempRoot, days: [
            todayKey: ["claude-sonnet": [
                "inputTokens": 300,
                "outputTokens": 100,
                "cacheReadTokens": 0,
                "cacheCreateTokens": 0,
                "costUSD": 0.0,
                "requests": 1
            ]]
        ])

        let provider = ClaudeProvider(
            homeDirectory: tempRoot.path,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)

        XCTAssertEqual(summary.costSummary?.overall?.tokens, 400)
        XCTAssertEqual(summary.unpricedModels, ["claude-sonnet"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-claude-provider-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private func writeClaudeArchive(home: URL, days: [String: [String: [String: Any]]]) throws {
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
        try data.write(to: dir.appendingPathComponent("proxy-usage-claude-v1.json"), options: .atomic)
    }
}
