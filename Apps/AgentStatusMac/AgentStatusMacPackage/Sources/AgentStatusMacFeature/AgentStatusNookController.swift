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

    init(store: MacSessionStore, actions: AgentStatusNookActions) {
        let model = AgentStatusNookModel(store: store)
        let activityQueue = NookActivityQueue()
        let appState = AppState()
        appState.replaceAppearancePreferences(
            Self.normalizedAppearancePreferences(appState.appearancePreferences)
        )

        var configuration = NookConfiguration()
        configuration.setHome {
            NookActivityHost(queue: activityQueue) {
                AgentStatusNookHomeView(model: model, actions: actions)
            }
        }
        configuration.setCompactLeading {
            AgentStatusNookCompactStatus(model: model.compactModel)
        }
        configuration.setCompactTrailing {
            AgentStatusNookCompactCount(model: model.compactModel)
        }
        configuration.topBar = NookTopBarConfiguration(
            showsTopBar: true,
            showsSettings: false,
            showsStatusBanner: false,
            leadingTitle: { _ in "Agent Status" },
            leadingIcon: "terminal",
            width: .contentColumn
        )
        configuration.setTopBarTrailingItems {
            AgentStatusNookSettingsButton(action: actions.openMainSettings)
        }
        configuration.showsMenuBarExtra = false
        configuration.branding = NookHostBranding(
            hostName: "Agent Status",
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

        model.onSnapshot = { [weak self, weak model, activityQueue] previous, current, initial in
            guard let self, let model, self.activityNotificationsEnabled, !initial else { return }
            Self.handleTurnEvents(
                previous: previous,
                current: current,
                model: model,
                hapticEnabled: appState.appearancePreferences.hapticFeedbackEnabled,
                queue: activityQueue,
                coordinator: self.coordinator
            )
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
        coordinator.hideNook()
    }

    func showNook() {
        coordinator.showHome()
    }

    func toggleKeepOpen() {
        coordinator.toggleKeepNookOpen()
    }

    /// L3 rows only: USER opens the turn-started card, TURN END the
    /// turn-complete card, FAILED / ABORTED a high-priority toast. Nothing else
    /// expands the Notch.
    private static func handleTurnEvents(
        previous: [AgentStatusNookSession],
        current: [AgentStatusNookSession],
        model: AgentStatusNookModel,
        hapticEnabled: Bool,
        queue: NookActivityQueue,
        coordinator: AppCoordinator
    ) {
        let events = AgentStatusNookActivityDiff.turnEvents(previous: previous, current: current)
        guard !events.isEmpty else { return }
        for event in events {
            guard let session = current.first(where: { $0.id == event.sessionID }) else { continue }
            switch event.kind {
            case .started:
                model.showTurnCard(.turnStarted(session.id))
                coordinator.showHome()
            case .ended:
                model.showTurnCard(.turnEnded(session.id))
                coordinator.showHome()
            case .failed:
                queue.enqueue(NookActivity(
                    coalescingKey: session.id.rawValue,
                    priority: .high,
                    title: session.title,
                    subtitle: event.row.text.count > 120 ? String(event.row.text.prefix(117)) + "…" : event.row.text,
                    systemImage: "exclamationmark.circle.fill",
                    tint: Color(event.row.tag.categoryColor),
                    dwell: .seconds(2.8)
                ))
            }
        }
        NookHaptics.confirm(enabled: hapticEnabled)
    }
}

// MARK: - Palette (design system · Notch / dark)

/// Shorthands over the shared design system for the dark glass panel.
private typealias DS = DesignSystem
private typealias NotchMetric = DesignSystem.Notch
private typealias NotchType = DesignSystem.Typography

private extension Color {
    static let nookTitle = Color(DS.InkDark.primary)
    static let nookBody = Color(DS.InkDark.body)
    static let nookSecondary = Color(DS.InkDark.secondary)
    static let nookSubtitle = Color(DS.InkDark.subtitle)
    static let nookLabel = Color(DS.InkDark.label)
    static let nookTertiary = Color(DS.InkDark.tertiary)
    static let nookQuaternary = Color(DS.InkDark.quaternary)
    static let nookHairline = Color(DS.InkDark.hairline)
    static let nookElbow = Color(DS.InkDark.elbow)
    static let nookCardFill = Color(DS.InkDark.cardFill)
    static let nookCardRing = Color(DS.InkDark.cardRing)
    static let nookControlFill = Color(DS.InkDark.controlFill)
    static let nookTurnLabel = Color(DS.InkDark.turnLabel)
}

/// Dark ladder of the lifecycle tiers (design system · sessionStatesDark).
private extension SessionStatusTone {
    var nookColor: Color { Color(darkStyle.color) }
    /// 3px halo around the 8px dot; Completed has none.
    var nookHalo: Color? { darkStyle.halo.map(Color.init) }
    var nookPillFill: Color { Color(darkStyle.pillFill) }
    var nookPillRing: Color { Color(darkStyle.pillRing) }
    /// Pill text over the tinted pill (`Running · Model turn` in `#9DC7FF`).
    var nookPillText: Color { Color(darkStyle.pillText) }
}

// MARK: - Home (routes)

private struct AgentStatusNookHomeView: View {
    @ObservedObject var model: AgentStatusNookModel
    let actions: AgentStatusNookActions
    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.nookContentInsets) private var contentInsets

    var body: some View {
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
        .padding(.top, NotchMetric.listTopInset)
        .padding(.bottom, contentInsets.bottom)
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
                     : "Open Agent Status Settings to check the daemon.")
                    .designText(NotchType.notchCaption)
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NotchMetric.emptyStateVertical)
        } else {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            let next = index + 1 < model.sessions.count ? model.sessions[index + 1] : nil
                            if session.isChild {
                                AgentStatusNookSubagentRow(
                                    session: session,
                                    hasFollowingSibling: next?.isChild == true,
                                    onOpen: { model.showDetail(session.id) }
                                )
                            } else {
                                AgentStatusNookSessionRow(
                                    session: session,
                                    hasChildren: next?.isChild == true,
                                    onOpen: { model.showDetail(session.id) },
                                    onArchive: { model.archive(session.id) }
                                )
                            }
                            if let next, !next.isChild {
                                Color.nookHairline
                                    .frame(height: DS.Stroke.separator)
                                    .padding(.horizontal, NotchMetric.sideInset)
                            }
                        }
                    }
                }
                .frame(maxHeight: NotchMetric.listMaxHeight)
                // Footer `9 16 12`, hairline on top, "N of M sessions" 10/590 `.4`.
                Text("\(model.sessions.filter { !$0.isChild }.count) of \(model.totalSessionCount) sessions")
                    .designText(NotchType.notchChip)
                    .foregroundStyle(Color.nookTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(
                        top: NotchMetric.footerTop, leading: NotchMetric.sideInset,
                        bottom: NotchMetric.footerBottom, trailing: NotchMetric.sideInset
                    ))
                    .overlay(alignment: .top) { Color.nookHairline.frame(height: DS.Stroke.separator) }
                    .padding(.top, NotchMetric.footerGap)
            }
        }
    }
}

// MARK: - 2 Session list

/// `Codex` / `Claude` chip: height 20, r6, `.09` fill + `.6` text; completed
/// rows dim to `.07` / `.45`.
private struct AgentStatusNookAgentChip: View {
    let agent: AgentKind
    var dimmed = false

    var body: some View {
        Text(agent.providerName)
            .designText(NotchType.notchChip)
            .foregroundStyle(Color(dimmed ? DS.InkDark.label : DS.InkDark.chipText))
            .padding(.horizontal, NotchMetric.chipHorizontalPadding)
            .frame(height: NotchMetric.chipHeight)
            .background(
                Color(dimmed ? DS.InkDark.chipFillDim : DS.InkDark.chipFill),
                in: RoundedRectangle(cornerRadius: DS.Radius.notchChip, style: .continuous)
            )
    }
}

/// 8px tier dot with a 3px halo (none for Completed). The Running halo
/// breathes (~1.6s ease-in-out); every other tier is static.
private struct AgentStatusNookStatusDot: View {
    let tone: SessionStatusTone
    var size: CGFloat = NotchMetric.rowDot
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(tone.nookColor)
            .frame(width: size, height: size)
            .background {
                if let halo = tone.nookHalo {
                    Circle()
                        .fill(halo)
                        .frame(width: size + NotchMetric.rowDotHalo * 2, height: size + NotchMetric.rowDotHalo * 2)
                        .opacity(tone == .blue && breathing ? DS.Opacity.breathingHalo : 1)
                }
            }
            .onAppear { breathing = tone == .blue }
            .onChange(of: tone) { _, newTone in breathing = newTone == .blue }
            .animation(
                tone == .blue ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: breathing
            )
    }
}

/// Grid `8px 1fr auto`, gap 10, padding `10 16 11` (`10 16 4` when subagent
/// rows follow). Title `#fff` while active, `.72` once completed. The trailing
/// group is agent chip + a 20pt cell holding the relative time, swapped in
/// place for the archive button on hover once the turn has ended — no layout
/// shift, and the cell is exactly button-width so the inset equals the row's
/// 16pt right padding.
private struct AgentStatusNookSessionRow: View {
    let session: AgentStatusNookSession
    var hasChildren = false
    let onOpen: () -> Void
    let onArchive: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: NotchMetric.rowGap) {
                AgentStatusNookStatusDot(tone: session.statusTone)
                    .frame(width: NotchMetric.rowDot, height: NotchMetric.rowDot)

                Text(session.title)
                    .designText(NotchType.listTitle)
                    .foregroundStyle(session.turnEnded ? Color.nookSecondary : Color.nookTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: NotchMetric.rowGap) {
                    AgentStatusNookAgentChip(agent: session.agent, dimmed: session.turnEnded)
                    ZStack(alignment: .trailing) {
                        if hovering && session.turnEnded {
                            Button(action: onArchive) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: NotchMetric.archiveSymbolSize, weight: .regular))
                                    .foregroundStyle(Color.nookSecondary)
                                    .frame(width: NotchMetric.trailingCell, height: NotchMetric.trailingCell)
                                    .background(
                                        Color(DS.InkDark.archiveFill),
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
                    .frame(width: NotchMetric.trailingCell, height: NotchMetric.trailingCell, alignment: .trailing)
                }
                .padding(.leading, NotchMetric.rowGap)
            }
            .padding(EdgeInsets(
                top: NotchMetric.rowTop, leading: NotchMetric.sideInset,
                bottom: hasChildren ? NotchMetric.rowBottomWithChildren : NotchMetric.rowBottom,
                trailing: NotchMetric.sideInset
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.statusText)")
    }
}

/// Subagent row (only while the parent's turn runs): grid `6px 1fr auto`,
/// padding `3 16 3 34` (`9` below the last child), 11/510 `.72` title, mono 10
/// `.32` time, and a 1px `.16` elbow from the parent's dot that continues
/// while more children follow.
private struct AgentStatusNookSubagentRow: View {
    let session: AgentStatusNookSession
    let hasFollowingSibling: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: NotchMetric.rowGap) {
                Circle()
                    .fill(session.statusTone.nookColor)
                    .frame(width: NotchMetric.childDot, height: NotchMetric.childDot)
                Text(session.title)
                    .designText(NotchType.notchCaption)
                    .foregroundStyle(Color.nookSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SessionRelativeTimeFormatter.string(from: session.lastActivityAt))
                    .designText(NotchType.monoTimestamp)
                    .foregroundStyle(Color(DS.InkDark.timestampDim))
                    .frame(width: NotchMetric.childTimeWidth, alignment: .trailing)
            }
            .padding(EdgeInsets(
                top: NotchMetric.childRowVertical, leading: NotchMetric.childIndent,
                bottom: hasFollowingSibling ? NotchMetric.childRowVertical : NotchMetric.childRowLastBottom,
                trailing: NotchMetric.sideInset
            ))
            .background(alignment: .leading) {
                // Elbow: vertical from the parent's dot (x = 16 + 4), radius 5,
                // horizontal into this row's dot.
                GeometryReader { proxy in
                    Path { path in
                        let x = NotchMetric.elbowX
                        let radius = NotchMetric.elbowRadius
                        let midY = proxy.size.height / 2
                        let dotLeading = NotchMetric.childIndent - NotchMetric.childDot / 2
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: midY - radius))
                        path.addQuadCurve(to: CGPoint(x: x + radius, y: midY), control: CGPoint(x: x, y: midY))
                        path.addLine(to: CGPoint(x: dotLeading, y: midY))
                        if hasFollowingSibling {
                            path.move(to: CGPoint(x: x, y: midY))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                    }
                    .stroke(Color.nookElbow, lineWidth: DS.Stroke.elbow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title), subagent, \(session.statusText)")
    }
}

// MARK: - 3 / 4 Turn cards

/// Action row buttons: `30` tall, r9. Primary `#fff` on `#111` 13/590;
/// secondary `.1` fill + `.5px` `.14` ring, 12/590.
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
                .foregroundStyle(style == .primary ? Color(DS.InkDark.buttonInk) : Color.nookTitle)
                .frame(maxWidth: .infinity)
                .frame(height: NotchMetric.buttonHeight)
                .background(
                    style == .primary ? Color.nookTitle : Color(DS.InkDark.secondaryButtonFill),
                    in: shape
                )
                .overlay {
                    if style == .secondary {
                        shape.strokeBorder(Color(DS.InkDark.secondaryButtonRing), lineWidth: DS.Stroke.hairline)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Metric chip: padding `4 9`, r8, `.07` fill; value 11/590 tabular + 10 label `.45`.
private struct NookMetricPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchMetric.metricChipInnerGap) {
            Text(value)
                .font(Font(NotchType.notchCount).monospacedDigit())
                .foregroundStyle(Color.nookTitle)
            Text(label)
                .designText(NotchType.notchChipLabel)
                .foregroundStyle(Color.nookLabel)
        }
        .padding(.horizontal, NotchMetric.metricChipPaddingHorizontal)
        .padding(.vertical, NotchMetric.metricChipPaddingVertical)
        .background(Color(DS.InkDark.chipFillDim), in: RoundedRectangle(cornerRadius: DS.Radius.notchMetricChip, style: .continuous))
    }
}

/// Shared card header: 13/590 title, then `label` 10/590 + elapsed mono 10 `.4`
/// (gap 7), title↔trailing gap 10.
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

    var body: some View {
        VStack(alignment: .leading, spacing: NotchMetric.cardGap) {
            NookCardHeader(title: session.title) {
                Text(session.currentTurn?.outcome == .failed ? "Turn failed" : "Turn complete")
                    .designText(NotchType.notchChip)
                    .foregroundStyle(session.currentTurn?.outcome == .failed
                        ? SessionStatusTone.red.nookColor
                        : Color.nookTurnLabel)
                Text(session.elapsedText(now: .now))
                    .designText(NotchType.monoTimestamp)
                    .foregroundStyle(Color.nookTertiary)
            }
            HStack(spacing: NotchMetric.metricChipGap) {
                NookMetricPill(value: session.totalTokensText, label: "tokens")
                NookMetricPill(value: session.contextText, label: "context")
                NookMetricPill(value: "\(session.stillRunningCount)", label: "still running")
            }
            Text(session.lastAssistantMessage ?? session.currentUserMessage ?? "—")
                .designText(NotchType.notchBody)
                .foregroundStyle(Color(DS.InkDark.summaryBody))
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

/// Turn just started: "Turn started" + timer, `Agent · model · ~/cwd`, USER block.
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
                        .designText(NotchType.notchChip)
                        .foregroundStyle(Color.nookTurnLabel)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(session.elapsedText(now: context.date))
                            .designText(NotchType.monoTimestamp)
                            .foregroundStyle(Color.nookTertiary)
                    }
                }
                Text([session.agent.providerName, session.model, SessionPagePresentationBuilder.abbreviatedWorkspace(session.workspace)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .designText(NotchType.notchCaption)
                    .foregroundStyle(Color.nookSubtitle)
                    .lineLimit(1)
            }
            // Echoed user input: padding `9 11`, r10, `.06` fill, `.5px` `.09` ring.
            let cardShape = RoundedRectangle(cornerRadius: DS.Radius.notchCard, style: .continuous)
            VStack(alignment: .leading, spacing: NotchMetric.userCardGap) {
                Text("USER")
                    .designText(NotchType.notchCardLabel)
                    .foregroundStyle(Color.nookTertiary)
                Text(session.currentUserMessage ?? "—")
                    .designText(NotchType.notchBody)
                    .foregroundStyle(Color(DS.InkDark.echoBody))
                    .lineLimit(NotchMetric.bodyLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, NotchMetric.userCardPaddingVertical)
            .padding(.horizontal, NotchMetric.userCardPaddingHorizontal)
            .background(Color.nookCardFill, in: cardShape)
            .overlay { cardShape.strokeBorder(Color.nookCardRing, lineWidth: DS.Stroke.hairline) }
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
                            .background(Color.nookControlFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to sessions")
                    Text(session.title)
                        .designText(NotchType.sectionTitle)
                        .foregroundStyle(Color.nookTitle)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                // Tier pill: tone at .18 + .32 ring, 6px dot, 10/590 tone text;
                // then a capsule agent chip (.08 fill, .66 text).
                HStack(spacing: NotchMetric.pillRowGap) {
                    let tone = session.statusTone
                    HStack(spacing: NotchMetric.pillDotGap) {
                        Circle().fill(tone.nookColor).frame(width: NotchMetric.pillDot, height: NotchMetric.pillDot)
                        Text(session.statusText)
                            .designText(NotchType.notchChip)
                            .foregroundStyle(tone.nookPillText)
                    }
                    .padding(.horizontal, NotchMetric.pillHorizontalPadding)
                    .frame(height: NotchMetric.pillHeight)
                    .background(tone.nookPillFill, in: Capsule())
                    .overlay { Capsule().strokeBorder(tone.nookPillRing, lineWidth: DS.Stroke.hairline) }
                    Text(session.agent.providerName)
                        .designText(NotchType.notchChip)
                        .foregroundStyle(Color(DS.InkDark.chipTextStrong))
                        .padding(.horizontal, NotchMetric.pillHorizontalPadding)
                        .frame(height: NotchMetric.pillHeight)
                        .background(Color.nookControlFill, in: Capsule())
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
                        .foregroundStyle(Color.nookTertiary)
                    Text("\(session.recentRows.count) items")
                        .designText(NotchType.notchChip)
                        .foregroundStyle(Color(DS.InkDark.count))
                }
                .padding(.bottom, NotchMetric.activityHeaderBottom)
                if session.recentRows.isEmpty {
                    Text("No activity yet")
                        .designText(NotchType.notchCaption)
                        .foregroundStyle(Color.nookLabel)
                        .frame(height: NotchMetric.activityRowHeight)
                } else {
                    ForEach(session.recentRows) { row in
                        HStack(spacing: NotchMetric.activityRowGap) {
                            TimelineTagChip(tag: row.tag, label: row.tag.shortLabel, appearance: .dark, compact: true)
                                .frame(width: NotchMetric.activityTagWidth)
                            Text(row.text)
                                .designText(NotchType.notchCaption)
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

    /// Metric card: padding `7 9`, r10, `.06` fill; value 13/590 tabular,
    /// label 9/590/.04em uppercase `.42`.
    private func metricTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: NotchMetric.metricCardGap) {
            Text(value)
                .font(Font(NotchType.listTitle).monospacedDigit())
                .foregroundStyle(Color.nookTitle)
                .lineLimit(1)
            Text(label)
                .designText(NotchType.notchMetricLabel)
                .foregroundStyle(Color(DS.InkDark.metricLabel))
        }
        .padding(.vertical, NotchMetric.metricCardPaddingVertical)
        .padding(.horizontal, NotchMetric.metricCardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nookCardFill, in: RoundedRectangle(cornerRadius: DS.Radius.notchCard, style: .continuous))
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
        AgentStatusNookStatusDot(tone: model.sessionCount == 0 ? .gray : model.statusTone, size: NotchMetric.compactDot)
            .frame(width: NotchMetric.compactSlot, height: NotchMetric.compactSlot)
            .accessibilityLabel(model.sessionCount == 0 ? "No active Sessions" : "Active Sessions")
    }
}

private struct AgentStatusNookCompactCount: View {
    @ObservedObject var model: AgentStatusNookCompactModel

    var body: some View {
        Text("\(model.sessionCount)")
            .font(Font(NotchType.notchCount).monospacedDigit())
            .foregroundStyle(model.sessionCount == 0 ? Color(DS.InkDark.compactCountIdle) : Color.nookTitle)
            .frame(width: NotchMetric.compactSlot, height: NotchMetric.compactSlot)
            .accessibilityLabel("\(model.sessionCount) Sessions in Notch")
    }
}

private struct AgentStatusNookSettingsButton: View {
    let action: @MainActor () -> Void
    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: NotchMetric.settingsGlyph, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: NotchMetric.settingsButton, height: NotchMetric.settingsButton)
        }
        .buttonStyle(.plain)
        .help("Open Agent Status Settings")
        .accessibilityLabel("Open Agent Status Settings")
    }
}
