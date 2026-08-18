import AgentStatusCore
import AppKit

/// Row view with a neutral rounded selection (`AgentStatusDesign.Color.selection`),
/// inset from the column edges. Text keeps its normal colours when selected.
@MainActor
final class RoundedSelectionRowView: NSTableRowView {
    var horizontalInset: CGFloat = AgentStatusDesign.Layout.listHorizontalInset
    /// Space kept below the pill (rows that carry their own inter-row gap).
    var bottomInset: CGFloat = 0

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        var rect = bounds.insetBy(dx: horizontalInset, dy: 0)
        rect.size.height -= bottomInset
        if !isFlipped { rect.origin.y += bottomInset }
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: AgentStatusDesign.Layout.selectionCornerRadius,
            yRadius: AgentStatusDesign.Layout.selectionCornerRadius
        )
        AgentStatusDesign.Color.selection.setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent rows; the enclosing column paints the surface.
    }
}

/// `● Running · Thinking` capsule. Colour changes animate over 0.2s (no pulsing).
@MainActor
final class StatusPillView: NSView {
    private let dot = NSView()
    private let halo = NSView()
    private let label = NSTextField(labelWithString: "")
    private var tone: SessionStatusTone = .gray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = AgentStatusDesign.Layout.pillHeight / 2
        layer?.borderWidth = 0.5

        halo.wantsLayer = true
        halo.layer?.cornerRadius = 6
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = AgentStatusDesign.Font.pill
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        [halo, dot, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AgentStatusDesign.Layout.pillHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            halo.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            halo.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            halo.widthAnchor.constraint(equalToConstant: 12),
            halo.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        // Below the window stay-put priority (500): a long status can truncate,
        // it may never widen a column.
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 480), for: .horizontal)
        applyColors(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(tone: SessionStatusTone, text: String) {
        label.stringValue = text
        guard tone != self.tone else { return }
        self.tone = tone
        applyColors(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors(animated: false)
    }

    private func applyColors(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.2 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.backgroundColor = tone.pillFill.cgColor
        layer?.borderColor = tone.pillStroke.cgColor
        dot.layer?.backgroundColor = tone.appKitColor.cgColor
        halo.layer?.backgroundColor = (tone.dotHalo ?? .clear).cgColor
        CATransaction.commit()
        label.textColor = tone.pillText
    }
}

/// Neutral text capsule (`Codex`, counts).
@MainActor
final class CapsuleChipView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        label.font = AgentStatusDesign.Font.pill
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = AgentStatusDesign.Color.chipFill.cgColor
        layer?.borderColor = AgentStatusDesign.Color.chipStroke.cgColor
    }
}

/// The strip directly under the toolbar title: pills on the left, an optional
/// truncating description on the right, hairline underneath. Hosted as a
/// top-aligned split-view-item accessory (see `DetailSubheaderAccessoryController`).
@MainActor
final class DetailSubheaderView: NSView {
    static let contentHeight: CGFloat = AgentStatusDesign.Layout.subheaderTopInset
        + AgentStatusDesign.Layout.pillHeight
        + AgentStatusDesign.Layout.subheaderBottomInset
        + 1

    private let stack = NSStackView()
    private let trailingLabel = NSTextField(labelWithString: "")
    private let hairline = NSBox()

    init(horizontalInset: CGFloat) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        trailingLabel.font = AgentStatusDesign.Font.caption
        trailingLabel.textColor = .tertiaryLabelColor
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.maximumNumberOfLines = 1
        trailingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hairline.boxType = .separator

        [stack, hairline].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.contentHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: AgentStatusDesign.Layout.subheaderTopInset),
            stack.heightAnchor.constraint(equalToConstant: AgentStatusDesign.Layout.pillHeight),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setLeadingViews(_ views: [NSView], trailingText: String?, trailingMonospaced: Bool = false) {
        var arranged = views
        trailingLabel.font = trailingMonospaced ? AgentStatusDesign.Font.mono : AgentStatusDesign.Font.caption
        if let trailingText {
            trailingLabel.stringValue = trailingText
            trailingLabel.toolTip = trailingText
            arranged.append(trailingLabel)
        }
        stack.setViews(arranged, in: .leading)
    }
}

/// Places a `DetailSubheaderView` directly under the toolbar of a split-view item.
/// Using the accessory API (rather than a plain subview) keeps the toolbar's soft
/// scroll-edge look instead of a hard line under the title.
@MainActor
final class DetailSubheaderAccessoryController: NSSplitViewItemAccessoryViewController {
    let subheader: DetailSubheaderView

    init(horizontalInset: CGFloat) {
        subheader = DetailSubheaderView(horizontalInset: horizontalInset)
        super.init(nibName: nil, bundle: nil)
        automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) {
            preferredScrollEdgeEffectStyle = .soft
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = subheader
    }
}

/// Rounded card: 14pt radius, hairline stroke, translucent fill, optional shadow.
@MainActor
final class CardView: NSView {
    init(cornerRadius: CGFloat = AgentStatusDesign.Layout.cardCornerRadius, shadow: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        if shadow {
            self.shadow = NSShadow()
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.08
            layer?.shadowRadius = 12
            layer?.shadowOffset = CGSize(width: 0, height: -8)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = AgentStatusDesign.Color.cardFill.cgColor
        layer?.borderColor = AgentStatusDesign.Color.cardStroke.cgColor
    }
}

/// 1px hairline used inside cards.
@MainActor
func makeHairline() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    return box
}

/// Top-anchored container for `NSScrollView.documentView` (AppKit views are
/// bottom-anchored by default, which would pin short content to the bottom).
@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Shows exactly one of several child view controllers, edge-to-edge.
/// (Unlike `NSTabViewController`, extra children — e.g. split-item accessories
/// AppKit attaches — do not disturb the selection.)
@MainActor
final class SwitchingContainerViewController: NSViewController {
    private let pages: [NSViewController]
    private(set) var selectedIndex = 0

    init(pages: [NSViewController]) {
        self.pages = pages
        super.init(nibName: nil, bundle: nil)
        pages.forEach { addChild($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        install(pages[selectedIndex])
    }

    func select(_ index: Int) {
        guard index != selectedIndex, pages.indices.contains(index) else { return }
        let outgoing = pages[selectedIndex]
        selectedIndex = index
        guard isViewLoaded else { return }
        outgoing.view.removeFromSuperview()
        install(pages[index])
    }

    private func install(_ controller: NSViewController) {
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
