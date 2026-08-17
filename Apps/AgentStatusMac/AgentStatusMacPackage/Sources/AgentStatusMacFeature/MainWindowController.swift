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

    init(store: MacSessionStore, relayHost: RelayHostController, nook: AgentStatusNookController) {
        rootController = RootSplitViewController(store: store, relayHost: relayHost, nook: nook)
        toolbarController = MainWindowToolbarController(store: store, splitView: rootController.splitView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Status"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.minSize = NSSize(width: 940, height: 600)
        window.center()

        super.init(window: window)
        window.contentViewController = rootController
        toolbarController.window = window
        window.toolbar = toolbarController.toolbar
        rootController.onSelection = { [weak toolbarController] tab in
            toolbarController?.select(tab)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func select(_ tab: Tab) {
        rootController.select(tab)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func selectSettings(_ section: AgentStatusSettingsSection) {
        rootController.selectSettings(section)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Mail-style hierarchy: one navigation sidebar, one context list, and one detail.
/// Sessions and Settings both use all three columns; Pairing collapses the context list.
@MainActor
final class RootSplitViewController: NSSplitViewController {
    private let navigation = NavigationSidebarViewController()
    private let contentListTabs: NSTabViewController
    private let detailTabs = NSTabViewController()
    private let contentListItem: NSSplitViewItem
    private let settingsNavigation: SettingsNavigationViewController
    private let settingsDetail: SettingsDetailViewController
    var onSelection: ((MainWindowController.Tab) -> Void)?

    init(store: MacSessionStore, relayHost: RelayHostController, nook: AgentStatusNookController) {
        let settingsNavigation = SettingsNavigationViewController()
        let settingsDetail = SettingsDetailViewController(store: store, nook: nook)
        self.settingsNavigation = settingsNavigation
        self.settingsDetail = settingsDetail
        let contentListTabs = NSTabViewController()
        contentListTabs.tabStyle = .unspecified
        contentListTabs.tabView.tabViewType = .noTabsNoBorder
        contentListTabs.addTabViewItem(Self.item(
            label: "Sessions",
            controller: SessionListViewController(store: store)
        ))
        contentListTabs.addTabViewItem(Self.item(
            label: "Settings",
            controller: settingsNavigation
        ))
        self.contentListTabs = contentListTabs
        contentListItem = NSSplitViewItem(contentListWithViewController: contentListTabs)
        super.init(nibName: nil, bundle: nil)

        splitView.dividerStyle = .thin
        detailTabs.tabStyle = .unspecified
        detailTabs.tabView.tabViewType = .noTabsNoBorder
        detailTabs.addTabViewItem(Self.item(
            label: "Session Detail",
            controller: SessionDetailViewController(store: store)
        ))
        detailTabs.addTabViewItem(Self.item(
            label: "iPhone",
            controller: PairingViewController(relayHost: relayHost)
        ))
        detailTabs.addTabViewItem(Self.item(
            label: "Settings",
            controller: settingsDetail
        ))

        let navigationItem = NSSplitViewItem(sidebarWithViewController: navigation)
        navigationItem.allowsFullHeightLayout = true
        navigationItem.minimumThickness = 190
        navigationItem.maximumThickness = 280
        navigationItem.preferredThicknessFraction = 0.17

        contentListItem.minimumThickness = 300
        contentListItem.maximumThickness = 500
        contentListItem.preferredThicknessFraction = 0.30
        contentListItem.canCollapse = true

        let detailItem = NSSplitViewItem(viewController: detailTabs)
        detailItem.minimumThickness = AgentStatusDetailLayout.minimumColumnWidth

        addSplitViewItem(navigationItem)
        addSplitViewItem(contentListItem)
        addSplitViewItem(detailItem)

        navigation.onSelection = { [weak self] tab in self?.select(tab) }
        settingsNavigation.onSelection = { [weak settingsDetail] section in
            settingsDetail?.select(section)
        }
        select(.sessions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func select(_ tab: MainWindowController.Tab) {
        detailTabs.selectedTabViewItemIndex = tab.rawValue
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
        navigation.select(tab)
        onSelection?(tab)
    }

    func selectSettings(_ section: AgentStatusSettingsSection) {
        select(.settings)
        settingsNavigation.select(section)
        settingsDetail.select(section)
    }

    private static func item(label: String, controller: NSViewController) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        return item
    }
}
