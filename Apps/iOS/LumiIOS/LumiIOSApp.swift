import UIKit
import IOSFeature

@main
final class LumiIOSApp: UIResponder, UIApplicationDelegate {
    static let coordinator = IOSApplicationCoordinator()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The notification-center delegate must be in place before launching
        // finishes, or the tap that cold-launched the app is dropped.
        Self.coordinator.bootstrap()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.coordinator.updatePushToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Self.coordinator.pushRegistrationFailed(error)
    }
}

/// Named in the Info.plist scene manifest.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        LumiIOSApp.coordinator.start(in: window)
        for context in connectionOptions.urlContexts {
            LumiIOSApp.coordinator.open(context.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        LumiIOSApp.coordinator.resume()
    }

    /// `lumi://pair?relay=…&code=…` from the system camera or a link.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            LumiIOSApp.coordinator.open(context.url)
        }
    }
}
