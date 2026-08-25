import AppKit
import Sparkle
import Testing
@testable import MacFeature

@Suite(.serialized)
@MainActor
struct SoftwareUpdateControllerTests {
    @Test
    func appMenuTargetsTheSettingsUpdater() {
        let updates = SoftwareUpdateController()

        let menuItem = updates.makeCheckForUpdatesMenuItem()

        #expect(menuItem.target === updates.standardController)
        #expect(menuItem.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
    }

    @Test
    func automaticCheckSettingWritesThroughToSparkleAndPersists() async {
        let originalValue: Bool
        do {
            let updates = SoftwareUpdateController()
            originalValue = updates.standardController.updater.automaticallyChecksForUpdates
            updates.setAutomaticallyChecksForUpdates(!originalValue)
            await Task.yield()

            #expect(updates.standardController.updater.automaticallyChecksForUpdates == !originalValue)
            #expect(updates.automaticallyChecksForUpdates == !originalValue)
        }

        let relaunchedUpdates = SoftwareUpdateController()
        defer { relaunchedUpdates.setAutomaticallyChecksForUpdates(originalValue) }
        #expect(relaunchedUpdates.automaticallyChecksForUpdates == !originalValue)
    }
}
