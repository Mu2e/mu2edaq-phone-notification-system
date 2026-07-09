# Mu2e Notify — iOS app

SwiftUI app (iOS 16+) that receives Mu2e DAQ push notifications and
shows an event dashboard.

## Build

```bash
cd Mu2eNotify
open Mu2eNotify.xcodeproj
```

Before building for a device:

1. Set the `DEVELOPMENT_TEAM` build setting in Xcode to your Apple
   Developer team ID.
2. The bundle id `gov.fnal.mu2e.Mu2eNotify` must match `apns.bundle_id`
   in the server's `config/notify-server.yaml`, and the App ID must have
   the Push Notifications capability in the developer portal.
3. `Sources/Mu2eNotify.entitlements` uses `aps-environment: development`;
   switch to `production` for TestFlight/App Store builds and set
   `apns.sandbox: false` on the server.

`project.yml` is kept as an XcodeGen source of truth for teams that want
to regenerate the project, but `Mu2eNotify.xcodeproj` is checked in and
can be opened directly with Xcode.

## Enrollment flow

1. Server web UI → **Devices → Enroll a new phone** (shows a QR code and
   a one-time auto-configuration URL, valid ~30 minutes).
2. In the app: **Scan QR code** (or paste the URL). The app POSTs to
   `/api/devices/register` with the enrollment token and receives its
   permanent device bearer token.
3. The app requests push permission and uploads its APNs token via
   `/api/devices/token` (also whenever Apple rotates it).
4. Settings tab: device name and minimum severity, synced to the server.

## Runtime behavior

The dashboard refreshes when it opens, when the app returns to the
foreground, when a push is received, and every few seconds while the
dashboard is visible. Pull-to-refresh still forces an immediate fetch.
Each refresh also fetches `GET /api/categories`, so the category filter
chips reflect the server's configured list without a new app build.
Events display their category as a badge when set; an event with no
category shows none. Category filtering combines (AND) with the
severity filter.

The Settings tab shows three push-related states:

- **Push permission**: the iOS notification authorization state.
- **APNS token**: whether Apple has issued a token and the app has stored it.
- **Server APNS**: whether the server reports APNS enabled. `Log-only`
  means events are being recorded but the server is not sending real
  Apple push notifications yet.

## Tests

Run the `Mu2eNotifyTests` scheme in Xcode (XCTest): model decoding,
severity ordering, and enrollment-QR parsing.
