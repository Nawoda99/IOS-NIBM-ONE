# iOS app

Open `NIBMOne.xcodeproj` in Xcode 16+ on a Mac, choose the NIBMOne scheme and an iOS 17+ simulator. All app sources, the Xcode project, Swift domain tests and Mac verification script live in this folder.

Copy `.env.example` to `.env` if the file is missing. Running `npm run setup` from `../backend` also creates it without overwriting existing settings.

```dotenv
API_BASE_URL=http://192.168.12.90:8080
USE_MYSQL_BACKEND=true
```

Set `API_BASE_URL` to the Node PC's LAN address. Use `http://localhost:8080` only when Node runs on the same Mac as the simulator. Fingerprint machine settings belong only in MySQL's `punch_machine` table. The current HTTP exception in `NIBMOne/Info.plist` covers `192.168.12.90`; update that scoped exception if the server IP changes. Allow Local Network access when prompted on the iPhone.

Xcode copies this `.env` into the app bundle. Rebuild after editing it. A changed configuration updates the login screen defaults on the next launch; manual login-screen edits are preserved while the bundled configuration stays the same. These settings are public: never put MySQL passwords, integration keys or employee passwords in this file.

From the repository root on a Mac, run `bash IOS/scripts/verify-macos.sh` to run Swift tests and build for the simulator. For backend setup and EPF login accounts, see [the main README](../README.md).

## Attendance, Leave and Tickets

The attendance calendar shows the full selected month, Monday first, with first IN and last OUT as `HH:mm` in Asia/Colombo. Previous/next arrows load that month from the authenticated API. One punch leaves OUT pending; the recorded span includes breaks. Missing dates show No record, since no absence or lateness policy has been configured. Active calendars refresh every 30 seconds. The demo login has no actual machine punches; real attendance requires an account with the employee's actual EPF.

Leave requests, attachment upload, request history and Approver decisions use the backend. Tickets, photos, comments, Support status changes and coordinates also persist in MySQL. MapKit lets the user tap a location, use current location, and open tickets from map pins. QR scanning uses VisionKit's camera scanner or Vision image recognition through **Read QR from photo**. Registered sample QR payloads are `AC-305-01`, `PROJ-B204`, `ROOM-A103`; unknown codes show an error. The simulator can use a QR image or manual entry.

## Widget setup

`NIBMOneWidget` is an embedded WidgetKit extension built with the NIBMOne scheme. It shares `NIBMOne/WidgetSummary.swift` with the app. Select the same development team for both targets. Before a signed device build, set unique bundle IDs (the widget ID must begin with the app ID), register an App Group for your team, and set that same group in both entitlements files and `WidgetSummary.groupID`. The checked-in placeholder is `group.com.example.NIBMOne`. Keep App Groups enabled under Signing & Capabilities for both targets.

Build and run the app, sign in, refresh, then add **NIBM ONE summary** from the Home Screen widget gallery. Small shows today's IN/OUT; Medium also shows pending leave and open-ticket counts. Tap a section to open its app tab. The cache contains display data only, no credentials or EPF. It clears on sign out/relaunch and expires at Sri Lankan midnight or after eight hours. It refreshes from app updates; iOS schedules widget rendering, so it is not a live background machine reader. This follows Apple's [shared container and timeline guidance](https://developer.apple.com/documentation/widgetkit/timelineprovider).

Open More > Settings > Home Screen widget to see whether shared storage is available. Swift tests cover summary expiry/serialization and calendar rules; they and the Apple SDK build still need to run on a Mac. Windows checks verify Swift grammar, project references and XML only.
