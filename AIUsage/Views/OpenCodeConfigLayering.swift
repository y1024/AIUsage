import SwiftUI

// MARK: - OpenCode Config Layering
// 给「激活后的 opencode.json」预览计算分层行标（JSONRawEditorView 的 lineMarkers）：
//   N = 节点受管块（始终最终生效） C = 通用配置 O = 通用覆盖用户原文 无标 = 用户原文
// 输入三层字典 + 最终 pretty JSON 文本，按缩进推导每行的键路径并归源。
// 与 Claude 编辑器 ProxyConfigEditorView+JSONTab 的标注算法同构（C/N/O 颜色由
// JSONWebEditorAssets 渲染），但层语义不同：Claude 是 通用/节点/覆盖，这里是
// 用户原文/通用/受管，故独立实现而非共用。

enum OpenCodeConfigLayering {

    /// 行号(1-based) → 标记字母。`text` 必须是 2 空格缩进、键排序的 pretty JSON
    /// （OpenCodeConfigManager.jsonString 的输出格式）。
    static func lineMarkers(
        text: String,
        pristine: [String: Any],
        common: [String: Any],
        managed: [String: Any]
    ) -> [Int: String] {
        var markers: [Int: String] = [:]
        var stack: [Scope] = []
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " }.count
            let depth = max(0, indent / 2)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("}") || trimmed.hasPrefix("]") {
                if let marker = stack.last?.marker {
                    markers[index + 1] = marker
                }
                while let last = stack.last, last.depth >= depth {
                    stack.removeLast()
                }
                continue
            }

            guard let key = jsonKey(in: trimmed) else {
                // 无键行（数组元素、多行值等）继承当前容器的归源，避免数组内容不着色。
                if !trimmed.isEmpty, let marker = stack.last?.marker {
                    markers[index + 1] = marker
                }
                continue
            }

            // 数组/对象内部行继承容器的归源。
            while let last = stack.last, last.depth >= depth {
                stack.removeLast()
            }

            let path = stack.map(\.key) + [key]
            let lineMarker = marker(for: path, pristine: pristine, common: common, managed: managed)
            if let lineMarker {
                markers[index + 1] = lineMarker
            }

            if containsContainerStart(line) {
                stack.append(Scope(depth: depth, key: key, marker: lineMarker))
            }
        }
        return markers
    }

    // MARK: - Internals

    private struct Scope {
        let depth: Int
        let key: String
        let marker: String?
    }

    /// nil = 用户原文（不着色）。受管 > 覆盖 > 通用。
    private static func marker(
        for path: [String],
        pristine: [String: Any],
        common: [String: Any],
        managed: [String: Any]
    ) -> String? {
        if value(at: path, in: managed) != nil { return "N" }
        let inCommon = value(at: path, in: common) != nil
        if inCommon, value(at: path, in: pristine) != nil { return "O" }
        if inCommon { return "C" }
        return nil
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        guard !path.isEmpty else { return object }
        var current: Any = object
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    private static func jsonKey(in trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("\""),
              let closingQuote = trimmedLine.dropFirst().firstIndex(of: "\""),
              trimmedLine[trimmedLine.index(after: closingQuote)...].hasPrefix(":") else {
            return nil
        }
        return String(trimmedLine[trimmedLine.index(trimmedLine.startIndex, offsetBy: 1)..<closingQuote])
    }

    private static func containsContainerStart(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let tail = line[line.index(after: colon)...]
        return tail.contains("{") || tail.contains("[")
    }
}
