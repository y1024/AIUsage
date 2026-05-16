import SwiftUI

struct ProviderIconView: View {
    let providerId: String
    let size: CGFloat

    init(_ providerId: String, size: CGFloat = 32) {
        self.providerId = providerId
        self.size = size
    }

    // Map provider id → asset name (openai covers codex)
    private var assetName: String {
        switch providerId {
        case "codex", "codex-cost": return "openai"
        default: return providerId
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var brandImage: NSImage? {
        NSImage(named: assetName)
    }

    var body: some View {
        Group {
            if let img = brandImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(accentColor)
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    private var fallbackSymbol: String {
        switch providerId {
        case "antigravity": return "atom"
        case "copilot": return "chevron.left.forwardslash.chevron.right"
        case "claude":  return "sparkles"
        case "cursor":  return "cursorarrow.rays"
        case "gemini":  return "star.fill"
        case "kiro":    return "cloud.fill"
        case "codex", "codex-cost": return "brain.head.profile"
        case "droid":   return "cpu"
        case "warp":    return "terminal"
        case "amp":     return "bolt.fill"
        default:        return "cube.fill"
        }
    }

    private var accentColor: Color {
        switch providerId {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude":  return .purple
        case "cursor":  return .green
        case "gemini":  return .orange
        case "kiro":    return .purple
        case "codex", "codex-cost": return .indigo
        case "droid":   return .yellow
        case "warp":    return .pink
        case "amp":     return .teal
        default:        return .gray
        }
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
