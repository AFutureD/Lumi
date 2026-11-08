import Core
import Transport
import Foundation
import UIKit

/// The few things the iPhone keeps outside the Keychain: the name it pairs
/// under, which Macs the Sessions filter hides, when each Mac last finished
/// a sync, and per held session the sync mark (the daemon's timeline facts
/// at the last sync and the loaded window). Session content itself is
/// never written here.
@MainActor
final class LocalSettings {
    static let shared = LocalSettings()

    private let defaults: UserDefaults
    private enum Key {
        static let deviceName = "Lumi.deviceName"
        static let deselectedHosts = "Lumi.deselectedHosts"
        static let deselectedStatuses = "Lumi.deselectedStatuses"
        static let lastSyncByHost = "Lumi.lastSyncByHost"
        static let lastRelayURL = "Lumi.lastRelayURL"
        static let syncMarksByHost = "Lumi.syncMarksByHost"
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

    // MARK: - Sync marks

    /// The marks of every session this iPhone holds rows of, per Mac.
    func syncMarks(for hostID: HostID) -> [SessionID: SessionSyncMark] {
        guard let data = defaults.data(forKey: Key.syncMarksByHost),
              let all = try? JSONDecoder().decode([String: [String: SessionSyncMark]].self, from: data),
              let marks = all[hostID.rawValue] else { return [:] }
        return Dictionary(uniqueKeysWithValues: marks.map { (SessionID($0.key), $0.value) })
    }

    /// Replaces the Mac's marks wholesale (the channel owns them in memory
    /// and writes them through after each change).
    func setSyncMarks(_ marks: [SessionID: SessionSyncMark], for hostID: HostID) {
        var all = (defaults.data(forKey: Key.syncMarksByHost))
            .flatMap { try? JSONDecoder().decode([String: [String: SessionSyncMark]].self, from: $0) } ?? [:]
        if marks.isEmpty {
            all[hostID.rawValue] = nil
        } else {
            all[hostID.rawValue] = Dictionary(uniqueKeysWithValues: marks.map { ($0.key.rawValue, $0.value) })
        }
        if all.isEmpty {
            defaults.removeObject(forKey: Key.syncMarksByHost)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Key.syncMarksByHost)
        }
    }
}
