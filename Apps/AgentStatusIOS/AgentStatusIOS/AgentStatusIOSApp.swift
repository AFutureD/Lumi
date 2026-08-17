import UIKit
import AgentStatusIOSFeature

@main
final class AgentStatusIOSApp: UIResponder, UIApplicationDelegate {
    private let coordinator = IOSApplicationCoordinator()
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        coordinator.start(in: window)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        coordinator.resume()
    }
}
