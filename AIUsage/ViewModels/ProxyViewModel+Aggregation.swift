import Foundation
import QuotaBackend

extension ProxyViewModel {

    // MARK: - Family Scoping
    // 代理实测统计支持按家族（Claude 代理 / Codex 代理）聚合；nil 表示全部家族。

    /// 属于 Codex 家族的节点 id 集合，用于按家族过滤日志。configurations 数量很小，
    /// 每次聚合调用现算一次即可，避免维护额外的可变缓存。
    private var codexConfigIdSet: Set<String> {
        Set(configurations.filter { $0.nodeType.isCodex }.map(\.id))
    }

    private func configIdMatchesFamily(_ configId: String, family: ProxyNodeFamily?, codexIds: Set<String>) -> Bool {
        guard let family else { return true }
        let isCodex = codexIds.contains(configId)
        return family.isCodex == isCodex
    }

    // MARK: - Aggregation for ProxyStatsView

    func allLogs(nodeFilter: String?, modelFilter: String?, family: ProxyNodeFamily? = nil) -> [ProxyRequestLog] {
        let key = LogCacheKey(nodeFilter: nodeFilter, modelFilter: modelFilter, family: family)
        if let cached = _logCache[key] { return cached }

        let codexIds = codexConfigIdSet
        var result: [ProxyRequestLog] = []
        for (configId, logs) in recentLogs {
            if let node = nodeFilter, node != configId { continue }
            if !configIdMatchesFamily(configId, family: family, codexIds: codexIds) { continue }
            for log in logs {
                if let model = modelFilter, log.upstreamModel != model { continue }
                result.append(log)
            }
        }
        let sorted = result.sorted { $0.timestamp < $1.timestamp }
        _logCache[key] = sorted
        return sorted
    }

    struct ModelTimePoint: Identifiable {
        let id: String
        let date: Date
        let model: String
        var cost: Double
        var tokens: Int
    }

    func modelTimeSeries(nodeFilter: String?, granularity: String, family: ProxyNodeFamily? = nil) -> [ModelTimePoint] {
        let cacheKey = TimeSeriesKey(nodeFilter: nodeFilter, granularity: granularity, family: family)
        if let cached = _timeSeriesCache[cacheKey] as? [ModelTimePoint] {
            return cached
        }

        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: nil, family: family)
        guard !logs.isEmpty else {
            _timeSeriesCache[cacheKey] = [ModelTimePoint]()
            return []
        }

        let cal = Calendar.current
        let format = granularity == "hourly" ? "yyyy-MM-dd HH" : "yyyy-MM-dd"

        var map: [String: ModelTimePoint] = [:]
        var allModels = Set<String>()
        var minDate = logs[0].timestamp
        var maxDate = logs[0].timestamp

        for log in logs {
            let timeKey = DateFormat.string(from: log.timestamp, format: format)
            let key = "\(timeKey)|\(log.upstreamModel)"
            let dateStart: Date
            if granularity == "hourly" {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: log.timestamp)
                dateStart = cal.date(from: comps) ?? log.timestamp
            } else {
                dateStart = cal.startOfDay(for: log.timestamp)
            }
            allModels.insert(log.upstreamModel)
            if log.timestamp < minDate { minDate = log.timestamp }
            if log.timestamp > maxDate { maxDate = log.timestamp }

            var pt = map[key] ?? ModelTimePoint(id: key, date: dateStart, model: log.upstreamModel, cost: 0, tokens: 0)
            pt.cost += log.estimatedCostUSD
            pt.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            map[key] = pt
        }

        let step: Calendar.Component = granularity == "hourly" ? .hour : .day
        var cursor: Date
        let end: Date
        if granularity == "hourly" {
            cursor = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: minDate)) ?? minDate
            end = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: maxDate)) ?? maxDate
        } else {
            cursor = cal.startOfDay(for: minDate)
            end = cal.startOfDay(for: maxDate)
        }

        while cursor <= end {
            let timeKey = DateFormat.string(from: cursor, format: format)
            for model in allModels {
                let key = "\(timeKey)|\(model)"
                if map[key] == nil {
                    map[key] = ModelTimePoint(id: key, date: cursor, model: model, cost: 0, tokens: 0)
                }
            }
            guard let next = cal.date(byAdding: step, value: 1, to: cursor) else { break }
            cursor = next
        }

        let result = map.values.sorted { ($0.date, $0.model) < ($1.date, $1.model) }
        _timeSeriesCache[cacheKey] = result
        return result
    }

    struct ModelAggregate: Identifiable {
        let id: String
        let model: String
        var cost: Double
        var tokens: Int
        var requests: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        // 可用性 / 延迟信号（issue #27）：直接从请求日志逐条聚合，无需额外埋点。
        var successfulRequests: Int = 0
        /// 成功请求的总响应耗时（ms），用于算平均；失败请求不计入（错误耗时会污染延迟信号）。
        var responseTimeMsTotalSuccess: Double = 0
        /// 首字时间 TTFT 的总和（ms）与样本数，仅流式成功请求提供。
        var firstTokenMsTotal: Double = 0
        var firstTokenSamples: Int = 0

        var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

        /// cache_read / (input + cache_read + cache_creation) — percentage of billable input surface served from cache.
        var cacheHitRate: Double {
            let denom = inputTokens + cacheReadTokens + cacheCreationTokens
            guard denom > 0 else { return 0 }
            return Double(cacheReadTokens) / Double(denom) * 100
        }

        /// 可用率（成功 / 总请求，百分比）。无请求为 0。
        var availability: Double {
            guard requests > 0 else { return 0 }
            return Double(successfulRequests) / Double(requests) * 100
        }

        /// 成功请求的平均总响应耗时（ms）。受输出长度影响，作为兜底延迟信号。
        var avgResponseMs: Double {
            guard successfulRequests > 0 else { return 0 }
            return responseTimeMsTotalSuccess / Double(successfulRequests)
        }

        /// 平均首字时间 TTFT（ms）。仅流式样本，更能反映「响应快不快」；无样本为 nil。
        var avgFirstTokenMs: Double? {
            guard firstTokenSamples > 0 else { return nil }
            return firstTokenMsTotal / Double(firstTokenSamples)
        }
    }

    func modelAggregates(nodeFilter: String?, modelFilter: String?, since: Date? = nil, family: ProxyNodeFamily? = nil) -> [ModelAggregate] {
        let cacheKey = AggregateKey(nodeFilter: nodeFilter, modelFilter: modelFilter, since: since, family: family)
        if let cached = _modelAggCache[cacheKey] as? [ModelAggregate] {
            return cached
        }

        var logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter, family: family)
        if let since { logs = logs.filter { $0.timestamp >= since } }
        var map: [String: ModelAggregate] = [:]

        for log in logs {
            let key = log.upstreamModel
            var agg = map[key] ?? ModelAggregate(
                id: key, model: key, cost: 0, tokens: 0, requests: 0,
                inputTokens: 0, outputTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0
            )
            agg.cost += log.estimatedCostUSD
            agg.tokens += log.tokensInput + log.tokensOutput + log.tokensCache
            agg.requests += 1
            agg.inputTokens += log.tokensInput
            agg.outputTokens += log.tokensOutput
            agg.cacheReadTokens += log.tokensCacheRead
            agg.cacheCreationTokens += log.tokensCacheCreation
            if log.success {
                agg.successfulRequests += 1
                agg.responseTimeMsTotalSuccess += log.responseTimeMs
            }
            if let ttft = log.firstTokenMs {
                agg.firstTokenMsTotal += ttft
                agg.firstTokenSamples += 1
            }
            map[key] = agg
        }

        let result = map.values.sorted { $0.cost > $1.cost }
        _modelAggCache[cacheKey] = result
        return result
    }

    func allUpstreamModels(nodeFilter: String?, family: ProxyNodeFamily? = nil) -> [String] {
        let cacheKey = UpstreamModelsKey(nodeFilter: nodeFilter, family: family)
        if let cached = _upstreamModelsCache[cacheKey] {
            return cached
        }
        let codexIds = codexConfigIdSet
        var models = Set<String>()
        for (configId, logs) in recentLogs {
            if let node = nodeFilter, node != configId { continue }
            if !configIdMatchesFamily(configId, family: family, codexIds: codexIds) { continue }
            for log in logs { models.insert(log.upstreamModel) }
        }
        let result = models.sorted()
        _upstreamModelsCache[cacheKey] = result
        return result
    }

    struct OverallStats {
        var cost: Double
        var tokens: Int
        var requests: Int
        var successRate: Double
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int

        var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

        /// cache_read / (input + cache_read + cache_creation). 0 when no cache-eligible traffic yet.
        var cacheHitRate: Double {
            let denom = inputTokens + cacheReadTokens + cacheCreationTokens
            guard denom > 0 else { return 0 }
            return Double(cacheReadTokens) / Double(denom) * 100
        }
    }

    func overallStats(nodeFilter: String?, modelFilter: String?, family: ProxyNodeFamily? = nil) -> OverallStats {
        overallStats(nodeFilter: nodeFilter, modelFilter: modelFilter, since: nil, family: family)
    }

    func overallStats(nodeFilter: String?, modelFilter: String?, since: Date?, family: ProxyNodeFamily? = nil) -> OverallStats {
        let cacheKey = AggregateKey(nodeFilter: nodeFilter, modelFilter: modelFilter, since: since, family: family)
        if let cached = _overallStatsCache[cacheKey] as? OverallStats {
            return cached
        }

        var logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter, family: family)
        if let since { logs = logs.filter { $0.timestamp >= since } }

        var cost = 0.0, tokens = 0, input = 0, output = 0
        var cacheRead = 0, cacheCreate = 0, successCount = 0
        for log in logs {
            cost += log.estimatedCostUSD
            let logTokens = log.tokensInput + log.tokensOutput + log.tokensCache
            tokens += logTokens
            input += log.tokensInput
            output += log.tokensOutput
            cacheRead += log.tokensCacheRead
            cacheCreate += log.tokensCacheCreation
            if log.success { successCount += 1 }
        }
        let rate = logs.isEmpty ? 0.0 : Double(successCount) / Double(logs.count) * 100
        let result = OverallStats(
            cost: cost,
            tokens: tokens,
            requests: logs.count,
            successRate: rate,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate
        )
        _overallStatsCache[cacheKey] = result
        return result
    }

    func dataDateRange(nodeFilter: String?, modelFilter: String?, family: ProxyNodeFamily? = nil) -> (earliest: Date?, latest: Date?, days: Int) {
        let cacheKey = LogCacheKey(nodeFilter: nodeFilter, modelFilter: modelFilter, family: family)
        if let cached = _dateRangeCache[cacheKey] {
            return cached
        }
        let logs = allLogs(nodeFilter: nodeFilter, modelFilter: modelFilter, family: family)
        guard let earliest = logs.first?.timestamp, let latest = logs.last?.timestamp else {
            let empty: (earliest: Date?, latest: Date?, days: Int) = (nil, nil, 0)
            _dateRangeCache[cacheKey] = empty
            return empty
        }
        let calendar = Calendar.current
        let earliestDay = calendar.startOfDay(for: earliest)
        let latestDay = calendar.startOfDay(for: latest)
        let days = max(1, (calendar.dateComponents([.day], from: earliestDay, to: latestDay).day ?? 0) + 1)
        let result: (earliest: Date?, latest: Date?, days: Int) = (earliest, latest, days)
        _dateRangeCache[cacheKey] = result
        return result
    }
}
