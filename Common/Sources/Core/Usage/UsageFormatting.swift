import Transport
import Foundation

/// Number and name rendering shared by every Usage surface: compact token
/// counts that line up in a column, dollar costs, project names.
public enum UsageFormatting {
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
        guard let value else { return "—" }
        if value > 0, value < 0.005 { return "<$0.01" }
        return "$" + (dollars.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    /// Three significant figures with a unit — `804`, `9.99K`, `12.3K`,
    /// `804K`, `1.20M`, `19.9B` — so a column of counts reads at a glance.
    public static func tokens(_ value: Int64) -> String {
        let magnitude = Double(value.magnitude)
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (unit, suffix) in units where magnitude / unit >= 0.9995 {
            let scaled = magnitude / unit
            let decimals = scaled < 9.995 ? 2 : (scaled < 99.95 ? 1 : 0)
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

    /// `83%` — the share of `part` in `whole`; `<1%` for a sliver, `—` when
    /// there is nothing to take a share of.
    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "—" }
        let ratio = Double(part) / Double(whole)
        if ratio > 0, ratio < 0.005 { return "<1%" }
        return String(format: "%.0f%%", (ratio * 100).rounded())
    }

    /// Cache reads over everything the model processed.
    public static func cacheRatio(_ tokens: UsageTokens) -> String {
        percent(tokens.cacheRead, of: tokens.total)
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

    /// `~/Developer/lumi` — the full path with the home folder abbreviated,
    /// or `nil` when there is no path to show.
    public static func projectPath(_ workspace: String, home: String? = nil) -> String? {
        SessionPagePresentationBuilder.abbreviatedWorkspace(workspace, home: home)
    }
}
