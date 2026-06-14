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
    private static let toolResultNeedle = Data("\"tool_result\"".utf8)
    private static let webSearchTools: Set<String> = ["WebSearch", "WebFetch"]

    /// 已解析待配对的 tool_use（等其 tool_result 确定成功/失败后再计入累加器）。
    private struct PendingCall {
        let kind: CallKind
        let name: String
        let server: String?
        let agent: String   // "main" / "subagent"
        let dayKey: String
    }

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
            // 路径含 subagents/ 的整文件视为 subagent；其具体类型取边车 agent-<id>.meta.json 的 agentType
            // （如 Explore / Plan），拿不到则归为通用 "subagent"。常规文件再按行内 isSidechain 兜底。
            let isSubagentFile = file.contains("/subagents/")
            let subagentType = isSubagentFile ? readSubagentType(forFile: file) : nil
            let fallbackDayKey = clock.dayKey(fileModificationDate(file) ?? Date())
            // 同文件内按 tool_use_id 配对 tool_result（成功率）。配对发生在文件内、顺序保证 result 在 use 之后。
            var pending: [String: PendingCall] = [:]
            CallAnalyticsLineReader.forEachLine(
                path: file,
                needles: [Self.toolUseNeedle, Self.toolResultNeedle],
                maxLineBytes: Self.maxLineBytes
            ) { line in
                parseLine(line, clock: clock, fallbackDayKey: fallbackDayKey,
                          isSubagentFile: isSubagentFile, subagentType: subagentType,
                          pending: &pending, into: &accumulator)
            }
            // 文件结束仍未配到 tool_result 的 tool_use：只计数，成功率未知（不计入分母）。
            for call in pending.values {
                accumulator.add(source: .claude, kind: call.kind, name: call.name,
                                server: call.server, dayKey: call.dayKey, agent: call.agent, success: nil)
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
        isSubagentFile: Bool,
        subagentType: String?,
        pending: inout [String: PendingCall],
        into accumulator: inout CallEventAccumulator
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return
        }

        switch type {
        case "assistant":
            let dayKey: String
            if let ts = object["timestamp"] as? String, let date = clock.date(fromISO: ts) {
                dayKey = clock.dayKey(date)
            } else {
                dayKey = fallbackDayKey
            }
            // agent：子代理文件用其具体类型（拿不到→"subagent"）；常规文件按行 isSidechain 兜底；否则 "main"。
            let agent: String
            if isSubagentFile {
                agent = subagentType ?? "subagent"
            } else if (object["isSidechain"] as? Bool) == true {
                agent = "subagent"
            } else {
                agent = "main"
            }
            for item in content {
                guard (item["type"] as? String) == "tool_use",
                      let rawName = item["name"] as? String, !rawName.isEmpty else {
                    continue
                }
                let call = makeCall(rawName: rawName, input: item["input"] as? [String: Any], agent: agent, dayKey: dayKey)
                if let id = (item["id"] as? String), !id.isEmpty {
                    pending[id] = call   // 等 tool_result 再计入（带成功/失败）
                } else {
                    // 无 id 无法配对：只计数，成功率未知。
                    accumulator.add(source: .claude, kind: call.kind, name: call.name,
                                    server: call.server, dayKey: call.dayKey, agent: call.agent, success: nil)
                }
            }

        case "user":
            // 用户行里的 tool_result 给出对应 tool_use 的成功/失败：is_error==true→失败，false/缺省→成功。
            for item in content {
                guard (item["type"] as? String) == "tool_result",
                      let id = item["tool_use_id"] as? String,
                      let call = pending.removeValue(forKey: id) else {
                    continue
                }
                let isError = (item["is_error"] as? Bool) == true
                accumulator.add(source: .claude, kind: call.kind, name: call.name,
                                server: call.server, dayKey: call.dayKey, agent: call.agent, success: !isError)
            }

        default:
            return
        }
    }

    private func makeCall(rawName: String, input: [String: Any]?, agent: String, dayKey: String) -> PendingCall {
        if let mcp = CallAnalyticsNaming.parseClaudeMCP(rawName) {
            return PendingCall(
                kind: .mcp,
                name: CallAnalyticsNaming.mcpDisplayName(server: mcp.server, tool: mcp.tool),
                server: mcp.server,
                agent: agent,
                dayKey: dayKey
            )
        }

        if rawName == "Skill" {
            let trimmed = (input?["skill"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let skillName = trimmed.isEmpty ? "(unknown)" : trimmed
            return PendingCall(kind: .skill, name: skillName, server: nil, agent: agent, dayKey: dayKey)
        }

        let kind: CallKind = Self.webSearchTools.contains(rawName) ? .webSearch : .builtin
        return PendingCall(kind: kind, name: rawName, server: nil, agent: agent, dayKey: dayKey)
    }

    /// 读取子代理边车 `agent-<id>.meta.json` 的 `agentType`（如 Explore / Plan）。拿不到返回 nil。
    private func readSubagentType(forFile file: String) -> String? {
        guard file.hasSuffix(".jsonl") else { return nil }
        let metaPath = String(file.dropLast(".jsonl".count)) + ".meta.json"
        guard let data = FileManager.default.contents(atPath: metaPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (object["agentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty else {
            return nil
        }
        return type
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
