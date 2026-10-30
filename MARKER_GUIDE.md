# NIBM ONE marker setup

This submission contains a SwiftUI iOS client and a Node.js/Sequelize/MySQL backend. It is a development submission with the gaps listed in ASSESSMENT_GAPS.md. It does not contain database passwords, production data, raw fingerprint logs or biometric templates.

## Requirements

- Mac with Xcode 16 or later for the iOS 17+ app and embedded widget.
- Node.js 22 or later and MySQL 8.0 or later for the API.
- For optional live hardware pulls, access to the same trusted network as a compatible T900 using node-zklib. Hardware is not needed to inspect the source or run the local demo.

## Configure the backend

From `backend`, run `npm ci`. Create a local `backend/.env` with the following settings, replacing the database account values privately:

```dotenv
HOST=0.0.0.0
PORT=8080
DATABASE_HOST=127.0.0.1
DATABASE_PORT=3306
DATABASE_NAME=nibm_one_ios
DATABASE_USERNAME=YOUR_MYSQL_USER
DATABASE_PASSWORD=YOUR_MYSQL_PASSWORD
DATABASE_TLS=false
AUTO_MIGRATE=true
SEED_DEMO_USERS=true
```

Run `npm start`. The MySQL account needs permission to create/use the database and create its exact selected tables. Startup uses `src/backup-schema.js` and validates existing definitions. It will reject mismatched or extra tables without deleting their data. Do not point this at the full production backup database.

The earlier environment templates and backend test directories were deliberately removed by the project owner. Therefore do not use `npm run setup`, `npm test` or `npm run test:mysql` as evidence of the final archive's verification: their expected template/test inputs are absent. Configure the environment manually as above. Existing package scripts are retained as part of the supplied implementation.

## Check access and accounts

The currently configured development API is `http://192.168.12.90:8080`. This is a private LAN address, not an internet deployment. It is usable only while the student's server is running and the marker has a network route to it. Otherwise run the supplied backend locally. No public marker URL or hosted database access has been provisioned.

Open `/health`; a healthy response identifies MySQL, Node.js and node-zklib. The sample accounts below are created only when `SEED_DEMO_USERS=true`; existing accounts are not overwritten.

| EPF | Password | Role |
| --- | --- | --- |
| 900001 | Demo@123 | Employee |
| 900002 | Manager@123 | Approver |
| 900003 | Support@123 | Support |

These are test accounts with write permissions within their role, not read-only access. Use an isolated test database for marking. The sample employee does not own actual machine punches. Register actual employees with their actual EPF and identity number to see their own machine records; do not reassign other employees' punches to a sample account.

Authenticated API routes include `/api/snapshot`, `/api/attendance?month=YYYY-MM`, `/api/leave`, `/api/tickets` and privileged `/api/machines`. Obtain a token from `POST /api/login` with JSON fields `epfNo` and `password`, then use `Authorization: Bearer TOKEN`. Use `POST /api/logout` when finished. Tokens expire after eight hours.

## Run the iOS app

The ZIP includes public `IOS/.env` values for the current LAN server. Change its `API_BASE_URL` to your API host, keep `USE_MYSQL_BACKEND=true`, and rebuild. Use `http://localhost:8080` only when the backend is running on the simulator's Mac. A physical iPhone must use the server's reachable LAN address and allow Local Network access. A changed HTTP IP also needs its scoped ATS exception updated in `NIBMOne/Info.plist`.

Open `IOS/NIBMOne.xcodeproj`, choose the NIBMOne scheme and an iOS simulator, then build. Run `bash IOS/scripts/verify-macos.sh` from the repository root for the existing Swift package tests and simulator build. Those tests currently use XCTest; this does not meet the assessment's Swift Testing requirement. Neither they nor an Apple SDK build have been run on this Windows packaging host.

For an offline UI demonstration, turn off Use MySQL backend on the login screen and use 900001 / Demo@123. The role picker in this mode controls sample data only; it is not a live backend role switch.

## Fingerprint and advanced features

Machine configuration comes only from MySQL's `punch_machine` table. The student's T900 is row 24 at 192.168.12.15:4370. Enable polling with its active and sync_enabled flags; the backend rereads settings before connecting. A clean database intentionally contains no automatically registered machine. Do not create a hardware row unless you have permission to contact that machine.

Daily times use the first distinct punch as IN and last distinct punch as OUT, in Asia/Colombo. One timestamp leaves OUT pending. The elapsed span includes breaks. Unknown terminal direction codes are preserved independently.

MapKit supports attaching a chosen/current location to a ticket and selecting its map pin. VisionKit scans camera QR codes; Vision can detect a QR in a saved image. Registered sample payloads are AC-305-01, PROJ-B204 and ROOM-A103. A live asset registry API is not configured.

For WidgetKit, select the same signing team on the app and extension. Use unique bundle identifiers and a registered App Group, and put the same group identifier in both entitlements and WidgetSummary.groupID. The placeholder group is group.com.example.NIBMOne. Add the small or medium NIBM ONE summary widget after signing in and refreshing the app. Its display cache holds no credentials; it clears on logout/relaunch and expires at midnight/eight hours. iOS schedules widget refreshes.

## Repository and privacy

The report records the exact submission branch and commit. The source ZIP is exported from that commit using git archive. Grant the lecturer access to the private GitHub repository through GitHub; repository visibility and lecturer membership have not been changed by packaging. Real `.env` secrets, uploads, database rows and attendance logs are excluded from the archive.
