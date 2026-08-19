import AppKit

/// Actions the toolbar forwards into the column controllers.
@MainActor
struct MainWindowToolbarActions {
    var search: (String) -> Void = { _ in }
    var toggleInspector: () -> Void = {}
    var generatePairingCode: () -> Void = {}
    var canGeneratePairingCode: () -> Bool = { false }
    var settingsTitle: () -> String = { "" }
}

/// Unified toolbar with three tracked sections:
/// sidebar (toggle, trailing) | content list (search / "Settings") | detail (title + actions).
@MainActor
final class MainWindowToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    private static let contentTitle = NSToolbarItem.Identifier("AgentStatus.ContentTitle")
    private static let searchSessions = NSToolbarItem.Identifier("AgentStatus.SearchSessions")
    private static let settingsLabel = NSToolbarItem.Identifier("AgentStatus.SettingsLabel")
    private static let refreshSessions = NSToolbarItem.Identifier("AgentStatus.RefreshSessions")
    private static let detailSeparator = NSToolbarItem.Identifier("AgentStatus.DetailSeparator")
    private static let deleteSession = NSToolbarItem.Identifier("AgentStatus.DeleteSession")
    private static let toggleInspector = NSToolbarItem.Identifier("AgentStatus.ToggleInspector")
    private static let generatePairingCode = NSToolbarItem.Identifier("AgentStatus.GeneratePairingCode")

    let toolbar = NSToolbar(identifier: "AgentStatus.MainToolbar")
    weak var window: NSWindow?
    var actions = MainWindowToolbarActions()

    private let store: MacSessionStore
    private let relayHost: RelayHostController
    private let splitView: NSSplitView
    private var selectedTab: MainWindowController.Tab = .sessions
    private weak var titleLabel: NSTextField?
    private weak var deleteItem: NSToolbarItem?
    private weak var generateButton: NSButton?
    private weak var searchField: NSSearchField?

    init(store: MacSessionStore, relayHost: RelayHostController, splitView: NSSplitView) {
        self.store = store
        self.relayHost = relayHost
        self.splitView = splitView
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        store.observe { [weak self] in self?.updateState() }
        relayHost.observe { [weak self] in self?.updateState() }
    }

    func select(_ tab: MainWindowController.Tab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        rebuildItems()
    }

    /// Re-reads titles and enabled states without touching item layout.
    func updateState() {
        deleteItem?.isEnabled = store.selectedSession != nil
        generateButton?.isEnabled = actions.canGeneratePairingCode()
        updateTitle()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers(for: .sessions)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            Self.searchSessions,
            Self.settingsLabel,
            Self.detailSeparator,
            Self.contentTitle,
            Self.refreshSessions,
            Self.deleteSession,
            Self.toggleInspector,
            Self.generatePairingCode,
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
        case Self.searchSessions:
            makeSearchItem(identifier: itemIdentifier)
        case Self.settingsLabel:
            makeSettingsLabelItem(identifier: itemIdentifier)
        case Self.refreshSessions:
            makeActionItem(
                identifier: itemIdentifier,
                label: "Refresh",
                symbol: "arrow.clockwise",
                action: #selector(refresh),
                toolTip: "Rebuild the selected session from its transcript and resync all sessions"
            )
        case Self.detailSeparator:
            NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 1
            )
        case Self.deleteSession:
            makeDeleteItem(identifier: itemIdentifier)
        case Self.toggleInspector:
            makeActionItem(
                identifier: itemIdentifier,
                label: "Toggle Inspector",
                symbol: "sidebar.right",
                action: #selector(toggleInspector)
            )
        case Self.generatePairingCode:
            makeGenerateItem(identifier: itemIdentifier)
        default:
            nil
        }
    }

    // MARK: Layout per tab

    private func identifiers(for tab: MainWindowController.Tab) -> [NSToolbarItem.Identifier] {
        let sidebar: [NSToolbarItem.Identifier] = [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator]
        switch tab {
        case .sessions:
            return sidebar + [
                Self.searchSessions,
                .flexibleSpace,
                Self.detailSeparator,
                Self.contentTitle,
                .flexibleSpace,
                Self.refreshSessions,
                Self.deleteSession,
                Self.toggleInspector,
            ]
        case .pairing:
            return sidebar + [
                Self.contentTitle,
                .flexibleSpace,
                Self.generatePairingCode,
            ]
        case .settings:
            return sidebar + [
                Self.settingsLabel,
                .flexibleSpace,
                Self.detailSeparator,
                Self.contentTitle,
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
        updateState()
    }

    // MARK: Items

    private func makeTitleItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let title = NSTextField(labelWithString: "")
        title.font = AgentStatusDesign.Font.title
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true
        title.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Title"
        item.paletteLabel = "Title"
        item.view = title
        item.visibilityPriority = .high
        item.isBordered = false
        titleLabel = title
        updateTitle()
        return item
    }

    private func makeSearchItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.label = "Filter Sessions"
        item.paletteLabel = "Filter Sessions"
        item.searchField.placeholderString = "Filter sessions"
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.sendsWholeSearchString = false
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        item.searchField.delegate = self
        item.preferredWidthForSearchField = AgentStatusDesign.Layout.sessionListWidth - 28
        item.resignsFirstResponderWithCancel = true
        item.visibilityPriority = .high
        searchField = item.searchField
        return item
    }

    private func makeSettingsLabelItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let label = NSTextField(labelWithString: "Settings")
        label.font = AgentStatusDesign.Font.group
        label.textColor = .labelColor
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Settings"
        item.paletteLabel = "Settings"
        item.view = label
        item.isBordered = false
        return item
    }

    private func makeActionItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        toolTip: String? = nil
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip ?? label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
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

    private func makeGenerateItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let button = NSButton(title: "Generate new code", target: self, action: #selector(generatePairingCode))
        button.bezelStyle = .rounded
        button.bezelColor = .controlAccentColor
        button.controlSize = .regular
        button.font = AgentStatusDesign.Font.rowTitle
        button.isEnabled = actions.canGeneratePairingCode()
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Generate New Code"
        item.paletteLabel = "Generate New Code"
        item.toolTip = "Generate a new one-time pairing code"
        item.view = button
        item.isBordered = false
        generateButton = button
        return item
    }

    // MARK: Actions

    @objc private func refresh() {
        store.refreshSelectedSession()
    }

    @objc private func toggleInspector() {
        actions.toggleInspector()
    }

    @objc private func generatePairingCode() {
        actions.generatePairingCode()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        actions.search(sender.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        actions.search(field.stringValue)
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

    private func updateTitle() {
        guard let titleLabel else { return }
        let text: String
        switch selectedTab {
        case .sessions:
            if let detail = store.selectedSession {
                text = SessionListRowPresentation(session: detail.summary).title
            } else {
                text = "Select a Session"
            }
        case .pairing:
            text = "Pair iPhone"
        case .settings:
            text = actions.settingsTitle()
        }
        guard titleLabel.stringValue != text else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        titleLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: AgentStatusDesign.Font.title,
                .kern: AgentStatusDesign.Font.titleKerning,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        titleLabel.toolTip = text
    }
}
