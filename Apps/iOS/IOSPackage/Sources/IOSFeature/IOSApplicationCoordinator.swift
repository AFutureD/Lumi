import Remote
import Transport
import Foundation
import os
import UIKit
@preconcurrency import UserNotifications

private let pushLog = os.Logger(subsystem: "app.huanan.lumi", category: "push")

/// Owns the Relay controller and the three tabs (Sessions / Macs / Settings).
@MainActor
public final class IOSApplicationCoordinator: NSObject {
    private let settings = LocalSettings.shared
    private lazy var relay = RelayDeviceController(settings: settings)
    private let notifications = NotificationAuthorization()
    private let tabs = UITabBarController()
    private lazy var sessions = SessionsViewController(relay: relay, settings: settings)
    private lazy var macs = MacsViewController(
        relay: relay,
        settings: settings,
        onShowSessions: { [weak self] hostID in self?.showSessions(onlyFor: hostID) },
        onAddDevice: { [weak self] in self?.presentAddMac(prefill: nil) }
    )
    private lazy var settingsScreen = SettingsViewController(relay: relay, notifications: notifications)

    public override init() {
        super.init()
    }

    /// Runs inside `didFinishLaunching`, before any scene connects: the
    /// notification-center delegate must be set by then or the system drops
    /// the tap that cold-launched the app.
    public func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
        notifications.onAuthorized = {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    public func start(in window: UIWindow) {
        if ProcessInfo.processInfo.arguments.contains("-LumiPreviewData") {
            relay.usePreview(PreviewFixture.channelStates(now: Date()))
        }
        tabs.viewControllers = [sessions, macs, settingsScreen].map { screen in
            let navigation = UINavigationController(rootViewController: screen)
            navigation.navigationBar.prefersLargeTitles = true
            return navigation
        }
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        relay.start()
        Task { await notifications.refresh() }
        if let pending = pendingSession {
            pendingSession = nil
            openSession(hostID: pending.hostID, sessionID: pending.sessionID)
        }
    }

    public func resume() {
        relay.start()
        Task { await notifications.refresh() }
    }

    // MARK: - Push notifications

    /// The APNs token from the app delegate, hex-encoded, forwarded to every
    /// paired Mac's Relay.
    public func updatePushToken(_ token: Data) {
        relay.updatePushToken(token.map { String(format: "%02x", $0) }.joined())
    }

    public func pushRegistrationFailed(_ error: Error) {
        pushLog.warning("push_registration_failed: \(String(describing: error), privacy: .public)")
    }

    /// A tap can be delivered before the scene has connected (cold launch):
    /// the target waits here for `start(in:)` to replay it.
    private var pendingSession: (hostID: HostID, sessionID: SessionID)?

    private func openSession(hostID: HostID, sessionID: SessionID) {
        guard tabs.viewControllers?.isEmpty == false else {
            pendingSession = (hostID, sessionID)
            return
        }
        tabs.presentedViewController?.dismiss(animated: false)
        tabs.selectedIndex = 0
        guard let navigation = tabs.viewControllers?.first as? UINavigationController else { return }
        navigation.popToRootViewController(animated: false)
        navigation.pushViewController(
            SessionDetailViewController(relay: relay, hostID: hostID, sessionID: sessionID),
            animated: false
        )
    }

    // MARK: - Navigation

    private func showSessions(onlyFor hostID: HostID) {
        sessions.showOnly(hostID: hostID)
        (tabs.viewControllers?.first as? UINavigationController)?.popToRootViewController(animated: false)
        tabs.selectedIndex = 0
    }

    /// `lumi://pair?relay=…&code=…` from the system camera or a link:
    /// opens Add Mac with both fields filled (or hands the link to the sheet
    /// already up) and pairs straight away.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let link = PairingLink(url: url, allowInsecureLocalhost: AddMacViewController.allowsInsecureLocalhost) else { return false }
        if let addMac {
            addMac.apply(link)
        } else {
            presentAddMac(prefill: link)
        }
        return true
    }

    private weak var addMac: AddMacViewController?

    private func presentAddMac(prefill: PairingLink?) {
        guard addMac == nil else { return }
        tabs.selectedIndex = 1
        let screen = AddMacViewController(relay: relay, settings: settings, prefill: prefill) { [weak self] in
            self?.tabs.presentedViewController?.dismiss(animated: true)
        }
        addMac = screen
        let navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.preferredCornerRadius = IOSDS.Layout.cardRadius
            sheet.prefersGrabberVisible = true
        }
        (tabs.presentedViewController ?? tabs).present(navigation, animated: true)
    }
}

extension IOSApplicationCoordinator: UNUserNotificationCenterDelegate {
    /// In the foreground the live view is already on screen: no banner.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// Tapping a banner lands on the session it names. The completion must
    /// run on the main thread: UIKit does snapshot/state-restoration work
    /// there and asserts (crashing the launch) if it lands off-main — which
    /// is exactly where the async-variant bridge left it.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let target = PushNotificationRouting.session(in: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let target {
                self.openSession(hostID: target.hostID, sessionID: target.sessionID)
            } else {
                pushLog.warning("push_tap_without_session_payload")
            }
            completionHandler()
        }
    }
}
