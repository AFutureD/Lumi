import AppKit
import AgentStatusMacFeature

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
