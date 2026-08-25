import AppKit
import Combine
import Sparkle

/// Owns Lumi's one Sparkle updater and exposes only the settings the product
/// lets people change. Sparkle remains the source of truth for persistence,
/// scheduling, menu validation, download, and installation state.
@MainActor
final class SoftwareUpdateController: ObservableObject {
    let standardController: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private var canCheckObservation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?
    private var hasStarted = false

    init(startingUpdater: Bool = false) {
        standardController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let updater = standardController.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        automaticChecksObservation = updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        standardController.startUpdater()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        standardController.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        standardController.checkForUpdates(nil)
    }

    /// The App menu targets the same controller used by Settings so Sparkle's
    /// built-in validation disables every entry while a check is in flight.
    func makeCheckForUpdatesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = standardController
        return item
    }
}
