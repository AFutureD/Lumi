import AppKit
import NookApp
import NookComponents
import SwiftUI

@MainActor
final class AgentStatusNookController {
    let appState: AppState

    private let model: AgentStatusNookModel
    private let activityQueue: NookActivityQueue
    private let coordinator: AppCoordinator

    init(
        store: MacSessionStore,
        openMainSettings: @escaping @Sendable @MainActor () -> Void
    ) {
        let model = AgentStatusNookModel(store: store)
        let activityQueue = NookActivityQueue()
        let appState = AppState()

        var configuration = NookConfiguration()
        configuration.setHome {
            NookActivityHost(queue: activityQueue) {
                AgentStatusNookHomeView(model: model)
            }
        }
        configuration.setCompactLeading {
            AgentStatusNookCompactStatus(model: model)
        }
        configuration.setCompactTrailing {
            AgentStatusNookCompactCount(model: model)
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
            AgentStatusNookSettingsButton(action: openMainSettings)
        }
        configuration.expandedWidth = 520
        configuration.showsMenuBarExtra = false
        configuration.branding = NookHostBranding(
            hostName: "Agent Status",
            hostTagline: "Live Codex Sessions"
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

        model.onSnapshot = { [activityQueue] previous, current, initial in
            guard !initial else { return }
            Self.enqueueActivities(
                previous: previous,
                current: current,
                hapticEnabled: appState.appearancePreferences.hapticFeedbackEnabled,
                into: activityQueue
            )
        }
    }

    func start() {
        model.start()
        coordinator.start()
        // OpenNook is embedded in a regular AppKit app rather than running as a
        // standalone menu-bar process, so restore the host application's policy.
        NSApp.setActivationPolicy(.regular)
    }

    func stop() async {
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

    private static func enqueueActivities(
        previous: [AgentStatusNookSession],
        current: [AgentStatusNookSession],
        hapticEnabled: Bool,
        into queue: NookActivityQueue
    ) {
        let changes = AgentStatusNookActivityDiff.changedSessions(previous: previous, current: current)
        for session in changes {
            queue.enqueue(NookActivity(
                coalescingKey: session.id.rawValue,
                priority: session.statusTone == .orange ? .high : .normal,
                title: session.title,
                subtitle: activitySubtitle(for: session),
                systemImage: activitySymbol(for: session),
                tint: session.statusTone.swiftUIColor,
                dwell: .seconds(2.8)
            ))
        }
        NookHaptics.confirm(enabled: hapticEnabled && !changes.isEmpty)
    }

    private static func activitySubtitle(for session: AgentStatusNookSession) -> String {
        let message = session.currentUserMessage.map { value in
            value.count > 120 ? String(value.prefix(117)) + "…" : value
        }
        return [session.statusText, message].compactMap { $0 }.joined(separator: " · ")
    }

    private static func activitySymbol(for session: AgentStatusNookSession) -> String {
        switch session.lifecycle {
        case .completed: "checkmark.circle.fill"
        case .failed, .interrupted: "exclamationmark.circle.fill"
        case .waitingForInput where session.phase == .waitingForApproval: "hand.raised.fill"
        default: "terminal"
        }
    }
}

private struct AgentStatusNookHomeView: View {
    @ObservedObject var model: AgentStatusNookModel
    @Environment(\.nookResolvedTheme) private var theme
    @Environment(\.nookContentInsets) private var contentInsets

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.daemonAvailable ? "terminal" : "bolt.horizontal.circle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(theme.secondaryLabel)
                    Text(model.daemonAvailable ? "No active Sessions" : "Daemon unavailable")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                    Text(model.daemonAvailable
                         ? "Start a new Codex Session to see it here."
                         : "Open Agent Status Settings to check the daemon.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                            AgentStatusNookSessionRow(session: session)
                            if index < model.sessions.count - 1 {
                                Divider().overlay(theme.subtleStroke)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, contentInsets.bottom)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct AgentStatusNookSessionRow: View {
    let session: AgentStatusNookSession
    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(session.statusTone.swiftUIColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primaryLabel)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.statusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(session.statusTone.swiftUIColor)
                        .lineLimit(1)
                }
                Text(session.currentUserMessage ?? "Waiting for the first user message")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.statusText)")
    }
}

private struct AgentStatusNookCompactStatus: View {
    @ObservedObject var model: AgentStatusNookModel

    var body: some View {
        Circle()
            .fill(model.sessions.first?.statusTone.swiftUIColor ?? Color.gray)
            .frame(width: 8, height: 8)
            .frame(width: 28, height: 28)
            .accessibilityLabel(model.sessions.first?.statusText ?? "No active Sessions")
    }
}

private struct AgentStatusNookCompactCount: View {
    @ObservedObject var model: AgentStatusNookModel
    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Text("\(model.totalSessionCount)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.primaryLabel)
            .frame(width: 28, height: 28)
            .accessibilityLabel("\(model.totalSessionCount) Sessions in Notch")
    }
}

private struct AgentStatusNookSettingsButton: View {
    let action: @Sendable @MainActor () -> Void
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
