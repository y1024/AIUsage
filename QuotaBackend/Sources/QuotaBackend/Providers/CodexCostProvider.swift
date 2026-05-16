import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Codex Cost Provider
// Reads local Codex session JSONL logs and derives token/cost totals.
// Data sources: ~/.codex/sessions, ~/.codex/archived_sessions, or $CODEX_HOME.

public struct CodexCostProvider: ProviderFetcher {
    public let id = "codex-cost"
    public let displayName = "Codex Token Stats"
    public let description = "Local token ledger from Codex session logs"

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    private static let sessionMetaNeedle = Data("\"session_meta\"".utf8)
    private static let tokenCountNeedle = Data("\"token_count\"".utf8)
    private static let turnContextNeedle = Data("\"turn_context\"".utf8)
    private static let compactTurnContextTypeNeedle = Data("\"type\":\"turn_context\"".utf8)
    private static let compactEventMsgTypeNeedle = Data("\"type\":\"event_msg\"".utf8)
    private static let fileScanCache = CodexCostFileScanCache()
    private static let usageArchive = CodexUsageArchiveStore()
    private static let cacheSchemaVersion = 3
    private static let defaultScanDays = 30
    private static let defaultArchiveScopeID = "default"
    private static let filenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    public static func requestFullHistoryImport() async {
        await usageArchive.requestFullHistoryImport()
    }

    public static func needsFullHistoryImport() async -> Bool {
        await usageArchive.needsFullHistoryImport()
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
            throw ProviderError("logs_not_found", "No Codex session logs found under \(roots.joined(separator: ", "))")
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

    // MARK: - File discovery

    private func resolveSessionRoots() -> [String] {
        let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? "\(homeDirectory)/.codex"
        return [
            "\(codexHome)/sessions",
            "\(codexHome)/archived_sessions"
        ]
    }

    private func archiveScopeID() -> String {
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.path
        let explicitCodexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        if homeDirectory == defaultHome, explicitCodexHome == nil {
            return Self.defaultArchiveScopeID
        }
        return explicitCodexHome ?? "\(homeDirectory)/.codex"
    }

    private func collectJSONLFiles(roots: [String], scanWindow: CodexScanWindow?) -> [String] {
        var files: [String] = []
        var seen = Set<String>()
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            let candidates: [URL]
            if let scanWindow {
                candidates = listDatePartitionedJSONLFiles(root: rootURL, scanWindow: scanWindow)
                    + listFlatJSONLFiles(root: rootURL, scanWindow: scanWindow)
            } else {
                candidates = listAllJSONLFiles(root: rootURL)
            }
            for candidate in candidates {
                let path = candidate.path
                guard seen.insert(path).inserted else { continue }
                files.append(path)
            }
        }
        return files.sorted()
    }

    private func listDatePartitionedJSONLFiles(root: URL, scanWindow: CodexScanWindow) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var files: [URL] = []
        var date = dateFromDayKey(scanWindow.scanSinceKey) ?? Date()
        let until = dateFromDayKey(scanWindow.scanUntilKey) ?? date

        while date <= until {
            let comps = calendar().dateComponents([.year, .month, .day], from: date)
            let dayDir = root
                .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
            if let items = try? FileManager.default.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                files.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "jsonl" })
            }

            guard let next = calendar().date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }

        return files
    }

    private func listFlatJSONLFiles(root: URL, scanWindow: CodexScanWindow) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return items.filter { item in
            guard item.pathExtension.lowercased() == "jsonl" else { return false }
            guard let dayKey = dayKeyFromFilename(item.lastPathComponent) else { return true }
            return scanWindow.containsScanDay(dayKey)
        }
    }

    private func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = Self.filenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let matchRange = Range(match.range(at: 1), in: filename) else {
            return nil
        }
        return String(filename[matchRange])
    }

    private func listAllJSONLFiles(root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var files: [URL] = []
        for case let item as URL in enumerator {
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            if let values = try? item.resourceValues(forKeys: Set<URLResourceKey>([.isRegularFileKey])),
               values.isRegularFile == false {
                continue
            }
            files.append(item)
        }
        return files
    }

    // MARK: - Scanning

    private func scanFiles(_ files: [String]) async -> CodexUsageSnapshot {
        let fingerprintsByFile = fileFingerprints(files)
        let cachedByFile = await Self.fileScanCache.entries(matching: fingerprintsByFile)
        var parsedUpdates: [String: CodexParsedFile] = [:]

        var metadataByFile: [String: SessionMetadata] = [:]
        var fileBySessionId: [String: String] = [:]

        for file in files {
            guard let metadata = cachedByFile[file]?.metadata ?? parseSessionMetadata(file) else { continue }
            metadataByFile[file] = metadata
            if let sessionId = metadata.sessionId, fileBySessionId[sessionId] == nil {
                fileBySessionId[sessionId] = file
            }
        }

        var filesToParse = Set(files.filter { cachedByFile[$0] == nil })
        var changedSessionIds = Set(filesToParse.compactMap { metadataByFile[$0]?.sessionId })
        var addedDependent = true
        while addedDependent {
            addedDependent = false
            for (file, metadata) in metadataByFile {
                guard !filesToParse.contains(file),
                      let parentId = metadata.forkedFromId,
                      changedSessionIds.contains(parentId) else {
                    continue
                }
                filesToParse.insert(file)
                if let sessionId = metadata.sessionId {
                    changedSessionIds.insert(sessionId)
                }
                addedDependent = true
            }
        }

        var snapshotCacheByFile: [String: [TimestampedTotals]] = [:]
        func snapshots(for file: String) -> [TimestampedTotals] {
            if let cached = snapshotCacheByFile[file] {
                return cached
            }
            if let cached = parsedUpdates[file]?.snapshots ?? cachedByFile[file]?.snapshots {
                snapshotCacheByFile[file] = cached
                return cached
            }
            let parsed = parseTokenSnapshots(file)
            snapshotCacheByFile[file] = parsed.snapshots
            return parsed.snapshots
        }

        func inheritedTotals(sessionId: String, atOrBefore cutoffTimestamp: String) -> CodexTotals? {
            guard let file = fileBySessionId[sessionId] else { return nil }
            let snapshots = snapshots(for: file)

            let cutoffDate = parseTimestamp(cutoffTimestamp)
            var inherited: CodexTotals?
            for snapshot in snapshots {
                let isBeforeCutoff: Bool
                if let snapshotDate = snapshot.date, let cutoffDate {
                    isBeforeCutoff = snapshotDate <= cutoffDate
                } else {
                    isBeforeCutoff = snapshot.timestamp <= cutoffTimestamp
                }
                if isBeforeCutoff { inherited = snapshot.totals }
            }
            return inherited
        }

        var snapshot = CodexUsageSnapshot()
        var seenSessions = Set<String>()
        for file in files {
            let metadata = metadataByFile[file]
            if let sessionId = metadata?.sessionId {
                guard seenSessions.insert(sessionId).inserted else {
                    if filesToParse.contains(file), let fingerprint = fingerprintsByFile[file] {
                        parsedUpdates[file] = CodexParsedFile(
                            fingerprint: fingerprint,
                            metadata: metadata,
                            aggregate: CodexFileAggregate(sessionId: metadata?.sessionId),
                            snapshots: nil
                        )
                    }
                    continue
                }
            }
            let fileAggregate: CodexFileAggregate
            if filesToParse.contains(file) {
                fileAggregate = parseFile(file, metadata: metadata, inheritedTotals: inheritedTotals)
                if let fingerprint = fingerprintsByFile[file] {
                    parsedUpdates[file] = CodexParsedFile(
                        fingerprint: fingerprint,
                        metadata: metadata,
                        aggregate: fileAggregate,
                        snapshots: snapshotCacheByFile[file]
                    )
                }
            } else {
                fileAggregate = cachedByFile[file]?.aggregate ?? CodexFileAggregate(sessionId: metadata?.sessionId)
            }
            snapshot.merge(fileAggregate)
        }

        for (file, snapshots) in snapshotCacheByFile where parsedUpdates[file] == nil {
            if let cached = cachedByFile[file] {
                parsedUpdates[file] = CodexParsedFile(
                    fingerprint: cached.fingerprint,
                    metadata: cached.metadata,
                    aggregate: cached.aggregate,
                    snapshots: snapshots
                )
            }
        }

        if !parsedUpdates.isEmpty || cachedByFile.count != files.count {
            await Self.fileScanCache.store(parsedUpdates, keeping: Set(files))
        }

        return snapshot
    }

    private func fileFingerprints(_ files: [String]) -> [String: CodexFileFingerprint] {
        Dictionary(uniqueKeysWithValues: files.map { file in
            (file, fileFingerprint(file))
        })
    }

    private func fileFingerprint(_ path: String) -> CodexFileFingerprint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return CodexFileFingerprint(
            path: path,
            size: size,
            modifiedAt: modifiedAt,
            pricingSignature: pricingCacheSignature()
        )
    }

    private func pricingCacheSignature() -> String {
        "\(Self.cacheSchemaVersion):official-openai-api-pricing"
    }

    private func parseSessionMetadata(_ path: String) -> SessionMetadata? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var buffer = Data()
        let chunkSize = 64 * 1024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
                if let metadata = parseSessionMetadataLine(lineData) {
                    return metadata
                }
            }
        }
        return parseSessionMetadataLine(buffer)
    }

    private func parseSessionMetadataLine(_ data: Data) -> SessionMetadata? {
        guard !data.isEmpty,
              data.range(of: Self.sessionMetaNeedle) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta" else {
            return nil
        }
        let payload = obj["payload"] as? [String: Any]
        return SessionMetadata(
            sessionId: firstNonEmpty(
                payload?["session_id"] as? String,
                payload?["sessionId"] as? String,
                payload?["id"] as? String,
                obj["session_id"] as? String,
                obj["sessionId"] as? String,
                obj["id"] as? String
            ),
            forkedFromId: firstNonEmpty(
                payload?["forked_from_id"] as? String,
                payload?["forkedFromId"] as? String,
                payload?["parent_session_id"] as? String,
                payload?["parentSessionId"] as? String
            ),
            forkTimestamp: firstNonEmpty(payload?["timestamp"] as? String, obj["timestamp"] as? String)
        )
    }

    private func parseTokenSnapshots(_ path: String) -> (sessionId: String?, snapshots: [TimestampedTotals]) {
        var sessionId: String?
        var previousTotals: CodexTotals?
        var snapshots: [TimestampedTotals] = []

        scanJSONLLines(
            path,
            matching: [Self.sessionMetaNeedle, Self.tokenCountNeedle],
            maxLineBytes: 512 * 1024,
            prefixBytes: 512 * 1024
        ) { data in
            if data.range(of: Self.sessionMetaNeedle) != nil {
                if sessionId == nil {
                    sessionId = parseSessionMetadataLine(data)?.sessionId
                }
                return
            }

            guard data.range(of: Self.compactEventMsgTypeNeedle) != nil,
                  data.range(of: Self.tokenCountNeedle) != nil,
                  let timestamp = extractJSONStringField("timestamp", from: data) else {
                return
            }

            if let next = tokenUsageTotals(named: "total_token_usage", in: data) {
                previousTotals = next
                snapshots.append(TimestampedTotals(timestamp: timestamp, date: parseTimestamp(timestamp), totals: next))
            } else if let last = tokenUsageTotals(named: "last_token_usage", in: data) {
                let base = previousTotals ?? CodexTotals(input: 0, cached: 0, output: 0)
                let next = CodexTotals(
                    input: base.input + last.input,
                    cached: base.cached + last.cached,
                    output: base.output + last.output
                )
                previousTotals = next
                snapshots.append(TimestampedTotals(timestamp: timestamp, date: parseTimestamp(timestamp), totals: next))
            }
        }

        return (sessionId, snapshots)
    }

    private func parseFile(
        _ path: String,
        metadata: SessionMetadata?,
        inheritedTotals: (String, String) -> CodexTotals?
    ) -> CodexFileAggregate {
        var currentModel: String?
        var previousTotals: CodexTotals?
        let inherited = metadata.flatMap { meta -> CodexTotals? in
            guard let parentId = meta.forkedFromId else { return nil }
            return inheritedTotals(parentId, meta.forkTimestamp ?? "")
        }
        var remainingInherited = inherited
        var aggregate = CodexFileAggregate(sessionId: metadata?.sessionId)

        scanJSONLLines(
            path,
            matching: [
                Self.tokenCountNeedle,
                Self.turnContextNeedle,
                Self.sessionMetaNeedle
            ],
            maxLineBytes: 256 * 1024,
            prefixBytes: 32 * 1024
        ) { data in
            guard data.range(of: Self.tokenCountNeedle) != nil
                || data.range(of: Self.turnContextNeedle) != nil
                || data.range(of: Self.sessionMetaNeedle) != nil else {
                return
            }

            if data.range(of: Self.compactTurnContextTypeNeedle) != nil {
                currentModel = extractJSONStringField("model", from: data) ?? currentModel
                return
            }

            if data.range(of: Self.sessionMetaNeedle) != nil {
                return
            }

            guard let tsText = extractJSONStringField("timestamp", from: data),
                  let timestamp = parseTimestamp(tsText) else {
                return
            }

            if data.range(of: Self.turnContextNeedle) != nil {
                currentModel = extractJSONStringField("model", from: data) ?? currentModel
                return
            }

            guard data.range(of: Self.compactEventMsgTypeNeedle) != nil else { return }

            guard data.range(of: Self.tokenCountNeedle) != nil else { return }
            let modelFromInfo = firstNonEmpty(
                extractJSONStringField("model", from: data),
                extractJSONStringField("model_name", from: data)
            )
            let model = normalizeModel(modelFromInfo ?? currentModel ?? "gpt-5")

            var delta = CodexTotals(input: 0, cached: 0, output: 0)

            if let rawTotals = tokenUsageTotals(named: "total_token_usage", in: data) {
                let currentTotals: CodexTotals
                if let inherited {
                    currentTotals = CodexTotals(
                        input: max(0, rawTotals.input - inherited.input),
                        cached: max(0, rawTotals.cached - inherited.cached),
                        output: max(0, rawTotals.output - inherited.output)
                    )
                } else {
                    currentTotals = rawTotals
                }
                let previous = previousTotals ?? CodexTotals(input: 0, cached: 0, output: 0)
                delta = CodexTotals(
                    input: max(0, currentTotals.input - previous.input),
                    cached: max(0, currentTotals.cached - previous.cached),
                    output: max(0, currentTotals.output - previous.output)
                )
                previousTotals = currentTotals
                remainingInherited = nil
            } else if let rawDelta = tokenUsageTotals(named: "last_token_usage", in: data) {
                delta = adjustedLastDelta(rawDelta, remainingInherited: &remainingInherited)
                let previous = previousTotals ?? CodexTotals(input: 0, cached: 0, output: 0)
                previousTotals = CodexTotals(
                    input: previous.input + delta.input,
                    cached: previous.cached + delta.cached,
                    output: previous.output + delta.output
                )
            } else {
                return
            }

            guard delta.input > 0 || delta.cached > 0 || delta.output > 0 else { return }
            let cached = min(delta.cached, delta.input)
            let nonCachedInput = max(0, delta.input - cached)
            let cost = estimateCost(model: model, input: nonCachedInput, cacheRead: cached, output: delta.output)

            let row = CodexRow(
                dayKey: dayKey(timestamp),
                model: model,
                inputTokens: nonCachedInput,
                cacheReadTokens: cached,
                outputTokens: delta.output,
                totalTokens: nonCachedInput + cached + delta.output,
                estimatedCostUsd: cost
            )
            aggregate.record(row: row, hourKey: hourBucketKey(timestamp))
        }

        return aggregate
    }

    private func scanJSONLLines(
        _ path: String,
        matching needles: [Data] = [],
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (Data) -> Void
    ) {
        let effectivePrefixBytes = max(1, min(prefixBytes, maxLineBytes))
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(min(effectivePrefixBytes, 32 * 1024))

        func appendSegment(_ segment: Data.SubSequence) {
            guard !segment.isEmpty else { return }
            guard lineBuffer.count < effectivePrefixBytes else { return }
            let remaining = effectivePrefixBytes - lineBuffer.count
            if segment.count <= remaining {
                lineBuffer.append(contentsOf: segment)
            } else {
                lineBuffer.append(contentsOf: segment.prefix(remaining))
            }
        }

        func flushLine() {
            defer {
                lineBuffer.removeAll(keepingCapacity: true)
            }
            guard !lineBuffer.isEmpty,
                  lineMatches(lineBuffer, in: lineBuffer.startIndex..<lineBuffer.endIndex, needles: needles) else {
                return
            }
            let line = lineBuffer
            autoreleasepool {
                onLine(line)
            }
        }

        #if canImport(Darwin)
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let chunkSize = 128 * 1024
        var readBuffer = [UInt8](repeating: 0, count: chunkSize)

        func appendPointer(_ pointer: UnsafePointer<UInt8>, count: Int) {
            guard count > 0, lineBuffer.count < effectivePrefixBytes else { return }
            let countToAppend = min(count, effectivePrefixBytes - lineBuffer.count)
            lineBuffer.append(pointer, count: countToAppend)
        }

        while true {
            let bytesRead = readBuffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(fd, base, chunkSize)
            }
            if bytesRead <= 0 { break }

            readBuffer.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < bytesRead {
                    let remaining = bytesRead - offset
                    if let found = memchr(base.advanced(by: offset), 0x0A, remaining) {
                        let newline = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        appendPointer(base.advanced(by: offset), count: newline - offset)
                        flushLine()
                        offset = newline + 1
                    } else {
                        appendPointer(base.advanced(by: offset), count: remaining)
                        offset = bytesRead
                    }
                }
            }
        }
        flushLine()
        #else
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }

        let newline = Data([0x0A])
        let chunkSize = 256 * 1024

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            var searchStart = chunk.startIndex
            while searchStart < chunk.endIndex,
                  let newlineRange = chunk.range(of: newline, options: [], in: searchStart..<chunk.endIndex) {
                appendSegment(chunk[searchStart..<newlineRange.lowerBound])
                flushLine()
                searchStart = newlineRange.upperBound
            }

            if searchStart < chunk.endIndex {
                appendSegment(chunk[searchStart..<chunk.endIndex])
            }
        }
        flushLine()
        #endif
    }

    private func lineMatches(_ data: Data, in range: Range<Data.Index>, needles: [Data]) -> Bool {
        guard !needles.isEmpty else { return true }
        for needle in needles where data.range(of: needle, options: [], in: range) != nil {
            return true
        }
        return false
    }

    private func adjustedLastDelta(_ rawDelta: CodexTotals, remainingInherited: inout CodexTotals?) -> CodexTotals {
        guard var remaining = remainingInherited else { return rawDelta }
        let adjusted = CodexTotals(
            input: max(0, rawDelta.input - remaining.input),
            cached: max(0, rawDelta.cached - remaining.cached),
            output: max(0, rawDelta.output - remaining.output)
        )
        remaining.input = max(0, remaining.input - rawDelta.input)
        remaining.cached = max(0, remaining.cached - rawDelta.cached)
        remaining.output = max(0, remaining.output - rawDelta.output)
        remainingInherited = (remaining.input == 0 && remaining.cached == 0 && remaining.output == 0) ? nil : remaining
        return adjusted
    }

    private func extractJSONStringField(_ field: String, from data: Data) -> String? {
        let needle = Data("\"\(field)\"".utf8)
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let keyRange = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
            var index = keyRange.upperBound
            skipJSONWhitespace(in: data, index: &index)
            guard index < data.endIndex, data[index] == 0x3A else {
                searchStart = keyRange.upperBound
                continue
            }

            index += 1
            skipJSONWhitespace(in: data, index: &index)
            guard index < data.endIndex, data[index] == 0x22 else {
                searchStart = keyRange.upperBound
                continue
            }

            index += 1
            var bytes: [UInt8] = []
            bytes.reserveCapacity(32)
            var escaped = false
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                if escaped {
                    bytes.append(byte)
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    return String(bytes: bytes, encoding: .utf8)
                } else {
                    bytes.append(byte)
                }
            }
            return nil
        }

        return nil
    }

    private func skipJSONWhitespace(in data: Data, index: inout Data.Index) {
        while index < data.endIndex {
            switch data[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private func tokenUsageTotals(named field: String, in data: Data) -> CodexTotals? {
        guard let range = jsonObjectRange(named: field, in: data) else { return nil }
        let cached = jsonIntField("cached_input_tokens", in: data, range: range)
        let cacheRead = jsonIntField("cache_read_input_tokens", in: data, range: range)
        return CodexTotals(
            input: jsonIntField("input_tokens", in: data, range: range),
            cached: cached > 0 ? cached : cacheRead,
            output: jsonIntField("output_tokens", in: data, range: range)
        )
    }

    private func jsonObjectRange(named field: String, in data: Data) -> Range<Data.Index>? {
        let needle = Data("\"\(field)\"".utf8)
        guard let keyRange = data.range(of: needle) else { return nil }
        var index = keyRange.upperBound
        skipJSONWhitespace(in: data, index: &index)
        guard index < data.endIndex, data[index] == 0x3A else { return nil }
        index += 1
        skipJSONWhitespace(in: data, index: &index)
        guard index < data.endIndex, data[index] == 0x7B else { return nil }

        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    return start..<data.index(after: index)
                }
            }
            index += 1
        }
        return nil
    }

    private func jsonIntField(_ field: String, in data: Data, range: Range<Data.Index>) -> Int {
        let needle = Data("\"\(field)\"".utf8)
        guard let keyRange = data.range(of: needle, options: [], in: range) else { return 0 }
        var index = keyRange.upperBound
        skipJSONWhitespace(in: data, index: &index)
        guard index < range.upperBound, data[index] == 0x3A else { return 0 }
        index += 1
        skipJSONWhitespace(in: data, index: &index)

        if index < range.upperBound, data[index] == 0x22 {
            index += 1
        }

        var sign = 1
        if index < range.upperBound, data[index] == 0x2D {
            sign = -1
            index += 1
        }

        var value = 0
        var sawDigit = false
        while index < range.upperBound {
            let byte = data[index]
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            value = value * 10 + Int(byte - 0x30)
            index += 1
        }
        return sawDigit ? max(0, value * sign) : 0
    }

    // MARK: - Aggregation

    private struct TimelineBucket {
        let bucket: String
        let label: String
        let estimatedCostUsd: Double
        let totalTokens: Int
    }

    private func aggregateDays(
        _ bucketsByDay: [String: CodexAggregateBucket],
        matching: (String) -> Bool
    ) -> CodexAggregateBucket {
        var result = CodexAggregateBucket.empty
        for (day, bucket) in bucketsByDay where matching(day) {
            result.merge(bucket)
        }
        return result
    }

    private func todayHourlyTimeline(
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

    private func trailingDailyTimeline(
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

    private func bucketMetrics(
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

    private func encodeTimeline(_ buckets: [TimelineBucket]) -> [AnyCodable] {
        buckets.map { bucket in
            AnyCodable([
                "bucket": AnyCodable(bucket.bucket),
                "label": AnyCodable(bucket.label),
                "usd": AnyCodable(bucket.estimatedCostUsd),
                "tokens": AnyCodable(bucket.totalTokens)
            ] as [String: AnyCodable])
        }
    }

    // MARK: - Pricing

    private struct Pricing {
        let inputPerToken: Double
        let outputPerToken: Double
        let cacheReadPerToken: Double
        let threshold: Int?
        let inputAbove: Double?
        let outputAbove: Double?
        let cacheReadAbove: Double?

        init(_ input: Double, _ output: Double, _ cacheRead: Double,
             threshold: Int? = nil, inputAbove: Double? = nil,
             outputAbove: Double? = nil, cacheReadAbove: Double? = nil) {
            inputPerToken = input
            outputPerToken = output
            cacheReadPerToken = cacheRead
            self.threshold = threshold
            self.inputAbove = inputAbove
            self.outputAbove = outputAbove
            self.cacheReadAbove = cacheReadAbove
        }
    }

    // OpenAI official API prices per token. Source values are published per
    // 1M tokens, so $1.25 / 1M is represented as 1.25e-6 here.
    private static let pricing: [String: Pricing] = [
        "gpt-5": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5-codex": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5-mini": Pricing(2.5e-7, 2e-6, 2.5e-8),
        "gpt-5-nano": Pricing(5e-8, 4e-7, 5e-9),
        "gpt-5-pro": Pricing(1.5e-5, 1.2e-4, 1.5e-5),
        "gpt-5.1": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5.1-codex": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5.1-codex-max": Pricing(1.25e-6, 1e-5, 1.25e-7),
        "gpt-5.1-codex-mini": Pricing(2.5e-7, 2e-6, 2.5e-8),
        "gpt-5.2": Pricing(1.75e-6, 1.4e-5, 1.75e-7),
        "gpt-5.2-codex": Pricing(1.75e-6, 1.4e-5, 1.75e-7),
        "gpt-5.2-pro": Pricing(2.1e-5, 1.68e-4, 2.1e-5),
        "gpt-5.3-codex": Pricing(1.75e-6, 1.4e-5, 1.75e-7),
        "gpt-5.4": Pricing(2.5e-6, 1.5e-5, 2.5e-7, threshold: 272_000, inputAbove: 5e-6, outputAbove: 2.25e-5, cacheReadAbove: 5e-7),
        "gpt-5.4-mini": Pricing(7.5e-7, 4.5e-6, 7.5e-8),
        "gpt-5.4-nano": Pricing(2e-7, 1.25e-6, 2e-8),
        "gpt-5.4-pro": Pricing(3e-5, 1.8e-4, 3e-5, threshold: 272_000, inputAbove: 6e-5, outputAbove: 2.7e-4, cacheReadAbove: 6e-5),
        "gpt-5.5": Pricing(5e-6, 3e-5, 5e-7, threshold: 272_000, inputAbove: 1e-5, outputAbove: 4.5e-5, cacheReadAbove: 1e-6),
        "gpt-5.5-pro": Pricing(3e-5, 1.8e-4, 3e-5),
        "codex-mini-latest": Pricing(1.5e-6, 6e-6, 3.75e-7)
    ]

    private func estimateCost(model: String, input: Int, cacheRead: Int, output: Int) -> Double? {
        guard let p = Self.pricing[model] else { return nil }
        let rawInput = input + cacheRead
        let usesLongContext = p.threshold.map { rawInput > $0 } ?? false
        let inputRate = usesLongContext ? (p.inputAbove ?? p.inputPerToken) : p.inputPerToken
        let cacheRate = usesLongContext ? (p.cacheReadAbove ?? p.cacheReadPerToken) : p.cacheReadPerToken
        let outputRate = usesLongContext ? (p.outputAbove ?? p.outputPerToken) : p.outputPerToken
        return roundUsd(Double(input) * inputRate + Double(cacheRead) * cacheRate + Double(output) * outputRate)
    }

    private func normalizeModel(_ raw: String) -> String {
        Self.normalizeModelStatic(raw)
    }

    private static func normalizeModelStatic(_ raw: String) -> String {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("openai/") {
            model = String(model.dropFirst("openai/".count))
        }
        if pricing[model] != nil { return model }
        if let range = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if pricing[base] != nil { return base }
        }
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if pricing[base] != nil { return base }
        }
        return model
    }

    // MARK: - Date and misc helpers

    private func parseTimestamp(_ value: String) -> Date? {
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return SharedFormatters.parseISO8601(value)
    }

    private func currentScanWindow(now: Date) -> CodexScanWindow {
        let cal = calendar()
        let today = cal.startOfDay(for: now)
        let since = cal.date(byAdding: .day, value: -(Self.defaultScanDays - 1), to: today) ?? today
        let scanSince = cal.date(byAdding: .day, value: -1, to: since) ?? since
        let scanUntil = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return CodexScanWindow(
            sinceKey: dayKey(since),
            untilKey: dayKey(today),
            scanSinceKey: dayKey(scanSince),
            scanUntilKey: dayKey(scanUntil),
            dayCount: Self.defaultScanDays,
            rangeLabel: "Last \(Self.defaultScanDays) days"
        )
    }

    private func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.calendar = calendar()
        comps.timeZone = timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }

    private func archivedDayCount(
        _ bucketsByDay: [String: CodexAggregateBucket],
        now: Date,
        fallback: Int
    ) -> Int {
        guard let firstKey = bucketsByDay.keys.sorted().first,
              let firstDay = dateFromDayKey(firstKey) else {
            return fallback
        }
        let days = calendar().dateComponents(
            [.day],
            from: calendar().startOfDay(for: firstDay),
            to: calendar().startOfDay(for: now)
        ).day.map { $0 + 1 } ?? fallback
        return max(days, fallback)
    }

    private func archivedRangeLabel(
        _ bucketsByDay: [String: CodexAggregateBucket],
        fallback: String
    ) -> String {
        let keys = bucketsByDay.keys.sorted()
        guard let first = keys.first, let last = keys.last else { return fallback }
        if first == last { return first }
        return "\(first)..\(last)"
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
        let weekday = comps.weekday ?? 1
        let offset = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -offset, to: date) else {
            let key = dayKey(date)
            return (start: key, end: key, dayKeys: [key])
        }
        var keys = Set<String>()
        for i in 0..<7 {
            if let day = cal.date(byAdding: .day, value: i, to: monday) {
                keys.insert(dayKey(day))
            }
        }
        let end = cal.date(byAdding: .day, value: 6, to: monday).map(dayKey) ?? dayKey(monday)
        return (start: dayKey(monday), end: end, dayKeys: keys)
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

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func roundUsd(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = value >= 1 ? 2 : 4
        formatter.maximumFractionDigits = value >= 1 ? 2 : 4
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private func relieveMallocPressure() {
        #if canImport(Darwin)
        malloc_zone_pressure_relief(nil, Int.max)
        #endif
    }
}

private struct CodexScanWindow: Sendable {
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

private struct SessionMetadata: Codable, Sendable {
    let sessionId: String?
    let forkedFromId: String?
    let forkTimestamp: String?
}

private struct CodexTotals: Codable, Sendable {
    var input: Int
    var cached: Int
    var output: Int
}

private struct TimestampedTotals: Codable, Sendable {
    let timestamp: String
    let date: Date?
    let totals: CodexTotals
}

private struct CodexRow: Codable, Sendable {
    let dayKey: String
    let model: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUsd: Double?
}

private struct CodexFileFingerprint: Codable, Equatable, Sendable {
    let path: String
    let size: UInt64
    let modifiedAt: TimeInterval
    let pricingSignature: String
}

private struct CodexModelAggregate: Codable, Sendable {
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

private struct CodexAggregateBucket: Codable, Sendable {
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

private struct CodexFileAggregate: Codable, Sendable {
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

private struct CodexUsageSnapshot: Sendable {
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

private struct CodexParsedFile: Codable, Sendable {
    let fingerprint: CodexFileFingerprint
    let metadata: SessionMetadata?
    let aggregate: CodexFileAggregate
    let snapshots: [TimestampedTotals]?
}

private struct CodexCostPersistentCache: Codable, Sendable {
    let version: Int
    var files: [String: CodexParsedFile]
}

private struct CodexUsageArchive: Codable, Sendable {
    let version: Int
    var updatedAt: String
    var days: [String: CodexAggregateBucket]
    var fullHistoryImportedAt: String?
}

private struct CodexUsageArchiveState: Sendable {
    let days: [String: CodexAggregateBucket]
}

private actor CodexUsageArchiveStore {
    private static let artifactVersion = 2
    private static let defaultScopeID = "default"
    private var archives: [String: CodexUsageArchive] = [:]
    private var loadedScopes: Set<String> = []
    private var fullHistoryImportRequestedForAllScopes = false

    func requestFullHistoryImport() {
        fullHistoryImportRequestedForAllScopes = true
    }

    func needsFullHistoryImport() -> Bool {
        let archive = loadArchiveIfNeeded(scope: Self.defaultScopeID)
        return archive.fullHistoryImportedAt == nil
    }

    func consumeFullHistoryImportRequest(scope: String) -> Bool {
        let archive = loadArchiveIfNeeded(scope: scope)
        guard fullHistoryImportRequestedForAllScopes, archive.fullHistoryImportedAt == nil else {
            fullHistoryImportRequestedForAllScopes = false
            return false
        }
        fullHistoryImportRequestedForAllScopes = false
        return true
    }

    func merge(
        scope: String,
        days: [String: CodexAggregateBucket],
        completedFullHistoryImport: Bool
    ) -> CodexUsageArchiveState {
        var archive = loadArchiveIfNeeded(scope: scope)

        var changed = false
        for (day, bucket) in days {
            guard bucket.usageRows > 0 else { continue }
            archive.days[day] = bucket
            changed = true
        }

        if completedFullHistoryImport {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
            changed = true
        }

        if changed {
            archive.updatedAt = SharedFormatters.iso8601String(from: Date())
            archives[scope] = archive
            saveDiskArchive(scope: scope, archive: archive)
        } else {
            archives[scope] = archive
        }

        return CodexUsageArchiveState(days: archive.days)
    }

    private func loadArchiveIfNeeded(scope: String) -> CodexUsageArchive {
        if let archive = archives[scope], loadedScopes.contains(scope) {
            return archive
        }
        loadedScopes.insert(scope)

        guard scope == Self.defaultScopeID else {
            let archive = CodexUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
            archives[scope] = archive
            return archive
        }

        let url = Self.archiveFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexUsageArchive.self, from: data),
              decoded.version == Self.artifactVersion else {
            let archive = CodexUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
            archives[scope] = archive
            return archive
        }
        archives[scope] = decoded
        return decoded
    }

    private func saveDiskArchive(scope: String, archive: CodexUsageArchive) {
        guard scope == Self.defaultScopeID else { return }
        let url = Self.archiveFileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            let data = try encoder.encode(archive)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort archive: current rolling-window stats should still render if this write fails.
        }
    }

    private static func archiveFileURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("codex-cost-usage-archive-v\(artifactVersion).json")
    }
}

private actor CodexCostFileScanCache {
    private static let artifactVersion = 2
    private var entriesByFile: [String: CodexParsedFile] = [:]
    private var hasLoadedDiskCache = false

    func entries(matching fingerprintsByFile: [String: CodexFileFingerprint]) -> [String: CodexParsedFile] {
        loadDiskCacheIfNeeded()

        var matching: [String: CodexParsedFile] = [:]
        for (file, fingerprint) in fingerprintsByFile {
            guard let entry = entriesByFile[file],
                  entry.fingerprint == fingerprint else {
                continue
            }
            matching[file] = entry
        }
        return matching
    }

    func store(_ updates: [String: CodexParsedFile], keeping validFiles: Set<String>) {
        loadDiskCacheIfNeeded()

        entriesByFile = entriesByFile.filter { validFiles.contains($0.key) }
        for (file, entry) in updates {
            entriesByFile[file] = entry
        }
        saveDiskCache()
    }

    private func loadDiskCacheIfNeeded() {
        guard !hasLoadedDiskCache else { return }
        hasLoadedDiskCache = true

        let url = Self.cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CodexCostPersistentCache.self, from: data),
              decoded.version == Self.artifactVersion else {
            entriesByFile = [:]
            return
        }
        entriesByFile = decoded.files
    }

    private func saveDiskCache() {
        let url = Self.cacheFileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cache = CodexCostPersistentCache(version: Self.artifactVersion, files: entriesByFile)
            let encoder = JSONEncoder()
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort cache: stale or missing cache should never break token stats.
        }
    }

    private static func cacheFileURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("codex-cost-file-cache-v\(artifactVersion).json")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
