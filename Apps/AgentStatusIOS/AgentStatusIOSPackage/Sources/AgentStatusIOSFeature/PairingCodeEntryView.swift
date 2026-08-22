import AgentStatusDesignSystem
import AgentStatusRemote
import UIKit

/// Six code cells (design 1c): `XXX-XXX`, one character each, a dash between
/// the halves. A hidden text field takes the typing (alphanumeric keyboard,
/// auto-capitalised); whatever comes in — typed or pasted — goes through
/// `PairingCode.sanitize`, so `o`, `i`, `l`, `u`, spaces and hyphens land as
/// the code means them.
@MainActor
final class PairingCodeEntryView: UIControl, UITextFieldDelegate {
    private typealias Metric = DesignSystem.Pairing.IOS

    private let field = UITextField()
    private var cells: [CodeCellView] = []
    private(set) var isShowingError = false

    /// Sanitised, at most six characters.
    private(set) var code = "" {
        didSet { render() }
    }

    var onChange: ((String) -> Void)?
    /// Six characters entered (Return on the keyboard does the same).
    var onComplete: (() -> Void)?

    var isComplete: Bool { code.count == PairingCode.length }

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.delegate = self
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.returnKeyType = .continue
        field.textContentType = .oneTimeCode
        field.isAccessibilityElement = false
        field.alpha = 0.02
        field.tintColor = .clear
        field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(focusChanged), for: .editingDidBegin)
        field.addTarget(self, action: #selector(focusChanged), for: .editingDidEnd)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        let row = UIStackView()
        row.isUserInteractionEnabled = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Metric.cellGap
        row.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<PairingCode.length {
            if index == PairingCode.length / 2 {
                let dash = UIView()
                dash.isUserInteractionEnabled = false
                dash.backgroundColor = UIColor(Metric.dash)
                dash.layer.cornerRadius = Metric.dashHeight / 2
                dash.translatesAutoresizingMaskIntoConstraints = false
                dash.widthAnchor.constraint(equalToConstant: Metric.dashWidth).isActive = true
                dash.heightAnchor.constraint(equalToConstant: Metric.dashHeight).isActive = true
                row.addArrangedSubview(dash)
            }
            let cell = CodeCellView()
            cells.append(cell)
            row.addArrangedSubview(cell)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.widthAnchor.constraint(equalToConstant: 1),
            field.heightAnchor.constraint(equalToConstant: 1),
        ] + cells.dropFirst().map { $0.widthAnchor.constraint(equalTo: cells[0].widthAnchor) })
        addTarget(self, action: #selector(focus), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = "Pairing code"
        accessibilityTraits = .none
        render()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    // MARK: - API

    @objc func focus() {
        field.becomeFirstResponder()
    }

    func blur() {
        field.resignFirstResponder()
    }

    /// A scanned link or a paste: the whole code at once.
    func setCode(_ value: String) {
        code = PairingCode.sanitize(value)
        field.text = code
        isShowingError = false
        onChange?(code)
        if isComplete { onComplete?() }
    }

    /// Failure ①: red rings, caret back on the first cell, content kept.
    func showError(_ showing: Bool) {
        isShowingError = showing
        render()
    }

    func clear() {
        setCode("")
    }

    // MARK: - Field

    @objc private func fieldChanged() {
        let sanitised = PairingCode.sanitize(field.text ?? "")
        if field.text != sanitised { field.text = sanitised }
        let wasComplete = isComplete
        isShowingError = false
        code = sanitised
        onChange?(code)
        if isComplete, !wasComplete { onComplete?() }
    }

    @objc private func focusChanged() {
        render()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if isComplete { onComplete?() }
        return false
    }

    private func render() {
        let characters = Array(code)
        let focused = field.isFirstResponder
        for (index, cell) in cells.enumerated() {
            let glyph = index < characters.count ? String(characters[index]) : ""
            let isActive = focused && !isShowingError && (index == characters.count || (index == cells.count - 1 && characters.count == cells.count))
            let caretAtStart = focused && isShowingError && index == 0
            cell.configure(glyph: glyph, active: isActive || caretAtStart, error: isShowingError)
        }
        accessibilityValue = code.isEmpty ? "empty" : PairingCode.display(code)
    }
}

/// One cell: white, radius 10, hairline ring (accent 2pt while active,
/// red 1.5pt on error); SF Mono 26 / Semibold glyph; a blinking caret when
/// active and empty.
@MainActor
private final class CodeCellView: UIView {
    private typealias Metric = DesignSystem.Pairing.IOS
    private let label = UILabel()
    private let caret = UIView()
    private var caretAnimating = false

    init() {
        super.init(frame: .zero)
        // Taps anywhere on the row focus the hidden field (the control itself).
        isUserInteractionEnabled = false
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = Metric.cellRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = DesignSystem.Stroke.hairline
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .design(Metric.cellGlyph)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        caret.backgroundColor = UIColor(DesignSystem.Semantic.accent)
        caret.layer.cornerRadius = 1
        caret.isHidden = true
        caret.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(caret)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metric.cellHeight),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            caret.centerXAnchor.constraint(equalTo: centerXAnchor),
            caret.centerYAnchor.constraint(equalTo: centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 2),
            caret.heightAnchor.constraint(equalToConstant: Metric.cellGlyph.lineHeight - 4),
        ])
        applyRing(active: false, error: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(glyph: String, active: Bool, error: Bool) {
        label.text = glyph
        label.textColor = error ? UIColor(DesignSystem.Ink.destructive) : .label
        applyRing(active: active, error: error)
        let showCaret = active && glyph.isEmpty
        caret.isHidden = !showCaret
        if showCaret, !caretAnimating {
            caretAnimating = true
            UIView.animate(withDuration: 0.55, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]) {
                self.caret.alpha = 0.15
            }
        } else if !showCaret, caretAnimating {
            caretAnimating = false
            caret.layer.removeAllAnimations()
            caret.alpha = 1
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Ring colours are CGColor: refresh on appearance changes.
        setNeedsLayout()
    }

    private func applyRing(active: Bool, error: Bool) {
        if error {
            layer.borderWidth = Metric.cellRingErrorWidth
            layer.borderColor = UIColor(Metric.cellRingError).cgColor
        } else if active {
            layer.borderWidth = Metric.cellRingActiveWidth
            layer.borderColor = UIColor(DesignSystem.Semantic.accent).cgColor
        } else {
            layer.borderWidth = DesignSystem.Stroke.hairline
            layer.borderColor = UIColor(Metric.cellRing).cgColor
        }
    }
}
