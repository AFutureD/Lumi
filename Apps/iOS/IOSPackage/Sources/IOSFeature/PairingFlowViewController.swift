import DesignSystem
import Remote
import Transport
import UIKit

/// The second screen of Add Mac (design: SAS 比对 / 配对成功 / 失败四态 ②③④):
/// everything sits in one vertically centred stack — Mac name, Relay host,
/// then the SAS (or the result mark + title + body), then the buttons. The
/// navigation bar carries only the Mac name; the iPhone has no confirm
/// button — the nod happens on the Mac. Failure ① never reaches this screen
/// (it stays inline on the entry screen).
@MainActor
final class PairingFlowViewController: UIViewController {
    private typealias Metric = DesignSystem.Pairing.IOS

    private let attempt: RelayPairingAttempt
    private let onStartOver: () -> Void
    private let onFinished: () -> Void

    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let nameLabel = UILabel()
    private let hostLabel = UILabel()
    private let mark = ResultMarkView()
    private let sasRow = UIStackView()
    private let sasFirst = UILabel()
    private let sasSecond = UILabel()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var dismissTask: Task<Void, Never>?

    init(attempt: RelayPairingAttempt, onStartOver: @escaping () -> Void, onFinished: @escaping () -> Void) {
        self.attempt = attempt
        self.onStartOver = onStartOver
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.hidesBackButton = true

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Metric.sasGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        hostLabel.textAlignment = .center
        let heading = UIStackView(arrangedSubviews: [nameLabel, hostLabel])
        heading.axis = .vertical
        heading.alignment = .center
        heading.spacing = 4

        spinner.hidesWhenStopped = true

        for half in [sasFirst, sasSecond] {
            half.font = .design(Metric.sas)
            half.textColor = .label
            half.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        sasRow.axis = .horizontal
        sasRow.spacing = Metric.sasGroupGap
        sasRow.alignment = .firstBaseline
        sasRow.addArrangedSubview(sasFirst)
        sasRow.addArrangedSubview(sasSecond)

        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        // Mark → title → body sit closer together than the big blocks.
        let verdict = UIStackView(arrangedSubviews: [mark, titleLabel, bodyLabel])
        verdict.axis = .vertical
        verdict.alignment = .center
        verdict.spacing = 12
        verdict.setCustomSpacing(8, after: titleLabel)

        for (button, prominent) in [(primaryButton, true), (secondaryButton, false)] {
            var configuration = UIButton.Configuration.filled()
            configuration.cornerStyle = .fixed
            configuration.background.cornerRadius = Metric.buttonRadius
            configuration.baseBackgroundColor = prominent ? UIColor(DesignSystem.Semantic.accent) : .tertiarySystemFill
            configuration.baseForegroundColor = prominent ? .white : UIColor(DesignSystem.Semantic.accent)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.design(prominent ? IOSDS.Typography.sheetTitle : IOSDS.Typography.listTitle)
                return attributes
            }
            button.configuration = configuration
            button.heightAnchor.constraint(equalToConstant: Metric.buttonHeight).isActive = true
        }
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [primaryButton, secondaryButton])
        buttons.axis = .vertical
        buttons.spacing = Metric.buttonGap

        // Success puts the mark above the name; every other state puts the
        // name first. Both orders live in the stack; `render` hides the rest.
        [heading, spinner, sasRow, verdict, buttons].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -Metric.sasBottom / 2),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metric.contentInset),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metric.contentInset),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: Metric.contentTop),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Metric.failureMaxWidth),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Metric.failureMaxWidth + 40),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        attempt.onChange = { [weak self] in self?.render() }
        render()
    }

    // MARK: - Rendering

    private enum Verdict {
        case success
        case mismatch
        case neutral(String)
    }

    private func render() {
        if let failure = attempt.failure {
            renderFailure(failure)
            return
        }
        switch attempt.progress {
        case nil, .claiming:
            show(name: attempt.relayHost, host: nil, spinner: true, sas: nil, verdict: nil, title: nil, body: nil,
                 primary: nil, secondary: ("Cancel", { [weak self] in self?.cancel() }))
        case let .waitingForMac(hostName, relayHost):
            navigationItem.title = hostName ?? "Mac"
            show(name: hostName ?? "Mac", host: relayHost, spinner: true, sas: nil, verdict: nil, title: nil,
                 body: "等 Mac 亮出数字…",
                 primary: nil, secondary: ("Cancel", { [weak self] in self?.cancel() }))
        case let .comparing(sas, hostName, relayHost):
            navigationItem.title = hostName ?? "Mac"
            show(name: hostName ?? "Mac", host: relayHost, spinner: false, sas: sas, verdict: nil, title: nil,
                 body: "在 Mac 上核对这组数字，一样就点 Match。",
                 primary: nil, secondary: ("Cancel", { [weak self] in self?.cancel() }))
        case let .paired(_, hostName, relayHost):
            navigationItem.title = hostName ?? "Mac"
            show(name: hostName ?? "Mac", host: relayHost, spinner: false, sas: nil, verdict: .success, title: nil,
                 body: "Paired · syncing…", primary: nil, secondary: nil)
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Metric.successDwell))
                guard !Task.isCancelled else { return }
                self?.onFinished()
            }
        }
    }

    private func renderFailure(_ failure: PairingFailure) {
        let (name, host) = heading()
        switch failure {
        case .badCode:
            // Inline on the entry screen; if we are here, go back there.
            onStartOver()
        case .hostOffline:
            show(name: name, host: host, spinner: false, sas: nil, verdict: .neutral("exclamationmark"),
                 title: "Mac 不在线",
                 body: "配对码有效，但这台 Mac 现在没连上 Relay。确认 Lumi 正在运行后再试。",
                 primary: ("Try again", { [weak self] in self?.attempt.start() }),
                 secondary: ("Cancel", { [weak self] in self?.cancel() }))
        case .rejected:
            show(name: name, host: host, spinner: false, sas: nil, verdict: .neutral("xmark"),
                 title: "Mac 拒绝了这次配对",
                 body: "没有保存任何凭据。如果数字本来是一样的，回到 Mac 重新出一个码再来一次。",
                 primary: ("Start over", { [weak self] in self?.onStartOver() }), secondary: nil)
        case .commitMismatch:
            show(name: name, host: host, spinner: false, sas: nil, verdict: .mismatch,
                 title: "校验失败",
                 body: "Relay 返回的数据不一致，请换个网络重试。已中止配对，未保存任何凭据。",
                 primary: ("Try again", { [weak self] in self?.onStartOver() }),
                 secondary: ("Cancel", { [weak self] in self?.cancel() }))
        }
    }

    /// The Mac this attempt is about, from the last progress we saw.
    private func heading() -> (String, String?) {
        switch attempt.progress {
        case let .waitingForMac(hostName, relayHost), let .comparing(_, hostName, relayHost), let .paired(_, hostName, relayHost):
            return (hostName ?? "Mac", relayHost)
        case nil, .claiming:
            return ("Mac", attempt.relayHost)
        }
    }

    private func show(
        name: String,
        host: String?,
        spinner showSpinner: Bool,
        sas: String?,
        verdict: Verdict?,
        title: String?,
        body: String?,
        primary: (String, () -> Void)?,
        secondary: (String, () -> Void)?
    ) {
        // Success: mark on top, name below it, status line, host.
        let success: Bool = if case .success = verdict { true } else { false }
        if success {
            stack.insertArrangedSubview(mark, at: 0)
            nameLabel.setText(name, style: Metric.macName, color: .label)
            hostLabel.isHidden = false
            hostLabel.setText(host ?? "", style: Metric.relayHost, color: .inkTertiary)
            // The status line sits between the name and the host.
            titleLabel.isHidden = true
            bodyLabel.setText(body ?? "", style: Metric.sasHint, color: UIColor(Metric.sasHintInk))
            bodyLabel.isHidden = false
            stack.insertArrangedSubview(bodyLabel, at: 2)
            stack.setCustomSpacing(4, after: nameLabel.superview ?? nameLabel)
        } else {
            // Restore the regular order the stack was built in.
            if stack.arrangedSubviews.first === mark {
                stack.removeArrangedSubview(mark)
                mark.removeFromSuperview()
            }
            if let verdictStack = titleLabel.superview as? UIStackView, bodyLabel.superview !== verdictStack {
                stack.removeArrangedSubview(bodyLabel)
                bodyLabel.removeFromSuperview()
                verdictStack.addArrangedSubview(bodyLabel)
            }
            if let verdictStack = titleLabel.superview as? UIStackView, mark.superview !== verdictStack {
                verdictStack.insertArrangedSubview(mark, at: 0)
            }
            nameLabel.setText(name, style: Metric.macName, color: .label)
            hostLabel.isHidden = host == nil
            if let host { hostLabel.setText(host, style: Metric.relayHost, color: .inkTertiary) }
            titleLabel.isHidden = title == nil
            if let title { titleLabel.setText(title, style: Metric.failureTitle, color: .label) }
            bodyLabel.isHidden = body == nil
            if let body {
                let isFailure = verdict != nil
                bodyLabel.setText(body, style: isFailure ? Metric.failureBody : Metric.sasHint, color: UIColor(isFailure ? Metric.failureBodyInk : Metric.sasHintInk))
            }
        }
        bodyLabel.textAlignment = .center
        showSpinner ? spinner.startAnimating() : spinner.stopAnimating()
        mark.isHidden = verdict == nil
        switch verdict {
        case .success:
            mark.configure(color: UIColor(DesignSystem.Semantic.connected), symbol: "checkmark", size: Metric.successMark)
        case .mismatch:
            mark.configure(color: UIColor(DesignSystem.Semantic.error), symbol: "exclamationmark", size: Metric.failureMark)
        case let .neutral(symbol):
            mark.configure(color: UIColor(DesignSystem.Ink.quaternary), symbol: symbol, size: Metric.failureMark)
        case nil:
            break
        }
        if let verdictStack = titleLabel.superview as? UIStackView {
            verdictStack.isHidden = verdict == nil || success
        }
        sasRow.isHidden = sas == nil
        if let sas {
            let halves = PairingCode.displaySAS(sas).split(separator: " ")
            sasFirst.text = halves.first.map(String.init) ?? sas
            sasSecond.text = halves.count > 1 ? String(halves[1]) : ""
        }
        primaryButton.isHidden = primary == nil
        primaryButton.configuration?.title = primary?.0
        primaryAction = primary?.1
        secondaryButton.isHidden = secondary == nil
        secondaryButton.configuration?.title = secondary?.0
        secondaryAction = secondary?.1
        if let buttons = primaryButton.superview { buttons.isHidden = primary == nil && secondary == nil }
    }

    @objc private func primaryTapped() { primaryAction?() }
    @objc private func secondaryTapped() { secondaryAction?() }

    private func cancel() {
        dismissTask?.cancel()
        attempt.cancel()
        dismiss(animated: true)
    }
}

/// Coloured circle with an SF Symbol: 56 green ✓ on success, 52 grey ✕ / !
/// on a declined or offline Mac, 52 red ! only for a commitment mismatch.
@MainActor
private final class ResultMarkView: UIView {
    private let glyph = UIImageView()
    private var sizeConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func configure(color: UIColor, symbol: String, size: Double) {
        backgroundColor = color
        layer.cornerRadius = size / 2
        glyph.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.42, weight: .bold))
        NSLayoutConstraint.deactivate(sizeConstraints)
        sizeConstraints = [widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)]
        sizeConstraints.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(sizeConstraints)
    }
}
