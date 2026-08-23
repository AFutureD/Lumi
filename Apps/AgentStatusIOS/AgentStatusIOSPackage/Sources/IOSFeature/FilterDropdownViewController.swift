import DesignSystem
import UIKit

/// L3 §3.4 Dropdown panel of one filter group, shown as a system popover
/// under its trigger. UIKit owns the presentation — anchoring, outside-tap
/// dismissal, `passthroughViews` so the other trigger switches groups, the
/// right edge margin, rotation, VoiceOver — while `FilterPopoverBackgroundView`
/// draws the design's chrome and `FilterOptionRow` the checkbox rows.
@MainActor
final class FilterDropdownViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    let group: FilterGroup
    var onToggle: ((FilterOption) -> Void)?
    /// Dismissed by the system (outside tap) rather than by the owner.
    var onDismiss: (() -> Void)?

    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let rowsStack = UIStackView()
    private var rows: [FilterOptionRow] = []
    private var options: [FilterOption] = []

    init(group: FilterGroup) {
        self.group = group
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        popoverPresentationController?.delegate = self
        popoverPresentationController?.popoverBackgroundViewClass = FilterPopoverBackgroundView.self
        popoverPresentationController?.permittedArrowDirections = .up
        let inset = IOSDS.FilterPanel.edgeInset
        popoverPresentationController?.popoverLayoutMargins = UIEdgeInsets(top: 0, left: inset, bottom: inset, right: inset)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let p = IOSDS.FilterPanel.self
        view.backgroundColor = .clear
        view.layer.cornerRadius = p.radius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true

        headerLabel.setText(group.title.uppercased(), style: IOSDS.Typography.filterPanelHeader, color: UIColor(IOSDS.Color.filterPanelHeader))
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        let headerLine = UIView.hairline(color: UIColor(IOSDS.Color.filterPanelSeparator))

        rowsStack.axis = .vertical
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.addSubview(rowsStack)
        view.addSubview(headerLabel)
        view.addSubview(headerLine)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor),
            headerLabel.heightAnchor.constraint(equalToConstant: p.headerHeight),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: p.horizontalPadding),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -p.horizontalPadding),
            headerLine.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: -DS.Stroke.hairline),
            headerLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        applyOptions()
    }

    /// Rebuilt when the option set changes (a Mac paired / unpaired), else
    /// the rows update in place so the open panel reflects each tap.
    func configure(options: [FilterOption]) {
        self.options = options
        guard isViewLoaded else { return }
        applyOptions()
    }

    private func applyOptions() {
        if rows.map(\.option.id) != options.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = options.enumerated().map { index, option in
                let row = FilterOptionRow(option: option, separated: index > 0)
                row.addAction(UIAction { [weak self] _ in self?.onToggle?(row.option) }, for: .touchUpInside)
                rowsStack.addArrangedSubview(row)
                return row
            }
        } else {
            for (row, option) in zip(rows, options) { row.configure(option) }
        }
        let p = IOSDS.FilterPanel.self
        preferredContentSize = CGSize(width: p.width, height: p.headerHeight + p.rowHeight * Double(options.count))
    }

    // MARK: - UIPopoverPresentationControllerDelegate

    /// Stay a popover on iPhone (the default adapts to a full-screen sheet).
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss?()
    }
}

/// The panel's chrome: 268 wide, radius 14, thick material under
/// `rgba(252,252,252,.9)`, `0 0 0 .5px` outline and `0 14px 36px` shadow,
/// no arrow — the popover drops straight under its trigger.
final class FilterPopoverBackgroundView: UIPopoverBackgroundView {
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let tint = UIView()
    private var _arrowOffset: CGFloat = 0
    private var _arrowDirection: UIPopoverArrowDirection = .up

    override init(frame: CGRect) {
        super.init(frame: frame)
        let p = IOSDS.FilterPanel.self
        material.layer.cornerRadius = p.radius
        material.layer.cornerCurve = .continuous
        material.clipsToBounds = true
        material.layer.borderWidth = p.outline
        tint.backgroundColor = UIColor(IOSDS.Color.filterPanelFill)
        material.contentView.addSubview(tint)
        addSubview(material)
        layer.shadowColor = UIColor(IOSDS.Color.filterPanelShadow).cgColor
        layer.shadowOpacity = 1
        layer.shadowOffset = CGSize(width: 0, height: p.shadowOffsetY)
        layer.shadowRadius = p.shadowBlur / 2
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: FilterPopoverBackgroundView, _) in
            self.applyColors()
        }
        applyColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var arrowOffset: CGFloat {
        get { _arrowOffset }
        set { _arrowOffset = newValue }
    }

    override var arrowDirection: UIPopoverArrowDirection {
        get { _arrowDirection }
        set { _arrowDirection = newValue }
    }

    override class func contentViewInsets() -> UIEdgeInsets { .zero }
    override class func arrowHeight() -> CGFloat { 0 }
    override class func arrowBase() -> CGFloat { 0 }
    /// We draw the chrome; UIKit must not add its own border or rounding.
    override class var wantsDefaultContentAppearance: Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        material.frame = bounds
        tint.frame = material.bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: IOSDS.FilterPanel.radius).cgPath
    }

    private func applyColors() {
        material.layer.borderColor = UIColor(IOSDS.Color.filterPanelOutline).resolvedColor(with: traitCollection).cgColor
    }
}

/// One option: `[checkbox 22][icon tile 30][name][count]`, 48 tall,
/// `padding 0 14`, gap 11; a top hairline between rows.
final class FilterOptionRow: UIControl {
    private(set) var option: FilterOption

    private let checkbox = UIView()
    private let check = CAShapeLayer()
    private let tile = UIView()
    private let glyph = UIImageView()
    private let dot = UIView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()

    init(option: FilterOption, separated: Bool) {
        self.option = option
        super.init(frame: .zero)
        let p = IOSDS.FilterPanel.self
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button

        checkbox.layer.cornerRadius = p.checkboxRadius
        checkbox.layer.cornerCurve = .continuous
        checkbox.layer.borderWidth = p.checkboxRing
        check.path = Self.checkPath().cgPath
        check.fillColor = nil
        check.strokeColor = UIColor.white.cgColor
        check.lineWidth = p.checkStroke
        check.lineCap = .round
        check.lineJoin = .round
        check.frame = CGRect(x: (p.checkbox - p.checkWidth) / 2, y: (p.checkbox - p.checkHeight) / 2, width: p.checkWidth, height: p.checkHeight)
        checkbox.layer.addSublayer(check)

        tile.layer.cornerRadius = p.tileRadius
        tile.layer.cornerCurve = .continuous
        glyph.image = UIImage(systemName: "laptopcomputer", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = UIColor(IOSDS.Color.filterTileGlyph)
        dot.layer.cornerRadius = p.tileDot / 2
        tile.addSubview(glyph)
        tile.addSubview(dot)

        nameLabel.font = .design(IOSDS.Typography.listTitle)
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .design(IOSDS.Typography.filterOptionCount, tabular: true)
        countLabel.textColor = UIColor(IOSDS.Color.filterOptionCount)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = UIStackView(arrangedSubviews: [checkbox, tile, nameLabel, countLabel])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = p.gap
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [checkbox, tile, glyph, dot] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: p.rowHeight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.horizontalPadding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p.horizontalPadding),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: p.checkbox),
            checkbox.heightAnchor.constraint(equalToConstant: p.checkbox),
            tile.widthAnchor.constraint(equalToConstant: p.tile),
            tile.heightAnchor.constraint(equalToConstant: p.tile),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            dot.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: p.tileDot),
            dot.heightAnchor.constraint(equalToConstant: p.tileDot),
        ])
        if separated {
            let line = UIView.hairline(color: UIColor(IOSDS.Color.filterPanelSeparator))
            addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: topAnchor),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: FilterOptionRow, _) in
            self.applyColors()
        }
        configure(option)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(_ option: FilterOption) {
        self.option = option
        nameLabel.text = option.name
        countLabel.text = "\(option.count)"
        switch option.glyph {
        case .laptop:
            glyph.isHidden = false
            dot.isHidden = true
        case .dot:
            glyph.isHidden = true
            dot.isHidden = false
        }
        accessibilityLabel = option.name
        accessibilityValue = "\(option.count)"
        accessibilityTraits = option.isSelected ? [.button, .selected] : .button
        applyColors()
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .tertiarySystemFill : .clear }
    }

    private func applyColors() {
        let on = option.isSelected
        checkbox.backgroundColor = on ? UIColor(DS.Semantic.accent) : UIColor(IOSDS.Color.filterCheckboxOff)
        checkbox.layer.borderColor = on ? UIColor.clear.cgColor : UIColor(IOSDS.Color.filterCheckboxRing).resolvedColor(with: traitCollection).cgColor
        check.isHidden = !on
        switch option.glyph {
        case .laptop:
            tile.backgroundColor = UIColor(IOSDS.Color.filterTileNeutral)
        case let .dot(hue):
            tile.backgroundColor = UIColor(IOSDS.Color.filterTileFill(hue))
            dot.backgroundColor = UIColor(hue: hue)
        }
    }

    /// The 13 × 10 check of the screen file (`M1.6 6.4l4 4 8.8-8.8` in a 16 × 12 box).
    private static func checkPath() -> UIBezierPath {
        let p = IOSDS.FilterPanel.self
        let sx = p.checkWidth / 16, sy = p.checkHeight / 12
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 1.6 * sx, y: 6.4 * sy))
        path.addLine(to: CGPoint(x: 5.6 * sx, y: 10.4 * sy))
        path.addLine(to: CGPoint(x: 14.4 * sx, y: 1.6 * sy))
        return path
    }
}
