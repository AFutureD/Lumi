import AgentStatusTransport
import Foundation
import UIKit

/// The few things the iPhone keeps outside the Keychain: the name it pairs
/// under, which Macs the Sessions filter hides, and when each Mac last
/// finished a sync. Session content itself is never written here.
@MainActor
final class LocalSettings {
    static let shared = LocalSettings()

    private let defaults: UserDefaults
    private enum Key {
        static let deviceName = "AgentStatus.deviceName"
        static let deselectedHosts = "AgentStatus.deselectedHosts"
        static let deselectedStatuses = "AgentStatus.deselectedStatuses"
        static let lastSyncByHost = "AgentStatus.lastSyncByHost"
        static let lastRelayURL = "AgentStatus.lastRelayURL"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Name sent in the pairing request ("Rename this iPhone"). Defaults to
    /// the device name.
    var deviceName: String {
        get { defaults.string(forKey: Key.deviceName) ?? UIDevice.current.name }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { defaults.removeObject(forKey: Key.deviceName) } else { defaults.set(trimmed, forKey: Key.deviceName) }
        }
    }

    /// Macs hidden by the device filter. Stored as the *deselected* set so a
    /// newly paired Mac is shown without touching the filter.
    var deselectedHosts: Set<HostID> {
        get { Set((defaults.stringArray(forKey: Key.deselectedHosts) ?? []).map(HostID.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.deselectedHosts) }
    }

    /// Status groups hidden by the `Status` filter (stored as the deselected set).
    var deselectedStatuses: Set<SessionStatusGroup> {
        get { Set((defaults.stringArray(forKey: Key.deselectedStatuses) ?? []).compactMap(SessionStatusGroup.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.deselectedStatuses) }
    }

    /// The Relay URL last typed into Add Mac › Advanced — a prefill only,
    /// never a source of trust. `nil` = the built-in default.
    var lastRelayURL: URL? {
        get { defaults.string(forKey: Key.lastRelayURL).flatMap(URL.init(string:)) }
        set {
            if let newValue { defaults.set(newValue.absoluteString, forKey: Key.lastRelayURL) } else { defaults.removeObject(forKey: Key.lastRelayURL) }
        }
    }

    func lastSync(for hostID: HostID) -> Date? {
        (defaults.dictionary(forKey: Key.lastSyncByHost) as? [String: Date])?[hostID.rawValue]
    }

    func setLastSync(_ date: Date?, for hostID: HostID) {
        var marks = (defaults.dictionary(forKey: Key.lastSyncByHost) as? [String: Date]) ?? [:]
        marks[hostID.rawValue] = date
        defaults.set(marks, forKey: Key.lastSyncByHost)
    }
}
