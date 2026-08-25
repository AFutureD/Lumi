import UIKit
import UserNotifications

/// Push-notification permission as the Settings row shows it: not asked yet /
/// allowed / not allowed. Refreshed whenever the app comes to the foreground.
@MainActor
final class NotificationAuthorization {
    enum State: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var state: State = .notDetermined
    var onChange: (() -> Void)?
    /// Fired on every refresh that finds the permission granted (including
    /// the moment the person taps Allow), so the coordinator can register
    /// for remote notifications; registration is idempotent.
    var onAuthorized: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let next: State = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        @unknown default: .denied
        }
        if next != state {
            state = next
            onChange?()
        }
        if next == .authorized {
            onAuthorized?()
        }
    }

    /// `.notDetermined` → the system prompt; otherwise the app's notification settings.
    func handleTap() async {
        switch state {
        case .notDetermined:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refresh()
        case .authorized, .denied:
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }
}
