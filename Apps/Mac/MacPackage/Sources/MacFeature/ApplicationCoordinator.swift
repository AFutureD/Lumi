import Diagnostics
import Logging
import Remote
import Transport
import AppKit

private let log = Logger(label: "lifecycle")

@MainActor
public final class ApplicationCoordinator: NSObject {
    private let store = MacSessionStore()
    private lazy var relayHost = RelayHostStatusClient(store: store)
    private lazy var notch: HaloController = {
        var actions = HaloActions()
        actions.openMainSettings = { [weak self] in self?.showNotchSettings() }
        actions.showSession = { [weak self] sessionID in self?.showSession(sessionID) }
        return HaloController(store: store, actions: actions)
    }()
    private let softwareUpdates = SoftwareUpdateController()
    private lazy var mainWindow = MainWindowController(
        store: store,
        relayHost: relayHost,
        nook: notch,
        softwareUpdates: softwareUpdates
    )
    private lazy var daemonAutoUpdater = DaemonAutoUpdater(store: store)
    private var mainWindowCloseObserver: NSObjectProtocol?

    public override init() {
        super.init()
    }

    /// swift-log's bootstrap runs once per process, before anything logs:
    /// `LumiMacApp.main` calls this first. `app.log` sits next to the
    /// daemon's; `-LumiLogLevel debug` turns the per-frame lines on
    /// for one launch.
    public static func bootstrapLogging() {
        let configuration = LogConfiguration(
            subsystem: "app",
            minimumLevel: UserDefaults.standard.string(forKey: "LumiLogLevel").flatMap(Logger.Level.init(lenient:)) ?? .info,
            directory: LogConfiguration.defaultDirectory()
        )
        Diagnostics.bootstrap(configuration)
        log.info("app_started", metadata: .fields([
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            "log_level": configuration.minimumLevel.label.lowercased(),
            "log_directory": configuration.directory,
        ]))
    }

    public func start() {
        // Debug builds must not attach to the production update feed: a started
        // updater would prompt on second launch and offer to replace the dev app.
        #if !DEBUG
        softwareUpdates.start()
        #endif
        installMenu()
        refreshInstalledHooks()
        _ = relayHost
        store.start()
        daemonAutoUpdater.start()
        mainWindow.showWindow(nil)
        observeMainWindowClose()
        notch.start()
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshotExporter.run(notch: notch)
    }

    /// The app stays resident after the main window closes (the Notch keeps
    /// running), so the Dock icon follows the window: hide it on close and
    /// bring it back whenever the window is presented again.
    private func observeMainWindowClose() {
        guard mainWindowCloseObserver == nil, let window = mainWindow.window else { return }
        mainWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
                log.info("main_window_closed_dock_icon_hidden")
            }
        }
    }

    private func presentMainWindow(_ show: () -> Void) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            log.info("main_window_presented_dock_icon_restored")
        }
        show()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func stop() async {
        store.stop()
        relayHost.stop()
        await notch.stop()
        log.info("app_stopped")
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
        guard let helper = Bundle.main.url(forResource: "Spark", withExtension: nil) else { return }
        Task.detached(priority: .utility) {
            let codex = CodexHookInstaller()
            for refresh in [
                { try codex.refreshIfStale(helperSourceURL: helper) },
                { try ClaudeHookInstaller().refreshIfStale(helperSourceURL: helper) },
            ] {
                do {
                    try refresh()
                } catch {
                    log.error("hook_refresh_failed", metadata: .fields(["error": error]))
                }
            }
            guard codex.isInstalled() else { return }
            let trust = await CodexHookTrustAuthorizer().authorize(qos: .utility)
            if trust.needsAttention {
                log.warning("codex_hook_trust_unresolved", metadata: .fields(["state": String(describing: trust)]))
            } else {
                log.debug("codex_hook_trust_ok", metadata: .fields(["state": String(describing: trust)]))
            }
        }
    }

    @objc public func showMainWindow() {
        presentMainWindow {
            mainWindow.showWindow(nil)
            mainWindow.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func showSettings() {
        presentMainWindow {
            mainWindow.selectSettings(.general)
        }
    }

    private func showSession(_ sessionID: SessionID) {
        presentMainWindow {
            store.select(sessionID)
            mainWindow.select(.sessions)
        }
    }

    private func showNotchSettings() {
        presentMainWindow {
            mainWindow.selectSettings(.notch)
        }
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lumi", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(softwareUpdates.makeCheckForUpdatesMenuItem())
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "Quit Lumi", action: #selector(terminate), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let mainWindowItem = windowMenu.addItem(withTitle: "Lumi", action: #selector(showMainWindow), keyEquivalent: "0")
        mainWindowItem.target = self
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }
}
