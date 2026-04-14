import Foundation
import SwiftUI
import Combine
import QuotaBackend

// MARK: - Global Time Manager (单例，所有 View 共享一个 Timer)

class GlobalTimeManager: ObservableObject {
    static let shared = GlobalTimeManager()

    @Published var currentTime = Date()
    private var timer: AnyCancellable?
    private var activeViewCount = 0

    private init() {}

    func startIfNeeded() {
        activeViewCount += 1
        if timer == nil {
            timer = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] time in
                    self?.currentTime = time
                }
        }
    }

    func stopIfNeeded() {
        activeViewCount -= 1
        if activeViewCount <= 0 {
            timer?.cancel()
            timer = nil
            activeViewCount = 0
        }
    }
}

// MARK: - Refreshable Time Views

/// A view that displays a timestamp and automatically refreshes to keep the relative time accurate
struct RefreshableTimeView: View {
    let date: Date
    let language: String
    let font: Font
    let foregroundStyle: Color

    @StateObject private var timeManager = GlobalTimeManager.shared

    init(date: Date, language: String, font: Font = .caption2, foregroundStyle: Color = .secondary) {
        self.date = date
        self.language = language
        self.font = font
        self.foregroundStyle = foregroundStyle
    }

    private var formattedTime: String {
        // 使用 timeManager.currentTime 来触发重新计算
        _ = timeManager.currentTime
        return formatRefreshTimestamp(date, language: language)
    }

    var body: some View {
        Text(formattedTime)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .onAppear {
                timeManager.startIfNeeded()
            }
            .onDisappear {
                timeManager.stopIfNeeded()
            }
    }
}

// MARK: - Shared Formatting Utilities

func formatRelativeTime(_ isoString: String, language: String) -> String {
    guard let date = parseISO8601(isoString) else { return "" }
    let interval = Date().timeIntervalSince(date)
    let isZh = language == "zh"

    if interval < 60 {
        return isZh ? "刚刚" : "Just now"
    } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return isZh ? "\(minutes) 分钟前" : "\(minutes)m ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return isZh ? "\(hours) 小时前" : "\(hours)h ago"
    } else {
        let days = Int(interval / 86400)
        return isZh ? "\(days) 天前" : "\(days)d ago"
    }
}

func formatRelativeTimeFromDate(_ date: Date, language: String) -> String {
    let isZh = language == "zh"
    return isZh
        ? "最近活跃 \(date.formatted(.relative(presentation: .named)))"
        : "Last seen \(date.formatted(.relative(presentation: .named)))"
}

func formatRefreshTimestamp(_ date: Date, language: String) -> String {
    let locale = Locale(identifier: language == "zh" ? "zh_CN" : "en_US_POSIX")
    let clock = DateFormat.formatter("HH:mm:ss", timeZone: .current, locale: locale).string(from: date)
    return "\(formatRelativeRefreshTime(date, language: language)) · \(clock)"
}

func formatRefreshTimestamp(_ isoString: String, language: String) -> String {
    guard let date = parseISO8601(isoString) else { return "" }
    return formatRefreshTimestamp(date, language: language)
}

func formatRelativeRefreshTime(_ date: Date, language: String) -> String {
    let interval = max(0, Date().timeIntervalSince(date))
    let isZh = language == "zh"

    if interval < 60 {
        let seconds = max(1, Int(interval.rounded(.down)))
        return isZh ? "\(seconds) 秒前" : "\(seconds)s ago"
    } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return isZh ? "\(minutes) 分钟前" : "\(minutes)m ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return isZh ? "\(hours) 小时前" : "\(hours)h ago"
    } else {
        let days = Int(interval / 86400)
        return isZh ? "\(days) 天前" : "\(days)d ago"
    }
}

func formatCurrency(_ value: Double) -> String {
    let displayCurrency = UserDefaults.standard.string(forKey: "displayCurrency") ?? "USD"
    let usdToCnyRate: Double = 7.3

    let displayValue = displayCurrency == "CNY" ? value * usdToCnyRate : value
    let symbol = displayCurrency == "CNY" ? "¥" : "$"

    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencySymbol = symbol
    formatter.minimumFractionDigits = displayValue >= 1 ? 2 : 4
    formatter.maximumFractionDigits = displayValue >= 1 ? 2 : 4
    return formatter.string(from: NSNumber(value: displayValue)) ?? "\(symbol)0.00"
}

extension Int {
    func clamped(to range: ClosedRange<Int>, fallback: Int) -> Int {
        if self == 0 { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

func formatCompactNumber(_ value: Double) -> String {
    if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return String(format: "%.0f", value)
}

func formatNumber(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func parseISO8601(_ value: String) -> Date? {
    SharedFormatters.parseISO8601(value)
}

func membershipBadgeTint(for label: String?) -> Color {
    guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
          !label.isEmpty else {
        return Color(red: 0.55, green: 0.60, blue: 0.68)
    }

    let normalized = label.lowercased()

    if normalized.contains("enterprise") {
        return Color(red: 0.78, green: 0.25, blue: 0.34)
    }
    if normalized.contains("business") || normalized.contains("team") {
        return Color(red: 0.85, green: 0.61, blue: 0.15)
    }
    if normalized.contains("ultra") || normalized.contains("max") || normalized.contains("premium") {
        return Color(red: 0.73, green: 0.32, blue: 0.88)
    }
    if normalized.contains("pro") {
        return Color(red: 0.16, green: 0.74, blue: 0.46)
    }
    if normalized.contains("plus") {
        return Color(red: 0.36, green: 0.47, blue: 0.98)
    }
    if normalized.contains("hobby") {
        return Color(red: 0.17, green: 0.70, blue: 0.72)
    }
    if normalized.contains("free") {
        return Color(red: 0.55, green: 0.60, blue: 0.68)
    }
    if normalized.contains("local") {
        return Color(red: 0.42, green: 0.49, blue: 0.58)
    }

    return Color(red: 0.39, green: 0.60, blue: 0.93)
}

func preferredAccountIdentityLabel(_ candidates: [String?], excluding excluded: String? = nil) -> String? {
    let normalizedExcluded = excluded?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    let cleaned = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }

    guard !cleaned.isEmpty else { return nil }

    let prioritized = (cleaned.first { $0.contains("@") } ?? cleaned.first)
        .flatMap { label in
            label == normalizedExcluded ? nil : label
        }

    if let prioritized {
        return prioritized
    }

    return cleaned.first { $0 != normalizedExcluded }
}

func accountIdentityIcon(for _: String?) -> String {
    "person.crop.circle"
}
