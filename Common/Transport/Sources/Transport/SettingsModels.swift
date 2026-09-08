import Foundation

// Settings the daemon owns: what it must act on itself (which plan-usage
// accounts to poll) or what every client must agree on (how a percentage
// reads). They live in the daemon's `settings` table, one dotted key per
// leaf value, and cross the daemon ↔ Mac IPC boundary (`get_settings`,
// `set_settings`) and the Relay (`plan_usage` answers carry them), so the
// types live in Transport. Mac-only UI state (window widths, which Notch
// pills are shown) stays in the Mac app's own defaults.

/// Whether a plan-usage percentage reads as used or remaining. The bar
/// always draws the used share; only the number follows this.
public enum PlanUsagePercentStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case used
    case remaining
}

public struct PlanUsageSettings: Codable, Hashable, Sendable {
    /// Accounts the daemon asks the provider about. Absent = off.
    public var enabledAccounts: [PlanUsageAccountID]
    public var percentStyle: PlanUsagePercentStyle

    public init(enabledAccounts: [PlanUsageAccountID], percentStyle: PlanUsagePercentStyle) {
        self.enabledAccounts = enabledAccounts
        self.percentStyle = percentStyle
    }

    public static let defaults = PlanUsageSettings(enabledAccounts: [], percentStyle: .used)

    public func isEnabled(_ id: PlanUsageAccountID) -> Bool {
        enabledAccounts.contains(id)
    }

    private enum CodingKeys: String, CodingKey {
        case enabledAccounts
        case percentStyle
    }
}

/// Every daemon-owned setting, as one value. `set_settings` replaces the
/// whole thing; the daemon writes only the leaves that changed.
public struct DaemonSettings: Codable, Hashable, Sendable {
    public var planUsage: PlanUsageSettings

    public init(planUsage: PlanUsageSettings) {
        self.planUsage = planUsage
    }

    public static let defaults = DaemonSettings(planUsage: .defaults)

    private enum CodingKeys: String, CodingKey {
        case planUsage
    }
}
