# NIBM ONE iOS coursework source

NIBM ONE combines employee attendance, leave and service tickets in a SwiftUI app. A Node.js/Express API uses Sequelize/MySQL and pulls T900 logs through node-zklib. The runtime source is organised in two folders:

- `IOS/`: iOS 17+ app, Xcode project, WidgetKit extension and existing XCTest domain tests.
- `backend/`: Node API, exact backup table definitions, Sequelize models and machine reader.

Start with [MARKER_GUIDE.md](MARKER_GUIDE.md) for prerequisites, manual environment configuration, test accounts, network access and app/widget setup. Read [ASSESSMENT_GAPS.md](ASSESSMENT_GAPS.md) before evaluating completeness against the assessment. This package is a snapshot of the current implementation; an Apple SDK build and several mandatory coursework criteria remain outstanding.

## Features

The monthly attendance calendar loads the signed-in EPF's records, uses Sri Lankan dates, shows first IN and last OUT, and supports month navigation and raw punch details. One distinct punch leaves OUT pending. Time spans include breaks. It does not invent absence/late results without institutional rules.

Leave supports forms, attachments, history and role-protected approval/rejection. Tickets support room/asset references, photos, comments, status history and coordinates. MapKit provides a location picker and selectable ticket pins. VisionKit/Vision support camera and saved-photo QR scanning against three sample asset codes. The embedded small/medium WidgetKit extension shares an expiring display summary and routes taps to relevant tabs.

The database uses 26 selected definitions from the supplied backup, in `backend/src/backup-schema.js`, without custom tables or columns. Device configuration comes only from `punch_machine`; punches match employees by numeric EPF. No MySQL password, production backup, attendance rows, real employee data, uploads or device communication secrets are included.

## Verification status

Earlier development runs reported 38 Node checks and six isolated MySQL integration checks. The owner intentionally removed their source directories and generated results before packaging, so those historical checks are not a runnable test suite in this archive. The existing iOS tests use XCTest; the assessment requires the student to implement Swift Testing tests instead. No replacement implementation code was generated while preparing this submission package.

The final source is exported from the commit identified in the accompanying report and FINAL_COMMIT.txt. Grant the lecturer access to the private repository and verify the exact commit URL before submitting. The report, demonstration script and recording checklist are separate deliverables outside this source archive.
