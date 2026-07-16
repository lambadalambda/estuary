import Foundation
import UserNotifications

/// Incoming-message notifications. Only functional in a bundle build
/// (`make run-app`): UNUserNotificationCenter requires a bundle identifier,
/// so under bare `swift run` this is a silent no-op.
@MainActor
enum NotificationManager {
    private static let available = Bundle.main.bundleIdentifier != nil
    private static var requested = false

    static func postIncoming(chatName: String, preview: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        if !requested {
            requested = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = chatName
        content.body = preview
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
