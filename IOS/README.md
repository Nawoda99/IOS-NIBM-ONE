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

Employee profile groups the signed-in employee's personal, employment, contact and emergency-contact information. These read-only fields come from the HR database through login and snapshot responses; pull to refresh the profile after HR changes. Missing fields display **Not provided**, and employment dates display as calendar dates. Department, employment type and grade use their master-data names. Credentials and internal file paths are excluded. Demo mode labels its sample profile and does not populate missing HR information.

The attendance calendar shows the full selected month, Monday first, with first IN and last OUT as `HH:mm` in Asia/Colombo. Previous/next arrows load that month from the authenticated API. One punch leaves OUT pending; the recorded span includes breaks. Missing dates show No record, since no absence or lateness policy has been configured. Active calendars refresh every 30 seconds. The demo login has no actual machine punches; real attendance requires an account with the employee's actual EPF.

Leave requests, attachment upload, request history and Approver decisions use the backend. Tickets, photos, comments, Support status changes and coordinates also persist in MySQL. MapKit lets the user tap a location, use current location, and open tickets from map pins. QR scanning uses VisionKit's camera scanner or Vision image recognition through **Read QR from photo**. Registered sample QR payloads are `AC-305-01`, `PROJ-B204`, `ROOM-A103`; unknown codes show an error. The simulator can use a QR image or manual entry.

## Vehicle requests and Driver mode

Open **Home > Vehicle requests** or **More > Vehicle requests**. The request form follows the supplied layout: applicant and EPF, cost code, recommendation person, place to be visited, duty status, required date, outward time, inward time and **Send for recommendation**. It adapts to iPhone and iPad widths. Dates and times use Asia/Colombo; inward time must be later on the same day. Existing overlapping requests are rejected.

The workflow is **Pending recommendation → Pending approval → Approved → Assigned → In progress → Completed**. The selected supervisor can recommend or reject; a transport manager performs final approval and assigns a registered company vehicle and an employee with login access as driver. The driver or transport manager completes the trip and ends sharing. Self-approval is blocked. Requesters can cancel before a trip starts. The backend prevents overlapping vehicle/driver assignments and multiple active trips for one vehicle or driver.

Administrators have transport management by default. The role permission screen can grant `vehicles.request`, `vehicles.recommend` and `vehicles.manage` to other existing roles. Default Employee accounts can request; default Approver accounts can recommend requests addressed to them. Roles with explicitly saved permissions need the new permissions enabled by an administrator. The recommendation selector lists other active employees with vehicle-recommendation permission; this app database does not include HRMS employee-supervisor relationships. A driver needs an assigned trip and their normal employee login; no separate driver app is required.

1. Restart the backend after updating the code. Startup with `AUTO_MIGRATE=true`, or `npm run migrate`, adds `ios_company_vehicles`, `ios_vehicle_requests` and `ios_vehicle_locations`. The backup tables are not altered. These are app transport records; they are not automatically synchronized with the separate HRMS web application's `vehicle_requests` table.
2. In **More > Company vehicles**, a transport manager adds vehicle registrations and names. In Vehicle requests, recommend and approve the request, then use **Assign vehicle and driver**.
3. The assigned driver opens **More > Driver mode**, opens the trip and chooses **Start trip and share location**. iOS requests Location permission at this point. The driver can stop/resume sharing or complete the trip. No location is collected merely by opening Driver mode. Sharing continues across navigation and app lock, with the iOS location indicator and background location capability enabled. Force-closing the app, loss of permission, sign-out or session expiry stops new uploads; resume from Driver mode as needed.
4. The requester opens their assigned request and **Track vehicle**. Transport managers can view all active vehicles on the Company vehicles map. Other employees and recommendation-only supervisors cannot access GPS positions. Driver uploads are throttled to about ten seconds, and visible maps refresh about every ten seconds. Live means a sharing position less than 90 seconds old; paused/stale positions are labeled and shown grey. Only the current driver's sharing session can update a trip. Stopping or completing revokes its key so queued uploads cannot restart sharing.

Driver phones must reach the configured API when away from the office, using a reachable HTTPS endpoint or company VPN. A LAN-only server address will not work on mobile data outside that network. The implementation uses [Apple's background location support](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates). Verify foreground, locked-screen and background GPS behavior on a physical iPhone; an Apple SDK build and real-device GPS testing require Xcode on a Mac.

`npm test` covers schedule/GPS validation, access controls, sharing revocation and the other backend features. To run the full vehicle flow against the configured `nibm_one_ios` database in PowerShell, set `$env:RUN_VEHICLE_MYSQL_TESTS='true'` then run `node --test test/vehicles.mysql.test.js` from `backend`. It applies additive migrations, verifies they are repeatable, and rolls back its test employees, vehicles and requests. Swift tests also cover time-zone boundaries, form validation, status transitions and stale-location labels.

## Punch push notifications

New punches imported from a fingerprint machine now create an in-app notification and an APNs alert for the employee whose EPF matches the punch. The app requests permission after server sign-in, registers its APNs token with the authenticated backend and shows banners while open. Tapping a punch alert opens Attendance and refreshes records. Duplicate machine reads do not create another notification. Historical imports older than 15 minutes and timestamps more than one minute in the future do not generate alerts. Unknown terminal directions are shown as “Attendance punch recorded” rather than guessing IN/OUT.

To enable delivery:

1. In Apple Developer, enable Push Notifications for the app identifier. In Xcode select your team and unique app bundle ID, keep Push Notifications enabled for the NIBMOne target, and regenerate its provisioning profile. Development signing uses sandbox APNs; TestFlight/App Store uses production. The app reads the signing profile to select the environment.
2. Create an APNs signing key (`.p8`) in Apple Developer. Store it securely on the Node server. In `backend/.env` set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` (the exact app bundle ID), and `APNS_KEY_PATH` (absolute path to the `.p8` file). Never copy these values into the iOS `.env`. Restart the backend. With `AUTO_MIGRATE=true`, startup adds `ios_push_devices` without changing existing backup tables. If automatic migration is disabled, run `npm run migrate` during setup first.
3. Install the signed app on an iPhone, sign in with the employee’s EPF and allow notifications. More > Settings > Notification settings shows registration errors and whether the server has push credentials. Use **Retry registration** after fixing connectivity or server settings.
4. Punch on the linked terminal and wait for its configured sync interval (normally one minute), plus up to five seconds for delivery processing. Test with the app open, in the background, and after closing it; tap the alert and confirm Attendance. Repeat sync to verify no duplicate. Confirm an unrelated EPF receives no alert and explicit sign-out stops notifications.

The backend needs outbound HTTPS/HTTP2 access to Apple. It retries temporary failures, records delivery state in `push_notification_outbox`, removes invalid APNs tokens, and stops retrying after eight attempts or 15 minutes. Accepted deliveries to one device are remembered when another device needs a retry. Tokens survive closing the app; explicit sign-out removes that session’s tokens, and signing another employee into the same installation transfers ownership. Notification permission is controlled in iPhone Settings. Apple credentials and a signed device are required to verify actual delivery; a simulator build alone does not verify it. See [Apple’s APNs setup](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns) and [provider request documentation](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).

Backend tests run with `npm test` in `backend`. To run the isolated MySQL integration test in PowerShell, set `$env:RUN_PUSH_MYSQL_TESTS='true'` and run `node --test test/push.mysql.test.js`. Its database account must be allowed to create and drop a temporary database named `push_test_<random ID>`; it does not use the configured application database.

## Widget setup

`NIBMOneWidget` is an embedded WidgetKit extension built with the NIBMOne scheme. It shares `NIBMOne/WidgetSummary.swift` with the app. This assignment uses app bundle ID `com.nawoda.nibmone`, widget bundle ID `com.nawoda.nibmone.Widget`, and shared App Group `group.com.nawoda.nibmone`. Select the same paid development team for both targets. Register the widget App ID and the new App Group under that team, then associate the group with both App IDs. In Xcode, select that group under Signing & Capabilities for both targets. Both entitlements files and `WidgetSummary.groupID` already use this group. Keep the published app's existing identifiers, groups and certificates as they are.

If Xcode reports that `group.com.example.NIBMOne` is unavailable, update your Mac checkout to these settings, remove that old placeholder from the assignment targets' selected App Groups, and select `group.com.nawoda.nibmone`. Click **Try Again** to regenerate the assignment provisioning profiles with automatic signing enabled. App Groups are separate registrations from App IDs: creating `com.nawoda.nibmone` alone does not create the group. See [Apple's App Group registration guide](https://developer.apple.com/help/account/identifiers/register-an-app-group). For this assignment backend, set `APNS_BUNDLE_ID=com.nawoda.nibmone`; enable Push Notifications for the app target and App ID. Only the app target needs Push Notifications.

Build and run the app, sign in, refresh, then add **NIBM ONE summary** from the Home Screen widget gallery. Small shows today's IN/OUT; Medium also shows pending leave and open-ticket counts. Tap a section to open its app tab. The cache contains display data only, no credentials or EPF. It clears on sign out/relaunch and expires at Sri Lankan midnight or after eight hours. It refreshes from app updates; iOS schedules widget rendering, so it is not a live background machine reader. This follows Apple's [shared container and timeline guidance](https://developer.apple.com/documentation/widgetkit/timelineprovider).

Open More > Settings > Home Screen widget to see whether shared storage is available. Swift tests cover summary expiry/serialization and calendar rules; they and the Apple SDK build still need to run on a Mac. Windows checks verify Swift grammar, project references and XML only.
