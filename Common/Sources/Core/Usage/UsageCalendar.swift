import Transport
import Foundation

/// `UsageDay` ↔ `Date` under one calendar. The daemon buckets by the local
/// day of the record's timestamp; the Mac derives Today / This week / This
/// month from the same calendar, so both ends agree on where a day starts.
public extension UsageDay {
    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Midnight at the start of the day, or `nil` for an impossible date
    /// (`2026-02-30`).
    func start(in calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              UsageDay(date, calendar: calendar) == self else { return nil }
        return calendar.startOfDay(for: date)
    }

    func adding(days: Int, calendar: Calendar = .current) -> UsageDay? {
        guard let start = start(in: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return UsageDay(shifted, calendar: calendar)
    }

    /// Whole days from `self` to `other` (negative when `other` is earlier).
    func days(until other: UsageDay, calendar: Calendar = .current) -> Int? {
        guard let from = start(in: calendar), let to = other.start(in: calendar) else { return nil }
        return calendar.dateComponents([.day], from: from, to: to).day
    }
}
