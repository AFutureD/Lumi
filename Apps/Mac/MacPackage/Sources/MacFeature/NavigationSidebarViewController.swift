import AppKit

@MainActor
final class NavigationSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case section(String)
        case destination(MainWindowController.Tab, title: String, symbol: String)

        var tab: MainWindowController.Tab? {
            guard case let .destination(tab, _, _) = self else { return nil }
            return tab
        }
    }

    private let rows: [Row] = [
        .section("Monitor"),
        .destination(.sessions, title: "Sessions", symbol: "rectangle.split.2x1"),
        .section("Connections"),
        .destination(.pairing, title: "iPhone", symbol: "iphone"),
        .section("Application"),
        .destination(.settings, title: "Settings", symbol: "gearshape"),
    ]
    private let store: MacSessionStore
    private let relayHost: RelayHostStatusClient
    private let table = NSTableView()
    private var isSelecting = false
    private var selectedTab: MainWindowController.Tab = .sessions
    private var displayedSessionCount = 0
    private var displayedRelayConnected = false
    var onSelection: ((MainWindowController.Tab) -> Void)?

    init(store: MacSessionStore, relayHost: RelayHostStatusClient) {
        self.store = store
        self.relayHost = relayHost
        super.init(nibName: nil, bundle: nil)
        store.observe { [weak self] in self?.reloadDetails() }
        relayHost.observe { [weak self] in self?.reloadDetails() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation")))
        table.headerView = nil
        table.style = .plain
        table.floatsGroupRows = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        // Content sits 14pt from the sidebar edges; the selection capsule extends 4pt beyond.
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        displayedSessionCount = store.sessions.count
        displayedRelayConnected = relayHost.isConnected
        applySelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].tab != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section:
            row == 0
                ? Design.Layout.sidebarFirstGroupHeight
                : Design.Layout.sidebarGroupHeight
        case .destination:
            Design.Layout.sidebarRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? RoundedSelectionRowView {
            return existing
        }
        let rowView = RoundedSelectionRowView()
        rowView.horizontalInset = 0
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .section(title):
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title)
            label.font = Design.Font.group
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(
                    equalTo: cell.bottomAnchor,
                    constant: -Design.Layout.sidebarGroupBottomInset
                ),
            ])
            return cell
        case let .destination(tab, title, symbol):
            let cell = SidebarDestinationCell()
            cell.configure(title: title, symbol: symbol)
            configureDetail(for: tab, in: cell)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting,
              table.selectedRow >= 0,
              table.selectedRow < rows.count,
              let tab = rows[table.selectedRow].tab else { return }
        onSelection?(tab)
    }

    func select(_ tab: MainWindowController.Tab) {
        selectedTab = tab
        guard isViewLoaded else { return }
        applySelection()
    }

    private func applySelection() {
        guard let row = rows.firstIndex(where: { $0.tab == selectedTab }) else { return }
        isSelecting = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isSelecting = false
    }

    private func configureDetail(for tab: MainWindowController.Tab, in cell: SidebarDestinationCell) {
        switch tab {
        case .sessions:
            cell.showCount(store.sessions.count)
        case .pairing:
            cell.showDot(relayHost.isConnected)
        case .settings:
            cell.showNothing()
        }
    }

    /// Only the affected rows reload; selection and geometry are untouched.
    private func reloadDetails() {
        guard isViewLoaded else { return }
        var indexes = IndexSet()
        if store.sessions.count != displayedSessionCount {
            displayedSessionCount = store.sessions.count
            if let row = rows.firstIndex(where: { $0.tab == .sessions }) { indexes.insert(row) }
        }
        if relayHost.isConnected != displayedRelayConnected {
            displayedRelayConnected = relayHost.isConnected
            if let row = rows.firstIndex(where: { $0.tab == .pairing }) { indexes.insert(row) }
        }
        guard !indexes.isEmpty else { return }
        for row in indexes {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarDestinationCell,
                  let tab = rows[row].tab else { continue }
            configureDetail(for: tab, in: cell)
        }
    }
}

@MainActor
private final class SidebarDestinationCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyDown
        label.font = Design.Font.body
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        detailLabel.font = Design.Font.body
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = Design.Color.connected.cgColor

        [icon, label, detailLabel, dot].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(title: String, symbol: String) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }

    func showCount(_ count: Int) {
        detailLabel.stringValue = "\(count)"
        detailLabel.isHidden = false
        dot.isHidden = true
    }

    func showDot(_ visible: Bool) {
        detailLabel.isHidden = true
        dot.isHidden = !visible
    }

    func showNothing() {
        detailLabel.isHidden = true
        dot.isHidden = true
    }
}
