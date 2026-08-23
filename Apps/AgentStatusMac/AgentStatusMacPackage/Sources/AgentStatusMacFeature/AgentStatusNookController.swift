import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import AppKit
import NookApp
import NookComponents
import SwiftUI

enum AgentStatusNookAdjustmentDefaults {
    static let compactWidth: CGFloat = DesignSystem.Notch.compactWidth
    static let expandedWidth: CGFloat = DesignSystem.Notch.expandedWidth
    static let expandAnimationDuration: TimeInterval = 0.54

    static let compactWidthRange: ClosedRange<Double> = 32...240
    static let expandedWidthRange: ClosedRange<Double> = 360...720
    static let expandAnimationDurationRange: ClosedRange<Double> = 0.15...1.2
}

/// Actions the Notch surface hands back to the app.
struct AgentStatusNookActions {
    var openMainSettings: @MainActor () -> Void = {}
    var showSession: @MainActor (SessionID) -> Void = { _ in }
}

@MainActor
final class AgentStatusNookController {
    let appState: AppState

    private let model: AgentStatusNookModel
    private let activityQueue: NookActivityQueue
    private let coordinator: AppCoordinator
    private var activityNotificationsEnabled = false
    private var activityNotificationArmTask: Task<Void, Never>?

    /// Surface claim held while the turn-ended card is on screen. The token is
    /// shared across back-to-back turn ends: a newer presentation restarts the
    /// dwell instead of releasing and re-acquiring (which would flicker).
    private var turnCardSurfaceToken: NookSurfaceToken?
    private var turnCardSurfaceGeneration = 0
    private var turnCardSurfaceTask: Task<Void, Never>?

    /// Matches the turn card's route dwell in `AgentStatusNookModel.showTurnCard`.
    private static let turnCardSurfaceDwell: Duration = .seconds(6)

    /// Non-nil only when launched with `-LumiNotchStateLog <path>`.
    private var stateLogger: DebugNotchStateLogger?

    init(store: MacSessionStore, actions: AgentStatusNookActions) {
        let model = AgentStatusNookModel(store: store)
        let activityQueue = NookActivityQueue()
        let appState = AppState()
        appState.replaceAppearancePreferences(
            Self.normalizedAppearancePreferences(appState.appearancePreferences)
        )

        // The home closure renders before `coordinator` exists; the box hands
        // the host top bar its keep-open toggle once the coordinator is up.
        let coordinatorBox = AgentStatusNookCoordinatorBox()

        var configuration = NookConfiguration()
        configuration.setHome {
            NookActivityHost(queue: activityQueue) {
                AgentStatusNookHomeView(model: model, actions: actions, coordinatorBox: coordinatorBox)
            }
        }
        configuration.setCompactLeading {
            AgentStatusNookCompactStatus(model: model.compactModel)
        }
        configuration.setCompactTrailing {
            AgentStatusNookCompactCount(model: model.compactModel)
        }
        // The chrome's own top bar pads its clusters by the geometric corner
        // clearance (24pt here) and cannot hit the design's `0 14` band, so
        // the host draws the whole top band itself (`AgentStatusNookTopBar`).
        configuration.topBar = NookTopBarConfiguration(
            showsTopBar: false,
            showsSettings: false,
            showsStatusBanner: false,
            width: .intrinsic
        )
        // Rows pad themselves by `sideInset`, so every chrome-side horizontal
        // clearance is switched off and that 16 becomes the real distance to
        // the panel edge: `.intrinsic` drops the content-column gutter (which
        // is the corner clearance, `bottomCornerRadius`), and the two paddings
        // below are the chrome's own 8 + 8. The radii restate the framework
        // defaults — `style` is all-or-nothing, there is no partial override.
        configuration.style = NookStyle(
            topCornerRadius: 19,
            bottomCornerRadius: 24,
            expandedContentInsets: .zero
        )
        configuration.metrics.edgePadding = 0
        configuration.showsMenuBarExtra = false
        configuration.branding = NookHostBranding(
            hostName: "Lumi",
            hostTagline: "Live Agent Sessions"
        )
        configuration.chromeBehavior = NookChromeBehavior(
            hoverBehavior: [.keepVisible],
            showsLaunchShimmer: false
        )
        configuration.onReady = { coordinator in
            activityQueue.bind(to: coordinator)
        }

        self.model = model
        self.activityQueue = activityQueue
        self.appState = appState
        coordinator = AppCoordinator(appState: appState, configuration: configuration)
        coordinatorBox.coordinator = coordinator

        model.onSnapshot = { [weak self] previous, current, initial in
            guard let self, self.activityNotificationsEnabled, !initial else { return }
            self.handleTurnEvents(previous: previous, current: current)
        }
    }

    static func normalizedAppearancePreferences(
        _ preferences: NookAppearancePreferences
    ) -> NookAppearancePreferences {
        var normalized = preferences
        normalized.chromePalette = .dark
        normalized.presentation = .notch
        normalized.compactNotchWidth = normalized.compactNotchWidth
            ?? AgentStatusNookAdjustmentDefaults.compactWidth
        normalized.expandedNotchWidth = normalized.expandedNotchWidth
            ?? AgentStatusNookAdjustmentDefaults.expandedWidth
        normalized.expandAnimationDuration = normalized.expandAnimationDuration
            ?? AgentStatusNookAdjustmentDefaults.expandAnimationDuration
        return normalized
    }

    func start() {
        if stateLogger == nil { stateLogger = DebugNotchStateLogger(appState: appState) }
        model.start()
        activityNotificationArmTask?.cancel()
        activityNotificationArmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            self.activityNotificationsEnabled = true
            self.activityNotificationArmTask = nil
        }
        coordinator.start()
        // OpenNook is embedded in a regular AppKit app rather than running as a
        // standalone menu-bar process, so restore the host application's policy.
        NSApp.setActivationPolicy(.regular)
    }

    func stop() async {
        activityNotificationArmTask?.cancel()
        activityNotificationArmTask = nil
        activityNotificationsEnabled = false
        model.stop()
        await activityQueue.quiesce()
        await releaseTurnCardSurface()
        coordinator.hideNook()
    }

    func showNook() {
        coordinator.showHome()
    }

    func toggleKeepOpen() {
        coordinator.toggleKeepNookOpen()
    }

    // MARK: Debug snapshots (`DebugSnapshotExporter`)

    func debugShowDetailOfFirstSession() -> Bool {
        guard let first = model.sessions.first else { return false }
        model.showDetail(first.id)
        return true
    }

    func debugShowTurnEndedCardOfFirstSession() -> Bool {
        guard let first = model.sessions.first else { return false }
        model.showList()
        model.showTurnCard(.turnEnded(first.id), dwell: .seconds(30))
        return true
    }

    func debugShowTurnStartedCardOfFirstSession() -> Bool {
        guard let first = model.sessions.first else { return false }
        model.showList()
        model.showTurnCard(.turnStarted(first.id), dwell: .seconds(30))
        return true
    }

    /// L3 rows only: TURN END expands the Notch transiently with the
    /// turn-complete card, FAILED / ABORTED with a high-priority toast — both
    /// hand the surface back after their dwell. USER (turn start) leaves the
    /// Notch untouched: the session list reflects the new state on its own.
    /// Nothing else expands the Notch.
    private func handleTurnEvents(
        previous: [AgentStatusNookSession],
        current: [AgentStatusNookSession]
    ) {
        let events = AgentStatusNookActivityDiff.turnEvents(previous: previous, current: current)
        var notified = false
        for event in events {
            guard let session = current.first(where: { $0.id == event.sessionID }) else { continue }
            switch event.kind {
            case .started:
                stateLogger?.log("event=started session=\(session.id.rawValue) (no-op)")
            case .ended:
                stateLogger?.log("event=ended session=\(session.id.rawValue)")
                model.showTurnCard(.turnEnded(session.id))
                presentTurnCardSurface()
                notified = true
            case .failed:
                stateLogger?.log("event=failed session=\(session.id.rawValue)")
                activityQueue.enqueue(NookActivity(
                    coalescingKey: session.id.rawValue,
                    priority: .high,
                    title: session.title,
                    subtitle: event.row.text.count > 120 ? String(event.row.text.prefix(117)) + "…" : event.row.text,
                    systemImage: "exclamationmark.circle.fill",
                    tint: Color(event.row.tag.categoryColor),
                    dwell: .seconds(2.8)
                ))
                notified = true
            }
        }
        guard notified else { return }
        NookHaptics.confirm(enabled: appState.appearancePreferences.hapticFeedbackEnabled)
    }

    /// Expands the Notch for the turn-ended card through the arbiter's
    /// transient channel: claim, dwell, release — so the surface settles back
    /// to compact on its own instead of staying open (`showHome()` would mark
    /// the open user-initiated and never collapse). The arbiter denies the
    /// claim while the user owns the surface (hovering, opened it themselves,
    /// pinned); the card is still routed and visible whenever the panel is
    /// open. A FAILED toast (`.urgent`) can preempt this claim (`.normal`).
    private func presentTurnCardSurface() {
        turnCardSurfaceGeneration &+= 1
        let generation = turnCardSurfaceGeneration
        turnCardSurfaceTask?.cancel()
        let predecessor = turnCardSurfaceTask
        turnCardSurfaceTask = Task { @MainActor [weak self] in
            // Serialize behind the superseded presentation: cancellation wakes
            // its sleep early, and it leaves the held token for this task
            // (its release is guarded by the generation check below).
            await predecessor?.value
            guard let self, generation == self.turnCardSurfaceGeneration else { return }
            // A held claim whose surface the user has since dismissed
            // (hover-exit compacts without ending the claim) is stale — drop
            // it so this presentation expands again instead of dwelling on a
            // closed panel.
            if let stale = self.turnCardSurfaceToken, !self.appState.isNookVisible {
                self.turnCardSurfaceToken = nil
                await self.coordinator.endTransientPresentation(stale)
                guard generation == self.turnCardSurfaceGeneration else { return }
            }
            if self.turnCardSurfaceToken == nil {
                let claim = NookSurfaceClaim(
                    moduleID: self.coordinator.activeModuleID,
                    priority: .normal
                )
                guard let token = await self.coordinator.beginTransientPresentation(claim) else { return }
                self.turnCardSurfaceToken = token
            }
            try? await Task.sleep(for: Self.turnCardSurfaceDwell)
            guard !Task.isCancelled, generation == self.turnCardSurfaceGeneration,
                  let token = self.turnCardSurfaceToken else { return }
            self.turnCardSurfaceToken = nil
            await self.coordinator.endTransientPresentation(token)
        }
    }

    /// Releases a turn-card surface claim still held (or mid-acquisition) so
    /// `stop()` cannot leave a claim whose eventual release would re-show the
    /// surface after `hideNook()`.
    private func releaseTurnCardSurface() async {
        turnCardSurfaceGeneration &+= 1
        turnCardSurfaceTask?.cancel()
        await turnCardSurfaceTask?.value
        turnCardSurfaceTask = nil
        guard let token = turnCardSurfaceToken else { return }
        turnCardSurfaceToken = nil
        await coordinator.endTransientPresentation(token)
    }
}

// MARK: - Palette (design system · Notch / dark)

/// Shorthands over the shared design system for the dark panel
/// (`DesignSystem.InkDark` / `.SurfaceDark`, read as written — never derived
/// from the light ladder).
private typealias DS = DesignSystem
private typealias NotchMetric = DesignSystem.Notch
private typealias NotchType = DesignSystem.Typography

private extension Color {
    static let nookTitle = Color(DS.InkDark.primary)
    static let nookBody = Color(DS.InkDark.body)
    static let nookSecondary = Color(DS.InkDark.secondary)
    static let nookTertiary = Color(DS.InkDark.tertiary)
    static let nookQuaternary = Color(DS.InkDark.quaternary)
    static let nookAccentText = Color(DS.InkDark.accentText)
    static let nookSeparator = Color(DS.SurfaceDark.separator)
    static let nookHairline = Color(DS.SurfaceDark.hairline)
    static let nookCard = Color(DS.SurfaceDark.card)
    static let nookSelection = Color(DS.SurfaceDark.selection)
    static let nookControl = Color(DS.SurfaceDark.control)
    static let nookSecondaryButton = Color(DS.SurfaceDark.secondaryButton)
    static let nookAgentTag = Color(DS.SurfaceDark.agentTag)
    static let nookAgentTagText = Color(DS.InkDark.agentTagText)
    static let nookPanel = Color(DS.SurfaceDark.panel)
    static let nookListCard = Color(DS.SurfaceDark.listCard)
    static let nookSubagentPill = Color(DS.SurfaceDark.subagentPill)
    static let nookSubagentChevron = Color(DS.InkDark.subagentChevron)
    static let nookPillName = Color(DS.InkDark.pillName)
    static let nookPillTime = Color(DS.InkDark.pillTime)
    static let nookArchiveGlyph = Color(DS.InkDark.archiveGlyph)
}

/// Dark ladder of the lifecycle tiers (design system 4.1 · Dark).
private extension SessionStatusTone {
    var nookColor: Color { Color(darkStyle.color) }
}

// MARK: - Home (routes)

/// Hands the host top bar the chrome coordinator once it exists.
@MainActor
final class AgentStatusNookCoordinatorBox {
    weak var coordinator: AppCoordinator?
}

/// The panel's top band (host-drawn; the chrome's bar is disabled): height 32,
/// padding `0 14`, brand glyph + 11 / Regular `.58` title on the left, gear and
/// keep-open lock (15px line icons, `.62`) on the right, gaps 10 / 15. The
/// middle stays empty for the camera.
private struct AgentStatusNookTopBar: View {
    let actions: AgentStatusNookActions
    let coordinatorBox: AgentStatusNookCoordinatorBox
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NotchMetric.topBarLeadingGap) {
                Image(systemName: "terminal")
                    .font(.system(size: NotchMetric.topBarGlyph, weight: .regular))
                    .foregroundStyle(Color(DS.InkDark.brandIcon))
                    .frame(width: NotchMetric.topBarIconBox, height: NotchMetric.topBarIconBox)
                Text("Lumi")
                    .designText(NotchType.caption)
                    .foregroundStyle(Color.nookSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: NotchMetric.topBarTrailingGap) {
                topBarButton("gearshape", help: "Open Lumi Settings", action: actions.openMainSettings)
                topBarButton(
                    appState.keepNookOpen ? "lock.fill" : "lock.open",
                    active: appState.keepNookOpen,
                    help: appState.keepNookOpen ? "Let the panel close on its own" : "Keep the panel open"
                ) {
                    coordinatorBox.coordinator?.toggleKeepNookOpen()
                }
            }
        }
        .padding(.horizontal, NotchMetric.topBarSideInset)
        .frame(height: NotchMetric.topBandHeight)
    }

    private func topBarButton(
        _ systemName: String, active: Bool = false, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: NotchMetric.topBarGlyph, weight: .regular))
                .foregroundStyle(active ? Color.nookTitle : Color(DS.InkDark.icon))
                .frame(width: NotchMetric.topBarIconBox, height: NotchMetric.topBarIconBox)
                // Layout is the 15px glyph box so the design's gaps and the 14pt
                // trailing inset hold; the hit target still spans 24pt.
                .contentShape(Rectangle().inset(by: (NotchMetric.topBarIconBox - NotchMetric.settingsButton) / 2))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct AgentStatusNookHomeView: View {
    @ObservedObject var model: AgentStatusNookModel
    let actions: AgentStatusNookActions
    let coordinatorBox: AgentStatusNookCoordinatorBox
    @Environment(\.nookResolvedTheme) private var theme
    /// Measured heights of the list items, so the viewport can end exactly
    /// after the sixth session no matter how tall its rows are.
    @State private var listItemHeights: [SessionID: Double] = [:]

    var body: some View {
        VStack(spacing: 0) {
            AgentStatusNookTopBar(actions: actions, coordinatorBox: coordinatorBox)
            routeBody
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var routeBody: some View {
        Group {
            switch model.route {
            case .list:
                listBody
            case let .detail(id):
                if let session = model.session(id) {
                    AgentStatusNookDetailView(session: session, model: model, actions: actions)
                } else {
                    listBody
                }
            case let .turnStarted(id):
                if let session = model.session(id) {
                    AgentStatusNookTurnStartedCard(session: session, model: model, actions: actions)
                } else {
                    listBody
                }
            case let .turnEnded(id):
                if let session = model.session(id) {
                    AgentStatusNookTurnEndedCard(session: session, model: model, actions: actions)
                } else {
                    listBody
                }
            }
        }
        // Routes carry their own bottom padding (footer 12 / cards 12–15); the
        // chrome's 24pt corner-clearance would double it — measured, the panel's
        // 24pt bottom curve never reaches content that starts 16pt from the side.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.18), value: model.route)
    }

    @ViewBuilder
    private var listBody: some View {
        if model.sessions.isEmpty {
            VStack(spacing: NotchMetric.emptyStateGap) {
                Image(systemName: model.daemonAvailable ? "terminal" : "bolt.horizontal.circle")
                    .font(.system(size: NotchMetric.emptyStateGlyph, weight: .light))
                    .foregroundStyle(theme.secondaryLabel)
                Text(model.daemonAvailable ? "No active Sessions" : "Daemon unavailable")
                    .designText(NotchType.listTitle)
                    .foregroundStyle(theme.primaryLabel)
                Text(model.daemonAvailable
                     ? "Start a Codex or Claude Code Session to see it here."
                     : "Open Lumi Settings to check Lumen.")
                    .designText(NotchType.caption)
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NotchMetric.emptyStateVertical)
        } else {
            let items = AgentStatusNookSnapshot.listItems(from: model.sessions)
            VStack(spacing: 0) {
                // The viewport ends exactly after the sixth session (measured
                // heights — running rows and subagent groups are taller than
                // flat rows); everything beyond scrolls. Plain VStack: every
                // row lays out, so the first six always report a height.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Group {
                                if item.children.isEmpty {
                                    AgentStatusNookSessionRow(
                                        session: item.session,
                                        onOpen: { model.showDetail(item.session.id) },
                                        onArchive: { model.archive(item.session.id) }
                                    )
                                } else {
                                    AgentStatusNookSubagentGroupRow(
                                        item: item,
                                        expanded: model.subagentDisclosure.isExpanded(item),
                                        onOpen: { model.showDetail($0) },
                                        onArchive: { model.archive(item.session.id) },
                                        onToggle: { model.toggleSubagents(of: item) }
                                    )
                                }
                            }
                            .onGeometryChange(for: Double.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                listItemHeights[item.id] = height
                            }
                            if index < items.count - 1 {
                                Color.nookSeparator
                                    .frame(height: DS.Stroke.separator)
                                    .padding(.horizontal, NotchMetric.listSideInset)
                            }
                        }
                    }
                    .padding(.top, NotchMetric.listTopPadding)
                }
                .frame(maxHeight: listViewportHeight(for: items))
                // Footer: fixed 26pt, separator on top, count centred both axes.
                Text("\(model.listedSessionCount) session\(model.listedSessionCount == 1 ? "" : "s")")
                    .designText(NotchType.notchLabel)
                    .foregroundStyle(Color.nookQuaternary)
                    .frame(maxWidth: .infinity)
                    .frame(height: NotchMetric.footerHeight)
                    .overlay(alignment: .top) { Color.nookSeparator.frame(height: DS.Stroke.separator) }
            }
        }
    }

    /// Top padding + the first six items at their measured heights + the
    /// separators between them. Items not yet measured fall back to the
    /// flat-row height so the first pass is already close.
    private func listViewportHeight(for items: [AgentStatusNookListItem]) -> Double {
        let visible = items.prefix(NotchMetric.listMaxVisibleRows)
        let flatRow = NotchMetric.rowTop + NotchMetric.timeCellHeight + NotchMetric.rowBottom
        let rows = visible.reduce(0.0) { $0 + (listItemHeights[$1.id] ?? flatRow) }
        let separators = Double(max(0, visible.count - 1)) * DS.Stroke.separator
        return NotchMetric.listTopPadding + rows + separators
    }
}

// MARK: - 2 Session list

/// `Codex` / `Claude` tag: 15 tall, `0 5`, r4, translucent white fill
/// (`SurfaceDark.agentTag`) so it reads over any chrome backdrop,
/// 9 / Medium `.52` text. The same on every row — a finished turn only
/// steps down the title and the dot, never the tag.
private struct AgentStatusNookAgentChip: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.providerName)
            .designText(NotchType.notchAgentTag)
            .foregroundStyle(Color.nookAgentTagText)
            .padding(.horizontal, NotchMetric.agentTagHorizontalPadding)
            .frame(height: NotchMetric.agentTagHeight)
            .background(Color.nookAgentTag, in: RoundedRectangle(cornerRadius: DS.Radius.notchAgentTag, style: .continuous))
    }
}

/// 8px tier dot with a 3px halo; only in-progress tiers (Running / Waiting)
/// carry the halo and breathe, Completed and Failed are solid.
private struct AgentStatusNookStatusDot: View {
    let tone: SessionStatusTone
    var size: CGFloat = DS.StatusDot.notchSize

    var body: some View {
        DesignStatusDot(tone.darkStyle.dot, size: size, haloWidth: DS.StatusDot.notchHalo)
    }
}

/// First line `8px dot | title | tag + 26px time cell`, column gap 9,
/// padding `3 14 4`. Title `#fff` while the turn runs, `.78` once it has
/// ended — and the dot steps down with it (`statusTone` resolves a finished
/// turn to the Completed tier). The relative time swaps in place for the
/// 22pt archive button on hover once the turn has ended, so the right edges
/// align and nothing shifts. Running rows carry a second line with the
/// latest activity (category tag + summary) spanning the full content width.
private struct AgentStatusNookSessionRow: View {
    let session: AgentStatusNookSession
    /// The subagent group row provides the outer insets itself.
    var bare = false
    let onOpen: () -> Void
    let onArchive: () -> Void
    @State private var hovering = false

    /// The design gives the extra activity line to working (blue-tier) rows
    /// only — waiting and finished rows stay single-line.
    private var latestActivity: AgentStatusNookActivityRow? {
        session.statusTone == .blue ? session.recentRows.last : nil
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: NotchMetric.rowLineGap) {
                HStack(spacing: NotchMetric.rowColumnGap) {
                    AgentStatusNookStatusDot(tone: session.statusTone)

                    Text(session.title)
                        .designText(NotchType.listTitle)
                        .foregroundStyle(session.turnEnded ? Color.nookBody : Color.nookTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: NotchMetric.trailingClusterGap) {
                        AgentStatusNookAgentChip(agent: session.agent)
                        ZStack(alignment: .trailing) {
                            if hovering && session.turnEnded {
                                Button(action: onArchive) {
                                    Image(systemName: "archivebox")
                                        .font(.system(size: NotchMetric.archiveSymbolSize, weight: .regular))
                                        .foregroundStyle(Color.nookArchiveGlyph)
                                        .frame(width: NotchMetric.archiveButton, height: NotchMetric.archiveButton)
                                        .background(
                                            Color.nookSecondaryButton,
                                            in: RoundedRectangle(cornerRadius: DS.Radius.notchChip, style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Archive")
                                .accessibilityLabel("Archive session")
                            } else {
                                Text(SessionRelativeTimeFormatter.string(from: session.lastActivityAt))
                                    .designText(NotchType.monoTimestamp)
                                    .foregroundStyle(Color.nookQuaternary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .frame(minWidth: NotchMetric.timeCellWidth, alignment: .trailing)
                        .frame(height: NotchMetric.timeCellHeight)
                    }
                    .padding(.leading, NotchMetric.trailingClusterLeadingPad)
                }
                if let latestActivity {
                    // Runs under both the title and the trailing cluster (the
                    // mock stops it at the title column) so the summary's
                    // right edge lines up with the time cell above; indented
                    // by the dot column + gap to keep the left edge aligned.
                    AgentStatusNookActivityLine(row: latestActivity)
                        .padding(.leading, DS.StatusDot.notchSize + NotchMetric.rowColumnGap)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(bare ? EdgeInsets() : EdgeInsets(
                top: NotchMetric.rowTop, leading: NotchMetric.listSideInset,
                bottom: NotchMetric.rowBottom, trailing: NotchMetric.listSideInset
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.statusText)")
    }
}

/// The latest activity under a running title: category tag (14 tall, `0 4`,
/// r3, 9 / Semibold) + one-line summary (11 `.58`). The list promotes L1
/// hues to their L2 tint so the tiny tag keeps a legible fill (the mock
/// paints TOOL with the yellow tint); L3 stays solid.
private struct AgentStatusNookActivityLine: View {
    let row: AgentStatusNookActivityRow

    var body: some View {
        let style = row.tag.hue.tagStyle(row.level == .l1 ? .l2 : row.level, appearance: .dark)
        HStack(spacing: NotchMetric.activityLineGap) {
            Text(row.tag.shortLabel)
                .designText(NotchType.notchActivityTag)
                .foregroundStyle(Color(style.text))
                .padding(.horizontal, NotchMetric.activityTagHorizontalPadding)
                .frame(height: NotchMetric.activityTagHeight)
                .background(Color(style.fill), in: RoundedRectangle(cornerRadius: DS.Radius.notchActivityTag, style: .continuous))
            Text(row.text)
                .designText(NotchType.caption)
                .foregroundStyle(Color.nookSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// A session with subagents (Screen 2 / 2b): the row, then a 22pt count
/// strip — stacked status dots, `3 subagents · 2 running · 1 done`, a
/// chevron — that toggles the pill group under it. Padding `4 14 5`, 5pt
/// gaps; strip and pills are indented 17 so they start under the title text.
/// Running rows open by default, every other tier starts collapsed, and a
/// user's toggle sticks until the tier changes (`AgentStatusNookSubagentDisclosure`).
/// While hovered the row wears the `.07` r10 card inset `2 6 3`, painted
/// behind the flat geometry so nothing shifts.
private struct AgentStatusNookSubagentGroupRow: View {
    let item: AgentStatusNookListItem
    let expanded: Bool
    let onOpen: (SessionID) -> Void
    let onArchive: () -> Void
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMetric.subagentRowGap) {
            AgentStatusNookSessionRow(
                session: item.session,
                bare: true,
                onOpen: { onOpen(item.session.id) },
                onArchive: onArchive
            )
            AgentStatusNookSubagentStrip(
                tones: item.subagentTones,
                label: item.subagentSummary,
                expanded: expanded,
                onToggle: onToggle
            )
            .padding(.leading, NotchMetric.subagentIndent)
            if expanded {
                AgentStatusNookPillFlow(spacing: NotchMetric.pillFlowGap) {
                    ForEach(item.children) { child in
                        AgentStatusNookSubagentPill(session: child, onOpen: { onOpen(child.id) })
                    }
                }
                .padding(.leading, NotchMetric.subagentIndent)
            }
        }
        .padding(EdgeInsets(
            top: NotchMetric.subagentRowTop, leading: NotchMetric.listSideInset,
            bottom: NotchMetric.subagentRowBottom, trailing: NotchMetric.listSideInset
        ))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: DS.Radius.notchCard, style: .continuous)
                    .fill(Color.nookListCard)
                    .padding(EdgeInsets(
                        top: NotchMetric.cardMarginTop, leading: NotchMetric.cardMarginHorizontal,
                        bottom: NotchMetric.cardMarginBottom, trailing: NotchMetric.cardMarginHorizontal
                    ))
            }
        }
        .onHover { hovering = $0 }
    }
}

/// The count strip: 22 tall, gap 8 — the group's dots stacked (9px, 1.5px
/// panel-colour ring, overlapping by 3, running → waiting → failed → done),
/// the 11 `.58` summary (one line, ellipsis), and a 10 × 6 chevron at the
/// right edge that turns 180° over .18s while the group is open. The whole
/// strip is the hit target; only the chevron animates.
private struct AgentStatusNookSubagentStrip: View {
    let tones: [SessionStatusTone]
    let label: String
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: NotchMetric.subagentStripGap) {
                AgentStatusNookStackedDots(tones: tones)
                Text(label)
                    .designText(NotchType.caption)
                    .foregroundStyle(Color.nookSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: NotchMetric.subagentChevronSymbolSize, weight: .bold))
                    .foregroundStyle(Color.nookSubagentChevron)
                    .frame(width: NotchMetric.subagentChevronWidth, height: NotchMetric.subagentChevronHeight)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .animation(.easeInOut(duration: NotchMetric.subagentChevronAnimation), value: expanded)
            }
            .frame(height: NotchMetric.subagentStripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(expanded ? "Collapse subagents" : "Expand subagents")
    }
}

/// One 9px dot per subagent in that subagent's tier colour, each wearing a
/// 1.5px ring in the panel colour so the stack reads as separate dots;
/// from the second on they overlap the previous by 3 (later dots on top).
private struct AgentStatusNookStackedDots: View {
    let tones: [SessionStatusTone]

    var body: some View {
        let dot = NotchMetric.subagentStripDot
        let step = dot - NotchMetric.subagentStripDotOverlap
        ZStack(alignment: .leading) {
            ForEach(Array(tones.enumerated()), id: \.offset) { index, tone in
                Circle()
                    .fill(tone.nookColor)
                    .frame(width: dot, height: dot)
                    .background(Circle().fill(Color.nookPanel).padding(-NotchMetric.subagentStripDotRing))
                    .offset(x: Double(index) * step)
            }
        }
        .frame(
            width: tones.isEmpty ? 0 : dot + Double(tones.count - 1) * step,
            height: dot,
            alignment: .leading
        )
        .accessibilityHidden(true)
    }
}

/// Subagent pill: 20 tall, `0 7`, r6, `.13` fill — 5px status dot, name
/// (11 `.82`, compresses and ellipsizes, never stretches) and the
/// subagent's **duration** (mono 10 `.44`), not a relative timestamp.
private struct AgentStatusNookSubagentPill: View {
    let session: AgentStatusNookSession
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: NotchMetric.pillInnerGap) {
                Circle()
                    .fill(session.statusTone.nookColor)
                    .frame(width: DS.StatusDot.notchPillDot, height: DS.StatusDot.notchPillDot)
                Text(session.title)
                    .designText(NotchType.caption)
                    .foregroundStyle(Color.nookPillName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.elapsedText(now: Date()))
                    .designText(NotchType.monoTimestamp)
                    .foregroundStyle(Color.nookPillTime)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, NotchMetric.pillHorizontalPadding)
            .frame(height: NotchMetric.pillHeight)
            .background(Color.nookSubagentPill, in: RoundedRectangle(cornerRadius: DS.Radius.notchChip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title), subagent, \(session.statusText)")
    }
}

/// Left-aligned wrapping flow for the pills: content-sized items, `spacing`
/// gaps on both axes, a new line whenever the next pill would overflow. A
/// pill wider than the row is capped so its name ellipsizes.
private struct AgentStatusNookPillFlow: Layout {
    var spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(frames(width: bounds.width, subviews: subviews).frames, subviews) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
        }
        return (CGSize(width: maxX, height: y + lineHeight), frames)
    }
}

// MARK: - 3 / 4 Turn cards

/// Action row buttons: `30` tall, r9. Primary: accent fill (white) with
/// `#111` text, 13 / Semibold; secondary: `.16` fill + `.5px` `.18` ring,
/// 12 / Semibold.
private struct NookCardButton: View {
    enum Style { case primary, secondary }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.notchButton, style: .continuous)
        Button(action: action) {
            Text(title)
                .designText(style == .primary ? NotchType.notchButton : NotchType.notchSecondaryButton)
                .foregroundStyle(style == .primary ? Color(DS.InkDark.onAccentFill) : Color.nookTitle)
                .frame(maxWidth: .infinity)
                .frame(height: NotchMetric.buttonHeight)
                .background(
                    style == .primary ? Color(DS.SurfaceDark.accentFill) : Color.nookSecondaryButton,
                    in: shape
                )
                .overlay {
                    if style == .secondary {
                        shape.strokeBorder(Color.nookHairline, lineWidth: DS.Stroke.hairline)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Metric capsule: padding `4 9`, r8, control fill `.14`; value 11 / Semibold
/// tabular + 10 label `.50`.
private struct NookMetricPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchMetric.metricChipInnerGap) {
            Text(value)
                .font(Font(NotchType.pill).monospacedDigit())
                .foregroundStyle(Color.nookTitle)
            Text(label)
                .designText(NotchType.footnote)
                .foregroundStyle(Color.nookTertiary)
        }
        .padding(.horizontal, NotchMetric.metricChipPaddingHorizontal)
        .padding(.vertical, NotchMetric.metricChipPaddingVertical)
        .background(Color.nookControl, in: RoundedRectangle(cornerRadius: DS.Radius.notchMetricChip, style: .continuous))
    }
}

/// Shared card header: 13 / Semibold title, then `label` 10 / Medium +
/// elapsed mono 10 `.46` (gap 7), title↔trailing gap 10.
private struct NookCardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchMetric.headerTitleGap) {
            Text(title)
                .designText(NotchType.listTitle)
                .foregroundStyle(Color.nookTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: NotchMetric.headerTrailingGap) {
                trailing()
            }
            .fixedSize()
        }
    }
}

/// Turn complete: title + "Turn complete" · elapsed, metric chips, summary
/// (6 lines), "Jump to Agent".
private struct AgentStatusNookTurnEndedCard: View {
    let session: AgentStatusNookSession
    @ObservedObject var model: AgentStatusNookModel
    let actions: AgentStatusNookActions

    /// Same words as the timeline's TURN END / FAILED / ABORTED rows, and the
    /// same tier as the session tone: aborted is a failure too.
    private var outcomeText: String {
        switch session.currentTurn?.outcome {
        case .failed: "Turn failed"
        case .aborted: "Turn aborted"
        case .completed, nil: "Turn complete"
        }
    }

    private var outcomeIsFailure: Bool {
        session.currentTurn?.outcome == .failed || session.currentTurn?.outcome == .aborted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMetric.cardGap) {
            NookCardHeader(title: session.title) {
                Text(outcomeText)
                    .designText(NotchType.notchLabel)
                    .foregroundStyle(outcomeIsFailure ? SessionStatusTone.red.nookColor : Color.nookAccentText)
                Text(session.elapsedText(now: .now))
                    .designText(NotchType.monoTimestamp)
                    .foregroundStyle(Color.nookQuaternary)
            }
            HStack(spacing: NotchMetric.metricChipGap) {
                NookMetricPill(value: session.totalTokensText, label: "tokens")
                NookMetricPill(value: session.contextText, label: "context")
                NookMetricPill(value: "\(session.stillRunningCount)", label: "still running")
            }
            Text(session.lastAssistantMessage ?? session.currentUserMessage ?? "—")
                .designText(NotchType.notchBody)
                .foregroundStyle(Color.nookBody)
                .lineLimit(NotchMetric.bodyLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
            NookCardButton(title: "Jump to Agent", style: .primary) {
                AgentActivation.jump(to: session.agent, workspace: session.workspace)
                model.showList()
            }
            .padding(.top, NotchMetric.actionRowTop)
        }
        .padding(EdgeInsets(
            top: NotchMetric.cardTop, leading: NotchMetric.sideInset,
            bottom: NotchMetric.cardBottom, trailing: NotchMetric.sideInset
        ))
        .contentShape(Rectangle())
        .onTapGesture { model.showDetail(session.id) }
    }
}

/// Turn just started: "Turn started" + timer, `Agent · model · ~/cwd`, then
/// the user's input verbatim (11 / Regular `.78`, up to 6 lines) — plain text,
/// no card.
private struct AgentStatusNookTurnStartedCard: View {
    let session: AgentStatusNookSession
    @ObservedObject var model: AgentStatusNookModel
    let actions: AgentStatusNookActions

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMetric.cardGap) {
            // Header: title row, then `agent · model · cwd` 3pt below.
            VStack(alignment: .leading, spacing: NotchMetric.headerSubtitleGap) {
                NookCardHeader(title: session.title) {
                    Text("Turn started")
                        .designText(NotchType.notchLabel)
                        .foregroundStyle(Color.nookAccentText)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(session.elapsedText(now: context.date))
                            .designText(NotchType.monoTimestamp)
                            .foregroundStyle(Color.nookQuaternary)
                    }
                }
                Text([session.agent.providerName, session.model, SessionPagePresentationBuilder.abbreviatedWorkspace(session.workspace)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .designText(NotchType.caption)
                    .foregroundStyle(Color.nookSecondary)
                    .lineLimit(1)
            }
            Text(session.currentUserMessage ?? "—")
                .designText(NotchType.notchBody)
                .foregroundStyle(Color.nookBody)
                .lineLimit(NotchMetric.bodyLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(
            top: NotchMetric.cardTop, leading: NotchMetric.sideInset,
            bottom: NotchMetric.turnStartBottom, trailing: NotchMetric.sideInset
        ))
        .contentShape(Rectangle())
        .onTapGesture { model.showDetail(session.id) }
    }
}

// MARK: - 5 Session detail

private struct AgentStatusNookDetailView: View {
    let session: AgentStatusNookSession
    @ObservedObject var model: AgentStatusNookModel
    let actions: AgentStatusNookActions

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMetric.cardGap) {
            VStack(alignment: .leading, spacing: NotchMetric.headerBlockGap) {
                HStack(spacing: NotchMetric.headerTitleGap) {
                    Button(action: { model.showList() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: NotchMetric.backChevron, weight: .semibold))
                            .foregroundStyle(Color.nookBody)
                            .frame(width: NotchMetric.backButtonWidth, height: NotchMetric.backButtonHeight)
                            .background(Color.nookSelection, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to sessions")
                    Text(session.title)
                        .designText(NotchType.sectionTitle)
                        .foregroundStyle(Color.nookTitle)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                // Tier pill (3.1 · Dark, compact), then a capsule agent label
                // (selection fill `.12`, `.58` text).
                HStack(spacing: NotchMetric.pillRowGap) {
                    DesignStatusPill(session.statusText, style: session.statusTone.darkStyle.pill, compact: true)
                    Text(session.agent.providerName)
                        .designText(NotchType.notchLabel)
                        .foregroundStyle(Color.nookSecondary)
                        .padding(.horizontal, DS.StatusPill.notchHorizontalPadding)
                        .frame(height: DS.StatusPill.notchHeight)
                        .background(Color.nookSelection, in: Capsule())
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: NotchMetric.metricChipGap) {
                metricTile(session.totalTokensText, "TOKENS")
                metricTile(session.contextText, "CONTEXT")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    metricTile(session.elapsedText(now: context.date), "ELAPSED")
                }
            }

            VStack(alignment: .leading, spacing: NotchMetric.activityListGap) {
                HStack(spacing: NotchMetric.activityHeaderGap) {
                    Text("RECENT ACTIVITY")
                        .designText(NotchType.notchSectionLabel)
                        .foregroundStyle(Color.nookTitle)
                    Text("\(session.recentRows.count) items")
                        .designText(NotchType.notchLabel)
                        .foregroundStyle(Color.nookQuaternary)
                }
                .padding(.bottom, NotchMetric.activityHeaderBottom)
                if session.recentRows.isEmpty {
                    Text("No activity yet")
                        .designText(NotchType.caption)
                        .foregroundStyle(Color.nookTertiary)
                        .frame(height: NotchMetric.activityRowHeight)
                } else {
                    ForEach(session.recentRows) { row in
                        HStack(spacing: NotchMetric.activityRowGap) {
                            DesignTag(row.tag.shortLabel, style: row.tag.tagStyle(.dark), compact: true)
                                .frame(width: DS.Tag.compactWidth)
                            Text(row.text)
                                .designText(NotchType.caption)
                                .foregroundStyle(Color.nookBody)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: NotchMetric.activityRowHeight)
                    }
                }
            }

            HStack(spacing: NotchMetric.buttonGap) {
                NookCardButton(title: "Show in App", style: .primary) {
                    actions.showSession(session.id)
                }
                NookCardButton(title: "Jump to Agent", style: .secondary) {
                    AgentActivation.jump(to: session.agent, workspace: session.workspace)
                }
            }
            .padding(.top, NotchMetric.actionRowTop)
        }
        .padding(EdgeInsets(
            top: NotchMetric.detailTop, leading: NotchMetric.sideInset,
            bottom: NotchMetric.detailBottom, trailing: NotchMetric.sideInset
        ))
    }

    /// Metric card: padding `7 9`, r10, card fill `.10`; value 13 / Semibold
    /// tabular, label 9 / Semibold / .04em uppercase `.50`.
    private func metricTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: NotchMetric.metricCardGap) {
            Text(value)
                .font(Font(NotchType.listTitle).monospacedDigit())
                .foregroundStyle(Color.nookTitle)
                .lineLimit(1)
            Text(label)
                .designText(NotchType.notchMetricLabel)
                .foregroundStyle(Color.nookTertiary)
        }
        .padding(.vertical, NotchMetric.metricCardPaddingVertical)
        .padding(.horizontal, NotchMetric.metricCardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nookCard, in: RoundedRectangle(cornerRadius: DS.Radius.notchCard, style: .continuous))
    }
}

/// Brings the agent's own app forward ("Jump to Agent").
enum AgentActivation {
    private static let bundleIdentifiers: [AgentProvider: [String]] = [
        .codex: ["com.openai.codex", "com.openai.codex.desktop"],
        .claude: ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
    ]

    @MainActor
    static func jump(to agent: AgentKind, workspace: String?) {
        for identifier in bundleIdentifiers[agent.provider] ?? [] {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                running.activate()
                return
            }
        }
        // Terminal-based agents: surface the terminal that most likely hosts them.
        for identifier in ["com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable"] {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                running.activate()
                return
            }
        }
    }
}

// MARK: - 1 Collapsed bar

private struct AgentStatusNookCompactStatus: View {
    @ObservedObject var model: AgentStatusNookCompactModel

    var body: some View {
        AgentStatusNookStatusDot(tone: model.sessionCount == 0 ? .gray : model.statusTone)
            .frame(width: NotchMetric.compactSlot, height: NotchMetric.compactSlot)
            .accessibilityLabel(model.sessionCount == 0 ? "No active Sessions" : "Active Sessions")
    }
}

private struct AgentStatusNookCompactCount: View {
    @ObservedObject var model: AgentStatusNookCompactModel

    var body: some View {
        Text("\(model.sessionCount)")
            .font(Font(NotchType.pill).monospacedDigit())
            .foregroundStyle(model.sessionCount == 0 ? Color.nookQuaternary : Color.nookTitle)
            .frame(width: NotchMetric.compactSlot, height: NotchMetric.compactSlot)
            .accessibilityLabel("\(model.sessionCount) Sessions in Notch")
    }
}
