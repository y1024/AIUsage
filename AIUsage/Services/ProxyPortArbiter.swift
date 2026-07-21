import Foundation

// MARK: - Proxy Port Arbiter
// 跨 Claude / Codex / OpenCode / Science 各代理运行时的端口仲裁。各轨独立管理进程
// （ProxyRuntimeService 管 Claude/Codex，OpenCodeProxyRuntime 管 OpenCode），
// 原先冲突检测只在「同一轨道内」生效：不同轨道的节点配相同端口时无人发现，
// 启动前的 killStaleProcesses 还会把另一轨道正在运行的本 App helper 当作残留杀掉，
// 导致「激活/仅代理成功但代理实际不可用」且无任何提示。
//
// 仲裁器在任意启动/激活前提供「目标端口是否已被其它正在运行的代理占用」的跨轨判定，
// 数据直接读自两条运行时的真实进程状态（无独立可变状态，避免与实际进程漂移）。
// 端口以「集合」比较：开启 HTTPS 的节点同时占用 HTTP 与 HTTPS 两个端口，二者都参与冲突判定。

@MainActor
enum ProxyPortArbiter {
    /// 一个正在监听端口的代理节点：所属代理家族（Codex/Claude Gateway/OpenCode/Science）+ 节点展示名，
    /// 及其实际占用的端口集合（HTTPS 节点含两个端口）。
    struct Owner {
        let id: String
        let ports: [Int]
        /// 代理家族展示名，用于精确说明端口的实际占用方。
        let track: String
        /// 节点展示名。
        let label: String
    }

    /// 端口冲突命中结果：具体冲突的端口 + 占用方家族/节点名，供报错精确定位。
    struct Conflict {
        let port: Int
        let track: String
        let label: String
    }

    /// 当前正在监听的本 App 代理，跨各轨 + Gateway 聚合。仅统计进程确实在运行的节点
    /// （崩溃/未起的节点不占端口，不应误报冲突）。
    static func runningPortOwners() -> [Owner] {
        ProxyViewModel.shared.runningProxyPortOwners()
            + OpenCodeProxyRuntime.shared.runningPortOwners()
            + GlobalProxyRuntime.all.flatMap { $0.runningPortOwners() }
            + ScienceProxyManager.shared.runningPortOwners()
            + [CLIProxyRuntimeController.shared.runningPortOwner()].compactMap { $0 }
    }

    /// 若 `wantedPorts` 中任一端口已被「其它正在运行的代理」占用，返回首个冲突命中；否则 nil。
    /// `ownerId` 为正在启动/激活的节点自身 id（排除自己，幂等复用不算冲突）。
    static func conflict(forPorts wantedPorts: [Int], excluding ownerId: String) -> Conflict? {
        let wanted = Set(wantedPorts)
        guard !wanted.isEmpty else { return nil }
        for owner in runningPortOwners() where owner.id != ownerId {
            if let hit = owner.ports.first(where: { wanted.contains($0) }) {
                return Conflict(port: hit, track: owner.track, label: owner.label)
            }
        }
        return nil
    }
}
