import Foundation

// MARK: - OpenCode Message Parsing
// message.data JSON → CodexRow（通用聚合行）。字段口径（实测 OpenCode 1.2.26）：
//   tokens.total = input + output + cache.read + cache.write；reasoning 是 output 的子集，不参与求和。
//   input 已是非缓存输入，与本项目计费口径一致（见 docs/USAGE_AND_BILLING.md 总原则）。
//   cost 为 OpenCode 按 models.dev 定价预计算的冻结值；订阅渠道（OAuth）恒 0，不按「未定价」处理。
// 所有字段防御解析：缺失按 0 / nil，schema 漂移时静默丢行而非崩溃。

extension OpenCodeCostProvider {

    /// message.data 中本 provider 关心的子集。
    struct MessageData: Decodable {
        struct Tokens: Decodable {
            struct Cache: Decodable {
                let read: Int?
                let write: Int?
            }

            let input: Int?
            let output: Int?
            let cache: Cache?
        }

        struct TimeInfo: Decodable {
            let created: Int64?
            let completed: Int64?
        }

        let role: String?
        let providerID: String?
        let modelID: String?
        let cost: Double?
        let tokens: Tokens?
        /// created/completed epoch 毫秒；二者齐备时可得单条请求耗时（节点统计页用）。
        let time: TimeInfo?
    }

    /// 解析一行 message；非 assistant、零用量或无法解码的行返回 nil。
    /// decoder 由调用方每次 fetch 创建一只并复用（避免逐行新建，也避免跨任务共享）。
    func parseMessageRow(_ row: MessageRow, decoder: JSONDecoder) -> CodexRow? {
        guard let message = try? decoder.decode(MessageData.self, from: row.data),
              message.role == "assistant" else {
            return nil
        }

        let inputTokens = message.tokens?.input ?? 0
        let outputTokens = message.tokens?.output ?? 0
        let cacheReadTokens = message.tokens?.cache?.read ?? 0
        let cacheCreateTokens = message.tokens?.cache?.write ?? 0
        let totalTokens = inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens
        let cost = message.cost ?? 0
        guard totalTokens > 0 || cost > 0 else { return nil }

        let createdAt = Date(timeIntervalSince1970: Double(row.timeCreatedMillis) / 1000)
        return CodexRow(
            dayKey: dayKey(createdAt),
            model: modelLabel(providerID: message.providerID, modelID: message.modelID),
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreateTokens: cacheCreateTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            estimatedCostUsd: cost
        )
    }

    /// 模型名口径：`providerID/modelID`，保留 OpenCode 的内部供应商维度。
    func modelLabel(providerID: String?, modelID: String?) -> String {
        let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (provider.isEmpty, model.isEmpty) {
        case (false, false): return "\(provider)/\(model)"
        case (true, false):  return model
        case (false, true):  return provider
        case (true, true):   return "unknown"
        }
    }
}
