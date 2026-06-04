import Foundation

// MARK: - Claude Cost Models
// 日级聚合数据模型，供 ClaudeProvider 从「代理用量永久归档」构建 costSummary 使用。
// 成本已在代理侧逐条冻结，这里只做按模型 / 按日的纯加和聚合，不做任何重新定价。

struct ClaudeModelAggregate: Codable, Sendable {
    var model: String
    var totalTokens = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreateTokens = 0
    var estimatedCostUsd = 0.0

    mutating func merge(_ other: ClaudeModelAggregate) {
        totalTokens += other.totalTokens
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreateTokens += other.cacheCreateTokens
        estimatedCostUsd += other.estimatedCostUsd
    }
}

struct ClaudeAggregateBucket: Codable, Sendable {
    var usageRows = 0
    var totalTokens = 0
    var estimatedCostUsd = 0.0
    var unpricedModels: Set<String> = []
    var models: [String: ClaudeModelAggregate] = [:]

    static var empty: ClaudeAggregateBucket { ClaudeAggregateBucket() }

    mutating func merge(_ other: ClaudeAggregateBucket) {
        usageRows += other.usageRows
        totalTokens += other.totalTokens
        estimatedCostUsd += other.estimatedCostUsd
        unpricedModels.formUnion(other.unpricedModels)
        for (modelName, otherModel) in other.models {
            var model = models[modelName] ?? ClaudeModelAggregate(model: modelName)
            model.merge(otherModel)
            models[modelName] = model
        }
    }
}
