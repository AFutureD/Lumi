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

// MARK: - Weeks and months

public extension UsageDay {
    /// The Monday on or before this day — weeks start on Monday whatever
    /// the locale says (the Usage page's "This week" agrees).
    func startOfWeek(in calendar: Calendar = .current) -> UsageDay {
        guard let start = start(in: calendar) else { return self }
        let weekday = calendar.component(.weekday, from: start) // 1 = Sunday
        let sinceMonday = (weekday + 5) % 7
        return adding(days: -sinceMonday, calendar: calendar) ?? self
    }

    func endOfWeek(in calendar: Calendar = .current) -> UsageDay {
        startOfWeek(in: calendar).adding(days: 6, calendar: calendar) ?? self
    }

    var startOfMonth: UsageDay { UsageDay(year: year, month: month, day: 1) }

    func endOfMonth(in calendar: Calendar = .current) -> UsageDay {
        guard let start = startOfMonth.start(in: calendar),
              let days = calendar.range(of: .day, in: .month, for: start)?.count else { return self }
        return UsageDay(year: year, month: month, day: days)
    }
}

public extension UsagePeriod {
    /// The slot a moment on `day` (at `hour`) falls in.
    init(unit: UsagePeriodUnit, containing day: UsageDay, hour: Int, calendar: Calendar = .current) {
        switch unit {
        case .hour: self.init(unit: .hour, start: day, hour: hour)
        case .day: self.init(unit: .day, start: day)
        case .week: self.init(unit: .week, start: day.startOfWeek(in: calendar))
        case .month: self.init(unit: .month, start: day.startOfMonth)
        }
    }
}
