import Core
import DesignSystem
import Transport
import UIKit

/// One session in the Sessions list (design §1):
/// device name + status pill / title + time + chevron / latest activity /
/// subagent group (summary bar, chips when expanded), all flush left.
/// Full-width hairline under the row.
final class SessionRowCell: UICollectionViewListCell {
    static let reuseIdentifier = "SessionRowCell"

    private(set) var itemID: SessionListItemID?
    /// A subagent chip was tapped: open that child session.
    var onSelectSubagent: ((SessionID) -> Void)?
    /// The summary bar was tapped: flip this row's expanded state.
    var onToggleSubagents: (() -> Void)?
    private var item: SessionListItem?
    private var availableWidth: CGFloat = 0
    private var subagentsExpanded = false

    private let stack = UIStackView()
    private let deviceRow = UIStackView()
    private let deviceLabel = UILabel()
    private let statusPill = StatusPillView(
        height: IOSDS.SessionRow.statusPillHeight,
        horizontalPadding: IOSDS.SessionRow.statusPillHorizontalPadding,
        dotSize: IOSDS.SessionRow.statusPillDot,
        dotGap: IOSDS.SessionRow.statusPillDotGap,
        textStyle: IOSDS.Typography.statusLabel
    )
    private let titleRow = UIView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let chevron = ChevronView()
    private let latestRow = UIStackView()
    private let latestTag = TagView()
    private let latestLabel = UILabel()
    private let groupContainer = UIStackView()
    private let summaryBar = SubagentSummaryBar()
    private let chips = SubagentChipFlowView()
    private let separator = UIView.hairline(color: .rowSeparator)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .listPlainCell()
        buildLayout()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(item: SessionListItem, availableWidth: CGFloat, now: Date, subagentsExpanded: Bool) {
        self.item = item
        self.itemID = item.id
        self.availableWidth = availableWidth
        self.subagentsExpanded = subagentsExpanded

        deviceLabel.setText(item.deviceName, style: IOSDS.Typography.caption, color: .tertiaryLabel)
        statusPill.configure(text: item.statusLabel, tone: item.tone)
        titleLabel.setText(item.title, style: IOSDS.Typography.listTitle, color: .inkPrimary)
        if let latest = item.latest {
            latestRow.isHidden = false
            latestTag.configure(
                tag: latest.tag,
                label: latest.label,
                verticalPadding: IOSDS.SessionRow.latestTagVerticalPadding,
                horizontalPadding: IOSDS.SessionRow.latestTagHorizontalPadding,
                radius: IOSDS.SessionRow.latestTagRadius
            )
            latestLabel.setText(latest.text, style: IOSDS.Typography.caption, color: .secondaryLabel)
        } else {
            latestRow.isHidden = true
        }
        groupContainer.isHidden = item.subagents.isEmpty
        summaryBar.configure(tones: item.subagents.map(\.tone), text: item.subagentSummary, expanded: subagentsExpanded)
        chips.isHidden = !subagentsExpanded
        tick(now: now)
    }

    /// Refreshes the relative time and chip durations without re-laying out text.
    func tick(now: Date) {
        guard let item else { return }
        timeLabel.setText(item.timeText(now: now), style: IOSDS.Typography.caption, color: .tertiaryLabel, tabular: true)
        if !item.subagents.isEmpty, subagentsExpanded {
            chips.configure(
                items: item.subagents,
                availableWidth: availableWidth - IOSDS.SessionRow.chipIndent,
                now: now
            )
        }
    }

    private func buildLayout() {
        let row = IOSDS.SessionRow.self
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = row.lineGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(separator)

        deviceLabel.numberOfLines = 1
        titleLabel.numberOfLines = row.titleLineLimit
        titleLabel.lineBreakMode = .byTruncatingTail
        // Greedy wrapping: UIKit's default "push out" strategy moves the last
        // word of line 1 down to balance the lines, which opens a wide gap
        // between the title and the time. The gap is meant to be 10.
        titleLabel.lineBreakStrategy = []
        timeLabel.numberOfLines = 1
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        latestLabel.numberOfLines = 1

        deviceRow.axis = .horizontal
        deviceRow.alignment = .center
        deviceRow.spacing = row.columnGap
        let deviceSpacer = UIView()
        deviceSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        deviceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        deviceRow.addArrangedSubview(deviceLabel)
        deviceRow.addArrangedSubview(deviceSpacer)
        deviceRow.addArrangedSubview(statusPill)

        for view in [titleLabel, timeLabel, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            titleRow.addSubview(view)
        }
        let firstLineCenter = IOSDS.Typography.listTitle.lineHeight / 2
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: titleRow.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -row.columnGap),
            timeLabel.centerYAnchor.constraint(equalTo: titleLabel.topAnchor, constant: firstLineCenter),
            timeLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -row.trailingGap),
            chevron.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.topAnchor, constant: firstLineCenter),
        ])

        latestRow.axis = .horizontal
        latestRow.alignment = .center
        latestRow.spacing = row.latestGap
        latestRow.addArrangedSubview(latestTag)
        latestRow.addArrangedSubview(latestLabel)

        chips.onSelect = { [weak self] id in self?.onSelectSubagent?(id) }
        summaryBar.addTarget(self, action: #selector(toggleSubagents), for: .touchUpInside)
        groupContainer.axis = .vertical
        groupContainer.spacing = IOSDS.SubagentGroup.lineGap
        groupContainer.addArrangedSubview(summaryBar)
        groupContainer.addArrangedSubview(chips)

        stack.addArrangedSubview(deviceRow)
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(latestRow)
        stack.addArrangedSubview(groupContainer)
        stack.setCustomSpacing(row.chipBlockGap, after: latestRow)
        // A hidden latest row must not leave its gap behind.
        stack.setCustomSpacing(row.lineGap, after: titleRow)

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

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        // The group sits 4 under whichever line is last; the stack's custom
        // spacing after the title row only applies when the latest row hides.
        stack.setCustomSpacing(latestRow.isHidden ? IOSDS.SessionRow.chipBlockGap : IOSDS.SessionRow.lineGap, after: titleRow)
    }

    @objc private func toggleSubagents() {
        onToggleSubagents?()
    }
}

// MARK: - Subagent summary bar (collapsed group)

/// 26 tall: the subagents' dots stacked (11px, white ring, overlapping by 4,
/// running → waiting → done), `3 subagents · 2 running · 1 done`, and a
/// chevron that flips when the group is expanded. The whole bar toggles.
final class SubagentSummaryBar: UIControl {
    private let dots = UIView()
    private var dotViews: [UIView] = []
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)))
    private var dotsWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        let g = IOSDS.SubagentGroup.self
        dots.isUserInteractionEnabled = false
        dots.translatesAutoresizingMaskIntoConstraints = false
        label.font = .design(IOSDS.Typography.caption)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = UIColor(IOSDS.Color.subagentChevron)
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dots)
        addSubview(label)
        addSubview(chevron)
        dotsWidth = dots.widthAnchor.constraint(equalToConstant: g.dot)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: g.barHeight),
            dots.leadingAnchor.constraint(equalTo: leadingAnchor),
            dots.centerYAnchor.constraint(equalTo: centerYAnchor),
            dots.heightAnchor.constraint(equalToConstant: g.dot),
            dotsWidth,
            label.leadingAnchor.constraint(equalTo: dots.trailingAnchor, constant: g.gap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -g.gap),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: g.chevronWidth),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(tones: [SessionStatusTone], text: String, expanded: Bool) {
        let g = IOSDS.SubagentGroup.self
        while dotViews.count < tones.count {
            let dot = UIView()
            dot.layer.cornerRadius = g.dot / 2
            dot.layer.borderWidth = g.dotRing
            dots.addSubview(dot)
            dotViews.append(dot)
        }
        for (index, dot) in dotViews.enumerated() {
            dot.isHidden = index >= tones.count
            guard index < tones.count else { continue }
            dot.backgroundColor = tones[index].uiKitColor
            dot.layer.borderColor = UIColor.systemBackground.cgColor
            dot.frame = CGRect(x: CGFloat(index) * (g.dot - g.dotOverlap), y: 0, width: g.dot, height: g.dot)
        }
        dotsWidth.constant = tones.isEmpty ? 0 : g.dot + CGFloat(tones.count - 1) * (g.dot - g.dotOverlap)
        label.text = text
        accessibilityLabel = text
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }
}

// MARK: - Subagent chips (L4 §4.4)

/// One subagent chip: 26 tall, radius 8, `padding 0 9`, 6px dot (the
/// subagent's own tier, still), name 13 / 18, duration mono 12. Tapping it
/// opens the subagent's session; the fill darkens while pressed.
final class SubagentChipView: UIControl {
    private let dot = StatusDotView(size: IOSDS.SubagentChip.dot)
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private(set) var sessionID: SessionID?

    private static let nameFont = UIFont.design(IOSDS.Typography.subagentName)
    private static let timeFont = UIFont.design(IOSDS.Typography.subagentTime)

    init() {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = IOSDS.SubagentChip.radius
        layer.cornerCurve = .continuous
        nameLabel.font = Self.nameFont
        nameLabel.textColor = .inkPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = Self.timeFont
        timeLabel.textColor = .inkQuaternary
        addSubview(dot)
        addSubview(nameLabel)
        addSubview(timeLabel)
        dot.translatesAutoresizingMaskIntoConstraints = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: isHighlighted ? 0.05 : 0.2) {
                self.backgroundColor = self.isHighlighted ? .systemFill : .tertiarySystemFill
            }
        }
    }

    /// Natural width: padding + dot + gaps + name + time + padding.
    static func naturalWidth(name: String, time: String) -> CGFloat {
        let chip = IOSDS.SubagentChip.self
        let nameWidth = (name as NSString).size(withAttributes: [.font: nameFont]).width.rounded(.up)
        let timeWidth = (time as NSString).size(withAttributes: [.font: timeFont]).width.rounded(.up)
        return chip.horizontalPadding + chip.dot + chip.innerGap + nameWidth + chip.innerGap + timeWidth + chip.horizontalPadding
    }

    func configure(item: SubagentChipItem, now: Date) {
        sessionID = item.id
        dot.configure(tone: item.tone, animates: false)
        nameLabel.text = item.name
        timeLabel.text = item.durationText(now: now)
        accessibilityLabel = "\(item.name), subagent, \(item.durationText(now: now))"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let chip = IOSDS.SubagentChip.self
        let height = bounds.height
        dot.frame = CGRect(x: chip.horizontalPadding, y: (height - chip.dot) / 2, width: chip.dot, height: chip.dot)
        let timeWidth = (timeLabel.text ?? "").isEmpty ? 0 : ((timeLabel.text! as NSString).size(withAttributes: [.font: Self.timeFont]).width.rounded(.up))
        let timeX = bounds.width - chip.horizontalPadding - timeWidth
        timeLabel.frame = CGRect(x: timeX, y: 0, width: timeWidth, height: height)
        let nameX = chip.horizontalPadding + chip.dot + chip.innerGap
        nameLabel.frame = CGRect(x: nameX, y: 0, width: max(0, timeX - chip.innerGap - nameX), height: height)
    }
}

/// Lays subagent chips out in lines by the §4.4 pairing rule for a known
/// width, and reports its height through an explicit constraint so the
/// self-sizing row can measure it.
final class SubagentChipFlowView: UIView {
    var onSelect: ((SessionID) -> Void)?
    private var chipViews: [SubagentChipView] = []
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        heightConstraint.isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(items: [SubagentChipItem], availableWidth: CGFloat, now: Date) {
        let chip = IOSDS.SubagentChip.self
        while chipViews.count < items.count {
            let view = SubagentChipView()
            view.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            addSubview(view)
            chipViews.append(view)
        }
        for (index, view) in chipViews.enumerated() {
            view.isHidden = index >= items.count
        }
        let widths = items.map { SubagentChipView.naturalWidth(name: $0.name, time: $0.durationText(now: now)) }
        let lines = SubagentChipLayout.lines(widths: widths.map { Double($0) }, availableWidth: Double(availableWidth))
        var y: CGFloat = 0
        for line in lines {
            var x: CGFloat = 0
            for placement in line {
                let view = chipViews[placement.index]
                view.configure(item: items[placement.index], now: now)
                let natural = widths[placement.index]
                let width = min(natural, placement.maxWidth.map { CGFloat($0) } ?? natural)
                view.frame = CGRect(x: x, y: y, width: width, height: chip.height)
                x += width + chip.gap
            }
            y += chip.height + chip.gap
        }
        let height = lines.isEmpty ? 0 : y - chip.gap
        if heightConstraint.constant != height {
            heightConstraint.constant = height
        }
    }

    @objc private func chipTapped(_ chip: SubagentChipView) {
        guard let id = chip.sessionID else { return }
        onSelect?(id)
    }
}
