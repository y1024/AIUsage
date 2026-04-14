import Foundation

// MARK: - Shared ISO 8601 Formatters

public enum SharedFormatters {

    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO 8601 with fractional seconds in UTC (legacy Kiro auth JSON token timestamps).
    public static let iso8601FractionalUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Parse an ISO 8601 string, trying fractional seconds first.
    public static func parseISO8601(_ value: String) -> Date? {
        if let date = iso8601WithFractional.date(from: value) { return date }
        return iso8601.date(from: value)
    }

    /// Format a Date to ISO 8601 string (standard, no fractional).
    public static func iso8601String(from date: Date) -> String {
        iso8601.string(from: date)
    }
}

// MARK: - Date Formatting Helpers

public enum DateFormat {

    /// Thread-local `DateFormatter` cache keyed by format+timeZone.
    /// `DateFormatter` is not thread-safe, so we use a per-thread cache.
    private static let threadCache: ThreadLocal<[String: DateFormatter]> = ThreadLocal(initial: [:])

    public static func formatter(_ format: String, timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "en_US_POSIX")) -> DateFormatter {
        let key = "\(format)|\(timeZone.identifier)|\(locale.identifier)"
        if let cached = threadCache.value[key] { return cached }
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = timeZone
        f.locale = locale
        threadCache.value[key] = f
        return f
    }

    public static func string(from date: Date, format: String, timeZone: TimeZone = .current) -> String {
        formatter(format, timeZone: timeZone).string(from: date)
    }

    public static func date(from string: String, format: String, timeZone: TimeZone = .current) -> Date? {
        formatter(format, timeZone: timeZone).date(from: string)
    }
}

// MARK: - ThreadLocal Helper

/// Minimal thread-local storage wrapper.
final class ThreadLocal<T>: @unchecked Sendable {
    private let key: String
    private let initial: T

    init(initial: T) {
        self.key = "ThreadLocal.\(UUID().uuidString)"
        self.initial = initial
    }

    var value: T {
        get {
            Thread.current.threadDictionary[key] as? T ?? initial
        }
        set {
            Thread.current.threadDictionary[key] = newValue
        }
    }
}
