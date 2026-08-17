import UIKit

@MainActor
public final class IOSApplicationCoordinator: NSObject {
    private let relay = RelayDeviceController()
    private lazy var root = SessionSplitViewController(relay: relay)

    public override init() {
        super.init()
    }

    public func start(in window: UIWindow) {
        window.rootViewController = root
        window.makeKeyAndVisible()
        relay.start()
    }

    public func resume() {
        relay.start()
    }

}
