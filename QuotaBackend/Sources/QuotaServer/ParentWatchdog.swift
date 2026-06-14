import Foundation
import os.log

// MARK: - Parent Death Watchdog
// helper 进程必须随宿主 App（父进程）一起退出。否则 App 退出后 helper 会被
// launchd 收养成孤儿（PPID=1），占着代理端口，拖死下次启动时的代理恢复
// （旧版 OpenCode 顶部「本地代理未在运行」即源于此）。
//
// 为什么放在 helper 侧而不是 App 侧：
//   纯 SwiftUI App 的 `applicationWillTerminate` 在本工程并不可靠
//   （quit / Cmd-Q / Sparkle 更新等路径会绕过该 delegate 通知），
//   而崩溃 / 被强杀更没有任何 App 侧钩子能兜底。让 helper 自己盯住父进程，
//   才能覆盖「优雅退出 / 强制退出 / 崩溃 / 被 kill」的全部场景。
//
// 机制：
//   1) kqueue(EVFILT_PROC / NOTE_EXIT) 事件驱动——父进程一退出立即触发自杀。
//   2) getppid() 定时轮询兜底——万一 kqueue 注册失败或错过事件，
//      被收养（getppid() 变 1）时也能在数秒内收尾。
public enum ParentWatchdog {
    private static let log = Logger(subsystem: "com.aiusage.quotaserver", category: "Watchdog")

    /// 保持强引用，避免 DispatchSource 被提前释放而失效。
    private static var processSource: DispatchSourceProcess?
    private static var pollTimer: DispatchSourceTimer?

    /// 在进程启动早期调用：记录当前父进程，父进程消失即终止自身。
    public static func install() {
        let parentPID = getppid()

        // 启动时父进程已是 launchd（PPID=1）属异常：helper 本就该是 App 的子进程，
        // 此时直接退出，避免一开始就变成游离 helper。
        guard parentPID > 1 else {
            log.error("Started with no live parent (ppid=\(parentPID, privacy: .public)); exiting")
            exit(0)
        }

        log.info("Watching parent pid \(parentPID, privacy: .public)")
        installProcessExitWatch(parentPID: parentPID)
        installPollingFallback(parentPID: parentPID)
    }

    // MARK: - Internal Helpers

    /// 事件驱动：父进程退出立即触发。
    private static func installProcessExitWatch(parentPID: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: parentPID,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            log.notice("Parent \(parentPID, privacy: .public) exited; shutting down helper")
            exit(0)
        }
        source.resume()
        processSource = source
    }

    /// 轮询兜底：每 2s 复核父进程是否仍是启动时记录的那个。
    /// 一旦被收养（getppid() != 原父）说明原父已死，立即收尾。
    private static func installPollingFallback(parentPID: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            let current = getppid()
            if current != parentPID {
                log.notice("Reparented (ppid now \(current, privacy: .public)); parent gone, shutting down helper")
                exit(0)
            }
        }
        timer.resume()
        pollTimer = timer
    }
}
