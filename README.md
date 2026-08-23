# Agent Status

Agent Status aggregates multiple Codex Agents and Sessions on one Mac, displays them in an AppKit three-column window and an OpenNook surface, and synchronizes read-only data to UIKit clients through an end-to-end encrypted Cloudflare Relay.

## Repository layout

- `Apps`: AppKit macOS app and UIKit iOS app.
- `CLI`: SwiftPM daemon, stateless Hook helper, and daemon runtime.
- `Common`: shared Swift packages for product state, persistence, Codex adaptation, IPC, encryption, and transport objects.
- `Common/Transport`: independent Foundation-only Swift package; the sole declaration source for cross-process and cross-device DTOs.
- `Relay`: TypeScript Cloudflare Worker and per-Mac Durable Object.
- Root: Xcode workspace, CI, scripts, and documentation.

## Product topology

- One Mac has one daemon, one Mac App, multiple Agents, and multiple Sessions.
- The Mac App and daemon synchronize over one local event stream, not one connection per Session.
- Each paired Mac—iPhone relationship is one remote channel carrying all Sessions for that Mac.
- One iPhone can connect to multiple Macs; one Mac can authorize multiple iPhones.
- daemon, Mac, and iOS use persistent local stores with the same SQLite schema; the daemon is the source of truth, the Mac app and iPhones are caches. Session history does not expire automatically.
- The daemon is the Relay host: paired iPhones keep syncing while the Mac app is closed; the Mac app only drives pairing through daemon IPC.
- Relay does not persist Session business payloads.

## Prerequisites

- macOS 26 or later.
- iOS 18 or later.
- Stable Xcode 26 selected for App builds.
- Swift 6.2.
- pnpm 11 for Relay development.

## Verify Swift packages

```sh
swift build --package-path Common
swift test --package-path Common
swift build --package-path Common/Transport
swift test --package-path Common/Transport
swift build --package-path CLI
swift test --package-path CLI
swift test --package-path Apps/Mac/MacPackage
scripts/smoke-local-chain.sh
scripts/check-transport-boundaries.sh
```

## Build Apps

Open `Lumi.xcworkspace` in Xcode 26, or use the project schemes from the command line:

```sh
xcodebuild -workspace Lumi.xcworkspace -scheme LumiMac build
xcodebuild -workspace Lumi.xcworkspace -scheme LumiIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The macOS main window uses AppKit, the Notch and its main-App settings detail use SwiftUI through OpenNook, and the iOS App uses UIKit. OpenNook is pinned to a specific revision in the macOS feature package.

## Relay

The current development Relay is deployed at:

```text
https://relay.lumi.huanan.app
```

The Relay URL is a build setting, not a user-editable preference. Keep the macOS and iOS values aligned:

- `Apps/Mac/Config/Shared.xcconfig`
- `Apps/iOS/Config/Shared.xcconfig`

Verify and deploy:

```sh
cd Relay
pnpm install --frozen-lockfile
pnpm run check
pnpm test
pnpm exec wrangler deploy
```

Relay stores device authorization and operational metadata only. Session payloads are encrypted for each paired device and are never written to Durable Object storage, KV, D1, or R2. APNs is intentionally outside the current implementation scope.

## Session data behavior

- daemon only begins tracking Sessions created after its initial Codex baseline.
- External Session content refreshes only at App startup, manual Refresh, and Agent events; deletion and clear-history operations synchronize their results immediately.
- Users can delete one Session from the macOS toolbar or clear all history in Settings.
- Deleted Sessions stay deleted in Agent Status even if later local activity arrives.
- Deleting Agent Status data never deletes Codex data.

## macOS packaging

Release builds compile daemon and helper for `arm64` and `x86_64`, combine them as Universal 2 executables, embed and sign them before signing the outer App. After archiving, run `scripts/verify-macos-bundle.sh` before notarization.

The Codex integration installer preserves existing Hooks. Users may need to review and trust the Agent Status definition through Codex `/hooks`.

## Documentation

- [Technical design index](docs/design/README.md)
- [System architecture](docs/design/system-architecture.md)
- [Data, communication, and storage](docs/design/data-communication-storage.md)
- [Agent Hook design](docs/design/agent-hook.md)
- [Product overview](docs/feat/index.md)
- [Design system handoff](design/README.md) — `design/DESIGN SYSTEM.html` is the source of every colour, type and spacing value; Swift tokens live in `Common/Sources/DesignSystem`
- [Current implementation task](docs/developer/tasks/260816T1953-agent-status-v1/TASK.md)
