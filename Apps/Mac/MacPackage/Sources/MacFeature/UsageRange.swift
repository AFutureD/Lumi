import Core
import Transport
import Foundation

/// The Usage page's day range: three presets that follow the calendar, or
/// two dates the person picked. Inclusive on both ends, never finer than a
/// day, never past today.
enum UsageRangeKind: String, CaseIterable {
    case today
    case thisWeek
    case thisMonth
    case custom

    var title: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This week"
        case .thisMonth: "This month"
        case .custom: "Custom"
        }
    }
}

struct UsageRange: Equatable {
    let kind: UsageRangeKind
    let since: UsageDay
    let until: UsageDay

    /// Weeks start on Monday regardless of locale.
    static func preset(_ kind: UsageRangeKind, now: Date, calendar base: Calendar) -> UsageRange {
        var calendar = base
        calendar.firstWeekday = 2
        let today = UsageDay(now, calendar: calendar)
        switch kind {
        case .today, .custom:
            return UsageRange(kind: kind, since: today, until: today)
        case .thisWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return UsageRange(kind: kind, since: UsageDay(start, calendar: calendar), until: today)
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
            return UsageRange(kind: kind, since: UsageDay(start, calendar: calendar), until: today)
        }
    }

    /// Clamped: the end never passes today, the start never passes the end.
    static func custom(since: UsageDay, until: UsageDay, now: Date, calendar: Calendar) -> UsageRange {
        let today = UsageDay(now, calendar: calendar)
        let end = min(until, today)
        let start = min(since, end)
        return UsageRange(kind: .custom, since: start, until: end)
    }
}

/// The last choice, so the page reopens where it was left.
struct UsageRangePreferences {
    private static let kindKey = "Lumi.Usage.RangeKind"
    private static let sinceKey = "Lumi.Usage.CustomSince"
    private static let untilKey = "Lumi.Usage.CustomUntil"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var kind: UsageRangeKind {
        get { defaults.string(forKey: Self.kindKey).flatMap(UsageRangeKind.init(rawValue:)) ?? .today }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.kindKey) }
    }

    var customRange: (since: UsageDay, until: UsageDay)? {
        get {
            guard let since = defaults.string(forKey: Self.sinceKey).flatMap(UsageDay.init(rawValue:)),
                  let until = defaults.string(forKey: Self.untilKey).flatMap(UsageDay.init(rawValue:)) else { return nil }
            return (since, until)
        }
        nonmutating set {
            defaults.set(newValue?.since.rawValue, forKey: Self.sinceKey)
            defaults.set(newValue?.until.rawValue, forKey: Self.untilKey)
        }
    }
}
