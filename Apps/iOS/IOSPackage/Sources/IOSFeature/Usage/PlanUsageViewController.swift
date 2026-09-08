import Core
import DesignSystem
import Transport
import os
import UIKit

private let log = os.Logger(subsystem: "app.huanan.lumi", category: "usage.plan")

/// Usage › Plan (handoff pages 8 / 8b / 9c): one inset-grouped card per
/// paired Mac, one account section per cell, each Mac's numbers following
/// its own daemon's percent style. Reads `MacChannelState.planUsage`; the
/// parent tab asks the Macs and polls.
@MainActor
final class PlanUsageViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable {
        case banner
        case mac(HostID)
        case pair
    }

    private enum Row: Hashable {
        case banner(String)
        case account(HostID, PlanUsageAccountID)
        case loading(HostID)
        case unavailable(HostID, String)
        case pairMac
    }

    private let relay: RelayDeviceController
    private let onRefresh: () -> Void
    private let onPairMac: () -> Void
    private var observer: UUID?
    private var states: [MacChannelState] = []
    private var refreshDeadline: Task<Void, Never>?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()

    init(relay: RelayDeviceController, onRefresh: @escaping () -> Void, onPairMac: @escaping () -> Void) {
        self.relay = relay
        self.onRefresh = onRefresh
        self.onPairMac = onPairMac
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulled), for: .valueChanged)
        collectionView.refreshControl = refresh
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        _ = dataSource
        observer = relay.observe { [weak self] in self?.reload() }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: - Refresh

    @objc private func pulled() {
        log.info("plan_pull_refresh")
        onRefresh()
        refreshDeadline?.cancel()
        refreshDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.endRefreshing(reason: "deadline")
        }
    }

    private func endRefreshing(reason: String) {
        guard collectionView.refreshControl?.isRefreshing == true else { return }
        log.debug("plan_refresh_end reason=\(reason, privacy: .public)")
        collectionView.refreshControl?.endRefreshing()
        refreshDeadline?.cancel()
        refreshDeadline = nil
    }

    // MARK: - Snapshot

    func reload() {
        states = relay.channelStates
        let now = Date()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        if states.isEmpty {
            snapshot.appendSections([.pair])
            snapshot.appendItems([.pairMac], toSection: .pair)
        } else {
            if states.allSatisfy({ !$0.isOnline }) {
                let newest = states.compactMap { $0.planUsage?.fetchedAt ?? $0.lastSyncAt }.max()
                snapshot.appendSections([.banner])
                snapshot.appendItems([.banner(UsageHistoryText.offlineBanner(lastSeen: newest, now: now))], toSection: .banner)
            }
            for state in states {
                snapshot.appendSections([.mac(state.hostID)])
                snapshot.appendItems(rows(for: state), toSection: .mac(state.hostID))
            }
        }
        // Every visible row re-reads its snapshot (stamps and reset times move).
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        reconfigureSupplementaries()
        if collectionView.refreshControl?.isRefreshing == true, !states.contains(where: { $0.planUsage?.isLoading == true }) {
            endRefreshing(reason: "loaded")
        }
    }

    private func rows(for state: MacChannelState) -> [Row] {
        guard let snapshot = state.planUsage, let plan = snapshot.state else {
            // No answer yet. A failed ask (timed out, Mac offline) says so;
            // anything else — never asked, or in flight — is the first load.
            if let error = state.planUsage?.error, state.planUsage?.isLoading != true {
                log.warning("plan_unavailable host=\(state.hostID.rawValue, privacy: .public) error=\(error, privacy: .public)")
                return [.unavailable(state.hostID, error)]
            }
            return [.loading(state.hostID)]
        }
        // Claude Code first, then Codex; the daemon already orders it so, but the card promises it.
        let accounts = plan.accounts.sorted { ($0.provider == .claude ? 0 : 1) < ($1.provider == .claude ? 0 : 1) }
        return accounts.map { .account(state.hostID, $0.id) }
    }

    private func accountModel(hostID: HostID, accountID: PlanUsageAccountID, now: Date) -> PlanAccountModel? {
        guard let state = states.first(where: { $0.hostID == hostID }),
              let snapshot = state.planUsage,
              let account = snapshot.state?.account(accountID) else { return nil }
        return PlanAccountModel.build(
            account: account,
            percentStyle: snapshot.settings?.planUsage.percentStyle ?? .used,
            macName: state.displayName,
            macOnline: state.isOnline,
            snapshotAt: snapshot.fetchedAt,
            now: now
        )
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            let sections = self?.dataSource.snapshot().sectionIdentifiers ?? []
            let section = sectionIndex < sections.count ? sections[sectionIndex] : nil
            switch section {
            case .mac:
                configuration.headerMode = .supplementary
                configuration.footerMode = sectionIndex == sections.count - 1 ? .supplementary : .none
            case .banner, .pair, nil:
                configuration.headerMode = .none
                configuration.footerMode = section == .pair ? .supplementary : .none
            }
            let layout = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if section == .banner {
                layout.contentInsets.bottom = 0
            }
            return layout
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, Row> {
        let account = UICollectionView.CellRegistration<PlanAccountCell, Row> { [weak self] cell, _, row in
            guard let self, case let .account(hostID, accountID) = row,
                  let model = accountModel(hostID: hostID, accountID: accountID, now: Date()) else { return }
            cell.configure(model)
        }
        let plain = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = .secondarySystemGroupedBackground
            cell.accessories = []
            switch row {
            case .banner(let text):
                var content = UIListContentConfiguration.cell()
                content.text = text
                content.textProperties.font = .design(IOSDS.Typography.caption)
                content.textProperties.color = UIColor(DS.PlanUsage.noticeWarningText)
                content.directionalLayoutMargins.top = IOSDS.Usage.bannerVerticalPadding
                content.directionalLayoutMargins.bottom = IOSDS.Usage.bannerVerticalPadding
                cell.contentConfiguration = content
                background.backgroundColor = UIColor(DS.PlanUsage.noticeWarningFill)
            case .loading:
                cell.contentConfiguration = UsageLoadingRowConfiguration(text: "Loading plan limits…")
            case .unavailable(_, let error):
                var content = UIListContentConfiguration.cell()
                content.text = "Can't reach this Mac · \(error)"
                content.textProperties.font = .design(IOSDS.Typography.caption)
                content.textProperties.color = UIColor(DS.PlanUsage.noticeWarningText)
                content.textProperties.numberOfLines = 0
                cell.contentConfiguration = content
            case .pairMac:
                var content = UIListContentConfiguration.cell()
                content.text = "Pair a Mac"
                content.textProperties.font = .design(IOSDS.Typography.listTitle)
                content.textProperties.color = .tintColor
                cell.contentConfiguration = content
                cell.accessories = [.disclosureIndicator()]
            case .account:
                break
            }
            cell.backgroundConfiguration = background
        }
        let header = UICollectionView.SupplementaryRegistration<PlanMacHeaderView>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            self?.configureHeader(view, section: indexPath.section)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            self?.configureFooter(view, section: indexPath.section)
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            if case .account = row {
                return collectionView.dequeueConfiguredReusableCell(using: account, for: indexPath, item: row)
            }
            return collectionView.dequeueConfiguredReusableCell(using: plain, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        return dataSource
    }

    private func configureHeader(_ view: PlanMacHeaderView, section: Int) {
        let sections = dataSource.snapshot().sectionIdentifiers
        guard section < sections.count, case let .mac(hostID) = sections[section],
              let state = states.first(where: { $0.hostID == hostID }) else { return }
        view.configure(name: state.displayName, online: state.isOnline, status: Self.statusWord(for: state, now: Date()))
    }

    private func configureFooter(_ view: UICollectionViewListCell, section: Int) {
        var content = UIListContentConfiguration.plainFooter()
        let sections = dataSource.snapshot().sectionIdentifiers
        content.text = section < sections.count && sections[section] == .pair
            ? "Plan limits come from each paired Mac's daemon. Pair a Mac to see them here."
            : "Plan limits come from each Mac's daemon, refreshed every 5 minutes. Cost and tokens are in History."
        content.textProperties.font = .design(IOSDS.Typography.caption)
        content.textProperties.color = UIColor(IOSDS.Usage.secondaryText)
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: IOSDS.Layout.groupHeaderGap,
            leading: IOSDS.Layout.groupFooterInset - IOSDS.Layout.cardMargin,
            bottom: IOSDS.Layout.groupGap,
            trailing: IOSDS.Layout.groupFooterInset - IOSDS.Layout.cardMargin
        )
        view.contentConfiguration = content
    }

    /// Headers and footers are not items, so a reload re-applies them by hand.
    private func reconfigureSupplementaries() {
        for view in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
            if let header = view as? PlanMacHeaderView, let path = collectionView.indexPath(forSupplementaryView: header) {
                configureHeader(header, section: path.section)
            }
        }
    }

    /// `Online` / `Offline · 2h ago` / `Offline` / `Revoked` — the same
    /// judgement the Macs tab makes, without the Relay host.
    static func statusWord(for state: MacChannelState, now: Date) -> String {
        if state.accessRevoked { return "Revoked" }
        if state.isOnline { return "Online" }
        if let lastSync = state.lastSyncAt {
            return "Offline · \(SessionRelativeTimeFormatter.string(from: lastSync, now: now)) ago"
        }
        return "Offline"
    }

    // MARK: - Selection

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .pairMac
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .pairMac {
            onPairMac()
        }
    }
}

/// Group title of a Mac's card: name 13/semibold, 6px dot, status word.
final class PlanMacHeaderView: UICollectionReusableView {
    private let name = UILabel()
    private let dot = DotAccessoryView(color: .clear, size: IOSDS.PlanUsage.statusDot)
    private let status = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.font = .design(IOSDS.Typography.captionEmphasized)
        name.textColor = UIColor(IOSDS.Usage.secondaryText)
        status.font = .design(IOSDS.Typography.caption, tabular: true)
        status.textColor = UIColor(IOSDS.Usage.tertiaryText)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: IOSDS.PlanUsage.statusDot),
            dot.heightAnchor.constraint(equalToConstant: IOSDS.PlanUsage.statusDot),
        ])
        let stack = UIStackView(arrangedSubviews: [name, dot, status, UIView()])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = IOSDS.PlanUsage.statusDotGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: IOSDS.Layout.groupHeaderInset - IOSDS.Layout.cardMargin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -IOSDS.Layout.groupHeaderGap),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(name: String, online: Bool, status: String) {
        self.name.text = name
        dot.backgroundColor = online ? UIColor(IOSDS.Color.systemGreen) : UIColor(IOSDS.Color.inactiveDot)
        self.status.text = status
    }
}

/// A spinner and a line of text — the first-load row of both segments.
struct UsageLoadingRowConfiguration: UIContentConfiguration {
    var text: String

    func makeContentView() -> any UIView & UIContentView { UsageLoadingRowView(configuration: self) }
    func updated(for state: any UIConfigurationState) -> UsageLoadingRowConfiguration { self }
}

final class UsageLoadingRowView: UIView, UIContentView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    var configuration: any UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: UsageLoadingRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: IOSDS.Usage.loadingSpinner),
            spinner.heightAnchor.constraint(equalToConstant: IOSDS.Usage.loadingSpinner),
        ])
        spinner.startAnimating()
        label.font = .design(IOSDS.Typography.body)
        label.textColor = .inkSecondary
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = IOSDS.Usage.noticeGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: IOSDS.Usage.noticeVerticalPadding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: IOSDS.Usage.cardHorizontalPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -IOSDS.Usage.cardHorizontalPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -IOSDS.Usage.noticeVerticalPadding),
        ])
        apply()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private func apply() {
        label.text = (configuration as? UsageLoadingRowConfiguration)?.text
    }
}
