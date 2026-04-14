import SwiftUI
import Combine

// MARK: - Navigation (used by AppState.selectedSection)

enum AppSection: String, Hashable {
    case dashboard
    case providers
    case costTracking
    case proxyManagement
    case proxyStats
    case inbox
    case settings
}

// MARK: - Quota card appearance

enum CardQuotaIndicatorStyle: String, CaseIterable {
    case bar
    case ring
    case segments
}

enum CardQuotaIndicatorMetric: String, CaseIterable {
    case remaining
    case used
}

// MARK: - AppSettings

/// User-facing preferences persisted in `UserDefaults` (non-secret): theme, language, refresh cadence, remote backend, quota card UI.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let supportedAutoRefreshIntervals: [Int] = [30, 60, 180, 300, 600, 900, 1800, 3600, 0]
    static let defaultAutoRefreshInterval = 300

    static let supportedClaudeCodeRefreshIntervals: [Int] = [10, 30, 60, 180, 300, 600, 0]
    static let defaultClaudeCodeRefreshInterval = 30

    @Published var isDarkMode = UserDefaults.standard.bool(forKey: "isDarkMode")
    @Published var themeMode: String = UserDefaults.standard.string(forKey: "themeMode") ?? "system"

    var resolvedColorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    @Published var autoRefreshInterval: Int = {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: "autoRefreshInterval") != nil
            ? defaults.integer(forKey: "autoRefreshInterval")
            : AppSettings.defaultAutoRefreshInterval
        return AppSettings.normalizedAutoRefreshInterval(storedValue)
    }()

    @Published var claudeCodeRefreshInterval: Int = {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: "claudeCodeRefreshInterval") != nil
            ? defaults.integer(forKey: "claudeCodeRefreshInterval")
            : AppSettings.defaultClaudeCodeRefreshInterval
        return AppSettings.normalizedClaudeCodeRefreshInterval(storedValue)
    }()

    @Published var language: String = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
    @Published var quotaIndicatorStyle: CardQuotaIndicatorStyle = CardQuotaIndicatorStyle(rawValue: UserDefaults.standard.string(forKey: "quotaIndicatorStyle") ?? "") ?? .bar
    @Published var quotaIndicatorMetric: CardQuotaIndicatorMetric = CardQuotaIndicatorMetric(rawValue: UserDefaults.standard.string(forKey: "quotaIndicatorMetric") ?? "") ?? .remaining

    @Published var claudeCodeDailyThreshold: Double = {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: "claudeCodeDailyThreshold") != nil
            ? defaults.double(forKey: "claudeCodeDailyThreshold")
            : 0.0
        return storedValue
    }()

    /// Persisted calendar day string (YYYY-MM-DD) for Claude Code cost threshold notification de-duplication.
    var lastNotifiedDate: String? {
        get { UserDefaults.standard.string(forKey: "claudeCodeLastNotifiedDate") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeCodeLastNotifiedDate") }
    }

    @Published var backendMode: String = UserDefaults.standard.string(forKey: "backendMode") ?? "local"
    @Published var remoteHost: String = UserDefaults.standard.string(forKey: "remoteHost") ?? "127.0.0.1"
    @Published var remotePort: Int = UserDefaults.standard.integer(forKey: "remotePort") == 0 ? 4318 : UserDefaults.standard.integer(forKey: "remotePort")

    private init() {
        autoRefreshInterval = Self.normalizedAutoRefreshInterval(autoRefreshInterval)
        claudeCodeRefreshInterval = Self.normalizedClaudeCodeRefreshInterval(claudeCodeRefreshInterval)
    }

    static func normalizedAutoRefreshInterval(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        guard !supportedAutoRefreshIntervals.contains(value) else { return value }

        return supportedAutoRefreshIntervals
            .filter { $0 > 0 }
            .min(by: { abs($0 - value) < abs($1 - value) })
            ?? defaultAutoRefreshInterval
    }

    static func normalizedClaudeCodeRefreshInterval(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        guard !supportedClaudeCodeRefreshIntervals.contains(value) else { return value }

        return supportedClaudeCodeRefreshIntervals
            .filter { $0 > 0 }
            .min(by: { abs($0 - value) < abs($1 - value) })
            ?? defaultClaudeCodeRefreshInterval
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        autoRefreshInterval = Self.normalizedAutoRefreshInterval(autoRefreshInterval)
        claudeCodeRefreshInterval = Self.normalizedClaudeCodeRefreshInterval(claudeCodeRefreshInterval)
        defaults.set(autoRefreshInterval, forKey: "autoRefreshInterval")
        defaults.set(claudeCodeRefreshInterval, forKey: "claudeCodeRefreshInterval")
        defaults.set(claudeCodeDailyThreshold, forKey: "claudeCodeDailyThreshold")
        defaults.set(isDarkMode, forKey: "isDarkMode")
        defaults.set(themeMode, forKey: "themeMode")
        defaults.set(language, forKey: "appLanguage")
        defaults.set(quotaIndicatorStyle.rawValue, forKey: "quotaIndicatorStyle")
        defaults.set(quotaIndicatorMetric.rawValue, forKey: "quotaIndicatorMetric")
        defaults.set(backendMode, forKey: "backendMode")
        defaults.set(remoteHost, forKey: "remoteHost")
        defaults.set(remotePort, forKey: "remotePort")
        APIService.shared.updateBaseURL("http://\(remoteHost):\(remotePort)")
    }

    func t(_ en: String, _ zh: String) -> String {
        language == "zh" ? zh : en
    }
}
