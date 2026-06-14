import Foundation

// MARK: - Claude Call Event Source
// 解析 Claude Code 的本地会话日志，提取工具 / MCP / Skill 调用计数。
// 数据来源: ~/.claude/projects/**/*.jsonl（或 $CLAUDE_CONFIG_DIR/projects）。
// 仅读 assistant 行 message.content[] 里 type==tool_use 的 name；不读 token、不读正文。
// 0.8.0 曾删除 Claude 的 JSONL 用量扫描，这里是「只为调用分析」的独立轻量扫描。

struct ClaudeCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    /// Claude 单行可能含 thinking 长文，给足缓冲以保证 tool_use 行被完整解析。
    private static let maxLineBytes = 4 * 1024 * 1024
    private static let toolUseNeedle = Data("\"tool_use\"".utf8)
    private static let webSearchTools: Set<String> = ["WebSearch", "WebFetch"]

    func resolveProjectRoots() -> [String] {
        if let env = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env.split(separator: ",").map { part -> String in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                return (trimmed as NSString).lastPathComponent == "projects" ? trimmed : "\(trimmed)/projects"
            }
        }
        return [
            "\(homeDirectory)/.config/claude/projects",
            "\(homeDirectory)/.claude/projects"
        ]
    }

    func collect(cutoff: Date?) -> (entries: [CallAnalyticsEntry], status: CallSourceStatus) {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        let roots = resolveProjectRoots().filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else {
            return ([], CallSourceStatus(source: .claude, available: false, eventCount: 0, filesScanned: 0, errorCode: nil))
        }

        let files = collectJSONLFiles(roots: roots, cutoff: cutoff)
        var accumulator = CallEventAccumulator()
        for file in files {
            let fallbackDayKey = clock.dayKey(fileModificationDate(file) ?? Date())
            CallAnalyticsLineReader.forEachLine(
                path: file,
                needles: [Self.toolUseNeedle],
                maxLineBytes: Self.maxLineBytes
            ) { line in
                parseLine(line, clock: clock, fallbackDayKey: fallbackDayKey, into: &accumulator)
            }
        }

        let status = CallSourceStatus(
            source: .claude,
            available: true,
            eventCount: accumulator.eventCount,
            filesScanned: files.count,
            errorCode: nil
        )
        return (accumulator.entries(), status)
    }

    // MARK: - Parsing

    private func parseLine(
        _ line: Data,
        clock: CallAnalyticsClock,
        fallbackDayKey: String,
        into accumulator: inout CallEventAccumulator
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "assistant",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return
        }

        let dayKey: String
        if let ts = object["timestamp"] as? String, let date = clock.date(fromISO: ts) {
            dayKey = clock.dayKey(date)
        } else {
            dayKey = fallbackDayKey
        }

        for item in content {
            guard (item["type"] as? String) == "tool_use",
                  let rawName = item["name"] as? String, !rawName.isEmpty else {
                continue
            }
            classify(rawName: rawName, input: item["input"] as? [String: Any], dayKey: dayKey, into: &accumulator)
        }
    }

    private func classify(
        rawName: String,
        input: [String: Any]?,
        dayKey: String,
        into accumulator: inout CallEventAccumulator
    ) {
        if let mcp = CallAnalyticsNaming.parseClaudeMCP(rawName) {
            accumulator.add(
                source: .claude,
                kind: .mcp,
                name: CallAnalyticsNaming.mcpDisplayName(server: mcp.server, tool: mcp.tool),
                server: mcp.server,
                dayKey: dayKey
            )
            return
        }

        if rawName == "Skill" {
            let trimmed = (input?["skill"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let skillName = trimmed.isEmpty ? "(unknown)" : trimmed
            accumulator.add(source: .claude, kind: .skill, name: skillName, server: nil, dayKey: dayKey)
            return
        }

        let kind: CallKind = Self.webSearchTools.contains(rawName) ? .webSearch : .builtin
        accumulator.add(source: .claude, kind: kind, name: rawName, server: nil, dayKey: dayKey)
    }

    // MARK: - File discovery

    private func collectJSONLFiles(roots: [String], cutoff: Date?) -> [String] {
        var files: [String] = []
        var seen = Set<String>()
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let item as URL in enumerator {
                guard item.pathExtension.lowercased() == "jsonl" else { continue }
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if values?.isRegularFile == false { continue }
                if let cutoff, let modified = values?.contentModificationDate, modified < cutoff { continue }
                guard seen.insert(item.path).inserted else { continue }
                files.append(item.path)
            }
        }
        return files
    }

    private func fileModificationDate(_ path: String) -> Date? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
