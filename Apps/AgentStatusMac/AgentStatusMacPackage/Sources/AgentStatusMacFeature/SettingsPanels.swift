import AgentStatusTransport
import AppKit
import ServiceManagement
import SwiftUI

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

    let version: String
    let build: String
    let hookLocation = "~/.codex/hooks.json · agent-status-helper --agent codex"
    let claudeHookLocation = "~/.claude/settings.json · agent-status-helper --agent claude"

    var presentError: (Error) -> Void = { _ in }
    /// Returns `true` when the destructive action was confirmed.
    var confirm: (_ title: String, _ message: String, _ button: String) async -> Bool = { _, _, _ in false }

    private let store: MacSessionStore
    private let loginService = SMAppService.mainApp
    private let daemonService = SMAppService.agent(plistName: "com.huanan.AgentStatusDaemon.plist")

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
            daemonServiceDescription = "Not connected · \(store.connectionError ?? Self.describe(daemonService.status))"
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
            if daemonService.status == .enabled {
                try daemonService.unregister()
            }
            try daemonService.register()
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
        do {
            let installer = CodexHookInstaller()
            if installer.isInstalled() {
                try installer.uninstall()
            } else {
                guard let helper = Bundle.main.url(forResource: "agent-status-helper", withExtension: nil) else {
                    throw CodexHookInstallerError.helperMissing
                }
                try installer.install(helperSourceURL: helper)
            }
        } catch {
            presentError(error)
        }
        reload()
    }

    func toggleClaudeHook() {
        do {
            let installer = ClaudeHookInstaller()
            if installer.isInstalled() {
                try installer.uninstall()
            } else {
                guard let helper = Bundle.main.url(forResource: "agent-status-helper", withExtension: nil) else {
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
                "Clear Agent Status Session history?",
                "This deletes Agent Status history from the daemon and synced app databases. It does not delete Codex's own files.",
                "Clear History"
            ) else { return }
            store.clearHistory()
        }
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "daemon is not installed"
        case .enabled: "daemon is registered but unavailable"
        case .requiresApproval: "approval is required in System Settings"
        case .notFound: "embedded daemon service was not found"
        @unknown default: "daemon status is unknown"
        }
    }
}

// MARK: - Panels

struct GeneralSettingsPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Startup") {
                SettingsCard {
                    SettingsRow(title: "Open Agent Status at login") {
                        Toggle("Open Agent Status at login", isOn: Binding(
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
                            Text("Stop & uninstall").foregroundStyle(AgentStatusDesign.Color.UI.destructiveText)
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
                        titleFont: AgentStatusDesign.Font.UI.rowTitle
                    ) {
                        Button { model.clearHistory() } label: {
                            Text("Clear history…").foregroundStyle(AgentStatusDesign.Color.UI.destructiveText)
                        }
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
            SettingsSection(title: "Codex") {
                SettingsCard {
                    HStack(spacing: 12) {
                        Group {
                            if let image = AgentIcons.image(for: .codex, pointSize: 20) {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.hookInstalled ? "Codex integration installed" : "Codex integration not installed")
                                .font(AgentStatusDesign.Font.UI.rowTitle)
                            Text(model.hookLocation)
                                .font(AgentStatusDesign.Font.UI.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.toggleCodexHook() } label: {
                            Text(model.hookInstalled ? "Remove Hook" : "Install Hook")
                                .foregroundStyle(model.hookInstalled ? AgentStatusDesign.Color.UI.destructiveText : .primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 52)
                    Divider()
                    SettingsFootnote(text: "Hooks go into ~/.codex/hooks.json. Installing the integration preserves existing Hook handlers.")
                }
            }
            SettingsSection(title: "Claude Code") {
                SettingsCard {
                    HStack(spacing: 12) {
                        Group {
                            if let image = AgentIcons.image(for: .claude, pointSize: 20) {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.claudeHookInstalled ? "Claude Code integration installed" : "Claude Code integration not installed")
                                .font(AgentStatusDesign.Font.UI.rowTitle)
                            Text(model.claudeHookLocation)
                                .font(AgentStatusDesign.Font.UI.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.toggleClaudeHook() } label: {
                            Text(model.claudeHookInstalled ? "Remove Hook" : "Install Hook")
                                .foregroundStyle(model.claudeHookInstalled ? AgentStatusDesign.Color.UI.destructiveText : .primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 52)
                    Divider()
                    SettingsFootnote(text: "Hooks go into the `hooks` key of ~/.claude/settings.json; other settings and other tools' hooks are preserved. The helper reads the session transcript on every hook.")
                }
            }
        }
        .onAppear { model.reload() }
    }
}

struct AboutSettingsPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Agent Status") {
                SettingsCard {
                    SettingsFactRow(label: "Version", value: "\(model.version) (\(model.build))", isMonospaced: true)
                    Divider()
                    SettingsFactRow(label: "Frameworks", value: "AppKit main window · OpenNook notch · UIKit iPhone app")
                    Divider()
                    SettingsFactRow(
                        label: "Updates",
                        value: "No automatic update channel is configured for this build.",
                        valueStyle: .secondary
                    )
                    Divider()
                    SettingsButtonRow {
                        Button("About Agent Status") { model.showAbout() }
                    }
                }
            }
        }
    }
}
