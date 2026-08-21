import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import UIKit

/// Activity tab: the chronological `TimelineRow` list. Tapping a row opens
/// its detail sheet.
@MainActor
final class ActivityListViewController: UIViewController, UICollectionViewDelegate {
    private enum Section { case activity }

    private var activities: [SessionActivityPresentation] = []
    private var byID: [String: SessionActivityPresentation] = [:]
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var dataSource = makeDataSource()
    private var didScrollToEnd = false
    /// Index of the topmost visible activity, whenever it changes.
    var onTopVisibleChange: ((Int) -> Void)?
    private var lastTopVisible = -1

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
        self.activities = activities
        byID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        guard isViewLoaded else { return }
        apply(animated: true, changed: activities.map(\.id).filter { previous[$0] != nil && previous[$0] != byID[$0] })
    }

    func scroll(toActivityAt index: Int, position: UICollectionView.ScrollPosition = .centeredVertically, animated: Bool = true) {
        guard index < activities.count else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: position, animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let top = collectionView.indexPathsForVisibleItems.map(\.item).min() ?? -1
        guard top >= 0, top != lastTopVisible else { return }
        lastTopVisible = top
        onTopVisibleChange?(top)
    }

    private func apply(animated: Bool, changed: [String] = []) {
        let wasNearEnd = collectionView.contentOffset.y >= collectionView.contentSize.height - collectionView.bounds.height - 80
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.activity])
        snapshot.appendItems(activities.map(\.id))
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: animated && view.window != nil) { [weak self] in
            guard let self, !activities.isEmpty else { return }
            if !didScrollToEnd || wasNearEnd {
                didScrollToEnd = true
                collectionView.scrollToItem(at: IndexPath(item: activities.count - 1, section: 0), at: .bottom, animated: false)
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
        return UICollectionViewDiffableDataSource<Section, String>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let activity = byID[id] else { return }
        let presentation = ActivityDetailPresentationBuilder.make(for: activity, in: activities)
        present(ActivityDetailSheetViewController(presentation: presentation), animated: true)
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
