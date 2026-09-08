import Core
import DesignSystem
import Transport
import UIKit

/// What one account section of a Plan card shows (handoff page 8b): the
/// header stamp, whether the mark and name are dimmed, one row per window
/// the provider reported (5 hours → 7 days → model windows), and at most
/// one note. Pure — built from Transport values and the Mac's own
/// `percentStyle`, so two Macs with different settings read differently.
struct PlanAccountModel: Equatable {
    struct Window: Equatable {
        /// `SESSION · 5 HOURS`, `WEEKLY · 7 DAYS`, `FABLE · 7 DAYS`.
        let title: String
        /// `42%` — used, or remaining under `percentStyle == .remaining`.
        let percent: String
        /// Always the used share: the bar never follows the percent style.
        let usedFraction: Double
        /// At or above `DesignSystem.PlanUsage.warningPercent`: the number turns orange.
        let warning: Bool
        /// `resets in 2h 10m`.
        let resets: String?
        /// `42% used`, right-aligned under the bar, only under `.remaining`.
        let usedNote: String?
    }

    struct Note: Equatable {
        let text: String
        /// Warning wording (`#8A5A28`) vs an informational grey line.
        let warning: Bool
    }

    let provider: AgentProvider
    let name: String
    /// `updated 2m ago`, or `off`; `nil` when the account has no usable answer.
    let stamp: String?
    let dimmed: Bool
    let windows: [Window]
    let note: Note?

    static func build(
        account: PlanUsageAccount,
        percentStyle: PlanUsagePercentStyle,
        macName: String,
        macOnline: Bool,
        snapshotAt: Date?,
        now: Date
    ) -> PlanAccountModel {
        let name = PlanUsagePresentation.agentName(account.provider)
        guard account.enabled else {
            return PlanAccountModel(provider: account.provider, name: name, stamp: "off", dimmed: false, windows: [], note: Note(text: "Switched off on this Mac", warning: false))
        }
        switch account.status {
        case .ok, .rateLimited:
            let windows = Self.windows(account.limits, percentStyle: percentStyle, now: now)
            let note: Note?
            if account.status == .rateLimited, let text = PlanUsagePresentation.statusText(account, now: now) {
                note = Note(text: text, warning: true)
            } else if !macOnline {
                let age = snapshotAt.map { SessionRelativeTimeFormatter.string(from: $0, now: now) }
                note = Note(text: age.map { "\(macName) offline · numbers from \($0) ago" } ?? "\(macName) offline", warning: true)
            } else {
                note = nil
            }
            return PlanAccountModel(
                provider: account.provider, name: name,
                stamp: PlanUsagePresentation.updatedText(account.fetchedAt, now: now),
                dimmed: false, windows: windows, note: note
            )
        case .credentialsMissing, .signInExpired, .signInRejected, .failed:
            return PlanAccountModel(
                provider: account.provider, name: name, stamp: nil, dimmed: true, windows: [],
                note: PlanUsagePresentation.statusText(account, now: now).map { Note(text: $0, warning: true) }
            )
        }
    }

    /// Fixed order: the 5-hour window, the weekly window, then model windows.
    /// Windows the provider did not report take no room.
    static func windows(_ limits: [PlanUsageLimit], percentStyle: PlanUsagePercentStyle, now: Date) -> [Window] {
        func rank(_ limit: PlanUsageLimit) -> Int {
            if limit.model != nil { return 2 }
            return limit.window == .session ? 0 : 1
        }
        return limits.sorted { rank($0) < rank($1) }.map { limit in
            let percent = PlanUsagePresentation.percent(limit, style: percentStyle)
            return Window(
                title: PlanUsagePresentation.windowTitle(limit),
                percent: "\(percent.value)%",
                usedFraction: min(1, max(0, limit.usedPercent / 100)),
                warning: limit.usedPercent >= DesignSystem.PlanUsage.warningPercent,
                resets: PlanUsagePresentation.resetText(limit, now: now),
                usedNote: percentStyle == .remaining ? "\(Int(limit.usedPercent.rounded()))% used" : nil
            )
        }
    }
}

/// One account section of a Plan card: header (mark · name · stamp), the
/// window rows, the note. Self-sizing inside an inset-grouped list.
final class PlanAccountCell: UICollectionViewListCell {
    private typealias P = IOSDS.PlanUsage

    private let mark = UIImageView()
    private let nameLabel = UILabel()
    private let stampLabel = UILabel()
    private let rows = UIStackView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = .secondarySystemGroupedBackground
        backgroundConfiguration = background

        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: P.mark),
            mark.heightAnchor.constraint(equalToConstant: P.mark),
        ])
        nameLabel.font = .design(IOSDS.Typography.sheetTitle)
        nameLabel.textColor = .inkPrimary
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stampLabel.font = .design(IOSDS.Typography.caption, tabular: true)
        stampLabel.textColor = UIColor(IOSDS.Usage.tertiaryText)
        stampLabel.textAlignment = .right
        stampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [mark, nameLabel, stampLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = P.headerGap
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: P.headerTop, leading: P.horizontalPadding, bottom: P.headerBottom, trailing: P.horizontalPadding)

        rows.axis = .vertical
        rows.spacing = 0

        stack.axis = .vertical
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(rows)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(_ model: PlanAccountModel) {
        mark.image = AgentMarks.image(for: model.provider, pointSize: P.mark)
        nameLabel.text = model.name
        stampLabel.text = model.stamp
        stampLabel.isHidden = model.stamp == nil
        let alpha = model.dimmed ? P.unavailableOpacity : 1
        mark.alpha = alpha
        nameLabel.alpha = alpha
        for view in rows.arrangedSubviews { view.removeFromSuperview() }
        for window in model.windows {
            rows.addArrangedSubview(PlanWindowRowView(window: window))
        }
        if let note = model.note {
            rows.addArrangedSubview(PlanNoteRowView(text: note.text, warning: note.warning))
        }
        if model.windows.isEmpty, model.note == nil {
            // Nothing to draw under the header; keep the bottom padding.
            rows.addArrangedSubview(PlanNoteRowView(text: "", warning: false))
        }
    }
}

/// `SESSION · 5 HOURS ······ 42%` / bar / `resets in 2h 10m  [42% used]`.
private final class PlanWindowRowView: UIView {
    private typealias P = IOSDS.PlanUsage

    init(window: PlanAccountModel.Window) {
        super.init(frame: .zero)
        let title = UILabel()
        title.setText(window.title, style: IOSDS.Typography.usageLabel, color: UIColor(IOSDS.Usage.secondaryText))
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let percent = UILabel()
        percent.font = .design(IOSDS.Typography.planUsagePercent, tabular: true)
        percent.textColor = window.warning ? UIColor(DS.PlanUsage.valueWarning) : .inkPrimary
        percent.text = window.percent
        percent.textAlignment = .right
        let top = UIStackView(arrangedSubviews: [title, percent])
        top.axis = .horizontal
        top.alignment = .lastBaseline
        top.spacing = P.headerGap

        let bar = PlanBarView(fraction: window.usedFraction)

        let resets = UILabel()
        resets.font = .design(IOSDS.Typography.caption, tabular: true)
        resets.textColor = UIColor(IOSDS.Usage.secondaryText)
        resets.text = window.resets
        let bottom = UIStackView(arrangedSubviews: [resets])
        bottom.axis = .horizontal
        bottom.alignment = .firstBaseline
        if let usedNote = window.usedNote {
            let used = UILabel()
            used.font = .design(IOSDS.Typography.caption, tabular: true)
            used.textColor = UIColor(IOSDS.Usage.tertiaryText)
            used.textAlignment = .right
            used.text = usedNote
            bottom.addArrangedSubview(used)
        }

        let stack = UIStackView(arrangedSubviews: [top, bar, bottom])
        stack.axis = .vertical
        stack.spacing = P.rowGap
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: P.rowTop, leading: P.horizontalPadding, bottom: P.rowBottom, trailing: P.horizontalPadding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if window.resets == nil, window.usedNote == nil { bottom.isHidden = true }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

/// The 6pt window bar: grey track, tint fill for the used share — one
/// colour in every band (the number carries the warning).
final class PlanBarView: UIView {
    private typealias P = IOSDS.PlanUsage
    private let fill = UIView()
    private let fraction: Double

    init(fraction: Double) {
        self.fraction = fraction
        super.init(frame: .zero)
        backgroundColor = UIColor(P.barTrack)
        layer.cornerRadius = P.barRadius
        clipsToBounds = true
        fill.backgroundColor = UIColor(P.barFill)
        fill.layer.cornerRadius = P.barRadius
        addSubview(fill)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: P.barHeight).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }
}

/// One line under the windows: `Switched off on this Mac` (grey) or a
/// warning (`Rate limited · retry in 4m 0s`, `Mac mini offline · …`).
final class PlanNoteRowView: UIView {
    private typealias P = IOSDS.PlanUsage

    init(text: String, warning: Bool) {
        super.init(frame: .zero)
        let label = UILabel()
        label.numberOfLines = 0
        label.setText(text, style: IOSDS.Typography.caption, color: warning ? UIColor(DS.PlanUsage.noticeWarningText) : UIColor(IOSDS.Usage.secondaryText))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: P.noteTop),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P.horizontalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -P.noteBottom),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}
