import AgentStatusTransport
import AppKit

@MainActor
public final class ApplicationCoordinator: NSObject {
    private let store = MacSessionStore()
    private lazy var relayHost = RelayHostController(store: store)
    private lazy var notch: AgentStatusNookController = {
        var actions = AgentStatusNookActions()
        actions.openMainSettings = { [weak self] in self?.showNotchSettings() }
        actions.showSession = { [weak self] sessionID in self?.showSession(sessionID) }
        return AgentStatusNookController(store: store, actions: actions)
    }()
    private lazy var mainWindow = MainWindowController(store: store, relayHost: relayHost, nook: notch)

    public override init() {
        super.init()
    }

    public func start() {
        installMenu()
        _ = relayHost
        store.start()
        mainWindow.showWindow(nil)
        notch.start()
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshotExporter.run(notch: notch)
    }

    public func stop() async {
        store.stop()
        await relayHost.stop()
        await notch.stop()
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
