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
        onScan: { [weak self] in self?.presentScanner() },
        onPaste: { [weak self] in self?.pairFromPasteboard() }
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

    /// "Paste pairing code": the Mac's *Copy pairing payload* puts the same
    /// JSON the QR carries on the clipboard (Universal Clipboard or a
    /// simulator). Pairs straight away and reports the result.
    private func pairFromPasteboard() {
        guard let text = UIPasteboard.general.string,
              let offer = try? TransportCoding.makeDecoder().decode(PairingOffer.self, from: Data(text.utf8)) else {
            presentAlert(title: "Nothing to pair", message: "The clipboard does not contain an Agent Status pairing code. On the Mac, open Pair iPhone and use Copy pairing payload.")
            return
        }
        Task {
            do {
                try await relay.pair(using: offer)
                presentAlert(title: "Paired", message: "\(offer.hostName ?? "This Mac") is connected.")
            } catch {
                presentAlert(title: "Pairing failed", message: error.localizedDescription)
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (tabs.presentedViewController ?? tabs).present(alert, animated: true)
    }

    private func presentScanner() {
        let scanner = PairingScannerViewController()
        scanner.onOffer = { [weak self, weak scanner] offer in
            guard let self else { return }
            scanner?.setBusy(true)
            Task {
                do {
                    try await relay.pair(using: offer)
                    scanner?.dismiss(animated: true)
                } catch {
                    scanner?.setBusy(false)
                    scanner?.show(error: error)
                }
            }
        }
        let navigation = UINavigationController(rootViewController: scanner)
        navigation.modalPresentationStyle = .fullScreen
        navigation.overrideUserInterfaceStyle = .dark
        tabs.present(navigation, animated: true)
    }
}
