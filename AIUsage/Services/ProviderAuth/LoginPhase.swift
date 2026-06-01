import Foundation

// MARK: - Shared Login Phase
// 所有浏览器/设备流登录协调器（Codex / Gemini / Antigravity / Copilot / Kiro）共用的阶段类型。
// 归属 Service 层：协调器只负责推进 phase；UI（ProviderLoginStatusCard）再把它映射成展示状态，
// 这样既消除了 5 份重复的 Phase 定义，也保持「服务层不反向依赖 UI 文件声明的类型」。

enum LoginPhase: Equatable {
    case idle
    case launching
    case waitingForBrowser
    case waitingForCompletion
    case succeeded
    case failed(String)
}
