import Foundation
import QuotaBackend

// MARK: - Proxy Usage Archive Folding
// 把 recentLogs 折叠进永久用量归档（ProxyUsageArchiveStore）。
// 折叠语义：整日替换——重算给定日期的全量聚合并覆盖归档对应日期，保证刷新幂等、不膨胀。
// 调用时机：loadLogs 后（裁剪前）一次全量入档；每个持久化周期把脏日期增量重算入档。

extension ProxyViewModel {

    var usageArchiveStore: ProxyUsageArchiveStore { ProxyUsageArchiveStore.shared }

    /// 节点归属的用量家族。Codex 节点 → .codex，其余（anthropicDirect / openaiProxy）→ .claude。
    func usageFamily(forConfigId configId: String) -> ProxyUsageFamily {
        let isCodex = configurations.first { $0.id == configId }?.nodeType.isCodex ?? false
        return isCodex ? .codex : .claude
    }

    /// 重算给定日期集合的每日聚合并整日替换进归档。
    /// 仅遍历命中这些日期的日志，保持单次持久化周期的成本可控。
    func foldDaysIntoUsageArchive(_ dayKeys: Set<String>) {
        guard !dayKeys.isEmpty else { return }

        var perFamily: [ProxyUsageFamily: [String: ProxyUsageDay]] = [:]
        for (configId, logs) in recentLogs {
            let family = usageFamily(forConfigId: configId)
            for log in logs {
                let dayKey = shardDayKey(log.timestamp)
                guard dayKeys.contains(dayKey) else { continue }
                var day = perFamily[family]?[dayKey] ?? ProxyUsageDay()
                var agg = day.models[log.upstreamModel] ?? ProxyUsageModelAgg()
                agg.add(log)
                day.models[log.upstreamModel] = agg
                perFamily[family, default: [:]][dayKey] = day
            }
        }

        for (family, days) in perFamily {
            usageArchiveStore.replaceDays(family, days: days)
        }
    }

    /// loadLogs 之后、裁剪之前调用：把当前内存中所有日期一次性入档，
    /// 确保任何即将被裁剪的日期在丢失原始日志前已冻结进永久归档。
    func foldAllLoadedDaysIntoUsageArchive() {
        var allDays = Set<String>()
        for logs in recentLogs.values {
            for log in logs { allDays.insert(shardDayKey(log.timestamp)) }
        }
        foldDaysIntoUsageArchive(allDays)
    }
}
