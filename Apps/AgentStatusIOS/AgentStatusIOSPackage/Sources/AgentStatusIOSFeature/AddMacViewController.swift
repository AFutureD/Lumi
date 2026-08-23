import AgentStatusDesignSystem
import AgentStatusRemote
import AgentStatusTransport
import UIKit

/// Add Mac (design 1c): the iPhone's one pairing entry. Six code cells,
/// `Continue`, `Scan code`, and an `Advanced` fold with the Relay URL. All
/// three ways in (type, scan, type + custom Relay) make the same
/// `RelayPairingAttempt`; once the code is spent the flow screen takes over.
/// Presented as a large-detent sheet from the Macs list.
@MainActor
final class AddMacViewController: UIViewController {
    private typealias Metric = DesignSystem.Pairing.IOS

    private let relay: RelayDeviceController
    private let settings: LocalSettings
    private let prefill: PairingLink?
    private let onFinished: () -> Void

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let intro = UILabel()
    private let codeEntry = PairingCodeEntryView()
    private let errorRow = UIStackView()
    private let errorLabel = UILabel()
    private let continueButton = UIButton(type: .system)
    private let scanButton = UIButton(type: .system)
    private let advancedToggle = UIButton(type: .system)
    private let advancedChevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let advancedBox = UIStackView()
    private let relayField = UITextField()
    private let relayHelp = UILabel()
    private var advancedOpen = false
    private var attempt: RelayPairingAttempt?
    private var flow: PairingFlowViewController?

    init(relay: RelayDeviceController, settings: LocalSettings, prefill: PairingLink?, onFinished: @escaping () -> Void) {
        self.relay = relay
        self.settings = settings
        self.prefill = prefill
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
        title = "Add Mac"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        if let sheet = navigationController?.sheetPresentationController {
            sheet.prefersGrabberVisible = true
        }
        configureContent()
        if let prefill {
            apply(prefill)
        } else if let remembered = settings.lastRelayURL {
            relayField.text = remembered.absoluteString
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if prefill == nil, attempt == nil { codeEntry.focus() }
    }

    /// A link that arrived while this sheet was already up: whatever was in
    /// flight is dropped and the new code goes straight in.
    func apply(_ link: PairingLink) {
        if attempt != nil || flow != nil {
            attempt?.cancel()
            attempt = nil
            flow = nil
            navigationController?.popToViewController(self, animated: false)
            setBusy(false)
        }
        relayField.text = link.relayURL == relay.defaultRelayURL ? "" : link.relayURL.absoluteString
        codeEntry.setCode(link.code)
        showInlineError(nil)
        if codeEntry.isComplete { startAttempt() }
    }

    // MARK: - Layout

    private func configureContent() {
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = Metric.blockGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Metric.contentTop),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Metric.contentInset),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Metric.contentInset),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Metric.blockGap),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Metric.contentInset),
        ])

        intro.numberOfLines = 0
        intro.setText("在 Mac 上打开 Lumi › Pair an iPhone，输入那里显示的 6 位配对码。", style: Metric.intro, color: UIColor(Metric.introInk))

        codeEntry.onChange = { [weak self] _ in self?.codeChanged() }
        codeEntry.onComplete = { [weak self] in self?.continueTapped() }

        let errorIcon = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
        errorIcon.tintColor = UIColor(DesignSystem.Semantic.error)
        errorIcon.contentMode = .scaleAspectFit
        errorIcon.translatesAutoresizingMaskIntoConstraints = false
        errorIcon.widthAnchor.constraint(equalToConstant: Metric.errorIcon).isActive = true
        errorIcon.heightAnchor.constraint(equalToConstant: Metric.errorIcon).isActive = true
        errorLabel.numberOfLines = 0
        errorRow.axis = .horizontal
        errorRow.alignment = .top
        errorRow.spacing = 8
        errorRow.addArrangedSubview(errorIcon)
        errorRow.addArrangedSubview(errorLabel)
        errorRow.isHidden = true

        var primary = UIButton.Configuration.filled()
        primary.title = "Continue"
        primary.baseBackgroundColor = UIColor(DesignSystem.Semantic.accent)
        primary.baseForegroundColor = .white
        primary.cornerStyle = .fixed
        primary.background.cornerRadius = Metric.buttonRadius
        primary.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.design(IOSDS.Typography.sheetTitle)
            return attributes
        }
        continueButton.configuration = primary
        continueButton.configurationUpdateHandler = { button in
            var configuration = button.configuration
            configuration?.baseBackgroundColor = button.isEnabled ? UIColor(DesignSystem.Semantic.accent) : UIColor.tertiarySystemFill
            configuration?.baseForegroundColor = button.isEnabled ? .white : UIColor(DesignSystem.Ink.quaternary)
            configuration?.showsActivityIndicator = button.configuration?.showsActivityIndicator ?? false
            button.configuration = configuration
        }
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        continueButton.heightAnchor.constraint(equalToConstant: Metric.buttonHeight).isActive = true

        var secondary = UIButton.Configuration.filled()
        secondary.title = "Scan code"
        secondary.image = UIImage(systemName: "qrcode.viewfinder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        secondary.imagePadding = 8
        secondary.baseBackgroundColor = .tertiarySystemFill
        secondary.baseForegroundColor = UIColor(DesignSystem.Semantic.accent)
        secondary.cornerStyle = .fixed
        secondary.background.cornerRadius = Metric.buttonRadius
        secondary.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.design(IOSDS.Typography.listTitle)
            return attributes
        }
        scanButton.configuration = secondary
        scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        scanButton.heightAnchor.constraint(equalToConstant: Metric.buttonHeight).isActive = true

        let buttons = UIStackView(arrangedSubviews: [continueButton, scanButton])
        buttons.axis = .vertical
        buttons.spacing = Metric.buttonGap

        var toggle = UIButton.Configuration.plain()
        toggle.title = "Advanced"
        toggle.baseForegroundColor = UIColor(Metric.advancedInk)
        toggle.contentInsets = .zero
        toggle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.design(IOSDS.Typography.body)
            return attributes
        }
        advancedToggle.configuration = toggle
        advancedToggle.contentHorizontalAlignment = .leading
        advancedToggle.addTarget(self, action: #selector(toggleAdvanced), for: .touchUpInside)
        advancedChevron.tintColor = UIColor(Metric.advancedInk)
        advancedChevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        advancedChevron.contentMode = .scaleAspectFit
        advancedChevron.translatesAutoresizingMaskIntoConstraints = false
        advancedChevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let toggleRow = UIStackView(arrangedSubviews: [advancedChevron, advancedToggle])
        toggleRow.axis = .horizontal
        toggleRow.alignment = .center
        toggleRow.spacing = 6
        toggleRow.isLayoutMarginsRelativeArrangement = true
        toggleRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 0)

        let fieldLabel = UILabel()
        fieldLabel.setText("Relay URL", style: Metric.fieldLabel, color: UIColor(Metric.fieldLabelInk))
        relayField.font = .design(Metric.fieldValue)
        relayField.textColor = .label
        relayField.attributedPlaceholder = NSAttributedString(
            string: "https://relay.example.com",
            attributes: [.foregroundColor: UIColor(Metric.placeholderInk), .font: UIFont.design(Metric.fieldValue)]
        )
        relayField.keyboardType = .URL
        relayField.autocapitalizationType = .none
        relayField.autocorrectionType = .no
        relayField.clearButtonMode = .whileEditing
        relayField.returnKeyType = .done
        relayField.addTarget(self, action: #selector(relayFieldDone), for: .editingDidEndOnExit)
        relayField.addTarget(self, action: #selector(relayFieldChanged), for: .editingChanged)
        let fieldStack = UIStackView(arrangedSubviews: [fieldLabel, relayField])
        fieldStack.axis = .vertical
        fieldStack.spacing = 2
        fieldStack.isLayoutMarginsRelativeArrangement = true
        fieldStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
        let cell = UIView()
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.layer.cornerRadius = IOSDS.Layout.cardRadius
        cell.layer.cornerCurve = .continuous
        fieldStack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(fieldStack)
        NSLayoutConstraint.activate([
            fieldStack.topAnchor.constraint(equalTo: cell.topAnchor),
            fieldStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            fieldStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            fieldStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            cell.heightAnchor.constraint(greaterThanOrEqualToConstant: Metric.fieldCellMinimumHeight),
        ])
        relayHelp.numberOfLines = 0
        relayHelp.setText(
            "留空即用内置 Relay（\(RelayURLValidation.displayHost(relay.defaultRelayURL))）。自托管填自己的 Worker 地址，例如 https://afuture.workers.dev；只收 https，填过一次就记住，下次预填。",
            style: IOSDS.Typography.caption, color: .inkTertiary
        )
        advancedBox.axis = .vertical
        advancedBox.spacing = 8
        advancedBox.addArrangedSubview(cell)
        advancedBox.addArrangedSubview(relayHelp)
        advancedBox.isHidden = true

        let advanced = UIStackView(arrangedSubviews: [toggleRow, advancedBox])
        advanced.axis = .vertical
        advanced.spacing = 8

        [intro, codeEntry, errorRow, buttons, advanced].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(10, after: codeEntry)
        stack.setCustomSpacing(Metric.blockGap - 10, after: errorRow)
        updateContinue()
    }

    // MARK: - Actions

    @objc private func cancel() {
        attempt?.cancel()
        codeEntry.blur()
        dismiss(animated: true)
    }

    @objc private func toggleAdvanced() {
        advancedOpen.toggle()
        UIView.animate(withDuration: 0.2) {
            self.advancedBox.isHidden = !self.advancedOpen
            self.advancedChevron.transform = self.advancedOpen ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
            self.stack.layoutIfNeeded()
        }
        if advancedOpen { relayField.becomeFirstResponder() }
    }

    @objc private func relayFieldDone() {
        relayField.resignFirstResponder()
        if codeEntry.isComplete { continueTapped() } else { codeEntry.focus() }
    }

    @objc private func relayFieldChanged() {
        if errorRow.isHidden == false, codeEntry.isShowingError == false { showInlineError(nil) }
    }

    @objc private func scanTapped() {
        codeEntry.blur()
        let scanner = PairingScannerViewController()
        scanner.onLink = { [weak self, weak scanner] link in
            scanner?.dismiss(animated: true) {
                self?.apply(link)
            }
        }
        let navigation = UINavigationController(rootViewController: scanner)
        navigation.modalPresentationStyle = .fullScreen
        navigation.overrideUserInterfaceStyle = .dark
        present(navigation, animated: true)
    }

    @objc private func continueTapped() {
        guard codeEntry.isComplete, attempt == nil else { return }
        startAttempt()
    }

    private var relayURLInput: URL? {
        let text = relayField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return relay.defaultRelayURL }
        return RelayURLValidation.normalize(text, allowInsecureLocalhost: Self.allowsInsecureLocalhost)
    }

    static var allowsInsecureLocalhost: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private func startAttempt() {
        guard let relayURL = relayURLInput else {
            showInlineError("Relay URL 必须是 https:// 开头的完整地址（只要主机名，不带路径或参数）。", onCode: false)
            if !advancedOpen { toggleAdvanced() }
            return
        }
        guard let code = PairingCode.normalize(codeEntry.code) else { return }
        codeEntry.blur()
        relayField.resignFirstResponder()
        showInlineError(nil)
        let text = relayField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        settings.lastRelayURL = text.isEmpty ? nil : relayURL
        let attempt = relay.makePairingAttempt(relayURL: relayURL, code: code)
        self.attempt = attempt
        attempt.onChange = { [weak self] in self?.attemptChanged() }
        setBusy(true)
        attempt.start()
    }

    private func attemptChanged() {
        guard let attempt else { return }
        if let failure = attempt.failure, flow == nil {
            // The code was refused before anything else happened: stay here.
            if failure == .badCode {
                self.attempt = nil
                setBusy(false)
                codeEntry.showError(true)
                showInlineError("配对码不对或已过期。Mac 上的码每 5 分钟换一次，重新看一眼再输。", onCode: true)
                continueButton.configuration?.title = "Try again"
                codeEntry.focus()
                return
            }
        }
        // Claiming happens on this screen (busy button); the flow screen takes
        // over once the code is spent — or on any failure past the code.
        let pastTheCode: Bool = switch attempt.progress {
        case nil, .claiming: attempt.failure != nil
        case .waitingForMac, .comparing, .paired: true
        }
        if flow == nil, pastTheCode {
            setBusy(false)
            let flow = PairingFlowViewController(attempt: attempt, onStartOver: { [weak self] in
                self?.startOver()
            }, onFinished: { [weak self] in
                self?.finished()
            })
            self.flow = flow
            navigationController?.pushViewController(flow, animated: true)
        }
    }

    /// Back from the flow screen to a fresh code (Start over / Try again on a
    /// failure that needs a new code).
    private func startOver() {
        attempt = nil
        flow = nil
        codeEntry.clear()
        navigationController?.popToViewController(self, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.codeEntry.focus() }
    }

    private func finished() {
        attempt = nil
        flow = nil
        onFinished()
    }

    private func setBusy(_ busy: Bool) {
        continueButton.configuration?.showsActivityIndicator = busy
        continueButton.configuration?.title = busy ? nil : "Continue"
        updateContinue()
        scanButton.isEnabled = !busy
    }

    /// Entry-screen primary button stays `Continue` while typing; only a
    /// refused code relabels it `Try again` until the code changes.
    private func codeChanged() {
        if continueButton.configuration?.title == "Try again" { continueButton.configuration?.title = "Continue" }
        updateContinue()
    }

    private func updateContinue() {
        continueButton.isEnabled = codeEntry.isComplete && attempt == nil
    }

    private func showInlineError(_ message: String?, onCode: Bool = true) {
        guard let message else {
            errorRow.isHidden = true
            codeEntry.showError(false)
            return
        }
        errorLabel.setText(message, style: IOSDS.Typography.caption, color: UIColor(DesignSystem.Ink.destructive))
        errorRow.isHidden = false
        if onCode { codeEntry.showError(true) }
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = view.window else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: window).minY)
        scroll.contentInset.bottom = overlap
        scroll.verticalScrollIndicatorInsets.bottom = overlap
    }
}
