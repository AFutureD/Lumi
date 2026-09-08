import Transport
import Foundation

/// The daemon's settings table: one row per leaf value under a dotted key
/// (`plan_usage.percent_style`), the value JSON-encoded. Settings that only
/// shape the Mac app's own windows stay in the app's defaults; what lands
/// here is what the daemon acts on or what every device must agree on.
public protocol SettingsStore: Sendable {
    func settings() async throws -> DaemonSettings
    /// Writes only the leaves that differ from what is stored.
    func replace(_ settings: DaemonSettings) async throws
}

/// The dotted keys and their JSON forms — the one place that knows how
/// `DaemonSettings` spreads over rows. Missing rows read as the defaults.
public enum SettingsKeys {
    public static let planUsagePercentStyle = "plan_usage.percent_style"
    public static let planUsageEnabledPrefix = "plan_usage.enabled."

    public static func planUsageEnabled(_ id: PlanUsageAccountID) -> String {
        planUsageEnabledPrefix + id.rawValue
    }

    /// Every row a settings value produces, in a stable order.
    public static func rows(_ settings: DaemonSettings) throws -> [(key: String, value: Data)] {
        let encoder = TransportCoding.makeEncoder()
        var rows: [(String, Data)] = [
            (planUsagePercentStyle, try encoder.encode(settings.planUsage.percentStyle)),
        ]
        for id in [PlanUsageAccountID.claude, .codex] {
            rows.append((planUsageEnabled(id), try encoder.encode(settings.planUsage.isEnabled(id))))
        }
        for id in settings.planUsage.enabledAccounts where id != .claude && id != .codex {
            rows.append((planUsageEnabled(id), try encoder.encode(true)))
        }
        return rows.map { (key: $0.0, value: $0.1) }
    }

    /// The settings a row set describes; unknown keys are ignored, a value
    /// that fails to decode is an error (never silently the default).
    public static func settings(rows: [(key: String, value: Data)]) throws -> DaemonSettings {
        let decoder = TransportCoding.makeDecoder()
        var result = DaemonSettings.defaults
        var enabled: [PlanUsageAccountID] = []
        for row in rows.sorted(by: { $0.key < $1.key }) {
            if row.key == planUsagePercentStyle {
                result.planUsage.percentStyle = try decoder.decode(PlanUsagePercentStyle.self, from: row.value)
            } else if row.key.hasPrefix(planUsageEnabledPrefix) {
                let id = PlanUsageAccountID(rawValue: String(row.key.dropFirst(planUsageEnabledPrefix.count)))
                if try decoder.decode(Bool.self, from: row.value) { enabled.append(id) }
            }
        }
        result.planUsage.enabledAccounts = enabled
        return result
    }
}

public actor InMemorySettingsStore: SettingsStore {
    private var stored: DaemonSettings

    public init(_ settings: DaemonSettings = .defaults) {
        stored = settings
    }

    public func settings() async throws -> DaemonSettings { stored }

    public func replace(_ settings: DaemonSettings) async throws {
        // Round-trip through rows so both stores normalise the same way.
        stored = try SettingsKeys.settings(rows: SettingsKeys.rows(settings))
    }
}
