import SwiftUI
import UserNotifications

@main
@MainActor
struct NIBMOneApp: App {
    @UIApplicationDelegateAdaptor(PushNotifications.self) private var push
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @StateObject private var driverTracker = DriverLocationTracker()
    init() { AppConfiguration.installBundledDefaults() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(push)
                .environmentObject(driverTracker)
                .preferredColorScheme(.light)
                .onOpenURL { model.openWidgetURL($0) }
                .task(id: model.isAuthenticated) {
                    if model.isAuthenticated && model.isRemoteSession {
                        await configureNotifications(requestPermission: true)
                        openNotification()
                    }
                }
                .onChange(of: push.deviceToken) { _, _ in Task { await syncPushToken() } }
                .onChange(of: model.isAuthenticated) { _, authenticated in
                    if !authenticated { driverTracker.stop(notifyServer: false) }
                }
                .onChange(of: push.receivedEvent) { _, _ in
                    openNotification()
                    Task { await model.refreshRemote() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && model.isAuthenticated && model.isRemoteSession {
                        Task { await configureNotifications(requestPermission: false); await model.refreshRemote() }
                    }
                }
        }
    }

    private func configureNotifications(requestPermission: Bool) async {
        try? await push.register(requestPermission: requestPermission)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied { await model.disablePushDevice() }
        else { await syncPushToken() }
    }

    private func syncPushToken() async {
        if let token = push.deviceToken {
            await model.registerPushDevice(token: token, environment: PushNotifications.environment)
        }
    }

    private func openNotification() {
        guard model.isAuthenticated, let destination = push.openedDestination else { return }
        model.openPushDestination(destination)
        push.consumeDestination()
    }
}
