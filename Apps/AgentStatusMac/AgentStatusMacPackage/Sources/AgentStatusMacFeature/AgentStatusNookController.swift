import AgentStatusCore
import AgentStatusTransport
import AppKit
import NookApp
import NookComponents
import SwiftUI

enum AgentStatusNookAdjustmentDefaults {
    static let compactWidth: CGFloat = 64
    static let expandedWidth: CGFloat = 520
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
                    tint: event.row.tag.accentColor,
                    dwell: .seconds(2.8)
                ))
            }
        }
        NookHaptics.confirm(enabled: hapticEnabled)
    }
}

// MARK: - Palette (design handoff, Notch / dark)

private enum NookInk {
    static let body = Color.white.opacity(0.8)
    static let title = Color.white
    static let subtitle = Color.white.opacity(0.52)
    static let label = Color.white.opacity(0.45)
    static let label2 = Color.white.opacity(0.4)
    static let timestamp = Color.white.opacity(0.38)
    static let timestamp2 = Color.white.opacity(0.32)
    static let childTitle = Color.white.opacity(0.72)
    static let hairline = Color.white.opacity(0.08)
    static let guide = Color.white.opacity(0.16)
    static let fill06 = Color.white.opacity(0.06)
    static let fill07 = Color.white.opacity(0.07)
    static let fill09 = Color.white.opacity(0.09)
    static let fill10 = Color.white.opacity(0.10)
    static let fill12 = Color.white.opacity(0.12)
    static let running = Color(hex: 0x4C9BFF)
    static let waiting = Color(hex: 0xF0A030)
    static let idle = Color.white.opacity(0.34)
    static let success = Color(hex: 0x4ED96C)
    static let turnStarted = Color(hex: 0x9DC7FF)
    static let buttonInk = Color(hex: 0x111111)
}

private extension SessionStatusTone {
    var nookColor: Color {
        switch self {
        case .blue: NookInk.running
        case .orange: NookInk.waiting
        case .green: NookInk.success
        case .gray: NookInk.idle
        }
    }
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
        .padding(.top, 4)
        .padding(.bottom, contentInsets.bottom)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.18), value: model.route)
    }

    @ViewBuilder
    private var listBody: some View {
        if model.sessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.daemonAvailable ? "terminal" : "bolt.horizontal.circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(theme.secondaryLabel)
                Text(model.daemonAvailable ? "No active Sessions" : "Daemon unavailable")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryLabel)
                Text(model.daemonAvailable
                     ? "Start a Codex or Claude Code Session to see it here."
                     : "Open Agent Status Settings to check the daemon.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
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
                                    onOpen: { model.showDetail(session.id) },
                                    onArchive: { model.archive(session.id) }
                                )
                            }
                            if let next, !next.isChild, index < model.sessions.count - 1 {
                                NookInk.hairline.frame(height: 1).padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text("\(model.sessions.filter { !$0.isChild }.count) of \(model.totalSessionCount) sessions")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NookInk.label2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
        }
    }
}

// MARK: - 5B Session list

private struct AgentStatusNookAgentChip: View {
    let agent: AgentKind
    var dimmed = false

    var body: some View {
        Text(agent.providerName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.6))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(dimmed ? NookInk.fill07 : NookInk.fill09, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct AgentStatusNookStatusDot: View {
    let tone: SessionStatusTone
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(tone.nookColor)
            .frame(width: size, height: size)
            .background(Circle().fill(tone.nookColor.opacity(0.24)).frame(width: size + 6, height: size + 6))
    }
}

/// Grid `8px 1fr auto`, gap 10, padding `10px 16px 4px`. The 28pt trailing
/// slot shows the relative time, replaced in place by the archive button on
/// hover when the turn has ended — no layout shift.
private struct AgentStatusNookSessionRow: View {
    let session: AgentStatusNookSession
    let onOpen: () -> Void
    let onArchive: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 10) {
                AgentStatusNookStatusDot(tone: session.statusTone)
                    .frame(width: 8, height: 8)

                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NookInk.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 16) {
                    AgentStatusNookAgentChip(agent: session.agent, dimmed: session.turnEnded)
                    ZStack(alignment: .trailing) {
                        if hovering && session.turnEnded {
                            Button(action: onArchive) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(Color.white.opacity(0.72))
                                    .frame(width: 20, height: 20)
                                    .background(NookInk.fill12, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Archive")
                            .accessibilityLabel("Archive session")
                        } else {
                            Text(SessionRelativeTimeFormatter.string(from: session.lastActivityAt))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(NookInk.timestamp)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 28, alignment: .trailing)
                }
                .padding(.leading, 10)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.statusText)")
    }
}

/// Subagent row: grid `6px 1fr auto`, padding `3px 16px 3px 34px`, an elbow
/// guide from the parent dot that continues while more children follow.
private struct AgentStatusNookSubagentRow: View {
    let session: AgentStatusNookSession
    let hasFollowingSibling: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(session.statusTone.nookColor)
                    .frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NookInk.childTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SessionRelativeTimeFormatter.string(from: session.lastActivityAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NookInk.timestamp2)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(EdgeInsets(top: 3, leading: 34, bottom: 3, trailing: 16))
            .background(alignment: .leading) {
                // Elbow: vertical from the parent's dot (x = 16 + 4), horizontal
                // into this row's dot.
                GeometryReader { proxy in
                    Path { path in
                        let x: CGFloat = 20
                        let midY = proxy.size.height / 2
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: midY - 5))
                        path.addQuadCurve(to: CGPoint(x: x + 5, y: midY), control: CGPoint(x: x, y: midY))
                        path.addLine(to: CGPoint(x: 31, y: midY))
                        if hasFollowingSibling {
                            path.move(to: CGPoint(x: x, y: midY))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                    }
                    .stroke(NookInk.guide, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title), subagent, \(session.statusText)")
    }
}

// MARK: - 5C / 5D Turn cards

private struct NookCardButton: View {
    enum Style { case primary, secondary }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style == .primary ? NookInk.buttonInk : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    style == .primary ? Color.white : NookInk.fill10,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    if style == .secondary {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct NookMetricPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(NookInk.title)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(NookInk.label)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(NookInk.fill07, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Turn complete: title + "Turn complete" · elapsed, metric pills, summary
/// (6 lines), "Jump to Agent".
private struct AgentStatusNookTurnEndedCard: View {
    let session: AgentStatusNookSession
    @ObservedObject var model: AgentStatusNookModel
    let actions: AgentStatusNookActions

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NookInk.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(session.currentTurn?.outcome == .failed ? "Turn failed" : "Turn complete")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.currentTurn?.outcome == .failed ? Color(hex: 0xEE4038) : NookInk.success)
                Text(session.elapsedText(now: .now))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NookInk.label2)
            }
            HStack(spacing: 6) {
                NookMetricPill(value: session.totalTokensText, label: "tokens")
                NookMetricPill(value: session.contextText, label: "context")
                NookMetricPill(value: "\(session.stillRunningCount)", label: "still running")
            }
            Text(session.lastAssistantMessage ?? session.currentUserMessage ?? "—")
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            NookCardButton(title: "Jump to Agent", style: .primary) {
                AgentActivation.jump(to: session.agent, workspace: session.workspace)
                model.showList()
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
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
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NookInk.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Turn started")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NookInk.turnStarted)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(session.elapsedText(now: context.date))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NookInk.label2)
                }
            }
            Text([session.agent.providerName, session.model, SessionPagePresentationBuilder.abbreviatedWorkspace(session.workspace)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(NookInk.subtitle)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                Text("USER")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.54)
                    .foregroundStyle(NookInk.label2)
                Text(session.currentUserMessage ?? "—")
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
            .background(NookInk.fill06, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .contentShape(Rectangle())
        .onTapGesture { model.showDetail(session.id) }
    }
}

// MARK: - 5E Session detail

private struct AgentStatusNookDetailView: View {
    let session: AgentStatusNookSession
    @ObservedObject var model: AgentStatusNookModel
    let actions: AgentStatusNookActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: { model.showList() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 22, height: 20)
                        .background(NookInk.fill09, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to sessions")
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NookInk.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(session.statusTone.nookColor).frame(width: 6, height: 6)
                    Text(session.statusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(NookInk.fill07, in: Capsule())
                AgentStatusNookAgentChip(agent: session.agent)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                metricTile(session.totalTokensText, "TOKENS")
                metricTile(session.contextText, "CONTEXT")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    metricTile(session.elapsedText(now: context.date), "ELAPSED")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("RECENT ACTIVITY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                    Text("\(session.recentRows.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .padding(.bottom, 2)
                if session.recentRows.isEmpty {
                    Text("No activity yet")
                        .font(.system(size: 11))
                        .foregroundStyle(NookInk.label)
                        .frame(height: 22)
                } else {
                    ForEach(session.recentRows) { row in
                        HStack(spacing: 12) {
                            TimelineTagChip(tag: row.tag, label: row.label, dark: true)
                                .frame(width: 60)
                            Text(row.text)
                                .font(.system(size: 11))
                                .foregroundStyle(NookInk.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 22)
                    }
                }
            }

            HStack(spacing: 8) {
                NookCardButton(title: "Show in App", style: .primary) {
                    actions.showSession(session.id)
                }
                NookCardButton(title: "Jump to Agent", style: .secondary) {
                    AgentActivation.jump(to: session.agent, workspace: session.workspace)
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
    }

    private func metricTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(NookInk.title)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.36)
                .foregroundStyle(Color.white.opacity(0.42))
        }
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NookInk.fill06, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

// MARK: - Collapsed bar

private struct AgentStatusNookCompactStatus: View {
    @ObservedObject var model: AgentStatusNookCompactModel

    var body: some View {
        Circle()
            .fill(model.statusTone.nookColor)
            .frame(width: 8, height: 8)
            .frame(width: 28, height: 28)
            .accessibilityLabel(model.sessionCount == 0 ? "No active Sessions" : "Active Sessions")
    }
}

private struct AgentStatusNookCompactCount: View {
    @ObservedObject var model: AgentStatusNookCompactModel

    var body: some View {
        Text("\(model.sessionCount)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(width: 28, height: 28)
            .accessibilityLabel("\(model.sessionCount) Sessions in Notch")
    }
}

private struct AgentStatusNookSettingsButton: View {
    let action: @MainActor () -> Void
    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Open Agent Status Settings")
        .accessibilityLabel("Open Agent Status Settings")
    }
}
