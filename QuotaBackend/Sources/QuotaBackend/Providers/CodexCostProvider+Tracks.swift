import Foundation

// MARK: - Codex Cost Provider: Track Building (subscription / API merge)
// 订阅轨：从 JSONL 快照里取 (Sub) 模型，丢弃 (API) 模型（它们走代理日志归档，避免双计）。
//        订阅制本质不按 token 计费，故订阅轨「只统计用量、成本恒 0」（不设订阅定价表）。
// 合并轨：API 日桶 + 订阅日桶按日合并（模型名带 (API)/(Sub) 标签，键天然不冲突）。

extension CodexCostProvider {
    static let subSourceSuffix = " (Sub)"

    /// 从快照构建订阅轨当日桶：仅 (Sub) 模型，仅统计 token，成本恒 0（订阅不计费）。
    /// 返回的桶保留 " (Sub)" 标签以便统计页区分来源。
    func buildSubscriptionDays(snapshot: CodexUsageSnapshot) -> [String: CodexAggregateBucket] {
        var out: [String: CodexAggregateBucket] = [:]

        for (day, dayBucket) in snapshot.days {
            var bucket = CodexAggregateBucket.empty
            for (modelKey, agg) in dayBucket.models where modelKey.hasSuffix(Self.subSourceSuffix) {
                var m = CodexModelAggregate(model: modelKey)
                m.inputTokens = agg.inputTokens
                m.outputTokens = agg.outputTokens
                m.cacheReadTokens = agg.cacheReadTokens
                m.totalTokens = agg.totalTokens
                m.estimatedCostUsd = 0  // 订阅制不计费，仅统计用量

                bucket.models[modelKey] = m
                bucket.usageRows += 1
                bucket.totalTokens += agg.totalTokens
            }
            if !bucket.models.isEmpty { out[day] = bucket }
        }
        return out
    }

    /// API 日桶 + 订阅日桶按日合并。
    func combineTrackDays(
        api: [String: CodexAggregateBucket],
        sub: [String: CodexAggregateBucket]
    ) -> [String: CodexAggregateBucket] {
        var out = api
        for (day, bucket) in sub {
            out[day, default: .empty].merge(bucket)
        }
        return out
    }

    /// 仅看「今天」：代理(API)归档里今天成本为 0 但有 token 的模型 → 视为当前缺定价（提示用户配价）。
    /// 历史日不再纳入——旧的、已不再使用或当时未配价的模型名不应永久纠缠（成本历史不可篡改）。
    func apiUnpricedModels(_ apiDays: [String: CodexAggregateBucket], todayKey: String) -> Set<String> {
        guard let bucket = apiDays[todayKey] else { return [] }
        var unpriced = Set<String>()
        for (modelKey, m) in bucket.models where m.estimatedCostUsd == 0 && m.totalTokens > 0 {
            unpriced.insert(modelKey)
        }
        return unpriced
    }
}
