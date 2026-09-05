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

    /// Days in the range, inclusive.
    func dayCount(calendar: Calendar) -> Int {
        (since.days(until: until, calendar: calendar) ?? 0) + 1
    }

    /// The period the Summary's delta compares against: yesterday, the same
    /// days last week, the same days last month, or the N days before a
    /// custom range. `nil` when the calendar cannot produce one.
    func comparison(calendar: Calendar) -> UsageRange? {
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
    func comparisonLabel(calendar: Calendar) -> String {
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
/// trend describe. Only the Summary card follows it.
enum UsageSummaryAgent: String, CaseIterable {
    case all
    case claude
    case codex

    var title: String {
        switch self {
        case .all: "All agents"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var provider: AgentProvider? {
        switch self {
        case .all: nil
        case .claude: .claude
        case .codex: .codex
        }
    }

    init(_ provider: AgentProvider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }
}

/// What the trend chart's y axis measures.
enum UsageTrendMetric: String, CaseIterable {
    case cost
    case tokens

    var title: String {
        switch self {
        case .cost: "Cost"
        case .tokens: "Tokens"
        }
    }
}

/// The Detail table's grouping dimension.
enum UsageDetailGroup: String, CaseIterable {
    case project
    case agent
    case time
    case model

    var title: String {
        switch self {
        case .project: "Project"
        case .agent: "Agent"
        case .time: "Time"
        case .model: "Model"
        }
    }
}

/// Row granularity of the Detail table under `Time`.
enum UsageDetailTimeUnit: String, CaseIterable {
    case day
    case week
    case month

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// The last choices, so the page reopens where it was left.
struct UsagePreferences {
    private static let kindKey = "Lumi.Usage.RangeKind"
    private static let sinceKey = "Lumi.Usage.CustomSince"
    private static let untilKey = "Lumi.Usage.CustomUntil"
    private static let summaryAgentKey = "Lumi.Usage.SummaryAgent"
    private static let trendMetricKey = "Lumi.Usage.TrendMetric"
    private static let detailGroupKey = "Lumi.Usage.DetailGroup"
    private static let detailTimeUnitKey = "Lumi.Usage.DetailTimeUnit"

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

    var summaryAgent: UsageSummaryAgent {
        get { defaults.string(forKey: Self.summaryAgentKey).flatMap(UsageSummaryAgent.init(rawValue:)) ?? .all }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.summaryAgentKey) }
    }

    var trendMetric: UsageTrendMetric {
        get { defaults.string(forKey: Self.trendMetricKey).flatMap(UsageTrendMetric.init(rawValue:)) ?? .cost }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.trendMetricKey) }
    }

    var detailGroup: UsageDetailGroup {
        get { defaults.string(forKey: Self.detailGroupKey).flatMap(UsageDetailGroup.init(rawValue:)) ?? .project }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.detailGroupKey) }
    }

    var detailTimeUnit: UsageDetailTimeUnit {
        get { defaults.string(forKey: Self.detailTimeUnitKey).flatMap(UsageDetailTimeUnit.init(rawValue:)) ?? .day }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.detailTimeUnitKey) }
    }
}
