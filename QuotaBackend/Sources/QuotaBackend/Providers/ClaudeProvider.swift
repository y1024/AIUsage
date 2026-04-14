import Foundation

// MARK: - Claude Provider
// 读取本地 Claude Code 项目 JSONL 日志，计算 token 用量和估算成本
// 数据来源: ~/.config/claude/projects/**/*.jsonl

public struct ClaudeProvider: ProviderFetcher {
    public let id = "claude"
    public let displayName = "Claude Code"
    public let description = "Usage-derived Claude Code spend ledger from local logs"

    let homeDirectory: String
    let timeZone: TimeZone

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeZone: TimeZone = .current) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let roots = resolveProjectRoots()
        let existingRoots = roots.filter { FileManager.default.fileExists(atPath: $0) }

        if existingRoots.isEmpty {
            throw ProviderError("logs_not_found", "No Claude project logs found under \(roots.joined(separator: ", "))")
        }

        let files = collectJSONLFiles(roots: existingRoots)
        if files.isEmpty {
            throw ProviderError("logs_not_found", "No Claude JSONL logs found")
        }

        let rows = try await scanFiles(files)
        if rows.isEmpty {
            throw ProviderError("no_usage_data", "Claude logs found but no usage data present")
        }

        let now = Date()
        let todayKey = dayKey(now)
        let weekRange = currentWeekRange(now)
        let monthKey = monthKeyStr(now)

        let today        = aggregate(rows: rows) { $0.dayKey == todayKey }
        let currentWeek  = aggregate(rows: rows) { weekRange.dayKeys.contains($0.dayKey) }
        let currentMonth = aggregate(rows: rows) { $0.monthKey == monthKey }
        let overall      = aggregate(rows: rows) { _ in true }

        var extra: [String: AnyCodable] = [:]

        extra["today.estimatedCostUsd"]  = AnyCodable(today.estimatedCostUsd)
        extra["today.totalTokens"]       = AnyCodable(today.totalTokens)
        extra["today.key"]               = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(currentWeek.estimatedCostUsd)
        extra["currentWeek.totalTokens"]      = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"]              = AnyCodable("\(weekRange.start)..\(weekRange.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(currentMonth.estimatedCostUsd)
        extra["currentMonth.totalTokens"]      = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"]              = AnyCodable(monthKey)
        extra["timeline.hourly"]              = AnyCodable(encodeTimeline(todayHourlyTimeline(rows: rows, now: now)))
        extra["timeline.daily"]               = AnyCodable(encodeTimeline(trailingDailyTimeline(rows: rows, now: now, days: 7)))

        extra["overall.estimatedCostUsd"]     = AnyCodable(overall.estimatedCostUsd)
        extra["overall.totalTokens"]          = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"]            = AnyCodable(overall.usageRows)
        extra["overall.duplicateRowsRemoved"] = AnyCodable(overall.duplicatesRemoved)
        extra["overall.unpricedModels"]       = AnyCodable(overall.unpricedModels.map { AnyCodable($0) })

        // All models with full stats (sorted by cost desc)
        func encodeModelBreakdown(_ agg: AggResult) -> [AnyCodable] {
            let sorted = agg.models.sorted { $0.estimatedCostUsd > $1.estimatedCostUsd }
            let totalCost = agg.estimatedCostUsd
            return sorted.map { m -> AnyCodable in
                let pct = totalCost > 0 ? roundUsd(m.estimatedCostUsd / totalCost * 100) : 0.0
                return AnyCodable([
                    "model": AnyCodable(m.model),
                    "totalTokens": AnyCodable(m.totalTokens),
                    "inputTokens": AnyCodable(m.inputTokens),
                    "outputTokens": AnyCodable(m.outputTokens),
                    "cacheReadTokens": AnyCodable(m.cacheReadTokens),
                    "cacheCreateTokens": AnyCodable(m.cacheCreateTokens),
                    "estimatedCostUsd": AnyCodable(m.estimatedCostUsd),
                    "estimatedCostDisplay": AnyCodable(formatCurrency(m.estimatedCostUsd)),
                    "percentage": AnyCodable(pct)
                ] as [String: AnyCodable])
            }
        }
        extra["currentMonth.models"] = AnyCodable(encodeModelBreakdown(currentMonth))
        extra["today.models"] = AnyCodable(encodeModelBreakdown(today))
        extra["currentWeek.models"] = AnyCodable(encodeModelBreakdown(currentWeek))
        extra["overall.models"] = AnyCodable(encodeModelBreakdown(overall))

        // Per-model timelines (hourly + daily)
        let modelNames = Set(rows.map(\.model))
        var modelTimelinesArr: [AnyCodable] = []
        for modelName in modelNames.sorted() {
            let modelRows = rows.filter { $0.model == modelName }
            let hourly = todayHourlyTimeline(rows: modelRows, now: now)
            let daily = trailingDailyTimeline(rows: modelRows, now: now, days: 7)
            guard !hourly.isEmpty || !daily.isEmpty else { continue }
            modelTimelinesArr.append(AnyCodable([
                "model": AnyCodable(modelName),
                "hourly": AnyCodable(encodeTimeline(hourly)),
                "daily": AnyCodable(encodeTimeline(daily))
            ] as [String: AnyCodable]))
        }
        extra["timeline.byModel"] = AnyCodable(modelTimelinesArr)

        var usage = ProviderUsage(provider: "claude", label: "Claude Code", extra: extra)
        var source = SourceInfo(mode: "auto", type: "claude-project-logs")
        source.roots = existingRoots
        usage.source = source
        return usage
    }

    // MARK: - File Discovery

    private func resolveProjectRoots() -> [String] {
        let envRoots = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        if let env = envRoots, !env.isEmpty {
            return env.split(separator: ",").map { p in
                let trimmed = p.trimmingCharacters(in: .whitespaces)
                return (trimmed as NSString).lastPathComponent == "projects" ? trimmed : "\(trimmed)/projects"
            }
        }
        return [
            "\(homeDirectory)/.config/claude/projects",
            "\(homeDirectory)/.claude/projects"
        ]
    }

    private func collectJSONLFiles(roots: [String]) -> [String] {
        var files: [String] = []
        for root in roots {
            walkJSONL(dir: root, into: &files)
        }
        return files.sorted()
    }

    private func walkJSONL(dir: String, into files: inout [String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries {
            let full = "\(dir)/\(entry)"
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                walkJSONL(dir: full, into: &files)
            } else if entry.hasSuffix(".jsonl") {
                files.append(full)
            }
        }
    }

    // MARK: - Scanning

    private func scanFiles(_ files: [String]) async throws -> [ClaudeRow] {
        var winners: [String: ClaudeRow] = [:]
        var unkeyed: [ClaudeRow] = []

        for file in files {
            let parsed = parseFile(file)
            for row in parsed {
                if let key = canonicalKey(row) {
                    if let existing = winners[key] {
                        if shouldReplace(existing, with: row) { winners[key] = row }
                    } else {
                        winners[key] = row
                    }
                } else {
                    unkeyed.append(row)
                }
            }
        }

        return (Array(winners.values) + unkeyed).sorted { $0.timestamp < $1.timestamp }
    }

    private func parseFile(_ path: String) -> [ClaudeRow] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var rows: [ClaudeRow] = []
        for line in content.components(separatedBy: "\n") {
            if let row = parseLine(line, filePath: path) {
                rows.append(row)
            }
        }
        return rows
    }

    private func parseLine(_ line: String, filePath: String) -> ClaudeRow? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.contains("\"type\":\"assistant\""),
              trimmed.contains("\"usage\""),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "assistant" else { return nil }

        let message = json["message"] as? [String: Any]
        let usage = message?["usage"] as? [String: Any]
        guard let usage else { return nil }

        guard let tsRaw = json["timestamp"] as? String,
              let ts = parseISO8601(tsRaw) else { return nil }

        let input     = usageInt(usage["input_tokens"])
        let cacheRead = usageInt(usage["cache_read_input_tokens"])
        let cacheCreate: Int
        if let direct = usage["cache_creation_input_tokens"] {
            cacheCreate = usageInt(direct)
        } else if let nested = usage["cache_creation"] as? [String: Any] {
            cacheCreate = nested.values.reduce(0) { $0 + usageInt($1) }
        } else {
            cacheCreate = 0
        }
        let output = usageInt(usage["output_tokens"])
        let total = input + cacheRead + cacheCreate + output
        guard total > 0 else { return nil }

        let rawModel = (message?["model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard rawModel.isEmpty || rawModel.lowercased().contains("claude") else { return nil }
        let displayModel = cleanModelName(rawModel.isEmpty ? "unknown" : rawModel)
        let pricingKey = normalizeToPricingKey(rawModel.isEmpty ? "unknown" : rawModel)

        let cost = estimateCost(model: pricingKey, input: input, cacheRead: cacheRead, cacheCreate: cacheCreate, output: output)
        let isSubagent = filePath.components(separatedBy: "/").contains("subagents")

        return ClaudeRow(
            filePath: filePath,
            pathRole: isSubagent ? "subagent" : "parent",
            dayKey: dayKey(ts),
            monthKey: monthKeyStr(ts),
            timestamp: ts,
            sessionId: firstNonEmpty(json["sessionId"] as? String, json["session_id"] as? String, (json["metadata"] as? [String: Any])?["sessionId"] as? String),
            messageId: firstNonEmpty(message?["id"] as? String),
            requestId: firstNonEmpty(json["requestId"] as? String),
            isSidechain: json["isSidechain"] as? Bool ?? false,
            model: displayModel,
            rawModel: rawModel.isEmpty ? displayModel : rawModel,
            inputTokens: input,
            cacheCreateTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            totalTokens: total,
            estimatedCostUsd: cost,
            priced: cost != nil
        )
    }

    // MARK: - Aggregation

    private struct AggResult {
        var usageRows = 0
        var totalTokens = 0
        var estimatedCostUsd = 0.0
        var models: [ModelAgg] = []
        var unpricedModels: Set<String> = []
        var duplicatesRemoved = 0
    }

    private struct ModelAgg {
        var model: String
        var totalTokens: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreateTokens: Int
        var estimatedCostUsd: Double
    }

    private func aggregate(rows: [ClaudeRow], matcher: (ClaudeRow) -> Bool) -> AggResult {
        var result = AggResult()
        var modelMap: [String: ModelAgg] = [:]

        for row in rows where matcher(row) {
            result.usageRows += 1
            result.totalTokens += row.totalTokens
            if let cost = row.estimatedCostUsd {
                result.estimatedCostUsd += cost
            } else {
                result.unpricedModels.insert(row.model)
            }
            var m = modelMap[row.model] ?? ModelAgg(model: row.model, totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreateTokens: 0, estimatedCostUsd: 0)
            m.totalTokens += row.totalTokens
            m.inputTokens += row.inputTokens
            m.outputTokens += row.outputTokens
            m.cacheReadTokens += row.cacheReadTokens
            m.cacheCreateTokens += row.cacheCreateTokens
            m.estimatedCostUsd += row.estimatedCostUsd ?? 0
            modelMap[row.model] = m
        }
        result.models = Array(modelMap.values)
        result.estimatedCostUsd = roundUsd(result.estimatedCostUsd)
        return result
    }

    private struct TimelineBucket {
        let bucket: String
        let label: String
        let estimatedCostUsd: Double
        let totalTokens: Int
    }

    private func todayHourlyTimeline(rows: [ClaudeRow], now: Date) -> [TimelineBucket] {
        let calendar = calendar()
        let startOfDay = calendar.startOfDay(for: now)
        let dayKey = dayKey(now)
        let currentHour = calendar.component(.hour, from: now)

        var totalsByHour: [Int: (usd: Double, tokens: Int)] = [:]
        for row in rows where row.dayKey == dayKey {
            let hour = calendar.component(.hour, from: row.timestamp)
            var aggregate = totalsByHour[hour] ?? (0, 0)
            aggregate.usd += row.estimatedCostUsd ?? 0
            aggregate.tokens += row.totalTokens
            totalsByHour[hour] = aggregate
        }

        return (0...currentHour).compactMap { hour -> TimelineBucket? in
            guard let date = calendar.date(byAdding: .hour, value: hour, to: startOfDay) else { return nil }
            let aggregate = totalsByHour[hour] ?? (0, 0)
            return TimelineBucket(
                bucket: hourBucketKey(date),
                label: hourBucketLabel(date),
                estimatedCostUsd: roundUsd(aggregate.usd),
                totalTokens: aggregate.tokens
            )
        }
    }

    private func trailingDailyTimeline(rows: [ClaudeRow], now: Date, days: Int) -> [TimelineBucket] {
        let calendar = calendar()
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today

        var totalsByDay: [String: (usd: Double, tokens: Int)] = [:]
        let validDayKeys = Set((0..<max(days, 1)).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return dayKey(day)
        })

        for row in rows where validDayKeys.contains(row.dayKey) {
            var aggregate = totalsByDay[row.dayKey] ?? (0, 0)
            aggregate.usd += row.estimatedCostUsd ?? 0
            aggregate.tokens += row.totalTokens
            totalsByDay[row.dayKey] = aggregate
        }

        return (0..<max(days, 1)).compactMap { offset -> TimelineBucket? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayKey(day)
            let aggregate = totalsByDay[key] ?? (0, 0)
            return TimelineBucket(
                bucket: key,
                label: dayBucketLabel(day),
                estimatedCostUsd: roundUsd(aggregate.usd),
                totalTokens: aggregate.tokens
            )
        }
    }

    private func encodeTimeline(_ buckets: [TimelineBucket]) -> [AnyCodable] {
        buckets.map { bucket in
            AnyCodable([
                "bucket": AnyCodable(bucket.bucket),
                "label": AnyCodable(bucket.label),
                "usd": AnyCodable(bucket.estimatedCostUsd),
                "tokens": AnyCodable(bucket.totalTokens)
            ])
        }
    }

    // MARK: - Claude Pricing Table (mirrors JS CLAUDE_PRICING)

    struct Pricing {
        let inputPerToken: Double
        let outputPerToken: Double
        let cacheCreatePerToken: Double
        let cacheReadPerToken: Double
        let threshold: Int?
        let inputAbove: Double?
        let outputAbove: Double?
        let cacheCreateAbove: Double?
        let cacheReadAbove: Double?

        init(_ i: Double, _ o: Double, _ cc: Double, _ cr: Double,
             threshold: Int? = nil, iA: Double? = nil, oA: Double? = nil, ccA: Double? = nil, crA: Double? = nil) {
            inputPerToken = i; outputPerToken = o; cacheCreatePerToken = cc; cacheReadPerToken = cr
            self.threshold = threshold; inputAbove = iA; outputAbove = oA; cacheCreateAbove = ccA; cacheReadAbove = crA
        }
    }

    // swiftlint:disable line_length
    static let pricing: [String: Pricing] = [
        "claude-haiku-4-5":          Pricing(1e-6, 5e-6, 1.25e-6, 1e-7),
        "claude-opus-4-5":           Pricing(5e-6, 2.5e-5, 6.25e-6, 5e-7),
        "claude-opus-4-6":           Pricing(5e-6, 2.5e-5, 6.25e-6, 5e-7),
        "claude-sonnet-4-5":         Pricing(3e-6, 1.5e-5, 3.75e-6, 3e-7, threshold: 200_000, iA: 6e-6, oA: 2.25e-5, ccA: 7.5e-6, crA: 6e-7),
        "claude-sonnet-4-6":         Pricing(3e-6, 1.5e-5, 3.75e-6, 3e-7, threshold: 200_000, iA: 6e-6, oA: 2.25e-5, ccA: 7.5e-6, crA: 6e-7),
        "claude-opus-4-20250514":    Pricing(1.5e-5, 7.5e-5, 1.875e-5, 1.5e-6),
        "claude-sonnet-4-20250514":  Pricing(3e-6, 1.5e-5, 3.75e-6, 3e-7, threshold: 200_000, iA: 6e-6, oA: 2.25e-5, ccA: 7.5e-6, crA: 6e-7),
        "claude-opus-4-1":           Pricing(1.5e-5, 7.5e-5, 1.875e-5, 1.5e-6)
    ]

    static func loadPricingOverrides() -> [String: Pricing] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (home as NSString).appendingPathComponent(".config/aiusage/proxy-pricing.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pricingDict = root["pricing"] as? [String: [String: Double]] else {
            return [:]
        }

        var overrides: [String: Pricing] = [:]
        for (model, prices) in pricingDict {
            let input = (prices["input_per_million"] ?? 0) / 1_000_000
            let output = (prices["output_per_million"] ?? 0) / 1_000_000
            let cache = (prices["cache_per_million"] ?? 0) / 1_000_000
            overrides[model] = Pricing(input, output, cache * 1.25, cache)
        }
        return overrides
    }

    private var effectivePricing: [String: Pricing] {
        var combined = Self.pricing
        for (key, value) in Self.loadPricingOverrides() {
            combined[key] = value
        }
        return combined
    }

    private func estimateCost(model: String, input: Int, cacheRead: Int, cacheCreate: Int, output: Int) -> Double? {
        guard let p = effectivePricing[model] else { return nil }

        func tiered(_ tokens: Int, base: Double, above: Double?, threshold: Int?) -> Double {
            guard let t = threshold, let a = above else { return Double(tokens) * base }
            let below = min(tokens, t)
            let over  = max(tokens - t, 0)
            return Double(below) * base + Double(over) * a
        }

        let cost = tiered(input,       base: p.inputPerToken,       above: p.inputAbove,       threshold: p.threshold)
                 + tiered(cacheRead,   base: p.cacheReadPerToken,   above: p.cacheReadAbove,   threshold: p.threshold)
                 + tiered(cacheCreate, base: p.cacheCreatePerToken, above: p.cacheCreateAbove, threshold: p.threshold)
                 + tiered(output,      base: p.outputPerToken,       above: p.outputAbove,      threshold: p.threshold)
        return roundUsd(cost)
    }

    // MARK: - Model normalization

    private func cleanModelName(_ raw: String) -> String {
        var model = raw.lowercased()
        if model.hasPrefix("anthropic/") { model = String(model.dropFirst("anthropic/".count)) }
        if model.hasPrefix("anthropic.") { model = String(model.dropFirst("anthropic.".count)) }
        model = model.replacingOccurrences(of: #"-v\d+:\d+$"#, with: "", options: .regularExpression)
        model = model.replacingOccurrences(of: ".", with: "-")
        return model
    }

    /// Full normalization to find a matching pricing key
    private func normalizeToPricingKey(_ raw: String) -> String {
        var model = raw.lowercased()
        if model.hasPrefix("anthropic/") { model = String(model.dropFirst("anthropic/".count)) }
        if model.hasPrefix("anthropic.") { model = String(model.dropFirst("anthropic.".count)) }
        model = model.replacingOccurrences(of: #"-v\d+:\d+$"#, with: "", options: .regularExpression)

        let aliases: [String: String] = [
            "claude-opus-4.6": "claude-opus-4-6",
            "claude-sonnet-4.6": "claude-sonnet-4-6",
            "claude-opus-4.5": "claude-opus-4-5",
            "claude-sonnet-4.5": "claude-sonnet-4-5",
            "claude-haiku-4.5": "claude-haiku-4-5",
            "claude-opus-4.1": "claude-opus-4-1",
            "claude-opus-4-5-thinking": "claude-opus-4-5",
            "claude-sonnet-4-5-thinking": "claude-sonnet-4-5",
            "claude-sonnet-4-6-thinking": "claude-sonnet-4-6",
            "claude-haiku-4-5-thinking": "claude-haiku-4-5",
            "claude-3-5-haiku": "claude-haiku-4-5",
            "claude-3.5-haiku": "claude-haiku-4-5",
            "claude-3-5-haiku-latest": "claude-haiku-4-5",
            "claude-3-5-sonnet": "claude-sonnet-4-5",
            "claude-3.5-sonnet": "claude-sonnet-4-5",
            "claude-3-5-sonnet-latest": "claude-sonnet-4-5"
        ]
        if let mapped = aliases[model] { model = mapped }

        if Self.pricing[model] != nil { return model }

        // Strip date suffix (e.g. -20250514)
        if let range = model.range(of: #"^(.*)-(\d{8})$"#, options: .regularExpression) {
            let stripped = String(model[range].dropLast(9))
            if Self.pricing[stripped] != nil { return stripped }
            if let mapped = aliases[stripped] { return mapped }
        }

        // Fuzzy family match: handle both "opus-4-6" and "4-6-opus" formats
        let families: [(keyword: String, key: String)] = [
            ("haiku-4-5", "claude-haiku-4-5"),
            ("4-5-haiku", "claude-haiku-4-5"),
            ("haiku-4.5", "claude-haiku-4-5"),
            ("4.5-haiku", "claude-haiku-4-5"),
            ("opus-4-6", "claude-opus-4-6"),
            ("4-6-opus", "claude-opus-4-6"),
            ("opus-4.6", "claude-opus-4-6"),
            ("4.6-opus", "claude-opus-4-6"),
            ("opus-4-5", "claude-opus-4-5"),
            ("4-5-opus", "claude-opus-4-5"),
            ("opus-4.5", "claude-opus-4-5"),
            ("4.5-opus", "claude-opus-4-5"),
            ("sonnet-4-6", "claude-sonnet-4-6"),
            ("4-6-sonnet", "claude-sonnet-4-6"),
            ("sonnet-4.6", "claude-sonnet-4-6"),
            ("4.6-sonnet", "claude-sonnet-4-6"),
            ("sonnet-4-5", "claude-sonnet-4-5"),
            ("4-5-sonnet", "claude-sonnet-4-5"),
            ("sonnet-4.5", "claude-sonnet-4-5"),
            ("4.5-sonnet", "claude-sonnet-4-5"),
            ("opus-4-1", "claude-opus-4-1"),
            ("4-1-opus", "claude-opus-4-1"),
            ("opus-4.1", "claude-opus-4-1"),
            ("4.1-opus", "claude-opus-4-1")
        ]
        for (keyword, key) in families {
            if model.contains(keyword) { return key }
        }

        return model
    }

    // MARK: - Dedup helpers

    private func canonicalKey(_ row: ClaudeRow) -> String? {
        if let s = row.sessionId, let m = row.messageId, let r = row.requestId { return "\(s):\(m):\(r)" }
        if let s = row.sessionId, let m = row.messageId { return "\(s):\(m)" }
        return nil
    }

    private func shouldReplace(_ existing: ClaudeRow, with candidate: ClaudeRow) -> Bool {
        if candidate.isSidechain != existing.isSidechain { return existing.isSidechain }
        if candidate.pathRole != existing.pathRole { return existing.pathRole == "subagent" }
        if candidate.totalTokens != existing.totalTokens { return candidate.totalTokens > existing.totalTokens }
        return candidate.timestamp > existing.timestamp
    }

    // MARK: - Date helpers

    private func parseISO8601(_ s: String) -> Date? {
        SharedFormatters.parseISO8601(s)
    }

    private func dayKey(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM-dd", timeZone: timeZone)
    }

    private func monthKeyStr(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM", timeZone: timeZone)
    }

    private func currentWeekRange(_ date: Date) -> (start: String, end: String, dayKeys: Set<String>) {
        let cal = calendar()
        let comps = cal.dateComponents(in: timeZone, from: date)
        let weekday = comps.weekday ?? 1 // 1=Sun in Gregorian
        // Convert to Mon=0 offset
        let offset = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -offset, to: date) else {
            let key = dayKey(date)
            return (start: key, end: key, dayKeys: [key])
        }
        var keys = Set<String>()
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: i, to: monday) {
                keys.insert(dayKey(d))
            }
        }
        let endKey = cal.date(byAdding: .day, value: 6, to: monday).map(dayKey) ?? dayKey(monday)
        return (start: dayKey(monday), end: endKey, dayKeys: keys)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func hourBucketKey(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM-dd-HH", timeZone: timeZone)
    }

    private func hourBucketLabel(_ date: Date) -> String {
        DateFormat.string(from: date, format: "HH:00", timeZone: timeZone)
    }

    private func dayBucketLabel(_ date: Date) -> String {
        DateFormat.string(from: date, format: "MM/dd", timeZone: timeZone)
    }

    // MARK: - Misc helpers

    private func usageInt(_ v: Any?) -> Int {
        switch v {
        case let n as Int: return max(0, n)
        case let d as Double: return max(0, Int(d))
        case let s as String: return max(0, Int(s) ?? 0)
        default: return 0
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.first { v in v.map { !$0.isEmpty } ?? false } ?? nil
    }

    private func roundUsd(_ v: Double) -> Double {
        (v * 1_000_000).rounded() / 1_000_000
    }

    private func formatCurrency(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.minimumFractionDigits = value >= 1 ? 2 : 4
        fmt.maximumFractionDigits = value >= 1 ? 2 : 4
        return fmt.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}

// MARK: - Internal Row Type

private struct ClaudeRow {
    let filePath: String
    let pathRole: String
    let dayKey: String
    let monthKey: String
    let timestamp: Date
    let sessionId: String?
    let messageId: String?
    let requestId: String?
    let isSidechain: Bool
    let model: String
    let rawModel: String
    let inputTokens: Int
    let cacheCreateTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUsd: Double?
    let priced: Bool
}
