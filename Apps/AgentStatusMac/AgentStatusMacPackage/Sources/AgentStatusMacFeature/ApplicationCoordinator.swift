import AgentStatusRemote
import AgentStatusTransport
import AppKit

@MainActor
public final class ApplicationCoordinator: NSObject {
    private let store = MacSessionStore()
    private lazy var relayHost = RelayHostStatusClient(store: store)
    private lazy var notch: AgentStatusNookController = {
        var actions = AgentStatusNookActions()
        actions.openMainSettings = { [weak self] in self?.showNotchSettings() }
        actions.showSession = { [weak self] sessionID in self?.showSession(sessionID) }
        return AgentStatusNookController(store: store, actions: actions)
    }()
    private lazy var mainWindow = MainWindowController(store: store, relayHost: relayHost, nook: notch)
    private lazy var daemonAutoUpdater = DaemonAutoUpdater(store: store)

    public override init() {
        super.init()
    }

    public func start() {
        installMenu()
        refreshInstalledHooks()
        // The Relay host moved into the daemon; the app's own registration
        // (pre-daemon builds) is retired rather than migrated.
        try? SecureStore(service: "com.huanan.AgentStatusMac.relay").delete(account: "host-credentials-v1")
        _ = relayHost
        store.start()
        daemonAutoUpdater.start()
        mainWindow.showWindow(nil)
        notch.start()
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshotExporter.run(notch: notch)
    }

    public func stop() async {
        store.stop()
        relayHost.stop()
        await notch.stop()
    }

    /// Hooks execute the helper copied into Application Support, not the one
    /// inside the app bundle, so an app update must refresh the copy — a
    /// stale helper keeps exiting 0 while silently dropping every ingest
    /// capability added since it was built.
    ///
    /// Codex trust is then re-authorized on every launch, not only after a
    /// rewrite of our own: its trust records are keyed by a handler's position
    /// in `hooks.json`, so any tool editing that file silently untrusts ours.
    private func refreshInstalledHooks() {
        guard let helper = Bundle.main.url(forResource: "agent-status-helper", withExtension: nil) else { return }
        Task.detached(priority: .utility) {
            let codex = CodexHookInstaller()
            for refresh in [
                { try codex.refreshIfStale(helperSourceURL: helper) },
                { try ClaudeHookInstaller().refreshIfStale(helperSourceURL: helper) },
            ] {
                do {
                    try refresh()
                } catch {
                    NSLog("agent-status hook refresh failed: %@", String(describing: error))
                }
            }
            guard codex.isInstalled() else { return }
            let trust = CodexHookTrustAuthorizer().authorize()
            if trust.needsAttention {
                NSLog("agent-status codex hook trust unresolved: %@", String(describing: trust))
            }
        }
    }

    @objc private func showMainWindow() {
        mainWindow.showWindow(nil)
        mainWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        mainWindow.selectSettings(.general)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSession(_ sessionID: SessionID) {
        store.select(sessionID)
        mainWindow.select(.sessions)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showNotchSettings() {
        mainWindow.selectSettings(.notch)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Agent Status", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "Quit Agent Status", action: #selector(terminate), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let mainWindowItem = windowMenu.addItem(withTitle: "Agent Status", action: #selector(showMainWindow), keyEquivalent: "0")
        mainWindowItem.target = self
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }
}
