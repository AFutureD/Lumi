import Core
import Transport
import Foundation

/// A segmented control's cases, each with its segment label.
protocol UsageTitled {
    var title: String { get }
}

// The range, agent and metric enums live in Core (`UsageRange.swift`) so
// the daemon and the iPhone share them; the Mac adds the segment titles.
extension UsageRangeKind: UsageTitled {}
extension UsageSummaryAgent: UsageTitled {}
extension UsageTrendMetric: UsageTitled {}

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
