import Testing
import UserNotifications
@testable import DeltaApp

@MainActor
@Suite struct NotificationManagerTests {
    @Test func foregroundNotificationsPresentBannerAndSound() {
        var installedDelegate: (any UNUserNotificationCenterDelegate)?
        NotificationManager.install(available: true) { installedDelegate = $0 }
        #expect(installedDelegate != nil)
        let options = NotificationManager.foregroundPresentationOptions
        #expect(options.contains(.banner))
        #expect(options.contains(.sound))
    }
}
