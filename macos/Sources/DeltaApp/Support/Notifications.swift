import Foundation
import UserNotifications

private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await NotificationManager.foregroundPresentationOptions
    }
}

/// Incoming-message notifications. Only functional in a bundle build
/// (`make run-app`): UNUserNotificationCenter requires a bundle identifier,
/// so under bare `swift run` this is a silent no-op.
@MainActor
enum NotificationManager {
    private enum AuthState { case unknown, requesting, granted, denied }

    private static let available = Bundle.main.bundleURL.pathExtension == "app"
    private static let delegate = ForegroundNotificationDelegate()
    private static var auth = AuthState.unknown
    /// Messages arriving while the permission prompt is up; flushed on grant.
    private static var pending: [(chatName: String, preview: String)] = []

    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [
        .banner, .sound,
    ]

    static func install(
        available: Bool = NotificationManager.available,
        setDelegate: (any UNUserNotificationCenterDelegate) -> Void = {
            UNUserNotificationCenter.current().delegate = $0
        }
    ) {
        guard available else { return }
        setDelegate(delegate)
    }

    static func postIncoming(chatName: String, preview: String) {
        guard available else { return }
        switch auth {
        case .granted:
            deliver(chatName: chatName, preview: preview)
        case .denied:
            break
        case .requesting:
            // The prompt is user-paced; queue instead of silently dropping
            // everything that arrives before it is answered.
            pending.append((chatName, preview))
        case .unknown:
            auth = .requesting
            pending.append((chatName, preview))
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    Task { @MainActor in
                        auth = granted ? .granted : .denied
                        let queued = pending
                        pending = []
                        if granted {
                            for item in queued {
                                deliver(chatName: item.chatName, preview: item.preview)
                            }
                        }
                    }
                }
        }
    }

    private nonisolated static func deliver(chatName: String, preview: String) {
        let content = UNMutableNotificationContent()
        content.title = chatName
        content.body = preview
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
