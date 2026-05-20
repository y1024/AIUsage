import Foundation
#if canImport(Darwin)
import Darwin
#endif

extension CodexCostProvider {
    static let currencyFormatterLock = NSLock()
    static let standardCurrencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
    static let fractionalCurrencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4
        return formatter
    }()

    func parseTimestamp(_ value: String) -> Date? {
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return SharedFormatters.parseISO8601(value)
    }

    func currentScanWindow(now: Date) -> CodexScanWindow {
        let cal = calendar()
        let today = cal.startOfDay(for: now)
        let since = cal.date(byAdding: .day, value: -(Self.defaultScanDays - 1), to: today) ?? today
        let scanSince = cal.date(byAdding: .day, value: -1, to: since) ?? since
        let scanUntil = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return CodexScanWindow(
            sinceKey: dayKey(since),
            untilKey: dayKey(today),
            scanSinceKey: dayKey(scanSince),
            scanUntilKey: dayKey(scanUntil),
            dayCount: Self.defaultScanDays,
            rangeLabel: "Last \(Self.defaultScanDays) days"
        )
    }

    func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.calendar = calendar()
        comps.timeZone = timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }

    func archivedDayCount(
        _ bucketsByDay: [String: CodexAggregateBucket],
        now: Date,
        fallback: Int
    ) -> Int {
        guard let firstKey = bucketsByDay.keys.sorted().first,
              let firstDay = dateFromDayKey(firstKey) else {
            return fallback
        }
        let days = calendar().dateComponents(
            [.day],
            from: calendar().startOfDay(for: firstDay),
            to: calendar().startOfDay(for: now)
        ).day.map { $0 + 1 } ?? fallback
        return max(days, fallback)
    }

    func archivedRangeLabel(
        _ bucketsByDay: [String: CodexAggregateBucket],
        fallback: String
    ) -> String {
        let keys = bucketsByDay.keys.sorted()
        guard let first = keys.first, let last = keys.last else { return fallback }
        if first == last { return first }
        return "\(first)..\(last)"
    }

    func dayKey(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM-dd", timeZone: timeZone)
    }

    func monthKeyStr(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM", timeZone: timeZone)
    }

    func currentWeekRange(_ date: Date) -> (start: String, end: String, dayKeys: Set<String>) {
        let cal = calendar()
        let comps = cal.dateComponents(in: timeZone, from: date)
        let weekday = comps.weekday ?? 1
        let offset = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -offset, to: date) else {
            let key = dayKey(date)
            return (start: key, end: key, dayKeys: [key])
        }
        var keys = Set<String>()
        for i in 0..<7 {
            if let day = cal.date(byAdding: .day, value: i, to: monday) {
                keys.insert(dayKey(day))
            }
        }
        let end = cal.date(byAdding: .day, value: 6, to: monday).map(dayKey) ?? dayKey(monday)
        return (start: dayKey(monday), end: end, dayKeys: keys)
    }

    func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func hourBucketKey(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM-dd-HH", timeZone: timeZone)
    }

    func hourBucketLabel(_ date: Date) -> String {
        DateFormat.string(from: date, format: "HH:00", timeZone: timeZone)
    }

    func dayBucketLabel(_ date: Date) -> String {
        DateFormat.string(from: date, format: "MM/dd", timeZone: timeZone)
    }

    func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func roundUsd(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    func formatCurrency(_ value: Double) -> String {
        let formatter = value >= 1 ? Self.standardCurrencyFormatter : Self.fractionalCurrencyFormatter
        Self.currencyFormatterLock.lock()
        defer { Self.currencyFormatterLock.unlock() }
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    func relieveMallocPressure() {
        #if canImport(Darwin)
        malloc_zone_pressure_relief(nil, Int.max)
        #endif
    }
}
