import Transport
import AppKit
import NookApp
import SwiftUI

enum SettingsSectionID: Int, CaseIterable {
    case general
    case notch
    case daemon
    case agents
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .notch: "Notch"
        case .daemon: "Daemon"
        case .agents: "Agents"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Launch behavior"
        case .notch: "Appearance and interaction"
        case .daemon: "Local service and history"
        case .agents: "Integrations and filters"
        case .about: "Version and updates"
        }
    }

    var detailSubtitle: String {
        switch self {
        case .general: "Choose how Lumi starts on this Mac."
        case .notch: "Configure the Notch surface, screen, size, and interaction."
        case .daemon: "The local service collects Codex events and writes them to SQLite."
        case .agents: "Integrations that report Session events, and filters that drop ghost Sessions."
        case .about: "Version, framework and update information."
        }
    }
}

/// Category column: 44pt two-line rows with the neutral rounded selection.
@MainActor
final class SettingsNavigationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var isSelecting = false
    private(set) var selectedSection: SettingsSectionID = .general
    var onSelection: ((SettingsSectionID) -> Void)?

    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Design.Layout.settingsNavigationRowHeight
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.additionalSafeAreaInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        applySelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsSectionID.allCases.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SettingsRowContainer")
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? RoundedSelectionRowView {
            return existing
        }
        let rowView = RoundedSelectionRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let section = SettingsSectionID(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: section.title)
        title.font = Design.Font.rowTitle
        let subtitle = NSTextField(labelWithString: section.subtitle)
        subtitle.font = Design.Font.caption
        subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(labels)
        cell.textField = title
        let inset = Design.Layout.listHorizontalInset + Design.Layout.listRowInset
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -inset),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting,
              let section = SettingsSectionID(rawValue: table.selectedRow) else { return }
        selectedSection = section
        onSelection?(section)
    }

    func select(_ section: SettingsSectionID) {
        selectedSection = section
        guard isViewLoaded else { return }
        applySelection()
    }

    private func applySelection() {
        isSelecting = true
        table.selectRowIndexes(IndexSet(integer: selectedSection.rawValue), byExtendingSelection: false)
        isSelecting = false
    }
}

/// Detail column: subheader (subtitle · Daemon status pill) above a hosted SwiftUI panel.
@MainActor
final class SettingsDetailViewController: NSViewController {
    private let store: MacSessionStore
    private let nook: HaloController
    private let softwareUpdates: SoftwareUpdateController
    private let model: SettingsModel
    let subheaderAccessory = DetailSubheaderAccessoryController(horizontalInset: DetailLayout.horizontalInset)
    private var subheader: DetailSubheaderView { subheaderAccessory.subheader }
    private let daemonPill = StatusPillView()
    private let hosting = NSHostingController(rootView: AnyView(EmptyView()))
    private var storeObservation: UUID?

    private(set) var selectedSection: SettingsSectionID = .general

    init(store: MacSessionStore, nook: HaloController, softwareUpdates: SoftwareUpdateController) {
        self.store = store
        self.nook = nook
        self.softwareUpdates = softwareUpdates
        model = SettingsModel(store: store)
        super.init(nibName: nil, bundle: nil)
        model.presentError = { [weak self] error in self?.showError(error) }
        model.confirm = { [weak self] title, message, button in
            await self?.confirm(title: title, message: message, button: button) ?? false
        }
        store.observe { [weak self] in
            guard self?.selectedSection == .daemon else { return }
            self?.updateSubheader()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        addChild(hosting)
        hosting.sizingOptions = []
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rebuild()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        model.reload()
        updateSubheader()
    }

    func select(_ section: SettingsSectionID) {
        guard selectedSection != section else { return }
        selectedSection = section
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        updateSubheader()
        hosting.rootView = AnyView(panel(for: selectedSection))
    }

    @ViewBuilder
    private func panel(for section: SettingsSectionID) -> some View {
        switch section {
        case .general:
            GeneralSettingsPanel(model: model, softwareUpdates: softwareUpdates)
        case .notch:
            HaloSettingsView(
                appState: nook.appState,
                showNook: { [weak nook] in nook?.showNook() },
                toggleKeepOpen: { [weak nook] in nook?.toggleKeepOpen() }
            )
        case .daemon:
            DaemonSettingsPanel(model: model)
        case .agents:
            AgentsSettingsPanel(model: model)
        case .about:
            AboutSettingsPanel(model: model, softwareUpdates: softwareUpdates)
        }
    }

    private func updateSubheader() {
        var leading: [NSView] = []
        if selectedSection == .daemon {
            if store.health != nil {
                daemonPill.configure(tone: .green, text: "Running")
            } else {
                daemonPill.configure(tone: .gray, text: "Not connected")
            }
            leading.append(daemonPill)
        }
        subheader.setLeadingViews(leading, trailingText: selectedSection.detailSubtitle)
    }

    private func confirm(title: String, message: String, button: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if let window = view.window {
            let response = await alert.beginSheetModal(for: window)
            return response == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
