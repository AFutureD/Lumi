import AppKit

@MainActor
final class MainWindowToolbarController: NSObject, NSToolbarDelegate {
    private static let contentTitle = NSToolbarItem.Identifier("AgentStatus.ContentTitle")
    private static let refreshSessions = NSToolbarItem.Identifier("AgentStatus.RefreshSessions")
    private static let detailSeparator = NSToolbarItem.Identifier("AgentStatus.DetailSeparator")
    private static let deleteSession = NSToolbarItem.Identifier("AgentStatus.DeleteSession")

    let toolbar = NSToolbar(identifier: "AgentStatus.MainToolbar")
    weak var window: NSWindow?

    private let store: MacSessionStore
    private let splitView: NSSplitView
    private var selectedTab: MainWindowController.Tab = .sessions
    private weak var titleLabel: NSTextField?
    private weak var subtitleLabel: NSTextField?
    private weak var deleteItem: NSToolbarItem?

    init(store: MacSessionStore, splitView: NSSplitView) {
        self.store = store
        self.splitView = splitView
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        store.observe { [weak self] in self?.updateStoreState() }
    }

    func select(_ tab: MainWindowController.Tab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        rebuildItems()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers(for: .sessions)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            Self.contentTitle,
            Self.refreshSessions,
            Self.detailSeparator,
            Self.deleteSession,
            .flexibleSpace,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.contentTitle:
            makeTitleItem(identifier: itemIdentifier)
        case Self.refreshSessions:
            makeActionItem(
                identifier: itemIdentifier,
                label: "Refresh Sessions",
                symbol: "arrow.clockwise",
                action: #selector(refresh)
            )
        case Self.detailSeparator:
            NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 1
            )
        case Self.deleteSession:
            makeDeleteItem(identifier: itemIdentifier)
        default:
            nil
        }
    }

    private func identifiers(for tab: MainWindowController.Tab) -> [NSToolbarItem.Identifier] {
        switch tab {
        case .sessions:
            [
                .toggleSidebar,
                .sidebarTrackingSeparator,
                Self.contentTitle,
                .flexibleSpace,
                Self.refreshSessions,
                Self.detailSeparator,
                Self.deleteSession,
                .flexibleSpace,
            ]
        case .pairing:
            [
                .toggleSidebar,
                .sidebarTrackingSeparator,
                Self.contentTitle,
                .flexibleSpace,
            ]
        case .settings:
            [
                .toggleSidebar,
                .sidebarTrackingSeparator,
                Self.contentTitle,
                .flexibleSpace,
                Self.detailSeparator,
                .flexibleSpace,
            ]
        }
    }

    private func rebuildItems() {
        while !toolbar.items.isEmpty {
            toolbar.removeItem(at: toolbar.items.count - 1)
        }
        for (index, identifier) in identifiers(for: selectedTab).enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        updateStoreState()
    }

    private func makeTitleItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.frame = NSRect(x: 0, y: 0, width: 170, height: 36)

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Current Section"
        item.paletteLabel = "Current Section"
        item.view = stack
        item.visibilityPriority = .high
        if #available(macOS 26.0, *) {
            item.isBordered = false
        }
        titleLabel = title
        subtitleLabel = subtitle
        updateTitle()
        return item
    }

    private func makeActionItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }

    private func makeDeleteItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = makeActionItem(
            identifier: identifier,
            label: "Delete Session",
            symbol: "trash",
            action: #selector(confirmDelete)
        )
        item.isEnabled = store.selectedSession != nil
        deleteItem = item
        return item
    }

    @objc private func refresh() {
        store.refresh()
    }

    @objc private func confirmDelete() {
        guard let window, let session = store.selectedSession else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this Session?"
        alert.informativeText = "“\(session.summary.title)” and its timeline will be removed from this Mac, the daemon, and connected iPhones."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.deleteSession(session.summary.id)
        }
    }

    private func updateStoreState() {
        deleteItem?.isEnabled = store.selectedSession != nil
        updateTitle()
    }

    private func updateTitle() {
        switch selectedTab {
        case .sessions:
            titleLabel?.stringValue = "Sessions"
            if store.health == nil {
                subtitleLabel?.stringValue = "Daemon unavailable"
            } else {
                subtitleLabel?.stringValue = "\(store.sessions.count) sessions"
            }
        case .pairing:
            titleLabel?.stringValue = "iPhone"
            subtitleLabel?.stringValue = "Pairing and channels"
        case .settings:
            titleLabel?.stringValue = "Settings"
            subtitleLabel?.stringValue = "App, Notch, daemon, and Agents"
        }
    }
}
