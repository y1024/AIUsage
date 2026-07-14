import SwiftUI
import AppKit

// MARK: - App Surface Tokens
// 浅色模式专用表面/描边/正文层级。避免 windowBackground ≈ controlBackground 的纯白叠纯白，
// 以及 Color.primary.opacity(0.03–0.05) 在浅色几乎不可见的问题。深色保持现有层次。

enum AppSurface {
    /// 页面底：浅色略暖灰纸面，深色用系统窗口底。
    static func page(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(nsColor: .windowBackgroundColor)
        case .light:
            fallthrough
        @unknown default:
            // 略暖的纸面灰，减轻纯白晃眼。
            return Color(red: 0.965, green: 0.961, blue: 0.953)
        }
    }

    /// 卡片/面板抬升面。
    static func card(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.055)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.995, green: 0.993, blue: 0.988)
        }
    }

    /// 芯片 / 胶囊 / 轻量行底。
    static func chip(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.primary.opacity(0.08)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.925, green: 0.918, blue: 0.908)
        }
    }

    /// 告警摘要行、次级列表行。
    static func row(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.primary.opacity(0.04)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.945, green: 0.940, blue: 0.932)
        }
    }

    /// 工具栏与页面同色带，避免再叠一层白。
    static func toolbar(_ scheme: ColorScheme) -> Color {
        page(scheme)
    }
}

enum AppStroke {
    static func card(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.10)
        case .light:
            fallthrough
        @unknown default:
            return Color.black.opacity(0.10)
        }
    }

    static func subtle(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.08)
        case .light:
            fallthrough
        @unknown default:
            return Color.black.opacity(0.08)
        }
    }
}

enum AppContent {
    /// 主标题/正文：浅色加深，避免发灰。
    static func primary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.primary
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.12, green: 0.11, blue: 0.10)
        }
    }

    /// 次要说明：浅色略深于系统 secondary。
    static func secondary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.secondary
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.38, green: 0.36, blue: 0.34)
        }
    }

    /// 时间戳等三级信息。
    static func tertiary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.secondary.opacity(0.85)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.52, green: 0.50, blue: 0.47)
        }
    }
}

extension View {
    func appPageBackground(_ scheme: ColorScheme) -> some View {
        background(AppSurface.page(scheme))
    }
}
