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
            let aggregate = bucketMetrics(snapshot.hours[hourBucketKey(date)], model: model)
            return TimelineBucket(
                bucket: hourBucketKey(date),
                label: hourBucketLabel(date),
                estimatedCostUsd: roundUsd(aggregate.estimatedCostUsd),
                totalTokens: aggregate.totalTokens
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
            let aggregate = bucketMetrics(bucketsByDay[key], model: model)
            return TimelineBucket(
                bucket: key,
                label: dayBucketLabel(day),
                estimatedCostUsd: roundUsd(aggregate.estimatedCostUsd),
                totalTokens: aggregate.totalTokens
            )
        }
    }

    func bucketMetrics(
        _ bucket: CodexAggregateBucket?,
        model: String?
    ) -> (estimatedCostUsd: Double, totalTokens: Int) {
        guard let bucket else { return (0, 0) }
        guard let model else {
            return (bucket.estimatedCostUsd, bucket.totalTokens)
        }
        let modelBucket = bucket.models[model]
        return (modelBucket?.estimatedCostUsd ?? 0, modelBucket?.totalTokens ?? 0)
    }

    func encodeTimeline(_ buckets: [TimelineBucket]) -> [AnyCodable] {
        buckets.map { bucket in
            AnyCodable([
                "bucket": AnyCodable(bucket.bucket),
                "label": AnyCodable(bucket.label),
                "usd": AnyCodable(bucket.estimatedCostUsd),
                "tokens": AnyCodable(bucket.totalTokens)
            ] as [String: AnyCodable])
        }
    }

}
