import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    enum Tab: Int {
        case sessions
        case pairing
        case settings
    }

    private let rootController: RootSplitViewController
    private let toolbarController: MainWindowToolbarController

    init(store: MacSessionStore, relayHost: RelayHostStatusClient, nook: HaloController) {
        rootController = RootSplitViewController(store: store, relayHost: relayHost, nook: nook)
        toolbarController = MainWindowToolbarController(
            store: store,
            relayHost: relayHost,
            splitView: rootController.splitView
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumi"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        // Without a transparent titlebar AppKit draws a hard "scroll pocket" line
        // under the toolbar wherever the column content does not scroll beneath it.
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1_200, height: 640)

        super.init(window: window)
        window.contentViewController = rootController
        // Setting the content view controller re-sizes the window to the view's
        // fitting size; restore the design size (or the saved frame) afterwards.
        window.setContentSize(NSSize(width: 1_440, height: 860))
        if !window.setFrameUsingName("Lumi.MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("Lumi.MainWindow")
        toolbarController.window = window
        toolbarController.actions = rootController.toolbarActions()
        window.toolbar = toolbarController.toolbar
        rootController.onSelection = { [weak toolbarController] tab in
            toolbarController?.select(tab)
        }
        rootController.onToolbarStateChange = { [weak toolbarController] in
            toolbarController?.updateState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func select(_ tab: Tab) {
        rootController.select(tab)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func selectSettings(_ section: SettingsSectionID) {
        rootController.selectSettings(section)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Persisted column geometry. Only user gestures (divider drags, sidebar toggle)
/// write here; data refreshes never touch the split view.
@MainActor
enum MainWindowLayoutPreferences {
    private static let defaults = UserDefaults.standard
    private static let sessionsListWidthKey = "Lumi.Layout.SessionsListWidth"
    private static let settingsListWidthKey = "Lumi.Layout.SettingsListWidth"
    private static let sidebarCollapsedKey = "Lumi.Layout.SidebarCollapsed"

    static var sessionsListWidth: CGFloat {
        get { stored(sessionsListWidthKey) ?? Design.Layout.sessionListWidth }
        set { defaults.set(Double(newValue), forKey: sessionsListWidthKey) }
    }

    static var settingsListWidth: CGFloat {
        get { stored(settingsListWidthKey) ?? Design.Layout.settingsListWidth }
        set { defaults.set(Double(newValue), forKey: settingsListWidthKey) }
    }

    static var isSidebarCollapsed: Bool {
        get { defaults.bool(forKey: sidebarCollapsedKey) }
        set { defaults.set(newValue, forKey: sidebarCollapsedKey) }
    }

    private static func stored(_ key: String) -> CGFloat? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        return value > 0 ? CGFloat(value) : nil
    }
}

/// Mail-style hierarchy: one navigation sidebar, one context list, and one detail.
/// Sessions and Settings both use all three columns; Pairing collapses the context list.
///
/// Width rules: the sidebar is fixed (224), the context list keeps its width across
/// window resizes (only divider drags change it), and the detail absorbs everything.
@MainActor
final class RootSplitViewController: NSSplitViewController {
    private let navigation: NavigationSidebarViewController
    private let contentListTabs: NSTabViewController
    private let detailPages: SwitchingContainerViewController
    private let navigationItem: NSSplitViewItem
    private let contentListItem: NSSplitViewItem
    private let detailItem: NSSplitViewItem
    private let sessionList: SessionListViewController
    private let sessionDetail: SessionDetailViewController
    private let pairing: PairingViewController
    private let settingsNavigation: SettingsNavigationViewController
    private let settingsDetail: SettingsDetailViewController
    private var selectedTab: MainWindowController.Tab = .sessions
    private var didApplyInitialLayout = false
    private var isApplyingLayout = false
    private var resizeObserver: NSObjectProtocol?
    private var sidebarObservation: NSKeyValueObservation?
    var onSelection: ((MainWindowController.Tab) -> Void)?
    var onToolbarStateChange: (() -> Void)?

    init(store: MacSessionStore, relayHost: RelayHostStatusClient, nook: HaloController) {
        navigation = NavigationSidebarViewController(store: store, relayHost: relayHost)
        sessionList = SessionListViewController(store: store)
        sessionDetail = SessionDetailViewController(store: store)
        pairing = PairingViewController(relayHost: relayHost)
        settingsNavigation = SettingsNavigationViewController()
        settingsDetail = SettingsDetailViewController(store: store, nook: nook)

        let contentListTabs = NSTabViewController()
        contentListTabs.tabStyle = .unspecified
        contentListTabs.tabView.tabViewType = .noTabsNoBorder
        contentListTabs.addTabViewItem(Self.item(label: "Sessions", controller: sessionList))
        contentListTabs.addTabViewItem(Self.item(label: "Settings", controller: settingsNavigation))
        self.contentListTabs = contentListTabs

        navigationItem = NSSplitViewItem(sidebarWithViewController: navigation)
        contentListItem = NSSplitViewItem(contentListWithViewController: contentListTabs)
        // Order follows `MainWindowController.Tab.rawValue`.
        detailPages = SwitchingContainerViewController(pages: [sessionDetail, pairing, settingsDetail])
        detailItem = NSSplitViewItem(viewController: detailPages)
        super.init(nibName: nil, bundle: nil)

        splitView.dividerStyle = .thin

        navigationItem.allowsFullHeightLayout = true
        navigationItem.minimumThickness = Design.Layout.sidebarWidth
        navigationItem.maximumThickness = Design.Layout.sidebarWidth
        navigationItem.canCollapse = true
        navigationItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // Holding priorities must stay below the divider-drag (490) and window-resize
        // (500) priorities; ordering alone decides who absorbs width changes.
        navigationItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 261)

        contentListItem.minimumThickness = Design.Layout.contentListMinimumWidth
        contentListItem.maximumThickness = Design.Layout.contentListMaximumWidth
        contentListItem.canCollapse = true
        contentListItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        contentListItem.titlebarSeparatorStyle = .line
        contentListItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        detailItem.minimumThickness = Design.Layout.detailMinimumWidth
        detailItem.holdingPriority = .defaultLow
        // The subheader strip carries its own hairline; no separator under the title.
        detailItem.titlebarSeparatorStyle = .none

        addSplitViewItem(navigationItem)
        addSplitViewItem(contentListItem)
        addSplitViewItem(detailItem)

        navigation.onSelection = { [weak self] tab in self?.select(tab) }
        settingsNavigation.onSelection = { [weak self] section in
            self?.settingsDetail.select(section)
            self?.onToolbarStateChange?()
        }
        select(.sessions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordListWidthIfNeeded() }
        }
        sidebarObservation = navigationItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.didApplyInitialLayout else { return }
                MainWindowLayoutPreferences.isSidebarCollapsed = self.navigationItem.isCollapsed
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didApplyInitialLayout else { return }
        navigationItem.isCollapsed = MainWindowLayoutPreferences.isSidebarCollapsed
        applyListWidth(for: selectedTab)
        applyDebugInitialTab()
        // Only after the initial geometry is in place do user drags get recorded.
        didApplyInitialLayout = true
    }

    func toolbarActions() -> MainWindowToolbarActions {
        var actions = MainWindowToolbarActions()
        actions.search = { [weak self] query in self?.sessionList.apply(filter: query) }
        actions.toggleInspector = { [weak self] in self?.sessionDetail.toggleInspector() }
        actions.settingsTitle = { [weak self] in self?.settingsDetail.selectedSection.title ?? "" }
        return actions
    }

    func select(_ tab: MainWindowController.Tab) {
        let previous = selectedTab
        selectedTab = tab
        detailPages.select(tab.rawValue)
        // The subheader strip lives under the toolbar as a split-item accessory;
        // the pairing page draws its own header instead.
        let accessory: NSSplitViewItemAccessoryViewController? = switch tab {
        case .sessions: sessionDetail.subheaderAccessory
        case .pairing: nil
        case .settings: settingsDetail.subheaderAccessory
        }
        if detailItem.topAlignedAccessoryViewControllers.first !== accessory {
            detailItem.topAlignedAccessoryViewControllers = accessory.map { [$0] } ?? []
        }
        switch tab {
        case .sessions:
            contentListTabs.selectedTabViewItemIndex = 0
            contentListItem.isCollapsed = false
        case .pairing:
            contentListItem.isCollapsed = true
        case .settings:
            contentListTabs.selectedTabViewItemIndex = 1
            contentListItem.isCollapsed = false
        }
        if didApplyInitialLayout, previous != tab, tab != .pairing {
            applyListWidth(for: tab)
        }
        navigation.select(tab)
        onSelection?(tab)
    }

    func selectSettings(_ section: SettingsSectionID) {
        select(.settings)
        settingsNavigation.select(section)
        settingsDetail.select(section)
        onToolbarStateChange?()
    }

    /// `LUMI_INITIAL_TAB=pairing|settings:<section>` (development screenshots only).
    private func applyDebugInitialTab() {
        guard let value = ProcessInfo.processInfo.environment["LUMI_INITIAL_TAB"] else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            if value == "pairing" {
                self.select(.pairing)
            } else if value.hasPrefix("settings") {
                let name = value.split(separator: ":").last.map(String.init) ?? "general"
                let section = SettingsSectionID.allCases.first { $0.title.lowercased() == name } ?? .general
                self.selectSettings(section)
            }
        }
    }

    // MARK: Column widths

    /// The only programmatic divider move: initial layout and tab switches.
    private func applyListWidth(for tab: MainWindowController.Tab) {
        let width: CGFloat
        switch tab {
        case .sessions: width = MainWindowLayoutPreferences.sessionsListWidth
        case .settings: width = MainWindowLayoutPreferences.settingsListWidth
        case .pairing: return
        }
        view.layoutSubtreeIfNeeded()
        // NSSplitViewController wraps item views; the arranged subview is the wrapper.
        guard splitView.arrangedSubviews.count > 1 else { return }
        let clamped = min(
            max(width, Design.Layout.contentListMinimumWidth),
            Design.Layout.contentListMaximumWidth
        )
        isApplyingLayout = true
        splitView.setPosition(splitView.arrangedSubviews[1].frame.minX + clamped, ofDividerAt: 1)
        view.layoutSubtreeIfNeeded()
        isApplyingLayout = false
    }

    private func recordListWidthIfNeeded() {
        guard didApplyInitialLayout,
              !isApplyingLayout,
              !splitView.inLiveResize,
              !contentListItem.isCollapsed,
              selectedTab != .pairing else { return }
        guard splitView.arrangedSubviews.count > 1 else { return }
        let width = splitView.arrangedSubviews[1].frame.width
        guard width >= Design.Layout.contentListMinimumWidth else { return }
        switch selectedTab {
        case .sessions:
            if abs(MainWindowLayoutPreferences.sessionsListWidth - width) >= 1 {
                MainWindowLayoutPreferences.sessionsListWidth = width
            }
        case .settings:
            if abs(MainWindowLayoutPreferences.settingsListWidth - width) >= 1 {
                MainWindowLayoutPreferences.settingsListWidth = width
            }
        case .pairing:
            break
        }
    }

    private static func item(label: String, controller: NSViewController) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        return item
    }
}
