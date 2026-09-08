import Core
import DesignSystem
import UIKit

/// What the figures card shows (handoff pages 9 / 9b): the header (range
/// or selected bucket), the COST and TOKENS blocks, the three counts, and
/// any notices — or, before a report is in, one loading / message line.
struct UsageFiguresModel: Equatable {
    struct Notice: Equatable {
        let text: String
        let warning: Bool
    }

    struct Figures: Equatable {
        var cost: String
        /// `↑ 18% vs last week` for the range; the agent split for a bucket.
        var costCaption: String
        var tokens: String
        var segments: [UsageSummaryFigures.Segment]
        /// `Cache read 78% · output 7%` / `composition for the whole range`.
        var composition: String
        var sessions: String
        var turns: String
        var calls: String
    }

    enum Body: Equatable {
        case figures(Figures)
        case loading(String)
        case message(String, warning: Bool)
    }

    /// `Sep 1 – 7, 2026`, or the selected bar's `Thu 9/4`.
    var title: String
    /// A bucket title reads 13/semibold tint.
    var titleEmphasized: Bool
    /// `updated 2m ago` / `updating…` / `offline · 5m ago`; hidden when `Clear` shows.
    var stamp: String?
    var stampTint: Bool
    var showsClear: Bool
    var body: Body
    var notices: [Notice]
}

/// The figures card. Every value comes from `UsageFiguresModel`; the view
/// holds no arithmetic.
final class UsageFiguresCardView: UIView {
    private typealias U = IOSDS.Usage

    var onClear: () -> Void = {}

    private let titleLabel = UILabel()
    private let stampLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let costValue = UILabel()
    private let costCaption = UILabel()
    private let tokensValue = UILabel()
    private let composition = UsageCompositionBarView()
    private let compositionCaption = UILabel()
    private let sessions = UsageCountColumn(title: "SESSIONS")
    private let turns = UsageCountColumn(title: "TURNS")
    private let calls = UsageCountColumn(title: "CALLS")
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private let messageLabel = UILabel()
    private let figuresStack = UIStackView()
    private let loadingRow = UIStackView()
    private let messageRow = UIStackView()
    private let noticesStack = UIStackView()
    private var model: UsageFiguresModel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = IOSDS.Layout.cardRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        // Header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stampLabel.font = .design(IOSDS.Typography.caption, tabular: true)
        stampLabel.textAlignment = .right
        var clear = UIButton.Configuration.plain()
        clear.title = "Clear"
        clear.contentInsets = .zero
        clear.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.design(IOSDS.Typography.action)
            return outgoing
        }
        clearButton.configuration = clear
        clearButton.addAction(UIAction { [weak self] _ in self?.onClear() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [titleLabel, stampLabel, clearButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = U.valueDeltaGap
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: U.cardHeaderVerticalPadding, leading: U.cardHorizontalPadding, bottom: U.cardHeaderVerticalPadding, trailing: U.cardHorizontalPadding)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: U.cardHeaderMinimumHeight).isActive = true

        // COST
        costValue.font = .design(IOSDS.Typography.usageBigValue, tabular: true)
        costValue.setContentHuggingPriority(.required, for: .horizontal)
        costValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        costCaption.font = .design(IOSDS.Typography.caption)
        costCaption.textColor = UIColor(U.secondaryText)
        costCaption.numberOfLines = 1
        costCaption.lineBreakMode = .byTruncatingTail
        costCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let costRow = UIStackView(arrangedSubviews: [costValue, costCaption])
        costRow.axis = .horizontal
        costRow.alignment = .lastBaseline
        costRow.spacing = U.valueDeltaGap
        let costBlock = Self.block(label: "COST", rows: [costRow])

        // TOKENS
        tokensValue.font = .design(IOSDS.Typography.usageBigValue, tabular: true)
        compositionCaption.font = .design(IOSDS.Typography.caption)
        compositionCaption.textColor = UIColor(U.secondaryText)
        let tokensBlock = Self.block(label: "TOKENS", rows: [tokensValue, composition, compositionCaption])
        tokensBlock.setCustomSpacing(U.compositionBarTopGap, after: tokensValue)
        tokensBlock.setCustomSpacing(U.compositionCaptionGap, after: composition)

        // Counts
        let counts = UIStackView(arrangedSubviews: [sessions, turns, calls])
        counts.axis = .horizontal
        counts.distribution = .fillEqually
        counts.alignment = .center
        counts.isLayoutMarginsRelativeArrangement = true
        counts.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: U.cardHorizontalPadding, bottom: 4, trailing: U.cardHorizontalPadding)
        counts.heightAnchor.constraint(greaterThanOrEqualToConstant: U.countsRowMinimumHeight).isActive = true

        figuresStack.axis = .vertical
        for view in [costBlock, UIView.hairline(color: UIColor(U.hairline)), tokensBlock, UIView.hairline(color: UIColor(U.hairline)), counts] {
            figuresStack.addArrangedSubview(view)
        }

        // Loading / message bodies
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingSpinner.widthAnchor.constraint(equalToConstant: U.loadingSpinner),
            loadingSpinner.heightAnchor.constraint(equalToConstant: U.loadingSpinner),
        ])
        loadingLabel.font = .design(IOSDS.Typography.body)
        loadingLabel.textColor = .inkSecondary
        loadingRow.axis = .horizontal
        loadingRow.alignment = .center
        loadingRow.spacing = U.noticeGap
        loadingRow.addArrangedSubview(loadingSpinner)
        loadingRow.addArrangedSubview(loadingLabel)
        loadingRow.isLayoutMarginsRelativeArrangement = true
        loadingRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: U.noticeVerticalPadding, leading: U.cardHorizontalPadding, bottom: U.noticeVerticalPadding, trailing: U.cardHorizontalPadding)

        messageLabel.font = .design(IOSDS.Typography.body)
        messageLabel.numberOfLines = 0
        messageRow.axis = .vertical
        messageRow.addArrangedSubview(messageLabel)
        messageRow.isLayoutMarginsRelativeArrangement = true
        messageRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: U.noticeVerticalPadding, leading: U.cardHorizontalPadding, bottom: U.noticeVerticalPadding, trailing: U.cardHorizontalPadding)

        noticesStack.axis = .vertical

        let stack = UIStackView(arrangedSubviews: [header, UIView.hairline(color: UIColor(U.hairline)), figuresStack, loadingRow, messageRow, noticesStack])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// `LABEL` over one or more rows, `padding 12 16 10`.
    private static func block(label: String, rows: [UIView]) -> UIStackView {
        let title = UILabel()
        title.setText(label, style: IOSDS.Typography.usageLabel, color: UIColor(U.secondaryText))
        let stack = UIStackView(arrangedSubviews: [title] + rows)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = U.blockLabelGap
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: U.blockTopPadding, leading: U.cardHorizontalPadding, bottom: U.blockBottomPadding, trailing: U.cardHorizontalPadding)
        return stack
    }

    func apply(_ model: UsageFiguresModel) {
        guard model != self.model else { return }
        self.model = model
        if model.titleEmphasized {
            titleLabel.font = .design(IOSDS.Typography.captionEmphasized)
            titleLabel.textColor = .tintColor
        } else {
            titleLabel.font = .design(IOSDS.Typography.caption, tabular: true)
            titleLabel.textColor = UIColor(U.secondaryText)
        }
        titleLabel.text = model.title
        stampLabel.text = model.stamp
        stampLabel.textColor = model.stampTint ? .tintColor : UIColor(U.tertiaryText)
        stampLabel.isHidden = model.showsClear || model.stamp == nil
        clearButton.isHidden = !model.showsClear

        switch model.body {
        case .figures(let figures):
            figuresStack.isHidden = false
            loadingRow.isHidden = true
            messageRow.isHidden = true
            costValue.text = figures.cost
            costCaption.text = figures.costCaption
            tokensValue.text = figures.tokens
            composition.segments = figures.segments
            compositionCaption.text = figures.composition
            sessions.value = figures.sessions
            turns.value = figures.turns
            calls.value = figures.calls
            loadingSpinner.stopAnimating()
        case .loading(let text):
            figuresStack.isHidden = true
            loadingRow.isHidden = false
            messageRow.isHidden = true
            loadingLabel.text = text
            loadingSpinner.startAnimating()
        case .message(let text, let warning):
            figuresStack.isHidden = true
            loadingRow.isHidden = true
            messageRow.isHidden = false
            messageLabel.text = text
            messageLabel.textColor = warning ? UIColor(DS.PlanUsage.noticeWarningText) : .inkSecondary
            loadingSpinner.stopAnimating()
        }

        for view in noticesStack.arrangedSubviews { view.removeFromSuperview() }
        for notice in model.notices {
            noticesStack.addArrangedSubview(UIView.hairline(color: UIColor(U.hairline)))
            let label = UILabel()
            label.numberOfLines = 0
            label.setText(notice.text, style: IOSDS.Typography.caption, color: notice.warning ? UIColor(DS.PlanUsage.noticeWarningText) : UIColor(U.secondaryText))
            let row = UIStackView(arrangedSubviews: [label])
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: U.noticeVerticalPadding, leading: U.cardHorizontalPadding, bottom: U.noticeVerticalPadding, trailing: U.cardHorizontalPadding)
            noticesStack.addArrangedSubview(row)
        }
        noticesStack.isHidden = model.notices.isEmpty
    }
}

/// `SESSIONS` over `34` — one of the three equal columns.
private final class UsageCountColumn: UIStackView {
    private let valueLabel = UILabel()

    var value: String {
        get { valueLabel.text ?? "" }
        set { valueLabel.text = newValue }
    }

    init(title: String) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .leading
        spacing = IOSDS.Usage.countsLabelGap
        let label = UILabel()
        label.setText(title, style: IOSDS.Typography.usageLabel, color: UIColor(IOSDS.Usage.secondaryText))
        valueLabel.font = .design(IOSDS.Typography.usageCount, tabular: true)
        valueLabel.textColor = .inkPrimary
        addArrangedSubview(label)
        addArrangedSubview(valueLabel)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
}

/// The 6pt four-segment token bar: Input → Cache read → Cache write →
/// Output in the data path's order, never sorted by size.
final class UsageCompositionBarView: UIView {
    private typealias U = IOSDS.Usage
    private var segmentLayers: [CALayer] = []

    var segments: [UsageSummaryFigures.Segment] = [] {
        didSet {
            guard segments != oldValue else { return }
            rebuild()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(U.barTrack)
        layer.cornerRadius = U.compositionBarRadius
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: U.compositionBarHeight).isActive = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: UsageCompositionBarView, _) in
            self.rebuild()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private func rebuild() {
        for layer in segmentLayers { layer.removeFromSuperlayer() }
        segmentLayers = segments.map { segment in
            let layer = CALayer()
            layer.backgroundColor = Self.color(for: segment.kind).resolvedColor(with: traitCollection).cgColor
            self.layer.addSublayer(layer)
            return layer
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for (layer, segment) in zip(segmentLayers, segments) {
            let width = bounds.width * CGFloat(segment.fraction)
            layer.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    static func color(for kind: UsageSummaryFigures.TokenKind) -> UIColor {
        switch kind {
        case .input: UIColor(DS.Chart.compositionInput)
        case .cacheRead: UIColor(DS.Chart.compositionCacheRead)
        case .cacheWrite: UIColor(DS.Chart.compositionCacheWrite)
        case .output: UIColor(DS.Chart.compositionOutput)
        }
    }
}
