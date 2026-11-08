import Core
import DesignSystem
import Transport
import UIKit

/// Activity tab: the chronological `TimelineRow` list. Tapping a row opens
/// its detail sheet. The list holds the newest rows the Mac sent; when the
/// Mac has older ones, a `Load earlier` row sits above the first activity
/// and pages them in, keeping what the person was looking at in place.
@MainActor
final class ActivityListViewController: UIViewController, UICollectionViewDelegate {
    private enum Section { case activity }
    /// The `Load earlier` row's item id; it scrolls with the rows above
    /// which it sits (a pinned header would float over them).
    private static let loadOlderItemID = "__load_older__"

    /// Whether older rows can be paged in, and whether a page is on its way.
    enum LoadOlderState: Equatable {
        case hidden
        case available
        case loading
    }

    private var activities: [SessionActivityPresentation] = []
    private var byID: [String: SessionActivityPresentation] = [:]
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private var didScrollToEnd = false
    /// Index of the topmost visible activity, whenever it changes.
    var onTopVisibleChange: ((Int) -> Void)?
    private var lastTopVisible = -1
    /// The sheet open on one activity, so a change to that activity (a
    /// trimmed row completed, a tool result landing) reaches it.
    private weak var openSheet: ActivityDetailSheetViewController?
    private var openSheetActivityID: String?

    var loadOlder: LoadOlderState = .hidden {
        didSet {
            guard loadOlder != oldValue, isViewLoaded else { return }
            apply(animated: false, changed: loadOlder == .hidden || oldValue == .hidden ? [] : [Self.loadOlderItemID])
        }
    }
    var onLoadOlder: (() -> Void)?
    /// The sheet asks for the whole copies of the trimmed rows it shows.
    var onLoadFullContent: (([TimelineItemID]) -> Void)?
    var isLoadingFullContent: (([TimelineItemID]) -> Bool)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        _ = dataSource
        apply(animated: false)
    }

    func update(_ activities: [SessionActivityPresentation]) {
        let previous = byID
        let previousFirstID = self.activities.first?.id
        self.activities = activities
        byID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        guard isViewLoaded else { return }
        // Older rows landed above what was shown: keep the eye where it was.
        let prepended = previousFirstID != nil && activities.first?.id != previousFirstID && byID[previousFirstID!] != nil
        apply(animated: !prepended, changed: activities.map(\.id).filter { previous[$0] != nil && previous[$0] != byID[$0] }, anchorTop: prepended)
        if let id = openSheetActivityID, let activity = byID[id] {
            openSheet?.update(ActivityDetailPresentationBuilder.make(for: activity, in: activities), isLoadingFullContent: isLoadingFullContent?(activity.row.items.map(\.id)) ?? false)
        }
    }

    func scroll(toActivityAt index: Int, position: UICollectionView.ScrollPosition = .centeredVertically, animated: Bool = true) {
        guard index < activities.count, let indexPath = dataSource.indexPath(for: activities[index].id) else { return }
        collectionView.scrollToItem(at: indexPath, at: position, animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Activity indices: the `Load earlier` row, when shown, is not one.
        let top = collectionView.indexPathsForVisibleItems
            .compactMap { dataSource.itemIdentifier(for: $0) }
            .filter { $0 != Self.loadOlderItemID }
            .compactMap { id in activities.firstIndex { $0.id == id } }
            .min() ?? -1
        guard top >= 0, top != lastTopVisible else { return }
        lastTopVisible = top
        onTopVisibleChange?(top)
    }

    private func apply(animated: Bool, changed: [String] = [], anchorTop: Bool = false) {
        let wasNearEnd = collectionView.contentOffset.y >= collectionView.contentSize.height - collectionView.bounds.height - 80
        let anchorID = anchorTop
            ? collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) }.first { $0 != Self.loadOlderItemID }
            : nil
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.activity])
        if loadOlder != .hidden { snapshot.appendItems([Self.loadOlderItemID]) }
        snapshot.appendItems(activities.map(\.id))
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: animated && view.window != nil) { [weak self] in
            guard let self, !activities.isEmpty else { return }
            if let anchorID, let indexPath = dataSource.indexPath(for: anchorID) {
                collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                return
            }
            if !didScrollToEnd || wasNearEnd, let last = activities.last, let indexPath = dataSource.indexPath(for: last.id) {
                didScrollToEnd = true
                collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
            }
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, String> {
        let registration = UICollectionView.CellRegistration<ActivityRowCell, String> { [weak self] cell, _, id in
            guard let activity = self?.byID[id] else { return }
            cell.configure(activity)
        }
        let loadOlderRegistration = UICollectionView.CellRegistration<LoadOlderCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(loadOlder) { [weak self] in self?.onLoadOlder?() }
        }
        return UICollectionViewDiffableDataSource<Section, String>(collectionView: collectionView) { collectionView, indexPath, id in
            if id == Self.loadOlderItemID {
                return collectionView.dequeueConfiguredReusableCell(using: loadOlderRegistration, for: indexPath, item: id)
            }
            return collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if id == Self.loadOlderItemID {
            if loadOlder == .available { onLoadOlder?() }
            return
        }
        guard let activity = byID[id] else { return }
        let presentation = ActivityDetailPresentationBuilder.make(for: activity, in: activities)
        let sheet = ActivityDetailSheetViewController(presentation: presentation)
        sheet.onLoadFullContent = { [weak self, weak sheet] itemIDs in
            guard let self else { return }
            onLoadFullContent?(itemIDs)
            // The sheet shows the channel's word on it: a spinner only while
            // a request is really in flight.
            if let sheet, let activity = byID[id] {
                sheet.update(ActivityDetailPresentationBuilder.make(for: activity, in: activities), isLoadingFullContent: isLoadingFullContent?(itemIDs) ?? false)
            }
        }
        openSheet = sheet
        openSheetActivityID = id
        present(sheet, animated: true)
    }
}

/// `Load earlier` above the first activity while the Mac holds older rows;
/// a spinner while a page is on its way. Absent from the list otherwise.
final class LoadOlderCell: UICollectionViewListCell {
    private let button = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .listPlainCell()
        button.setTitle("Load earlier", for: .normal)
        button.titleLabel?.font = .design(IOSDS.Typography.captionEmphasized)
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
        spinner.hidesWhenStopped = true
        let stack = UIStackView(arrangedSubviews: [spinner, button])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(_ state: ActivityListViewController.LoadOlderState, action: @escaping () -> Void) {
        self.action = action
        button.isEnabled = state == .available
        if state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}

/// Tag + time + chevron over two lines of content, `padding 10 16 11`.
final class ActivityRowCell: UICollectionViewListCell {
    private let tagView = TagView()
    private let timeLabel = UILabel()
    private let chevron = ChevronView()
    private let contentLabel = UILabel()
    private let separator = UIView.hairline(color: .rowSeparator)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .listPlainCell()
        let row = IOSDS.ActivityRow.self
        timeLabel.font = .design(IOSDS.Typography.activityTime)
        timeLabel.textColor = UIColor(IOSDS.Color.activityTime)
        let head = UIStackView(arrangedSubviews: [tagView, timeLabel, UIView(), chevron])
        head.axis = .horizontal
        head.alignment = .center
        head.spacing = row.headGap
        contentLabel.numberOfLines = row.contentLineLimit
        contentLabel.lineBreakMode = .byTruncatingTail
        let stack = UIStackView(arrangedSubviews: [head, contentLabel])
        stack.axis = .vertical
        stack.spacing = row.lineGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(separator)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: row.top),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: IOSDS.Layout.sideInset),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -IOSDS.Layout.sideInset),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -row.bottom),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(_ activity: SessionActivityPresentation) {
        let row = IOSDS.ActivityRow.self
        tagView.configure(
            tag: activity.tag,
            label: activity.label,
            verticalPadding: row.tagVerticalPadding,
            horizontalPadding: row.tagHorizontalPadding,
            radius: row.tagRadius
        )
        timeLabel.text = activity.occurredAt
        contentLabel.setText(activity.content, style: IOSDS.Typography.body, color: .inkPrimary)
    }
}
