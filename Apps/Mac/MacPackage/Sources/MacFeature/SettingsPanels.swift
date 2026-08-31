import Core
import Diagnostics
import Logging
import Transport
import AppKit
import ServiceManagement
import SwiftUI

private let log = Logger(label: "ui")

/// State + actions behind the General / Daemon / Agents / About panels.
/// The hosting view controller supplies window-bound confirmation and error UI.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var loginEnabled = false
    @Published private(set) var daemonRegistered = false
    @Published private(set) var daemonServiceDescription = ""
    @Published private(set) var isDaemonConnected = false
    @Published private(set) var daemonUptimeText: String?
    @Published private(set) var daemonSocketPath: String?
    @Published private(set) var activeSessionCount = 0
    @Published private(set) var storedSessionCount = 0
    @Published private(set) var historySizeText: String?
    @Published private(set) var hookInstalled = false
    @Published private(set) var claudeHookInstalled = false
    @Published private(set) var codexHookTrust: CodexHookTrustState = .unsupported
    @Published private(set) var isAuthorizingCodexHooks = false

    let version: String
    let build: String
    let hookLocation = "~/.codex/hooks.json"
    let claudeHookLocation = "~/.claude/settings.json"
    /// The Filters group's own state; shares this model's error surface.
    let filterRules = SessionFilterRulesModel()
    /// `~/Library/Logs/Lumi` — daemon.log, helper.log, app.log and errors.log.
    let logDirectory = LogConfiguration.defaultDirectory()
    var logDirectoryDescription: String {
        SessionPagePresentationBuilder.abbreviatedWorkspace(logDirectory.path) ?? logDirectory.path
    }

    var presentError: (Error) -> Void = { _ in }
    /// Returns `true` when the destructive action was confirmed.
    var confirm: (_ title: String, _ message: String, _ button: String) async -> Bool = { _, _, _ in false }

    private let store: MacSessionStore
    private let loginService = SMAppService.mainApp
    private let daemonService = DaemonServiceManager()
    /// Each probe launches a `codex app-server`, so panel re-appearances reuse
    /// the last answer for a while.
    private var lastCodexTrustProbe: Date?
    private static let codexTrustProbeInterval: TimeInterval = 60

    init(store: MacSessionStore) {
        self.store = store
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        store.observe { [weak self] in self?.reloadDaemonDiagnostics() }
        reload()
    }

    /// Re-reads every service status; called when a panel appears.
    func reload() {
        loginEnabled = loginService.status == .enabled
        daemonRegistered = daemonService.status == .enabled
        hookInstalled = CodexHookInstaller().isInstalled()
        claudeHookInstalled = ClaudeHookInstaller().isInstalled()
        reloadDaemonDiagnostics()
        probeCodexHookTrust()
    }

    /// Read-only check of whether Codex will actually run our handlers. Skipped
    /// while the hook is not installed, and rate-limited otherwise.
    private func probeCodexHookTrust(force: Bool = false) {
        guard hookInstalled else {
            codexHookTrust = .noHooks
            return
        }
        if !force, let last = lastCodexTrustProbe, Date().timeIntervalSince(last) < Self.codexTrustProbeInterval {
            return
        }
        lastCodexTrustProbe = Date()
        Task { [weak self] in
            let state = await CodexHookTrustAuthorizer().probe(qos: .utility)
            self?.codexHookTrust = state
        }
    }

    private func reloadDaemonDiagnostics() {
        if let health = store.health {
            isDaemonConnected = true
            daemonServiceDescription = "Running"
            daemonUptimeText = SessionElapsedFormatter.string(from: TimeInterval(health.uptimeSeconds))
            daemonSocketPath = SessionPagePresentationBuilder.abbreviatedWorkspace(health.socketPath)
            activeSessionCount = store.sessions.filter {
                switch $0.lifecycle {
                case .starting, .running, .waitingForInput: true
                default: false
                }
            }.count
        } else {
            isDaemonConnected = false
            daemonServiceDescription = "Not connected · \(store.connectionError ?? daemonService.describeStatus())"
            daemonUptimeText = nil
            daemonSocketPath = nil
            activeSessionCount = 0
        }
        storedSessionCount = store.sessions.count
        historySizeText = store.cacheDatabaseSizeBytes().map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }

    // MARK: Actions

    /// Opens the log folder in Finder (creating it, so the button always lands somewhere).
    func revealLogs() {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        log.info("logs_revealed")
        NSWorkspace.shared.activateFileViewerSelecting([logDirectory])
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try loginService.register()
            } else {
                try loginService.unregister()
            }
        } catch {
            presentError(error)
        }
        reload()
    }

    func installDaemon() {
        do {
            try daemonService.register()
            store.refresh()
        } catch {
            presentError(error)
        }
        reload()
    }

    func reinstallDaemon() {
        do {
            try daemonService.reinstall()
            store.refresh()
        } catch {
            presentError(error)
        }
        reload()
    }

    func uninstallDaemon() {
        Task {
            guard await confirm(
                "Stop and uninstall the daemon?",
                "Session collection stops until you install it again. Stored history is kept.",
                "Stop & Uninstall"
            ) else { return }
            do {
                try await daemonService.unregister()
                store.refresh()
            } catch {
                presentError(error)
            }
            reload()
        }
    }

    func toggleCodexHook() {
        var installed = false
        do {
            let installer = CodexHookInstaller()
            if installer.isInstalled() {
                try installer.uninstall()
            } else {
                guard let helper = Bundle.main.url(forResource: "Spark", withExtension: nil) else {
                    throw CodexHookInstallerError.helperMissing
                }
                try installer.install(helperSourceURL: helper)
                installed = true
            }
        } catch {
            presentError(error)
        }
        reload()
        // A freshly written hooks.json is untrusted by definition: Codex keys
        // trust to a handler's position in the file, and the install just moved
        // one in.
        if installed { authorizeCodexHooks() }
    }

    /// Writes the trust records Codex is missing for our handlers, then reports
    /// what Codex will enforce afterwards.
    func authorizeCodexHooks() {
        guard !isAuthorizingCodexHooks else { return }
        isAuthorizingCodexHooks = true
        Task { [weak self] in
            let state = await CodexHookTrustAuthorizer().authorize(qos: .userInitiated)
            guard let self else { return }
            isAuthorizingCodexHooks = false
            lastCodexTrustProbe = Date()
            codexHookTrust = state
        }
    }

    func toggleClaudeHook() {
        do {
            let installer = ClaudeHookInstaller()
            if installer.isInstalled() {
                try installer.uninstall()
            } else {
                guard let helper = Bundle.main.url(forResource: "Spark", withExtension: nil) else {
                    throw CodexHookInstallerError.helperMissing
                }
                try installer.install(helperSourceURL: helper)
            }
        } catch {
            presentError(error)
        }
        reload()
    }

    func clearHistory() {
        Task {
            guard await confirm(
                "Clear Lumi Session history?",
                "This deletes Lumi history from the daemon and synced app databases. It does not delete Codex's own files.",
                "Clear History"
            ) else { return }
            store.clearHistory()
        }
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

}

// MARK: - Panels

struct GeneralSettingsPanel: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var softwareUpdates: SoftwareUpdateController

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Startup") {
                SettingsCard {
                    SettingsRow(title: "Open Lumi at login") {
                        Toggle("Open Lumi at login", isOn: Binding(
                            get: { model.loginEnabled },
                            set: { model.setLoginEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    Divider()
                    SettingsFootnote(text: "The daemon is managed independently in Daemon settings.")
                }
            }
            SettingsSection(title: "Software Updates") {
                SettingsCard {
                    SettingsRow(title: "Automatically check for updates") {
                        Toggle(
                            "Automatically check for updates",
                            isOn: Binding(
                                get: { softwareUpdates.automaticallyChecksForUpdates },
                                set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    Divider()
                    SettingsFootnote(text: "Lumi asks before downloading or installing an update.")
                }
            }
        }
        .onAppear { model.reload() }
    }
}

struct DaemonSettingsPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Local service") {
                SettingsCard {
                    SettingsFactRow(label: "Status", value: model.daemonServiceDescription)
                    Divider()
                    SettingsFactRow(label: "Uptime", value: model.daemonUptimeText ?? "—", isMonospaced: model.daemonUptimeText != nil)
                    Divider()
                    SettingsFactRow(label: "Active sessions", value: "\(model.activeSessionCount)", isMonospaced: true)
                    Divider()
                    SettingsFactRow(label: "Stored sessions", value: "\(model.storedSessionCount)", isMonospaced: true)
                    Divider()
                    SettingsFactRow(label: "Socket", value: model.daemonSocketPath ?? "—", isMonospaced: model.daemonSocketPath != nil)
                }
                HStack(spacing: 8) {
                    if model.daemonRegistered {
                        Button("Reinstall daemon") { model.reinstallDaemon() }
                        Button { model.uninstallDaemon() } label: {
                            Text("Stop & uninstall").foregroundStyle(Design.Color.UI.destructiveText)
                        }
                    } else {
                        Button("Install & Start daemon") { model.installDaemon() }
                    }
                }
                .padding(.top, 2)
            }

            SettingsSection(title: "Session history") {
                SettingsCard {
                    SettingsRow(
                        title: historyTitle,
                        subtitle: "History stays in SQLite until you delete it.",
                        titleFont: Design.Font.UI.rowTitle
                    ) {
                        Button { model.clearHistory() } label: {
                            Text("Clear history…").foregroundStyle(Design.Color.UI.destructiveText)
                        }
                    }
                }
            }

            SettingsSection(title: "Logs") {
                SettingsCard {
                    SettingsRow(
                        title: model.logDirectoryDescription,
                        subtitle: "daemon.log, helper.log and app.log, plus errors.log with every error from all three. Session content is never written.",
                        titleFont: Design.Font.UI.rowTitle
                    ) {
                        Button("Show in Finder") { model.revealLogs() }
                    }
                }
            }
        }
        .onAppear { model.reload() }
    }

    private var historyTitle: String {
        let sessions = "\(model.storedSessionCount) stored session\(model.storedSessionCount == 1 ? "" : "s")"
        if let size = model.historySizeText {
            return "\(sessions) · \(size)"
        }
        return sessions
    }
}

struct AgentsSettingsPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Integrations", maxWidth: Design.Layout.settingsWideCardMaximumWidth) {
                SettingsCard {
                    codexRow
                    Divider()
                    claudeRow
                    Divider()
                    SettingsFootnote(text: "Hooks go into each agent's own config file. Installing or removing keeps other tools' handlers.")
                }
            }
            SessionFiltersGroup(model: model.filterRules)
        }
        .onAppear {
            model.reload()
            model.filterRules.presentError = model.presentError
            model.filterRules.load()
        }
    }

    /// Codex only runs handlers it has trusted, and it fails silently when it
    /// has not — so an untrusted install swaps the main button for the one
    /// action that restores ingest (`Trust`) and moves `Remove` into the
    /// row's context menu.
    @ViewBuilder private var codexRow: some View {
        let untrusted = codexUntrusted
        IntegrationRow(
            icon: AgentIcons.image(for: .codex, pointSize: 20),
            name: "Codex",
            configPath: model.hookLocation,
            subtitle: codexSubtitle,
            isWarning: untrusted,
            isInstalled: model.hookInstalled
        ) {
            if untrusted {
                Button(model.isAuthorizingCodexHooks ? "Trusting…" : "Trust") { model.authorizeCodexHooks() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isAuthorizingCodexHooks)
            } else if model.hookInstalled {
                Button { model.toggleCodexHook() } label: {
                    Text("Remove").foregroundStyle(Design.Color.UI.destructiveText)
                }
            } else {
                Button("Install") { model.toggleCodexHook() }
            }
        }
        .contextMenu {
            if untrusted {
                Button("Remove") { model.toggleCodexHook() }
            }
        }
    }

    @ViewBuilder private var claudeRow: some View {
        IntegrationRow(
            icon: AgentIcons.image(for: .claude, pointSize: 20),
            name: "Claude Code",
            configPath: model.claudeHookLocation,
            subtitle: model.claudeHookInstalled ? "Installed" : "Not installed",
            isWarning: false,
            isInstalled: model.claudeHookInstalled
        ) {
            if model.claudeHookInstalled {
                Button { model.toggleClaudeHook() } label: {
                    Text("Remove").foregroundStyle(Design.Color.UI.destructiveText)
                }
            } else {
                Button("Install") { model.toggleClaudeHook() }
            }
        }
    }

    private var codexUntrusted: Bool {
        if case .untrusted = model.codexHookTrust { return true }
        return false
    }

    private var codexSubtitle: String {
        guard model.hookInstalled else { return "Not installed" }
        return switch model.codexHookTrust {
        case let .trusted(count):
            "Installed · \(count) handler\(count == 1 ? "" : "s")"
        case let .untrusted(keys):
            "Codex has not trusted \(keys.count) handler\(keys.count == 1 ? "" : "s") — Sessions stop arriving"
        case .failed:
            "Installed · trust unverified — run /hooks in Codex to check"
        case .unsupported, .noHooks:
            "Installed"
        }
    }
}

/// One integration: 20pt icon, name with the mono config path on the same
/// baseline, a state (or warning) subtitle, and a single trailing button.
private struct IntegrationRow<Action: View>: View {
    let icon: NSImage?
    let name: String
    let configPath: String
    let subtitle: String
    let isWarning: Bool
    let isInstalled: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
            }
            .opacity(isInstalled ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(Design.Font.UI.rowTitle)
                    Text(configPath)
                        .font(Design.Font.UI.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitle)
                    .font(Design.Font.UI.caption)
                    .foregroundStyle(isWarning ? AnyShapeStyle(Design.Color.UI.warningText) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
    }
}

struct AboutSettingsPanel: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var softwareUpdates: SoftwareUpdateController

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Lumi") {
                SettingsCard {
                    SettingsFactRow(label: "Version", value: "\(model.version) (\(model.build))", isMonospaced: true)
                    Divider()
                    SettingsFactRow(label: "Frameworks", value: "AppKit main window · OpenNook notch · UIKit iPhone app")
                    Divider()
                    SettingsFactRow(
                        label: "Updates",
                        value: softwareUpdates.automaticallyChecksForUpdates ? "Stable · Automatic checks on" : "Stable · Automatic checks off",
                        valueStyle: .secondary
                    )
                    Divider()
                    SettingsButtonRow {
                        Button("Check for Updates…") { softwareUpdates.checkForUpdates() }
                            .disabled(!softwareUpdates.canCheckForUpdates)
                        Button("About Lumi") { model.showAbout() }
                    }
                }
            }
        }
    }
}
