# Agent Status for iOS

UIKit, iOS 18+. The UI and controller logic live in `AgentStatusIOSPackage` (`AgentStatusIOSFeature`); the Xcode app target supplies the application delegate, signing, entitlements and generated Info.plist settings. Open `AgentStatus.xcworkspace` at the repository root.

## Screens

Three tabs — **Sessions** (one merged list across every paired Mac; inline large title with `···` and the system search button in the bar; `Macs` / `Status` dropdown multi-select filters; collapsible subagent groups; pull-to-refresh), **Macs** (paired Macs, swipe to remove, `+` to scan or paste a pairing code, or rename this iPhone), **Settings** (notification permission, version, clear received data). A session opens Activity (three-lane strip + timeline, tap a row for the detail sheet) / Info (metrics + Overview / Lineage / Model / Usage).

Design source: `/DESIGN SYSTEM.html` at the repo root; every product value goes through `DesignSystem.IOS` in `Common/Sources/AgentStatusDesignSystem`. System controls keep system metrics and colours.

## Data

Pairing credentials live in the Keychain. Received session content is held in memory only — every connection asks the Mac for a full resend (`hello` with sequence 0); quitting the app clears it. Opening a session sends the Mac a sealed `attention` frame (`session_reviewed`) so the green unreviewed state clears everywhere. `UserDefaults` keeps the device name used for pairing, the device-filter selection and each Mac's last sync time.

## Running without a Mac

Launch with `-AgentStatusPreviewData` to load two fixture Macs with the sessions of the design screens (no Relay traffic). Useful for screenshots and layout checks:

```bash
xcrun simctl launch booted me.afuture.AgentStatusIOS -AgentStatusPreviewData
```

## Tests

Package tests (swift-testing) run through the app scheme:

```bash
xcodebuild -workspace Apps/AgentStatusIOS/AgentStatusIOS.xcworkspace -scheme AgentStatusIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipMacroValidation -only-testing:AgentStatusIOSFeatureTests test
```

The project intentionally does not use SwiftUI.
