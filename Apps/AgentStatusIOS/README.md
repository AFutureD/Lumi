# Agent Status for iOS

UIKit, iOS 18+. The UI and controller logic live in `AgentStatusIOSPackage` (`AgentStatusIOSFeature`); the Xcode app target supplies the application delegate, signing, entitlements and generated Info.plist settings. Open `AgentStatus.xcworkspace` at the repository root.

## Screens

Three tabs — **Sessions** (one merged list across every paired Mac; inline large title with `···` and the system search button in the bar; `Macs` / `Status` dropdown multi-select filters; collapsible subagent groups; pull-to-refresh), **Macs** (paired Macs, swipe to remove, `+` to scan or paste a pairing code, or rename this iPhone), **Settings** (notification permission, version, clear received data). A session opens Activity (three-lane strip + timeline, tap a row for the detail sheet) / Info (metrics + Overview / Lineage / Model / Usage).

Design source: `/DESIGN SYSTEM.html` at the repo root; every product value goes through `DesignSystem.IOS` in `Common/Sources/AgentStatusDesignSystem`. System controls keep system metrics and colours.

## Data

Pairing credentials live in the Keychain. Each paired Mac gets its own SQLite cache (`Application Support/Agent Status/Channels/<hostID>.sqlite3`, the shared `SQLiteSessionRepository` schema) that is shown immediately at launch; the Mac's daemon is the source of truth. On connect the iPhone sends a sealed `request` (`sync_index`), reconciles the returned index against the cache (`SyncReconcilePlan`: prune / fetch whole / fetch timeline tail / update summary) and then applies the daemon's live `session_message` events through the same reducer the daemon runs. Opening a session sends `session_reviewed` so the green unreviewed state clears everywhere. `UserDefaults` keeps the device name used for pairing, the filter selections and each Mac's last sync time.

## Running without a Mac

Launch with `-LumiPreviewData` to load two fixture Macs with the sessions of the design screens (no Relay traffic). Useful for screenshots and layout checks:

```bash
xcrun simctl launch booted me.afuture.AgentStatusIOS -LumiPreviewData
```

## Tests

Package tests (swift-testing) run through the app scheme:

```bash
xcodebuild -workspace Apps/AgentStatusIOS/AgentStatusIOS.xcworkspace -scheme AgentStatusIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipMacroValidation -only-testing:AgentStatusIOSFeatureTests test
```

The project intentionally does not use SwiftUI.
