import Foundation

// MARK: - Codex Cost Provider: Track Building (proxy / non-proxy merge)
// 非代理轨：从 JSONL 快照里取 (Non-Proxy) 模型；代理 JSONL 行已在解析阶段丢弃，避免和代理归档双计。
//          非代理只统计 token，成本恒 0。
// 合并轨：代理日桶 + 非代理日桶按日合并（模型名带 (Proxy)/(Non-Proxy) 标签，键天然不冲突）。

extension CodexCostProvider {
    static let proxySourceSuffix = " (Proxy)"
    static let nonProxySourceSuffix = " (Non-Proxy)"

    /// 从快照构建非代理轨当日桶：仅 (Non-Proxy) 模型，仅统计 token，成本恒 0。
    /// 返回的桶保留 " (Non-Proxy)" 标签以便统计页区分来源。
    func buildNonProxyDays(snapshot: CodexUsageSnapshot) -> [String: CodexAggregateBucket] {
        var out: [String: CodexAggregateBucket] = [:]

        for (day, dayBucket) in snapshot.days {
            var bucket = CodexAggregateBucket.empty
            for (modelKey, agg) in dayBucket.models where modelKey.hasSuffix(Self.nonProxySourceSuffix) {
                var m = CodexModelAggregate(model: modelKey)
                m.inputTokens = agg.inputTokens
                m.outputTokens = agg.outputTokens
                m.cacheReadTokens = agg.cacheReadTokens
                m.cacheCreateTokens = agg.cacheCreateTokens
                m.totalTokens = agg.totalTokens
                m.estimatedCostUsd = 0

                bucket.models[modelKey] = m
                bucket.usageRows += 1
                bucket.totalTokens += agg.totalTokens
            }
            if !bucket.models.isEmpty { out[day] = bucket }
        }
        return out
    }

    /// 代理日桶 + 非代理日桶按日合并。
    func combineTrackDays(
        proxy: [String: CodexAggregateBucket],
        nonProxy: [String: CodexAggregateBucket]
    ) -> [String: CodexAggregateBucket] {
        var out = proxy
        for (day, bucket) in nonProxy {
            out[day, default: .empty].merge(bucket)
        }
        return out
    }

    /// 仅看「今天」：代理归档里今天成本为 0 但有 token 的模型 → 视为当前缺定价（提示用户配价）。
    /// 历史日不再纳入——旧的、已不再使用或当时未配价的模型名不应永久纠缠（成本历史不可篡改）。
    func proxyUnpricedModels(_ proxyDays: [String: CodexAggregateBucket], todayKey: String) -> Set<String> {
        guard let bucket = proxyDays[todayKey] else { return [] }
        var unpriced = Set<String>()
        for (modelKey, m) in bucket.models where m.unpricedRequests > 0 && m.totalTokens > 0 {
            unpriced.insert(modelKey)
        }
        return unpriced
    }
}
