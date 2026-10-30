// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NIBMOneDomain",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "NIBMOneDomain", targets: ["NIBMOneDomain"])],
    targets: [
        .target(name: "NIBMOneDomain", path: "NIBMOne",
                exclude: ["AppModel.swift", "ContentView.swift", "DeviceFeatures.swift", "NIBMOneApp.swift", "Info.plist"],
                sources: ["Models.swift"]),
        .testTarget(name: "NIBMOneDomainTests", dependencies: ["NIBMOneDomain"], path: "Tests")
    ]
)
