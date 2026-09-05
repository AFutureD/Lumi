import Transport
import Foundation

/// Number and name rendering shared by every Usage surface: compact token
/// counts that line up in a column, dollar costs, project names.
public enum UsageFormatting {
    /// What a table shows where there is no value: an unpriced cost, an
    /// undefined ratio, a missing date.
    public static let dash = "—"

    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let dollars: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter
    }()

    /// `$1,234.56`; under a cent but not zero reads `<$0.01`; `nil` (no
    /// published price) reads `—`.
    public static func cost(_ value: Double?) -> String {
        guard let value else { return dash }
        if value > 0, value < 0.005 { return "<$0.01" }
        return "$" + (dollars.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    /// Compact with a unit — `804`, `12.4K`, `804.0K`, `795.3M`, `1.10B`:
    /// one decimal for K and M, two for B and T (the design's format), so a
    /// column of counts reads at a glance.
    public static func tokens(_ value: Int64) -> String {
        let magnitude = Double(value.magnitude)
        let units: [(Double, String, Int)] = [(1e12, "T", 2), (1e9, "B", 2), (1e6, "M", 1), (1e3, "K", 1)]
        for (unit, suffix, decimals) in units where magnitude / unit >= 0.9995 {
            let scaled = magnitude / unit
            return (value < 0 ? "-" : "") + String(format: "%.\(decimals)f", scaled) + suffix
        }
        return String(value)
    }

    /// `41,791,377` — the exact count, for tooltips.
    public static func exactTokens(_ value: Int64) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func count(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// `83.4%` — the share of `part` in `whole` to one decimal; `<0.1%` for
    /// a sliver, `—` when there is nothing to take a share of.
    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return dash }
        let ratio = Double(part) / Double(whole)
        if ratio > 0, ratio < 0.0005 { return "<0.1%" }
        return String(format: "%.1f%%", ratio * 100)
    }

    /// `↑ 12% vs yesterday` — how `current` moved against `previous`, or
    /// `no comparable previous period` when there is nothing to compare to.
    public static func delta(current: Double?, previous: Double?, against label: String) -> String {
        guard let current, let previous, previous > 0 else { return "no comparable previous period" }
        let change = (current - previous) / previous * 100
        let arrow = change >= 0 ? "↑" : "↓"
        return "\(arrow) \(String(format: "%.0f", abs(change).rounded()))% vs \(label)"
    }

    /// Cache reads over everything the model processed.
    public static func cacheRatio(_ tokens: UsageTokens) -> String {
        percent(tokens.cacheRead, of: tokens.total)
    }

    // MARK: Dates

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let longMonths = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// `Sat` — the weekday of a day (the trend's x axis under a week).
    public static func weekday(_ day: UsageDay, calendar: Calendar = .current) -> String {
        guard let start = day.start(in: calendar) else { return "" }
        return weekdays[calendar.component(.weekday, from: start) - 1]
    }

    /// `Sat, Sep 5` — a day row / the Last active column.
    public static func dayLabel(_ day: UsageDay, calendar: Calendar = .current) -> String {
        "\(weekday(day, calendar: calendar)), \(months[day.month - 1]) \(day.day)"
    }

    /// `9/5` — the trend's x axis under a month.
    public static func monthDay(_ day: UsageDay) -> String {
        "\(day.month)/\(day.day)"
    }

    /// `Aug 31 – Sep 6` — a week row.
    public static func weekLabel(_ start: UsageDay, calendar: Calendar = .current) -> String {
        let end = start.endOfWeek(in: calendar)
        return "\(months[start.month - 1]) \(start.day) – \(months[end.month - 1]) \(end.day)"
    }

    /// `September 2026` — a month row.
    public static func monthLabel(_ day: UsageDay) -> String {
        "\(longMonths[day.month - 1]) \(day.year)"
    }

    /// `09:00` — an hour bar.
    public static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    /// The row name of a time slice: day, week or month label; an hour
    /// reads `9/5 09:00`.
    public static func periodLabel(_ period: UsagePeriod, calendar: Calendar = .current) -> String {
        switch period.unit {
        case .hour: "\(monthDay(period.start)) \(hourLabel(period.hour ?? 0))"
        case .day: dayLabel(period.start, calendar: calendar)
        case .week: weekLabel(period.start, calendar: calendar)
        case .month: monthLabel(period.start)
        }
    }

    /// The working directory's last path component — the name a project row
    /// leads with. Empty (the transcript recorded no cwd) reads as unknown.
    public static func projectName(_ workspace: String) -> String {
        let parts = workspace.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last, !last.isEmpty else {
            return workspace.isEmpty ? "Unknown project" : workspace
        }
        return String(last)
    }
}
