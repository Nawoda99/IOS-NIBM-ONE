# NIBM ONE - SwiftUI MVP

This folder contains a native SwiftUI implementation based on the supplied proposal and prototype screen list. It covers the approved-MVP-shaped flows: sign-in, dashboard, attendance and punch records, leave balances/applications/history, tickets, QR entry point, map pins, notifications, profile, settings and sign-out.

## Open in Xcode

1. Create a new iOS App project in Xcode named `NIBMOne` using SwiftUI and Swift.
2. Replace the generated app source with the files in this folder and add `Info.plist` values to the target.
3. Set the deployment target to iOS 17 or later.
4. Run on the simulator. Camera QR scanning, Face ID, location permission, WidgetKit, App Intents, APNs and the Vapor/MySQL API are integration points for the next phase.

The sample data is intentionally local because the proposal states that the prototype uses sample records. The `AppModel` is the seam for replacing local data with `URLSession`/`Codable` services and authenticated backend routes.
