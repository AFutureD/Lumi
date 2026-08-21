import AgentStatusDesignSystem
import AgentStatusTransport
import UIKit

/// Sessions tab: one merged list across every paired Mac. Large Title and
/// search are the system's (`UISearchController` in the navigation item,
/// hidden until the list is pulled down); the Dropdown filter row sits under
/// the bar. Rows push the session detail.
@MainActor
final class SessionsViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private enum Section { case sessions }
    private static let filterBarKind = "filter-bar"

    private let relay: RelayDeviceController
    private let settings: LocalSettings
    private var observer: UUID?
    private var allItems: [SessionListItem] = []
    private var itemsByID: [SessionListItemID: SessionListItem] = [:]
    private var query = ""
    /// Rows the user toggled; rows without an entry follow the default
    /// (expanded while the session is running, collapsed otherwise).
    private var subagentToggles: [SessionListItemID: Bool] = [:]
    nonisolated(unsafe) private var ticker: Timer?
    private var header: SessionsHeaderView?


    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private let emptyLabel = UILabel()
    private let refreshControl = UIRefreshControl()
    private let searchController = UISearchController(searchResultsController: nil)

    init(relay: RelayDeviceController, settings: LocalSettings) {
        self.relay = relay
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = "Sessions"
        tabBarItem = UITabBarItem(title: "Sessions", image: UIImage(systemName: "list.bullet"), tag: 0)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    deinit {
        ticker?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .inline
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(title: "Refresh list", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.relay.refreshAll()
                },
            ])
        )
        // Apple's search-controller pattern: the navigation bar owns the
        // field and it filters this list in place (no results controller, no
        // dimming). On iOS 26 the field is integrated into the bar as a
        // button that expands on tap — collapsed by default; earlier systems
        // stack it under the title and hide it while scrolling.
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search sessions"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
        if #available(iOS 26.0, *) {
            navigationItem.preferredSearchBarPlacement = .integratedButton
        } else {
            navigationItem.preferredSearchBarPlacement = .stacked
        }
        definesPresentationContext = true

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(pulled), for: .valueChanged)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .design(IOSDS.Typography.body)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: IOSDS.Layout.groupFooterInset),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -IOSDS.Layout.groupFooterInset),
        ])
        collectionView.backgroundView = background

        _ = dataSource
        observer = relay.observe { [weak self] in self?.reload() }
        reload()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickVisibleCells() }
        }
    }

    /// Updates that arrived while a detail was on top were applied to an
    /// offscreen list; re-render every visible row on the way back so tone,
    /// latest activity and times are current the moment the list shows.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload(reconfigureAll: true)
        tickVisibleCells()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.reload(reconfigureAll: true)
        }
    }

    // MARK: - Data

    private func reload(reconfigureAll: Bool = false) {
        let channels = relay.channelStates
        let previous = itemsByID
        allItems = SessionListPresentation.items(from: channels)
        itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        let deselected = settings.deselectedHosts
        let deselectedStatuses = settings.deselectedStatuses
        let filtered = SessionListPresentation.filter(
            allItems,
            excludingHosts: deselected,
            excludingStatuses: deselectedStatuses,
            query: query
        )

        var snapshot = NSDiffableDataSourceSnapshot<Section, SessionListItemID>()
        snapshot.appendSections([.sessions])
        snapshot.appendItems(filtered.map(\.id), toSection: .sessions)
        let changed = filtered.map(\.id).filter { reconfigureAll || previous[$0] != itemsByID[$0] }
        snapshot.reconfigureItems(changed.filter { previous[$0] != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)

        configureFilterBar()
        updateEmptyState(channels: channels, visibleCount: filtered.count)
        if refreshControl.isRefreshing {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.refreshControl.endRefreshing()
            }
        }
    }

    private func updateEmptyState(channels: [MacChannelState], visibleCount: Int) {
        guard visibleCount == 0 else {
            emptyLabel.text = nil
            return
        }
        if channels.isEmpty {
            emptyLabel.text = "No Macs paired\nOpen Macs and scan the pairing code shown by Agent Status on your Mac."
        } else if !allItems.isEmpty {
            emptyLabel.text = "No matching sessions"
        } else if channels.contains(where: { $0.isOnline && $0.hasCompleteSync }) {
            emptyLabel.text = "No live sessions"
        } else if channels.contains(where: \.isOnline) {
            emptyLabel.text = "Syncing…\nWaiting for \(channels.filter(\.isOnline).map(\.displayName).joined(separator: ", ")) to send its sessions."
        } else {
            emptyLabel.text = "Mac unavailable\nSessions appear once a paired Mac is online."
        }
    }

    private func isExpanded(_ item: SessionListItem) -> Bool {
        subagentToggles[item.id] ?? (item.tone == .blue)
    }

    private func configureFilterBar() {
        let macs = SessionListPresentation.macOptions(channels: relay.channelStates, items: allItems, deselected: settings.deselectedHosts)
        let statuses = SessionListPresentation.statusOptions(items: allItems, deselected: settings.deselectedStatuses)
        header?.filterBar.configure(
            macsSelected: macs.count(where: \.isSelected),
            macsTotal: macs.count,
            statusSelected: statuses.count(where: \.isSelected),
            statusTotal: statuses.count
        )
    }

    /// One `UIMenu` per group: checkmarked multi-select that keeps the menu
    /// open, the count after each name; a group never empties.
    private func macsMenu() -> UIMenu {
        let options = SessionListPresentation.macOptions(channels: relay.channelStates, items: allItems, deselected: settings.deselectedHosts)
        let all = relay.channelStates.map(\.hostID)
        return UIMenu(options: .displayInline, children: options.map { option in
            UIAction(
                title: option.name,
                subtitle: "\(option.count)",
                image: UIImage(systemName: "laptopcomputer"),
                attributes: .keepsMenuPresented,
                state: option.isSelected ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                settings.deselectedHosts = SessionListPresentation.toggling(HostID(option.id), in: settings.deselectedHosts, all: all)
                reload()
            }
        })
    }

    private func statusMenu() -> UIMenu {
        let options = SessionListPresentation.statusOptions(items: allItems, deselected: settings.deselectedStatuses)
        return UIMenu(options: .displayInline, children: options.map { option in
            let group = SessionStatusGroup(rawValue: option.id)!
            return UIAction(
                title: option.name,
                subtitle: "\(option.count)",
                image: UIImage(systemName: "circle.fill")?.withTintColor(UIColor(hue: group.hue), renderingMode: .alwaysOriginal),
                attributes: .keepsMenuPresented,
                state: option.isSelected ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                settings.deselectedStatuses = SessionListPresentation.toggling(group, in: settings.deselectedStatuses, all: SessionStatusGroup.allCases)
                reload()
            }
        })
    }

    private func tickVisibleCells() {
        let now = Date()
        for case let cell as SessionRowCell in collectionView.visibleCells {
            cell.tick(now: now)
        }
    }

    private var rowAvailableWidth: CGFloat {
        collectionView.bounds.width - IOSDS.Layout.sideInset * 2
    }

    // MARK: - Layout & data source

    private func makeLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfiguration.showsSeparators = false
        listConfiguration.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout { _, environment in
            NSCollectionLayoutSection.list(using: listConfiguration, layoutEnvironment: environment)
        }
        let headerSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(IOSDS.SessionsHeader.gap + IOSDS.FilterTrigger.height + IOSDS.SessionsHeader.bottom + 1)
        )
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: Self.filterBarKind,
            alignment: .top
        )
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.boundarySupplementaryItems = [header]
        layout.configuration = configuration
        return layout
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, SessionListItemID> {
        let cellRegistration = UICollectionView.CellRegistration<SessionRowCell, SessionListItemID> { [weak self] cell, _, id in
            guard let self, let item = itemsByID[id] else { return }
            cell.configure(item: item, availableWidth: rowAvailableWidth, now: Date(), subagentsExpanded: isExpanded(item))
            cell.onSelectSubagent = { [weak self] childID in
                self?.open(hostID: id.hostID, sessionID: childID)
            }
            cell.onToggleSubagents = { [weak self] in self?.toggleSubagents(id) }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SessionsHeaderReusableView>(
            elementKind: Self.filterBarKind
        ) { [weak self] view, _, _ in
            guard let self else { return }
            header = view.header
            view.header.filterBar.macsMenuProvider = { [weak self] in self?.macsMenu() ?? UIMenu() }
            view.header.filterBar.statusMenuProvider = { [weak self] in self?.statusMenu() ?? UIMenu() }
            view.header.filterBar.onReset = { [weak self] in self?.resetFilters() }
            configureFilterBar()
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, SessionListItemID>(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
        return dataSource
    }

    // MARK: - Actions

    private func resetFilters() {
        settings.deselectedHosts = []
        settings.deselectedStatuses = []
        reload()
    }

    private func toggleSubagents(_ id: SessionListItemID) {
        guard let item = itemsByID[id] else { return }
        subagentToggles[id] = !isExpanded(item)
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    /// Show only this Mac (from the Macs tab).
    func showOnly(hostID: HostID) {
        settings.deselectedHosts = Set(relay.channelStates.map(\.hostID)).subtracting([hostID])
        reload()
    }

    @objc private func pulled() {
        relay.refreshAll()
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        reload()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        open(hostID: id.hostID, sessionID: id.sessionID)
    }

    private func open(hostID: HostID, sessionID: SessionID) {
        let detail = SessionDetailViewController(relay: relay, hostID: hostID, sessionID: sessionID)
        navigationController?.pushViewController(detail, animated: true)
    }
}

/// Hosts the Sessions header as the list's global header.
final class SessionsHeaderReusableView: UICollectionReusableView {
    let header = SessionsHeaderView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}
