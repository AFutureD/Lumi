import AgentStatusRemote
import AgentStatusTransport
import Foundation
import UIKit

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

    public func start(in window: UIWindow) {
        if ProcessInfo.processInfo.arguments.contains("-AgentStatusPreviewData") {
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
    }

    public func resume() {
        relay.start()
        Task { await notifications.refresh() }
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
