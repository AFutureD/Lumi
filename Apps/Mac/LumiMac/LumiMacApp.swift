import AppKit
import MacFeature

@main
@MainActor
final class LumiMacApp: NSObject, NSApplicationDelegate {
    private let coordinator = ApplicationCoordinator()
    private var isPreparingToTerminate = false

    static func main() {
        ApplicationCoordinator.bootstrapLogging()
        let application = NSApplication.shared
        let delegate = LumiMacApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    /// Relaunching the app (Finder, Spotlight, Dock) while it is resident
    /// reopens the main window — and with it the Dock icon hidden on close.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.showMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else { return .terminateLater }
        isPreparingToTerminate = true
        Task {
            await coordinator.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
