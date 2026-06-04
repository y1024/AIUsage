import Foundation

extension CodexCostProvider {
    func aggregateDays(
        _ bucketsByDay: [String: CodexAggregateBucket],
        matching: (String) -> Bool
    ) -> CodexAggregateBucket {
        var result = CodexAggregateBucket.empty
        for (day, bucket) in bucketsByDay where matching(day) {
            result.merge(bucket)
        }
        return result
    }

    typealias BucketMetrics = (estimatedCostUsd: Double, totalTokens: Int,
                                inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreateTokens: Int)

    func todayHourlyTimeline(
        snapshot: CodexUsageSnapshot,
        now: Date,
        model: String? = nil
    ) -> [TimelineBucket] {
        let calendar = calendar()
        let startOfDay = calendar.startOfDay(for: now)
        let currentHour = calendar.component(.hour, from: now)

        return (0...currentHour).compactMap { hour -> TimelineBucket? in
            guard let date = calendar.date(byAdding: .hour, value: hour, to: startOfDay) else { return nil }
            let m = bucketMetrics(snapshot.hours[hourBucketKey(date)], model: model)
            return TimelineBucket(
                bucket: hourBucketKey(date),
                label: hourBucketLabel(date),
                estimatedCostUsd: roundUsd(m.estimatedCostUsd),
                inputTokens: m.inputTokens,
                outputTokens: m.outputTokens,
                cacheReadTokens: m.cacheReadTokens,
                cacheCreateTokens: m.cacheCreateTokens,
                totalTokens: m.totalTokens
            )
        }
    }

    func trailingDailyTimeline(
        bucketsByDay: [String: CodexAggregateBucket],
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
                inputTokens: m.inputTokens,
                outputTokens: m.outputTokens,
                cacheReadTokens: m.cacheReadTokens,
                cacheCreateTokens: m.cacheCreateTokens,
                totalTokens: m.totalTokens
            )
        }
    }

    func bucketMetrics(
        _ bucket: CodexAggregateBucket?,
        model: String?
    ) -> BucketMetrics {
        guard let bucket else { return (0, 0, 0, 0, 0, 0) }
        if let model {
            guard let m = bucket.models[model] else { return (0, 0, 0, 0, 0, 0) }
            return (m.estimatedCostUsd, m.totalTokens,
                    m.inputTokens, m.outputTokens, m.cacheReadTokens, m.cacheCreateTokens)
        }
        var inp = 0; var out = 0; var cR = 0; var cC = 0
        for m in bucket.models.values {
            inp += m.inputTokens; out += m.outputTokens; cR += m.cacheReadTokens
            cC += m.cacheCreateTokens
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

}
