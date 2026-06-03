import Foundation

// MARK: - Claude Provider: Aggregation & Timeline Building

extension ClaudeProvider {

    struct TimelineBucket {
        let bucket: String
        let label: String
        let estimatedCostUsd: Double
        let totalTokens: Int
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreateTokens: Int = 0
    }

    func aggregateDays(
        _ bucketsByDay: [String: ClaudeAggregateBucket],
        matching: (String) -> Bool
    ) -> ClaudeAggregateBucket {
        var result = ClaudeAggregateBucket.empty
        for (day, bucket) in bucketsByDay where matching(day) {
            result.merge(bucket)
        }
        return result
    }

    func trailingDailyTimeline(
        bucketsByDay: [String: ClaudeAggregateBucket],
        now: Date,
        dayCount: Int,
        model: String? = nil
    ) -> [TimelineBucket] {
        let calendar = calendar()
        let today = calendar.startOfDay(for: now)
        let count = max(dayCount, 1)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today

        return (0..<count).compactMap { offset -> TimelineBucket? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayKey(day)
            let m = bucketMetrics(bucketsByDay[key], model: model)
            return TimelineBucket(
                bucket: key,
                label: dayBucketLabel(day),
                estimatedCostUsd: roundUsd(m.estimatedCostUsd),
                totalTokens: m.totalTokens,
                inputTokens: m.inputTokens,
                outputTokens: m.outputTokens,
                cacheReadTokens: m.cacheReadTokens,
                cacheCreateTokens: m.cacheCreateTokens
            )
        }
    }

    typealias BucketMetrics = (estimatedCostUsd: Double, totalTokens: Int,
                                inputTokens: Int, outputTokens: Int,
                                cacheReadTokens: Int, cacheCreateTokens: Int)

    func bucketMetrics(
        _ bucket: ClaudeAggregateBucket?,
        model: String?
    ) -> BucketMetrics {
        guard let bucket else { return (0, 0, 0, 0, 0, 0) }
        if let model {
            guard let m = bucket.models[model] else { return (0, 0, 0, 0, 0, 0) }
            return (m.estimatedCostUsd, m.totalTokens,
                    m.inputTokens, m.outputTokens,
                    m.cacheReadTokens, m.cacheCreateTokens)
        }
        var inp = 0; var out = 0; var cR = 0; var cC = 0
        for m in bucket.models.values {
            inp += m.inputTokens; out += m.outputTokens
            cR += m.cacheReadTokens; cC += m.cacheCreateTokens
        }
        return (bucket.estimatedCostUsd, bucket.totalTokens, inp, out, cR, cC)
    }

    func encodeTimeline(_ buckets: [TimelineBucket], includeDetail: Bool = false) -> [AnyCodable] {
        buckets.map { bucket in
            var dict: [String: AnyCodable] = [
                "bucket": AnyCodable(bucket.bucket),
                "label": AnyCodable(bucket.label),
                "usd": AnyCodable(bucket.estimatedCostUsd),
                "tokens": AnyCodable(bucket.totalTokens)
            ]
            if includeDetail {
                dict["inputTokens"] = AnyCodable(bucket.inputTokens)
                dict["outputTokens"] = AnyCodable(bucket.outputTokens)
                dict["cacheReadTokens"] = AnyCodable(bucket.cacheReadTokens)
                dict["cacheCreateTokens"] = AnyCodable(bucket.cacheCreateTokens)
            }
            return AnyCodable(dict)
        }
    }

    func encodeModelBreakdown(_ agg: ClaudeAggregateBucket) -> [AnyCodable] {
        let sorted = agg.models.values.sorted {
            if $0.estimatedCostUsd != $1.estimatedCostUsd { return $0.estimatedCostUsd > $1.estimatedCostUsd }
            return $0.totalTokens > $1.totalTokens
        }
        let totalCost = agg.estimatedCostUsd
        let totalTokens = agg.totalTokens
        return sorted.map { model -> AnyCodable in
            let pct = totalCost > 0
                ? roundUsd(model.estimatedCostUsd / totalCost * 100)
                : (totalTokens > 0 ? roundUsd(Double(model.totalTokens) / Double(totalTokens) * 100) : 0)
            return AnyCodable([
                "model": AnyCodable(model.model),
                "totalTokens": AnyCodable(model.totalTokens),
                "inputTokens": AnyCodable(model.inputTokens),
                "outputTokens": AnyCodable(model.outputTokens),
                "cacheReadTokens": AnyCodable(model.cacheReadTokens),
                "cacheCreateTokens": AnyCodable(model.cacheCreateTokens),
                "estimatedCostUsd": AnyCodable(roundUsd(model.estimatedCostUsd)),
                "estimatedCostDisplay": AnyCodable(formatCurrency(roundUsd(model.estimatedCostUsd))),
                "percentage": AnyCodable(pct)
            ] as [String: AnyCodable])
        }
    }
}
