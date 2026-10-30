import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class PushNotifications: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var deviceToken: String?
    @Published private(set) var registrationError: String?
    @Published private(set) var receivedEvent = UUID()
    @Published private(set) var openedDestination: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func register(requestPermission: Bool) async throws {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if requestPermission && settings.authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        registrationError = nil
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        registrationError = nil
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        registrationError = error.localizedDescription
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                          withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in self.receivedEvent = UUID() }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                          withCompletionHandler completionHandler: @escaping () -> Void) {
        let destination = response.notification.request.content.userInfo["destination"] as? [String: Any]
        let route = ["attendance", "leave", "ticket"].first { destination?[$0] != nil }
        Task { @MainActor in
            self.openedDestination = route
            self.receivedEvent = UUID()
        }
        completionHandler()
    }

    func consumeDestination() { openedDestination = nil }

    static var environment: String {
        // Read the actual signing entitlement, including Release builds signed for development.
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let profile = try? Data(contentsOf: url),
           let start = profile.range(of: Data("<plist".utf8)),
           let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
           let plist = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil),
           let values = plist as? [String: Any], let entitlements = values["Entitlements"] as? [String: Any],
           let environment = entitlements["aps-environment"] as? String {
            return environment == "production" ? "production" : "sandbox"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}
