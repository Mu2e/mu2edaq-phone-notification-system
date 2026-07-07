# Mu2e Notify — iOS app

SwiftUI app (iOS 16+) that receives Mu2e DAQ push notifications and
shows an event dashboard.

## Build

```bash
brew install xcodegen
cd Mu2eNotify
xcodegen generate
open Mu2eNotify.xcodeproj
```

Before building for a device:

1. Set `DEVELOPMENT_TEAM` in `project.yml` (your Apple Developer team ID)
   and re-run `xcodegen generate`.
2. The bundle id `gov.fnal.mu2e.Mu2eNotify` must match `apns.bundle_id`
   in the server's `config/notify-server.yaml`, and the App ID must have
   the Push Notifications capability in the developer portal.
3. `Sources/Mu2eNotify.entitlements` uses `aps-environment: development`;
   switch to `production` for TestFlight/App Store builds and set
   `apns.sandbox: false` on the server.

## Enrollment flow

1. Server web UI → **Devices → Enroll a new phone** (shows a QR code and
   a one-time auto-configuration URL, valid ~30 minutes).
2. In the app: **Scan QR code** (or paste the URL). The app POSTs to
   `/api/devices/register` with the enrollment token and receives its
   permanent device bearer token.
3. The app requests push permission and uploads its APNs token via
   `/api/devices/token` (also whenever Apple rotates it).
4. Settings tab: device name and minimum severity, synced to the server.

## Tests

Run the `Mu2eNotifyTests` scheme in Xcode (XCTest): model decoding,
severity ordering, and enrollment-QR parsing.
