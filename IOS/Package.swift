// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NIBMOneDomain",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "NIBMOneDomain", targets: ["NIBMOneDomain"])],
    targets: [
        .target(name: "NIBMOneDomain", path: "NIBMOne",
                exclude: ["VehicleViews.swift", "DriverLocationTracker.swift", "AppModel.swift", "APIClient.swift", "FingerprintMachineView.swift", "ContentView.swift", "DeviceFeatures.swift", "NIBMOneApp.swift", "PushNotifications.swift", "Info.plist", "NIBMOne.entitlements", "Assets.xcassets", "AdministrationViews.swift", "MapDashboard.swift"],
                sources: ["Models.swift", "AppConfiguration.swift", "WidgetSummary.swift", "VehicleModels.swift"]),
        .testTarget(name: "NIBMOneDomainTests", dependencies: ["NIBMOneDomain"], path: "Tests")
    ]
)
