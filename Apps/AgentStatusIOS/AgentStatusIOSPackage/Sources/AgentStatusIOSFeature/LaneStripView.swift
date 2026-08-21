import AgentStatusCore
import AgentStatusDesignSystem
import AgentStatusTransport
import UIKit

/// Three lanes — Input / Tools / Model — one 12px cell column per Activity
/// row, coloured in the row's own lane (L1 neutral / L2 pale / L3 solid),
/// blank elsewhere. Cross-lane rows draw a 4px bar through every lane.
/// Tapping a column reports the index into the strip's activities.
final class LaneStripView: UIView, UIScrollViewDelegate {
    var onSelect: ((Int) -> Void)?
    /// The user panned the strip: index of the activity whose column is now
    /// at the strip's left edge.
    var onUserScroll: ((Int) -> Void)?

    private let names = UIStackView()
    private let scrollView = UIScrollView()
    private let canvas = LaneCanvasView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let lane = IOSDS.Lane.self
        names.axis = .vertical
        names.alignment = .trailing
        names.spacing = lane.gap
        names.translatesAutoresizingMaskIntoConstraints = false
        for title in ["Input", "Tools", "Model"] {
            let label = UILabel()
            label.font = .design(IOSDS.Typography.laneName)
            label.textColor = .secondaryLabel
            label.text = title
            label.heightAnchor.constraint(equalToConstant: lane.cell).isActive = true
            names.addArrangedSubview(label)
        }
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.backgroundColor = .clear
        canvas.onSelect = { [weak self] index in self?.onSelect?(index) }
        addSubview(names)
        addSubview(scrollView)
        scrollView.addSubview(canvas)
        NSLayoutConstraint.activate([
            names.leadingAnchor.constraint(equalTo: leadingAnchor),
            names.topAnchor.constraint(equalTo: topAnchor),
            names.widthAnchor.constraint(equalToConstant: lane.nameWidth),
            scrollView.leadingAnchor.constraint(equalTo: names.trailingAnchor, constant: lane.nameGap),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            canvas.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            canvas.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Puts the column of `activityIndex` (or the next one that has a
    /// column) at the strip's left edge, clamped to the content.
    func scroll(toActivityAt activityIndex: Int) {
        guard let x = canvas.columnX(forActivityIndex: activityIndex) else { return }
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        scrollView.setContentOffset(CGPoint(x: min(x, maxX), y: 0), animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        if let index = canvas.activityIndex(atX: scrollView.contentOffset.x) { onUserScroll?(index) }
    }

    func configure(activities: [SessionActivityPresentation]) {
        let wasAtEnd = scrollView.contentOffset.x >= scrollView.contentSize.width - scrollView.bounds.width - 1
        canvas.columns = activities.enumerated().compactMap { index, activity in
            guard activity.appearsInLaneStrip else { return nil }
            return LaneCanvasView.Column(activityIndex: index, lane: activity.lane, color: UIColor(activity.tag.laneCellColor))
        }
        layoutIfNeeded()
        if wasAtEnd || scrollView.contentSize.width <= scrollView.bounds.width {
            let x = max(0, canvas.intrinsicContentSize.width - scrollView.bounds.width)
            scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: false)
        }
    }
}

final class LaneCanvasView: UIView {
    struct Column {
        let activityIndex: Int
        let lane: TimelineLane?
        let color: UIColor
    }

    var onSelect: ((Int) -> Void)?
    var columns: [Column] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: LaneCanvasView, _) in
            self.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private func columnWidth(of column: Column) -> CGFloat {
        column.lane == nil ? IOSDS.Lane.markerWidth : IOSDS.Lane.cell
    }

    /// Left x of the first column whose activity index is ≥ `activityIndex`.
    func columnX(forActivityIndex activityIndex: Int) -> CGFloat? {
        var x: CGFloat = 0
        for column in columns {
            if column.activityIndex >= activityIndex { return x }
            x += columnWidth(of: column) + IOSDS.Lane.gap
        }
        return columns.isEmpty ? nil : x
    }

    /// Activity index of the column at (or just after) content x.
    func activityIndex(atX target: CGFloat) -> Int? {
        var x: CGFloat = 0
        for column in columns {
            let width = columnWidth(of: column)
            if x + width > target { return column.activityIndex }
            x += width + IOSDS.Lane.gap
        }
        return columns.last?.activityIndex
    }

    override var intrinsicContentSize: CGSize {
        let lane = IOSDS.Lane.self
        let width = columns.reduce(CGFloat(0)) { $0 + columnWidth(of: $1) + lane.gap } - (columns.isEmpty ? 0 : lane.gap)
        return CGSize(width: max(0, width), height: lane.cell * 3 + lane.gap * 2)
    }

    private func row(for lane: TimelineLane) -> Int {
        switch lane {
        case .user: 0
        case .exec: 1
        case .model: 2
        }
    }

    override func draw(_ rect: CGRect) {
        let lane = IOSDS.Lane.self
        var x: CGFloat = 0
        for column in columns {
            let width = columnWidth(of: column)
            let rows: [Int] = column.lane.map { [row(for: $0)] } ?? [0, 1, 2]
            for row in rows {
                let cell = CGRect(x: x, y: CGFloat(row) * (lane.cell + lane.gap), width: width, height: lane.cell)
                let path = UIBezierPath(roundedRect: cell, cornerRadius: column.lane == nil ? lane.radius / 2 : lane.radius)
                column.color.resolvedColor(with: traitCollection).setFill()
                path.fill()
            }
            x += width + lane.gap
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        var x: CGFloat = 0
        for column in columns {
            let width = columnWidth(of: column)
            if location.x >= x - IOSDS.Lane.gap / 2 && location.x < x + width + IOSDS.Lane.gap / 2 {
                onSelect?(column.activityIndex)
                return
            }
            x += width + IOSDS.Lane.gap
        }
    }
}
