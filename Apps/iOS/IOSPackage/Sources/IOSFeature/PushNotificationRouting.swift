import Transport
import Foundation
@preconcurrency import UserNotifications

/// The custom half of a Lumi push payload: `{"lumi": {"hostID", "sessionID"}}`,
/// composed by the daemon and forwarded verbatim by the Relay.
enum PushNotificationRouting {
    static func session(in userInfo: [AnyHashable: Any]) -> (hostID: HostID, sessionID: SessionID)? {
        guard let lumi = userInfo["lumi"] as? [String: Any],
              let host = lumi["hostID"] as? String,
              let session = lumi["sessionID"] as? String else { return nil }
        return (HostID(host), SessionID(session))
    }

    /// Clears delivered banners for one session — opening the session read
    /// it. Matched on the full (host, session) pair: two Macs can hold
    /// sessions with the same ID.
    static func removeDelivered(hostID: HostID, sessionID: SessionID) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let matching = delivered
                .filter { notification in
                    guard let target = self.session(in: notification.request.content.userInfo) else { return false }
                    return target.hostID == hostID && target.sessionID == sessionID
                }
                .map(\.request.identifier)
            guard !matching.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: matching)
        }
    }
}
