import Foundation

// MARK: - OpenCode Cost Provider: Global Proxy Usage Archive Source
// OpenCode「全局统一代理」轨的用量来自代理日志的永久归档（proxy-usage-opencode-v<v>.json，
// App 侧 OpenCodeProxyRuntime 按激活节点定价就地算成本后增量写出，成本逐条冻结）。
// QuotaBackend 只读该 JSON（无法 import App，故在此定义匹配 DTO）。
//
// 模型键口径：App 侧已按 `aiusage-<slug>/<model>` 写出（与 opencode.db 直连/路线 B 完全一致），
// 故同节点同模型跨「全局代理」与「直连」两条路径在此按日合并为同一行（不加任何来源后缀）。
// db 侧已排除裸全局 provider `aiusage`，两源是互斥的事件集合，相加不双计。
//
// 数据来源: ~/.config/aiusage/usage-archive/proxy-usage-opencode-v<version>.json

extension OpenCodeCostProvider {
    static let proxyUsageArchiveVersion = 1

    private struct ProxyUsageModelAggDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
        let costUSD: Double
        let requests: Int
        let pricingResolvedRequests: Int?
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
            .appendingPathComponent(".config/aiusage/usage-archive/proxy-usage-opencode-v\(Self.proxyUsageArchiveVersion).json")
    }

    /// 读取 OpenCode 全局代理用量归档 → 按日 `CodexAggregateBucket`；模型键沿用归档原值
    /// （已是 `aiusage-<slug>/<model>`，与 db 同口径），成本采用冻结的 `costUSD`。
    func loadProxyDays() -> [String: CodexAggregateBucket] {
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

                var m = CodexModelAggregate(model: modelName)
                m.inputTokens = agg.inputTokens
                m.outputTokens = agg.outputTokens
                m.cacheReadTokens = agg.cacheReadTokens
                m.cacheCreateTokens = agg.cacheCreateTokens
                m.totalTokens = total
                m.estimatedCostUsd = agg.costUSD
                let requestCount = max(agg.requests, 0)
                let resolvedCount = agg.pricingResolvedRequests ?? (agg.costUSD > 0 ? requestCount : 0)
                m.unpricedRequests = max(0, requestCount - resolvedCount)

                bucket.models[modelName] = m
                bucket.usageRows += requestCount
                bucket.totalTokens += total
                bucket.estimatedCostUsd += agg.costUSD
            }
            if !bucket.models.isEmpty { result[day] = bucket }
        }
        return result
    }

    /// 把代理归档按日合并进 db 冻结后的每日桶。模型键同口径（`aiusage-<slug>/<model>`），
    /// 同节点同模型自动并入同一行；仅合并到内存结果，不回写 db 冻结归档——代理归档自身是代理用量的永久真相源。
    func mergeProxyDays(into dbDays: [String: CodexAggregateBucket]) -> [String: CodexAggregateBucket] {
        let proxyDays = loadProxyDays()
        guard !proxyDays.isEmpty else { return dbDays }

        var merged = dbDays
        for (day, proxyBucket) in proxyDays {
            var bucket = merged[day] ?? .empty
            bucket.usageRows += proxyBucket.usageRows
            bucket.totalTokens += proxyBucket.totalTokens
            bucket.estimatedCostUsd += proxyBucket.estimatedCostUsd
            for (model, agg) in proxyBucket.models {
                var existing = bucket.models[model] ?? CodexModelAggregate(model: model)
                existing.merge(agg)
                bucket.models[model] = existing
            }
            merged[day] = bucket
        }
        return merged
    }
}
