import Transport
import Foundation

/// The Usage page's day range: three presets that follow the calendar, or
/// two dates the person picked. Inclusive on both ends, never finer than a
/// day, never past today. Shared by the Mac page (which also offers
/// `custom`) and by the daemon expanding an iPhone's `UsageRangePreset`
/// with its own local calendar.
public enum UsageRangeKind: String, CaseIterable, Sendable {
    case today
    case thisWeek
    case thisMonth
    case custom

    public var title: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This week"
        case .thisMonth: "This month"
        case .custom: "Custom"
        }
    }

    public init(_ preset: UsageRangePreset) {
        switch preset {
        case .today: self = .today
        case .thisWeek: self = .thisWeek
        case .thisMonth: self = .thisMonth
        }
    }

    /// `nil` for `custom`, which the wire cannot name.
    public var preset: UsageRangePreset? {
        switch self {
        case .today: .today
        case .thisWeek: .thisWeek
        case .thisMonth: .thisMonth
        case .custom: nil
        }
    }
}

public struct UsageRange: Equatable, Sendable {
    public let kind: UsageRangeKind
    public let since: UsageDay
    public let until: UsageDay

    public init(kind: UsageRangeKind, since: UsageDay, until: UsageDay) {
        self.kind = kind
        self.since = since
        self.until = until
    }

    /// Weeks start on Monday regardless of locale — the same week the
    /// daemon buckets by (`UsageDay.startOfWeek`).
    public static func preset(_ kind: UsageRangeKind, now: Date, calendar: Calendar) -> UsageRange {
        let today = UsageDay(now, calendar: calendar)
        switch kind {
        case .today, .custom: return UsageRange(kind: kind, since: today, until: today)
        case .thisWeek: return UsageRange(kind: kind, since: today.startOfWeek(in: calendar), until: today)
        case .thisMonth: return UsageRange(kind: kind, since: today.startOfMonth, until: today)
        }
    }

    /// A wire preset expanded with this calendar — what the daemon does for
    /// an iPhone's `fetch_usage`.
    public static func expand(_ preset: UsageRangePreset, now: Date, calendar: Calendar) -> UsageRange {
        self.preset(UsageRangeKind(preset), now: now, calendar: calendar)
    }

    /// Clamped: the end never passes today, the start never passes the end.
    public static func custom(since: UsageDay, until: UsageDay, now: Date, calendar: Calendar) -> UsageRange {
        let today = UsageDay(now, calendar: calendar)
        let end = min(until, today)
        let start = min(since, end)
        return UsageRange(kind: .custom, since: start, until: end)
    }

    /// Days in the range, inclusive.
    public func dayCount(calendar: Calendar) -> Int {
        (since.days(until: until, calendar: calendar) ?? 0) + 1
    }

    /// The period the Summary's delta compares against: yesterday, the same
    /// days last week, the same days last month, or the N days before a
    /// custom range. `nil` when the calendar cannot produce one.
    public func comparison(calendar: Calendar) -> UsageRange? {
        let days = dayCount(calendar: calendar)
        switch kind {
        case .today:
            guard let yesterday = since.adding(days: -1, calendar: calendar) else { return nil }
            return UsageRange(kind: .custom, since: yesterday, until: yesterday)
        case .thisWeek:
            guard let start = since.adding(days: -7, calendar: calendar), let end = until.adding(days: -7, calendar: calendar) else { return nil }
            return UsageRange(kind: .custom, since: start, until: end)
        case .thisMonth:
            guard let lastMonthEnd = since.startOfMonth.adding(days: -1, calendar: calendar) else { return nil }
            let start = lastMonthEnd.startOfMonth
            let end = min(start.adding(days: days - 1, calendar: calendar) ?? lastMonthEnd, lastMonthEnd)
            return UsageRange(kind: .custom, since: start, until: end)
        case .custom:
            guard let start = since.adding(days: -days, calendar: calendar), let end = since.adding(days: -1, calendar: calendar) else { return nil }
            return UsageRange(kind: .custom, since: start, until: end)
        }
    }

    /// `yesterday` / `last week` / `last month` / `previous 30 days`.
    public func comparisonLabel(calendar: Calendar) -> String {
        switch kind {
        case .today: "yesterday"
        case .thisWeek: "last week"
        case .thisMonth: "last month"
        case .custom:
            dayCount(calendar: calendar) == 1 ? "previous day" : "previous \(dayCount(calendar: calendar)) days"
        }
    }
}

/// Summary's agent filter: which agent the metrics, composition bar and
/// trend describe. On the Mac only the Summary card follows it; on the
/// iPhone only the chart does.
public enum UsageSummaryAgent: String, CaseIterable, Sendable {
    case all
    case claude
    case codex

    public var title: String {
        switch self {
        case .all: "All agents"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var provider: AgentProvider? {
        switch self {
        case .all: nil
        case .claude: .claude
        case .codex: .codex
        }
    }

    public init(_ provider: AgentProvider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }
}

/// What the trend chart's y axis measures.
public enum UsageTrendMetric: String, CaseIterable, Sendable {
    case cost
    case tokens

    public var title: String {
        switch self {
        case .cost: "Cost"
        case .tokens: "Tokens"
        }
    }
}
