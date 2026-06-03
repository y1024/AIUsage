import Foundation

// MARK: - Codex Cost Provider: Proxy Usage Archive Source (API track)
// Codex API 轨数据源 = 代理日志永久归档（proxy-usage-codex-v<v>.json，App 侧 ProxyUsageArchiveStore
// 从 ProxyRequestLog 折叠写出，成本逐条冻结、支持同模型不同节点不同价、不可篡改）。
// QuotaBackend 只读该 JSON（无法 import App，故在此定义匹配 DTO）。模型名加 " (API)" 标签以便和订阅轨区分。
//
// 数据来源: ~/.config/aiusage/usage-archive/proxy-usage-codex-v<version>.json

extension CodexCostProvider {
    static let proxyUsageArchiveVersion = 1
    static let apiSourceSuffix = " (API)"

    private struct ProxyUsageModelAggDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
        let costUSD: Double
        let requests: Int
    }

    private struct ProxyUsageDayDTO: Decodable {
        let models: [String: ProxyUsageModelAggDTO]
    }

    private struct ProxyUsageArchiveDTO: Decodable {
        let version: Int
        let updatedAt: String
        let days: [String: ProxyUsageDayDTO]
    }

    func proxyUsageArchivePath() -> String {
        (homeDirectory as NSString)
            .appendingPathComponent(".config/aiusage/usage-archive/proxy-usage-codex-v\(Self.proxyUsageArchiveVersion).json")
    }

    /// 读取 Codex 代理用量归档 → 按日 `CodexAggregateBucket`，模型加 " (API)" 标签，成本采用冻结的 `costUSD`。
    func loadProxyApiDays() -> [String: CodexAggregateBucket] {
        let path = proxyUsageArchivePath()
        guard let data = FileManager.default.contents(atPath: path),
              let dto = try? JSONDecoder().decode(ProxyUsageArchiveDTO.self, from: data) else {
            return [:]
        }

        var result: [String: CodexAggregateBucket] = [:]
        for (day, dayDTO) in dto.days {
            var bucket = CodexAggregateBucket.empty
            for (modelName, agg) in dayDTO.models {
                let total = agg.inputTokens + agg.outputTokens + agg.cacheReadTokens + agg.cacheCreateTokens
                guard total > 0 else { continue }

                let tagged = "\(modelName)\(Self.apiSourceSuffix)"
                var m = CodexModelAggregate(model: tagged)
                m.inputTokens = agg.inputTokens
                m.outputTokens = agg.outputTokens
                // Codex 模型聚合无 cacheCreate 字段，并入 cacheRead 以保证 token 合计一致。
                m.cacheReadTokens = agg.cacheReadTokens + agg.cacheCreateTokens
                m.totalTokens = total
                m.estimatedCostUsd = agg.costUSD

                bucket.models[tagged] = m
                bucket.usageRows += max(agg.requests, 0)
                bucket.totalTokens += total
                bucket.estimatedCostUsd += agg.costUSD
            }
            if !bucket.models.isEmpty { result[day] = bucket }
        }
        return result
    }
}
