import Foundation

// MARK: - JSONC Sanitizer
// 把 JSONC（带注释、可含尾随逗号的 JSON）转换为标准 JSON 文本，供 JSONSerialization 解析。
// 仅做「去注释 + 去尾随逗号」两件事，严格尊重字符串字面量（含 \" 转义），不改动数据语义。
// 数据来源: OpenCode 的 opencode.jsonc。用途: 接管前解析；原文注释由调用方逐字备份保真还原。

enum JSONCSanitizer {
    /// 返回去除注释与尾随逗号后的标准 JSON 文本。对纯 JSON 输入是安全的近似恒等变换。
    static func sanitize(_ source: String) -> String {
        stripTrailingCommas(in: stripComments(in: source))
    }

    // MARK: - Comments

    /// 去掉 `// 行注释` 与 `/* 块注释 */`，字符串内的同形字符原样保留。行注释保留行尾换行。
    private static func stripComments(in source: String) -> String {
        let chars = Array(source)
        var result = [Character]()
        result.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "/" {
                    i += 2
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if next == "*" {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    i += 2  // 跳过结尾 */（未闭合则越界由循环条件兜底）
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return String(result)
    }

    // MARK: - Trailing commas

    /// 去掉对象/数组里最后一个元素后的尾随逗号（`,` 后仅空白即遇 `}`/`]`）。用空格中和以保持长度。
    private static func stripTrailingCommas(in source: String) -> String {
        var chars = Array(source)
        var inString = false
        var escaped = false
        var pendingComma: Int?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                pendingComma = nil
            case ",":
                pendingComma = i
            case " ", "\t", "\n", "\r":
                break  // 空白不打断「逗号 → 收尾括号」的判定
            case "}", "]":
                if let idx = pendingComma { chars[idx] = " " }
                pendingComma = nil
            default:
                pendingComma = nil
            }
            i += 1
        }
        return String(chars)
    }
}
