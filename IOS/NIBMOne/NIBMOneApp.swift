import SwiftUI

@main
@MainActor
struct NIBMOneApp: App {
    @StateObject private var model = AppModel()
    init() { AppConfiguration.installBundledDefaults() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .onOpenURL { model.openWidgetURL($0) }
        }
    }
}
