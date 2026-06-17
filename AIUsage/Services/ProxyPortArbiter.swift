import Foundation

// MARK: - Proxy Port Arbiter
// 跨 Claude / Codex / OpenCode 三条代理轨道的端口仲裁。三轨各自独立管理进程
// （ProxyRuntimeService 管 Claude/Codex，OpenCodeProxyRuntime 管 OpenCode），
// 原先冲突检测只在「同一轨道内」生效：不同轨道的节点配相同端口时无人发现，
// 启动前的 killStaleProcesses 还会把另一轨道正在运行的本 App helper 当作残留杀掉，
// 导致「激活/仅代理成功但代理实际不可用」且无任何提示。
//
// 仲裁器在任意启动/激活前提供「该端口是否已被其它正在运行的代理占用」的跨轨判定，
// 数据直接读自两条运行时的真实进程状态（无独立可变状态，避免与实际进程漂移）。

@MainActor
enum ProxyPortArbiter {
    /// 一个正在监听端口的代理节点：所属代理家族（Codex/Claude Code/OpenCode）+ 节点展示名，
    /// 用于在冲突报错中明确「哪个代理下的哪个节点」，便于用户定位。
    struct Owner {
        let id: String
        let port: Int
        /// 代理家族展示名（品牌词，不翻译）：用于「Codex 代理 / Claude Code 代理 / OpenCode 代理」。
        let track: String
        /// 节点展示名。
        let label: String
    }

    /// 当前正在监听的本 App 代理，跨三轨聚合。仅统计进程确实在运行的节点
    /// （崩溃/未起的节点不占端口，不应误报冲突）。
    static func runningPortOwners() -> [Owner] {
        ProxyViewModel.shared.runningProxyPortOwners()
            + OpenCodeProxyRuntime.shared.runningPortOwners()
    }

    /// 若目标端口已被「其它正在运行的代理」占用，返回占用方信息；否则返回 nil。
    /// `ownerId` 为正在启动/激活的节点自身 id（排除自己，幂等复用不算冲突）。
    static func conflictingOwner(forPort port: Int, excluding ownerId: String) -> Owner? {
        runningPortOwners().first { $0.id != ownerId && $0.port == port }
    }
}
