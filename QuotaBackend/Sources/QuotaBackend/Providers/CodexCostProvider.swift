import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Codex Cost Provider
// Reads local Codex session JSONL logs and derives token/cost totals.
// Data sources: ~/.codex/sessions, ~/.codex/archived_sessions, or $CODEX_HOME.

public struct CodexCostProvider: ProviderFetcher {
    public let id = "codex-cost"
    public let displayName = "Codex Logs"
    public let description = "Local token ledger from Codex session logs"

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    static let sessionMetaNeedle = Data("\"session_meta\"".utf8)
    static let tokenCountNeedle = Data("\"token_count\"".utf8)
    static let turnContextNeedle = Data("\"turn_context\"".utf8)
    static let compactTurnContextTypeNeedle = Data("\"type\":\"turn_context\"".utf8)
    static let compactEventMsgTypeNeedle = Data("\"type\":\"event_msg\"".utf8)
    static let fileScanCache = CodexCostFileScanCache()
    static let usageArchive = CodexUsageArchiveStore()
    static let cacheSchemaVersion = 3
    static let defaultScanDays = 30
    static let defaultArchiveScopeID = "default"
    static let filenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    public func requestFullHistoryImport() async {
        await Self.usageArchive.requestFullHistoryImport(scope: archiveScopeID())
    }

    public func needsFullHistoryImport() async -> Bool {
        await Self.usageArchive.needsFullHistoryImport(scope: archiveScopeID())
    }

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeZone: TimeZone = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()
        let archiveScope = archiveScopeID()
        let shouldImportFullHistory = await Self.usageArchive.consumeFullHistoryImportRequest(scope: archiveScope)
        let scanWindow = shouldImportFullHistory ? nil : currentScanWindow(now: now)
        let roots = resolveSessionRoots()
        let existingRoots = roots.filter { FileManager.default.fileExists(atPath: $0) }

        if existingRoots.isEmpty {
            let redactedRoots = SensitiveDataRedactor.redactPaths(in: roots.joined(separator: ", "))
            throw ProviderError("logs_not_found", "No Codex session logs found under \(redactedRoots)")
        }

        let files = collectJSONLFiles(roots: existingRoots, scanWindow: scanWindow)
        if files.isEmpty {
            throw ProviderError("logs_not_found", "No Codex JSONL logs found in \(scanWindow?.rangeLabel ?? "local history")")
        }

        let snapshot = await scanFiles(files)
        relieveMallocPressure()
        if snapshot.overall.usageRows == 0 {
            throw ProviderError("no_usage_data", "Codex logs found but no token usage data present")
        }
        let archivedDays = await Self.usageArchive.merge(
            scope: archiveScope,
            days: scanWindow.map { window in
                snapshot.days.filter { window.containsReportDay($0.key) }
            } ?? snapshot.days,
            completedFullHistoryImport: shouldImportFullHistory
        ).days

        let todayKey = dayKey(now)
        let weekRange = currentWeekRange(now)
        let monthKey = monthKeyStr(now)

        let today = archivedDays[todayKey] ?? snapshot.days[todayKey] ?? .empty
        let currentWeek = aggregateDays(archivedDays) { weekRange.dayKeys.contains($0) }
        let currentMonth = aggregateDays(archivedDays) { $0.hasPrefix(monthKey) }
        let overall = aggregateDays(archivedDays) { _ in true }
        let archiveDayCount = archivedDayCount(archivedDays, now: now, fallback: scanWindow?.dayCount ?? max(snapshot.days.count, Self.defaultScanDays))
        let overallRangeLabel = archivedRangeLabel(archivedDays, fallback: scanWindow?.rangeLabel ?? "All local history")

        var extra: [String: AnyCodable] = [:]
        extra["today.estimatedCostUsd"] = AnyCodable(roundUsd(today.estimatedCostUsd))
        extra["today.totalTokens"] = AnyCodable(today.totalTokens)
        extra["today.key"] = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(roundUsd(currentWeek.estimatedCostUsd))
        extra["currentWeek.totalTokens"] = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"] = AnyCodable("\(weekRange.start)..\(weekRange.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(roundUsd(currentMonth.estimatedCostUsd))
        extra["currentMonth.totalTokens"] = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"] = AnyCodable(monthKey)

        extra["timeline.hourly"] = AnyCodable(encodeTimeline(todayHourlyTimeline(snapshot: snapshot, now: now)))
        extra["timeline.daily"] = AnyCodable(encodeTimeline(trailingDailyTimeline(bucketsByDay: archivedDays, now: now, dayCount: archiveDayCount)))

        extra["overall.estimatedCostUsd"] = AnyCodable(roundUsd(overall.estimatedCostUsd))
        extra["overall.totalTokens"] = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"] = AnyCodable(overall.usageRows)
        extra["overall.rangeLabel"] = AnyCodable(overallRangeLabel)
        extra["overall.unpricedModels"] = AnyCodable(snapshot.unpricedModels.sorted().map { AnyCodable($0) })
        extra["overall.sessionCount"] = AnyCodable(snapshot.sessionIds.count)

        func encodeModelBreakdown(_ agg: CodexAggregateBucket) -> [AnyCodable] {
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
                    "cacheCreateTokens": AnyCodable(0),
                    "estimatedCostUsd": AnyCodable(roundUsd(model.estimatedCostUsd)),
                    "estimatedCostDisplay": AnyCodable(formatCurrency(roundUsd(model.estimatedCostUsd))),
                    "percentage": AnyCodable(pct)
                ] as [String: AnyCodable])
            }
        }

        extra["currentMonth.models"] = AnyCodable(encodeModelBreakdown(currentMonth))
        extra["today.models"] = AnyCodable(encodeModelBreakdown(today))
        extra["currentWeek.models"] = AnyCodable(encodeModelBreakdown(currentWeek))
        extra["overall.models"] = AnyCodable(encodeModelBreakdown(overall))

        var modelTimelines: [AnyCodable] = []
        let archivedModelNames = Set(archivedDays.values.flatMap { $0.models.keys })
        for modelName in archivedModelNames.sorted() {
            let hourly = todayHourlyTimeline(snapshot: snapshot, now: now, model: modelName)
            let daily = trailingDailyTimeline(bucketsByDay: archivedDays, now: now, dayCount: archiveDayCount, model: modelName)
            guard !hourly.isEmpty || !daily.isEmpty else { continue }
            modelTimelines.append(AnyCodable([
                "model": AnyCodable(modelName),
                "hourly": AnyCodable(encodeTimeline(hourly)),
                "daily": AnyCodable(encodeTimeline(daily))
            ] as [String: AnyCodable]))
        }
        extra["timeline.byModel"] = AnyCodable(modelTimelines)

        var usage = ProviderUsage(provider: id, label: displayName, extra: extra)
        var source = SourceInfo(mode: "auto", type: "codex-session-logs")
        source.roots = existingRoots
        usage.source = source
        return usage
    }
}
