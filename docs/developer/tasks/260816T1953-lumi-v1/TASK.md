# Agent Status v1

* Task: 260816T1953-agent-status-v1
* Author: Huanan
* Status: DEVELOPING
* Type: FEAT
* Related: None

## Outcome

Agent Status lets a user observe multiple Codex Agents and Sessions from a Mail-style macOS window, a compact Notch surface, and one or more read-only iPhone channels.

The completed feature must provide:

1. One local daemon per Mac that accepts low-latency Codex events, reconciles new Session logs, and retains history until the user deletes it.
2. A stateless Hook helper that delivers normalized events without replacing existing Codex Hooks.
3. AppKit and UIKit clients that share one versioned Swift transport package and keep persistent synchronized local data.
4. One Mac—iPhone channel per paired device relationship, carrying all Sessions for that Mac rather than creating per-Session connections.
5. A Cloudflare Relay that routes end-to-end encrypted live frames, supports QR pairing and per-device revocation, and does not persist Session content.
6. Build, runtime and test evidence for each component, with unverified release or device behavior called out explicitly.

## Acceptance Evidence

- Swift package builds and tests for transport, state reduction, persistence, Codex parsing, framing, daemon, helper, encryption, deletion and event multiplexing.
- macOS and iOS builds using a complete supported Xcode installation.
- Runtime evidence for App launch, Mail-style navigation, manual refresh, deletion, pairing, device revocation and remote Timeline display.
- Relay type-check, Worker-runtime tests, deployed health check and protocol-fixture consistency.
- A real Codex Hook-to-daemon-to-Mac-to-iPhone trace that retains structured model configuration, full mapped internal context and consumption metrics, verifies encrypted device delivery, and treats every synchronized copy as sensitive.
- Product documentation derived from reachable and verified behavior under `docs/feat/`.

## Risks and Current Constraints

- The current environment uses Xcode 26.6 and can build both Apps, but Developer ID signing, notarization and clean-machine installation remain unverified.
- The full remote path is verified with a sanitized synthetic Hook event and iOS Simulator; a real Codex Hook and physical iPhone remain pending.
- APNs is intentionally excluded from the current scope.
- Codex rollout formats can evolve; unsupported records must be ignored safely and covered by sanitized fixtures.

## Milestone Results

### Shared protocol and local service

- **Target:** independently buildable daemon/helper with one shared transport package and persistent Session state.
- **Delivered:** versioned immutable transport objects, unknown-value handling, framing, Codex adapter, idempotent state reduction, persistent storage, rollout resume, secure Unix socket, one daemon event stream per client, stateless helper, single/all deletion and deleted-Session suppression.
- **Verification evidence:** Transport 5/5, Common 12/12 and CLI 8/8 tests pass. Real daemon/helper smoke input created a Session through the current embedded binaries and a user-only socket. Duplicate, late and deleted-Session events are covered; the shared status-tone test covers every supported lifecycle color and both Waiting For Input phases.
- **Remaining risk:** the acceptance trace from an actual Codex /hooks invocation is still pending.

### Data synchronization and lifecycle

- **Target:** daemon, Mac and iOS maintain consistent persistent data without periodic UI polling.
- **Delivered:** Mac startup/manual/event refresh model, incremental Agent-event updates, authoritative manual snapshots, per-Mac iPhone stores, no time-based cleanup, single Session deletion, clear-all, and new-Session-only initial baseline.
- **Verification evidence:** one sanitized Session reached daemon, Mac list/detail and iOS list/detail; deleting it from the Mac removed it from iOS. Final daemon, Mac and current iOS channel stores each report 0 Sessions and 0 Timeline items. A Mac feature test covers daemon availability changes and forces an unchanged snapshot to be resent after recovery.
- **Remaining risk:** longer weak-network and process-restart runs remain to be exercised on physical devices.

### Relay and encrypted mobile transport

- **Target:** fixed product Relay, no-account pairing, per-device authorization, opaque forwarding, revocation and reconnect.
- **Delivered:** TypeScript Worker, one Durable Object per Mac, hashed credentials, one-time pairing, per-device revocation, hibernating WebSockets, bounded transient replay and per-device payload protection. No APNs handling is included.
- **Verification evidence:** type-check passes; Worker tests pass 6/6, including host-close presence; Swift golden vectors are consumed by Relay tests; deployment version `d946a09b-8aa2-4f5d-a439-a2506f15fe8f` is active at `agent-status-relay.afuture.workers.dev`; live `/health` returned protocol major 1 and status ok.
- **Remaining risk:** production observability, rate tuning and recovery behavior need longer-lived traffic.

### AppKit macOS client

- **Target:** native Mail-style three-column Session browser, iPhone pairing page, Settings, toolbar and Notch.
- **Delivered:** one standard split hierarchy with full-height sidebar, context-list middle column and detail column. The Session list is a native collapsible Outline showing authoritative Codex `threads.title`, Codex / Codex Subagent type and lifecycle/Turn status; Subagent lineage nests child Sessions under their Main Session and is shown in Overview. Detail is rewritten into Overview, Model Configuration, Usage, Internal Context and Activity modules. Settings uses category/detail, and only iPhone collapses the middle column. Refresh is positioned above the Session list and Delete above detail. The old custom panel was replaced by a pinned OpenNook revision: the expanded surface lists up to four current Session titles, statuses and current-Turn user messages, uses the ActivityNook queue for meaningful updates, and opens the main App's Notch settings. Session colors use one shared semantic palette across the Mac list, detail, Notch and iPhone.
- **Verification evidence:** macOS build-and-run succeeds under Xcode 26.6; Computer Use accessibility inspection confirms live `threads.title`, two current Subagents nested under the Main Session, collapse/expand behavior, Subagent Overview lineage, and one-line list/detail-header rendering for a stored multiline title while Overview retains the original value. OpenNook content, Notch gear-to-main-Settings path, Settings three-column layout and Notch options remain inspected. Manual Refresh, confirmation-based deletion and iPhone pairing/revocation remain exercised. Mac feature tests pass 11/11, including hierarchy nesting/orphan/cycle handling, multiline-title normalization, title/Agent/status presentation, five-module full detail, current-Turn message selection, Completed-session exclusion, activity diffing, appearance normalization and pairing layout.
- **Remaining risk:** final visual acceptance across window sizes, Developer ID packaging and clean-machine LaunchAgent behavior remain pending.

### UIKit iOS client

- **Target:** multiple Mac channels, online status, Session list and read-only Timeline.
- **Delivered:** QR/paste pairing, independent credentials per Mac, channel grouping, per-Mac synchronized storage, online/unavailable states, Timeline display, add/remove Mac, reconnect and current snapshot handling.
- **Verification evidence:** iOS Simulator build-and-run succeeds on iPhone 17 Pro; the deployed Relay delivered a sanitized Session and Timeline to the running App; quitting the Mac changed the channel to Unavailable without showing the stored Session; reconnect and subsequent Mac deletion returned the list to No live sessions.
- **Remaining risk:** physical camera pairing, background/foreground transitions and prolonged weak-network recovery remain pending.

### Product documentation and CI

- **Target:** current user-facing behavior documentation plus SwiftPM, Apps, Relay and protocol-boundary checks.
- **Delivered:** feature overview, Mac/iPhone modules, two end-to-end journeys, data flow, friction paths, CI jobs and bundle verification tooling. `docs/design/` now records the implemented system architecture, data/IPC/SQLite lifecycle, Hook and rollout ingestion, Relay pairing/E2EE, App runtime, build and release boundaries. Documentation reflects manual retention, fixed Relay configuration, persistent three-end storage, multiple channels, single Session deletion and the Mail-style Mac layout.
- **Verification evidence:** design claims are traced to current source, tests and build configuration; relative link and stale-claim checks are rerun after documentation review; transport-boundary checks confirm no duplicate DTO declarations and shared golden fixtures.
- **Remaining risk:** documentation must be reviewed again after real Codex Hook, physical iPhone and release packaging acceptance.

### Retained Session diagnostics

- **Target:** retain model configuration, internal context and consumption metrics without flooding the user-facing activity timeline.
- **Delivered:** structured payloads for model/provider/effort/thread settings, reasoning/base instructions/Turn context/world state/compacted history, and Token/context-window/rate-limit data. Each diagnostic category keeps its latest record in the existing persistent Timeline and encrypted full-snapshot path. Mac shows the retained data in dedicated Session detail modules while keeping it out of Activity; iPhone keeps it out of its primary activity list.
- **Verification evidence:** Transport 8/8, Common 20/20, CLI 9/9 and Mac Feature 11/11 tests pass; sanitized Codable, Codex `threads` title/Subagent parsing, identity round-trip changes, temporary state-read failure, GRDB replacement persistence and Relay full-detail diff tests cover the retained payloads and rewritten Mac presentation; macOS and iOS Simulator targets compile with the expanded shared model.
- **Remaining risk:** the installed daemon was replaced from the current Debug app and live title/Subagent ingestion was verified; large internal-context snapshots still share the existing local and Relay frame limits.

### Repository structure

- **Target:** separate platform Apps, command-line processes, common Swift libraries and Relay.
- **Delivered:** `Apps/` contains macOS and iOS projects, `CLI/` owns daemon/helper/runtime, `Common/` owns shared Swift libraries and the independent transport package, and `Relay/` is independently managed.
- **Verification evidence:** SwiftPM and Xcode targets resolve shared packages from `Common/`; Relay uses its own pnpm lockfile; Apps build through the shared workspace.
- **Remaining risk:** release automation still needs final signing identities and notarization credentials.

## References

- [Current technical design](../../../design/README.md)
- [Top UI research](</Users/huanan/Documents/Codex/2026-08-16/applications-vibe-island-app-agent-session-2/outputs/vibe-island-top-ui-report.md>)
- [Multi-agent session research](</Users/huanan/Documents/Codex/2026-08-16/ban/outputs/vibe-island-multi-agent-session-report.md>)
- [Relay transport research](</Users/huanan/Documents/Codex/2026-08-16/applications-vibe-island-app-agent-session/outputs/Paseo-Relay-传输机制调研.md>)
