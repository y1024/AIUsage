import Foundation

struct CodexScanWindow: Sendable {
    let sinceKey: String
    let untilKey: String
    let scanSinceKey: String
    let scanUntilKey: String
    let dayCount: Int
    let rangeLabel: String

    func containsReportDay(_ dayKey: String) -> Bool {
        dayKey >= sinceKey && dayKey <= untilKey
    }

    func containsScanDay(_ dayKey: String) -> Bool {
        dayKey >= scanSinceKey && dayKey <= scanUntilKey
    }
}

struct SessionMetadata: Codable, Sendable {
    let sessionId: String?
    let forkedFromId: String?
    let forkTimestamp: String?
}

struct CodexTotals: Codable, Sendable {
    var input: Int
    var cached: Int
    var output: Int
}

struct TimestampedTotals: Codable, Sendable {
    let timestamp: String
    let date: Date?
    let totals: CodexTotals
}

struct CodexRow: Codable, Sendable {
    let dayKey: String
    let model: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUsd: Double?
}

struct CodexFileFingerprint: Codable, Equatable, Sendable {
    let path: String
    let size: UInt64
    let modifiedAt: TimeInterval
    let pricingSignature: String
}

struct CodexModelAggregate: Codable, Sendable {
    var model: String
    var totalTokens = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var estimatedCostUsd = 0.0

    mutating func record(row: CodexRow) {
        totalTokens += row.totalTokens
        inputTokens += row.inputTokens
        outputTokens += row.outputTokens
        cacheReadTokens += row.cacheReadTokens
        estimatedCostUsd += row.estimatedCostUsd ?? 0
    }

    mutating func merge(_ other: CodexModelAggregate) {
        totalTokens += other.totalTokens
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        estimatedCostUsd += other.estimatedCostUsd
    }
}

struct CodexAggregateBucket: Codable, Sendable {
    var usageRows = 0
    var totalTokens = 0
    var estimatedCostUsd = 0.0
    var models: [String: CodexModelAggregate] = [:]

    static var empty: CodexAggregateBucket { CodexAggregateBucket() }

    mutating func record(row: CodexRow) {
        usageRows += 1
        totalTokens += row.totalTokens
        estimatedCostUsd += row.estimatedCostUsd ?? 0

        var model = models[row.model] ?? CodexModelAggregate(model: row.model)
        model.record(row: row)
        models[row.model] = model
    }

    mutating func merge(_ other: CodexAggregateBucket) {
        usageRows += other.usageRows
        totalTokens += other.totalTokens
        estimatedCostUsd += other.estimatedCostUsd
        for (modelName, otherModel) in other.models {
            var model = models[modelName] ?? CodexModelAggregate(model: modelName)
            model.merge(otherModel)
            models[modelName] = model
        }
    }
}

struct CodexFileAggregate: Codable, Sendable {
    var sessionId: String?
    var unpricedModels: Set<String> = []
    var overall = CodexAggregateBucket.empty
    var days: [String: CodexAggregateBucket] = [:]
    var hours: [String: CodexAggregateBucket] = [:]

    init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }

    mutating func record(row: CodexRow, hourKey: String) {
        if row.estimatedCostUsd == nil {
            unpricedModels.insert(row.model)
        }

        overall.record(row: row)
        days[row.dayKey, default: .empty].record(row: row)
        hours[hourKey, default: .empty].record(row: row)
    }
}

struct CodexUsageSnapshot: Sendable {
    var overall = CodexAggregateBucket.empty
    var days: [String: CodexAggregateBucket] = [:]
    var hours: [String: CodexAggregateBucket] = [:]
    var sessionIds: Set<String> = []
    var unpricedModels: Set<String> = []

    mutating func merge(_ file: CodexFileAggregate) {
        guard file.overall.usageRows > 0 else { return }

        overall.merge(file.overall)
        for (day, bucket) in file.days {
            days[day, default: .empty].merge(bucket)
        }
        for (hour, bucket) in file.hours {
            hours[hour, default: .empty].merge(bucket)
        }
        if let sessionId = file.sessionId {
            sessionIds.insert(sessionId)
        }
        unpricedModels.formUnion(file.unpricedModels)
    }
}

struct CodexParsedFile: Codable, Sendable {
    let fingerprint: CodexFileFingerprint
    let metadata: SessionMetadata?
    let aggregate: CodexFileAggregate
    let snapshots: [TimestampedTotals]?
}

struct CodexCostPersistentCache: Codable, Sendable {
    let version: Int
    var files: [String: CodexParsedFile]
}

struct CodexUsageArchive: Codable, Sendable {
    let version: Int
    var updatedAt: String
    var days: [String: CodexAggregateBucket]
    var fullHistoryImportedAt: String?
}

struct CodexUsageArchiveState: Sendable {
    let days: [String: CodexAggregateBucket]
}
