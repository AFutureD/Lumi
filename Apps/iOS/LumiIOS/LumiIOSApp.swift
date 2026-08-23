import UIKit
import IOSFeature

@main
final class LumiIOSApp: UIResponder, UIApplicationDelegate {
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

    /// `lumi://pair?relay=…&code=…` from the system camera or a link.
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        coordinator.open(url)
    }
}
