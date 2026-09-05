import Core
import Transport
import Foundation

/// A segmented control's cases, each with its segment label.
protocol UsageTitled {
    var title: String { get }
}

/// The Usage page's day range: three presets that follow the calendar, or
/// two dates the person picked. Inclusive on both ends, never finer than a
/// day, never past today.
enum UsageRangeKind: String, CaseIterable, UsageTitled {
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

    /// Weeks start on Monday regardless of locale — the same week the
    /// daemon buckets by (`UsageDay.startOfWeek`).
    static func preset(_ kind: UsageRangeKind, now: Date, calendar: Calendar) -> UsageRange {
        let today = UsageDay(now, calendar: calendar)
        switch kind {
        case .today, .custom: return UsageRange(kind: kind, since: today, until: today)
        case .thisWeek: return UsageRange(kind: kind, since: today.startOfWeek(in: calendar), until: today)
        case .thisMonth: return UsageRange(kind: kind, since: today.startOfMonth, until: today)
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
enum UsageSummaryAgent: String, CaseIterable, UsageTitled {
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
enum UsageTrendMetric: String, CaseIterable, UsageTitled {
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
enum UsageDetailGroup: String, CaseIterable, UsageTitled {
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
enum UsageDetailTimeUnit: String, CaseIterable, UsageTitled {
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
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var kind: UsageRangeKind {
        get { self["Lumi.Usage.RangeKind", default: .today] }
        nonmutating set { self["Lumi.Usage.RangeKind", default: .today] = newValue }
    }

    var customRange: (since: UsageDay, until: UsageDay)? {
        get {
            guard let since = defaults.string(forKey: "Lumi.Usage.CustomSince").flatMap(UsageDay.init(rawValue:)),
                  let until = defaults.string(forKey: "Lumi.Usage.CustomUntil").flatMap(UsageDay.init(rawValue:)) else { return nil }
            return (since, until)
        }
        nonmutating set {
            defaults.set(newValue?.since.rawValue, forKey: "Lumi.Usage.CustomSince")
            defaults.set(newValue?.until.rawValue, forKey: "Lumi.Usage.CustomUntil")
        }
    }

    var summaryAgent: UsageSummaryAgent {
        get { self["Lumi.Usage.SummaryAgent", default: .all] }
        nonmutating set { self["Lumi.Usage.SummaryAgent", default: .all] = newValue }
    }

    var trendMetric: UsageTrendMetric {
        get { self["Lumi.Usage.TrendMetric", default: .cost] }
        nonmutating set { self["Lumi.Usage.TrendMetric", default: .cost] = newValue }
    }

    var detailGroup: UsageDetailGroup {
        get { self["Lumi.Usage.DetailGroup", default: .project] }
        nonmutating set { self["Lumi.Usage.DetailGroup", default: .project] = newValue }
    }

    var detailTimeUnit: UsageDetailTimeUnit {
        get { self["Lumi.Usage.DetailTimeUnit", default: .day] }
        nonmutating set { self["Lumi.Usage.DetailTimeUnit", default: .day] = newValue }
    }

    /// A raw-string enum under one key; an unknown or missing value reads as the default.
    private subscript<Value: RawRepresentable>(key: String, default fallback: Value) -> Value where Value.RawValue == String {
        get { defaults.string(forKey: key).flatMap(Value.init(rawValue:)) ?? fallback }
        nonmutating set { defaults.set(newValue.rawValue, forKey: key) }
    }
}
