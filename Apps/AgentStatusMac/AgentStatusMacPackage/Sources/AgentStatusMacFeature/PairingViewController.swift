import AgentStatusDesignSystem
import AgentStatusRemote
import AgentStatusTransport
import AppKit
import CoreImage

/// Pair an iPhone (design 1b): the Mac is the side that shows the code and
/// the side that decides. Left column: the code card (QR + six characters +
/// Relay host + countdown) and, once an iPhone submits itself, the pending
/// card (its name, the six-digit SAS, Don't match / Match). Right column:
/// the paired iPhones. The page draws its own header — title, Relay pill at
/// the right, subtitle, rule — the toolbar carries only the sidebar chrome.
///
/// The daemon owns the pairing state machine; this screen drives rotation —
/// it starts a session when it appears, when the code expires and after an
/// outcome was shown — and cancels when it leaves.
@MainActor
final class PairingViewController: NSViewController {
    private typealias Pairing = DesignSystem.Pairing

    /// Left column minimum + gap + the devices column's minimum.
    static let minimumHorizontalContentWidth: CGFloat = Pairing.columnMinimumWidth + Pairing.columnGap + 360

    private let relayHost: RelayHostStatusClient

    // Header
    private let titleLabel = NSTextField(labelWithString: "Pair an iPhone")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let relayPill = StatusPillView()

    // Code card
    private let codeCard = CardView(cornerRadius: Pairing.cardRadius, shadow: true)
    private let qrImageView = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let relayHostLabel = NSTextField(labelWithString: "")
    private let expiryValueLabel = NSTextField(labelWithString: "")
    private let countdownBar = CountdownBarView()
    private let codeHelpLabel = NSTextField(wrappingLabelWithString: "到点自动换一个新码，旧码立刻作废。二维码里只有 Relay 地址和这 6 位。")
    private let newCodeButton = NSButton(title: "New code", target: nil, action: nil)

    // Pending card
    private let pendingCard = PendingCardView()
    private let pendingTitle = NSTextField(labelWithString: "")
    private let pendingSubtitle = NSTextField(labelWithString: "")
    private let sasFirstHalf = NSTextField(labelWithString: "")
    private let sasSecondHalf = NSTextField(labelWithString: "")
    private let sasHint = NSTextField(wrappingLabelWithString: "")
    private let dontMatchButton = NSButton(title: "Don't match", target: nil, action: nil)
    private let matchButton = NSButton(title: "Match", target: nil, action: nil)
    private let pendingFootnote = NSTextField(labelWithString: "")
    private let pendingStack = NSStackView()
    private let resultMark = ResultMarkView()
    private let resultTitle = NSTextField(labelWithString: "")
    private let resultBody = NSTextField(wrappingLabelWithString: "")
    private let resultStack = NSStackView()

    // Devices
    private let devicesCountChip = CapsuleChipView()
    private let devicesCard = CardView()
    private let deviceStack = NSStackView()
    private let recordsColumn = NSStackView()
    private let leftColumn = NSStackView()
    private let contentStack = NSStackView()
    private var compactRecordsWidthConstraint: NSLayoutConstraint?
    /// Activated only while the pending card is in the hierarchy — activating
    /// it eagerly (no common ancestor yet) throws, and AppKit swallowing that
    /// exception left the whole page blank.
    private var pendingCardWidthConstraint: NSLayoutConstraint?
    private var usesCompactLayout: Bool?

    // State
    private var isStarting = false
    private var isDeciding = false
    /// Why the last `relay_pairing_start` failed (shown in the code card);
    /// auto-retry backs off to every 30 s instead of every tick.
    private var startFailure: String?
    private var lastStartAttempt: Date?
    private var tickTask: Task<Void, Never>?
    /// The outcome currently shown in the pending card, until it collapses.
    private var shownOutcome: RelayPairingOutcome?
    private var outcomeDismissTask: Task<Void, Never>?
    /// The iPhone that paired on this visit, tinted once in the list.
    private var recentlyPairedDeviceName: String?
    private var pendingCardVisible = false

    private var canGenerateCode: Bool {
        relayHost.isConnected && !isStarting && relayHost.pairing?.pending == nil
    }

    init(relayHost: RelayHostStatusClient) {
        self.relayHost = relayHost
        super.init(nibName: nil, bundle: nil)
        relayHost.observe { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        configureUI()
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        relayHost.setPairingViewVisible(true)
        startTicking()
        ensureLiveCode()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        relayHost.setPairingViewVisible(false)
        tickTask?.cancel()
        tickTask = nil
        outcomeDismissTask?.cancel()
        outcomeDismissTask = nil
        shownOutcome = nil
        Task { await relayHost.cancelPairing() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContentLayout()
    }

    // MARK: UI

    private func configureUI() {
        let header = makeHeader()
        view.addSubview(header)
        configureCodeCard()
        configurePendingCard()
        configureDevicesColumn()

        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = Pairing.cardGap
        leftColumn.setViews([codeCard], in: .leading)
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        // Sized by its content (the Relay host never wraps), never below 420;
        // the devices column takes whatever is left.
        leftColumn.setHuggingPriority(.defaultHigh, for: .horizontal)
        leftColumn.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            leftColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: Pairing.columnMinimumWidth),
            codeCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
        ])

        contentStack.addArrangedSubview(leftColumn)
        contentStack.addArrangedSubview(recordsColumn)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        scroll.documentView = document
        view.addSubview(scroll)

        compactRecordsWidthConstraint = recordsColumn.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: AgentStatusDetailLayout.topInset),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -AgentStatusDetailLayout.bottomInset),
            // Unlike the other detail pages there is no reading-width cap: the
            // devices column stretches to the window edge (minus the inset).
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: AgentStatusDetailLayout.horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -AgentStatusDetailLayout.horizontalInset),
        ])
        updateContentLayout()
    }

    /// Title 22 / 400 with the Relay pill at its right, subtitle 11 / 400,
    /// a 1px rule underneath — inset like the content (28).
    private func makeHeader() -> NSView {
        titleLabel.font = AgentStatusDesign.Font.title
        titleLabel.textColor = AgentStatusDesign.Color.inkPrimary
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel, spacer, relayPill])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 12

        subtitleLabel.font = AgentStatusDesign.Font.caption
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = NSColor(Pairing.headerRule)
        rule.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleRow, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Pairing.headerTitleGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        header.addSubview(rule)
        let inset = AgentStatusDetailLayout.horizontalInset
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: Pairing.headerTop),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            rule.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: Pairing.headerBottom),
            rule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    private func configureCodeCard() {
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.backgroundColor = NSColor.white.cgColor
        qrImageView.layer?.cornerRadius = Pairing.qrRadius
        qrImageView.layer?.cornerCurve = .continuous
        qrImageView.layer?.borderWidth = 0.5
        qrImageView.layer?.borderColor = AgentStatusDesign.Color.cardStroke.cgColor
        qrImageView.setAccessibilityLabel("Pairing QR code")

        let codeCaption = Self.sectionLabel("CODE")
        codeLabel.font = .design(Pairing.code)
        codeLabel.textColor = AgentStatusDesign.Color.inkPrimary
        codeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let codeRow = codeLabel

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = NSColor(Pairing.divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let relayLabel = Self.sectionLabel("RELAY")
        relayHostLabel.font = .design(Pairing.relayHost)
        relayHostLabel.textColor = AgentStatusDesign.Color.inkPrimary
        // One line, never cut: a long Relay host widens the card instead.
        relayHostLabel.lineBreakMode = .byClipping
        relayHostLabel.maximumNumberOfLines = 1
        relayHostLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let expiresCaption = NSTextField(labelWithString: "Expires in")
        expiresCaption.font = AgentStatusDesign.Font.caption
        expiresCaption.textColor = .tertiaryLabelColor
        expiryValueLabel.font = .design(Pairing.expiryValue)
        expiryValueLabel.textColor = AgentStatusDesign.Color.inkPrimary
        let expiryRow = NSStackView(views: [expiresCaption, expiryValueLabel])
        expiryRow.orientation = .horizontal
        expiryRow.spacing = 6
        expiryRow.alignment = .firstBaseline
        countdownBar.translatesAutoresizingMaskIntoConstraints = false

        let codeColumn = NSStackView(views: [codeCaption, codeRow, divider, relayLabel, relayHostLabel, expiryRow, countdownBar])
        codeColumn.orientation = .vertical
        codeColumn.alignment = .leading
        codeColumn.spacing = 4
        codeColumn.setCustomSpacing(Pairing.dividerTop, after: codeRow)
        codeColumn.setCustomSpacing(Pairing.dividerBottom, after: divider)
        codeColumn.setCustomSpacing(8, after: relayHostLabel)
        codeColumn.setCustomSpacing(6, after: expiryRow)
        codeColumn.setHuggingPriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [qrImageView, codeColumn])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = Pairing.qrGap

        codeHelpLabel.font = AgentStatusDesign.Font.caption
        codeHelpLabel.textColor = .tertiaryLabelColor
        codeHelpLabel.maximumNumberOfLines = 3
        codeHelpLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        codeHelpLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newCodeButton.target = self
        newCodeButton.action = #selector(newCodeFromCard)
        newCodeButton.bezelStyle = .rounded
        newCodeButton.controlSize = .regular
        newCodeButton.setContentHuggingPriority(.required, for: .horizontal)
        let bottomRow = NSStackView(views: [codeHelpLabel, newCodeButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 12

        let card = NSStackView(views: [topRow, bottomRow])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 16
        card.edgeInsets = NSEdgeInsets(
            top: Pairing.cardPadding, left: Pairing.cardPadding, bottom: Pairing.cardPadding, right: Pairing.cardPadding
        )
        card.translatesAutoresizingMaskIntoConstraints = false
        codeCard.addSubview(card)
        NSLayoutConstraint.activate([
            qrImageView.widthAnchor.constraint(equalToConstant: Pairing.qrSize),
            qrImageView.heightAnchor.constraint(equalToConstant: Pairing.qrSize),
            countdownBar.heightAnchor.constraint(equalToConstant: Pairing.countdownHeight),
            countdownBar.widthAnchor.constraint(equalTo: codeColumn.widthAnchor),
            divider.widthAnchor.constraint(equalTo: codeColumn.widthAnchor),
            topRow.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -2 * Pairing.cardPadding),
            bottomRow.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -2 * Pairing.cardPadding),
            card.leadingAnchor.constraint(equalTo: codeCard.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: codeCard.trailingAnchor),
            card.topAnchor.constraint(equalTo: codeCard.topAnchor),
            card.bottomAnchor.constraint(equalTo: codeCard.bottomAnchor),
        ])
    }

    private func configurePendingCard() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "iphone", accessibilityDescription: "iPhone") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Pairing.pendingIcon, weight: .regular)
        icon.contentTintColor = NSColor(DesignSystem.Semantic.accent)
        pendingTitle.font = .design(Pairing.pendingTitle)
        pendingTitle.textColor = AgentStatusDesign.Color.inkPrimary
        pendingTitle.lineBreakMode = .byTruncatingMiddle
        pendingTitle.alignment = .center
        let titleRow = NSStackView(views: [icon, pendingTitle])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        pendingSubtitle.font = AgentStatusDesign.Font.caption
        pendingSubtitle.textColor = .tertiaryLabelColor
        pendingSubtitle.alignment = .center

        for half in [sasFirstHalf, sasSecondHalf] {
            half.font = .design(Pairing.sas)
            half.textColor = AgentStatusDesign.Color.inkPrimary
            half.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let sasRow = NSStackView(views: [sasFirstHalf, sasSecondHalf])
        sasRow.orientation = .horizontal
        sasRow.spacing = Pairing.sasGroupGap
        sasRow.alignment = .firstBaseline

        sasHint.font = .design(Pairing.sasHint)
        sasHint.textColor = AgentStatusDesign.Color.inkSecondary
        sasHint.alignment = .center
        sasHint.maximumNumberOfLines = 3

        dontMatchButton.target = self
        dontMatchButton.action = #selector(dontMatch)
        dontMatchButton.bezelStyle = .rounded
        dontMatchButton.controlSize = .large
        dontMatchButton.attributedTitle = NSAttributedString(
            string: "Don't match",
            attributes: [.foregroundColor: AgentStatusDesign.Color.destructiveText, .font: NSFont.design(Pairing.decisionButton)]
        )
        matchButton.target = self
        matchButton.action = #selector(match)
        matchButton.bezelStyle = .rounded
        matchButton.controlSize = .large
        matchButton.bezelColor = NSColor(DesignSystem.Semantic.accent)
        matchButton.attributedTitle = NSAttributedString(
            string: "Match",
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.design(Pairing.decisionButtonEmphasized)]
        )
        // Return is bound to neither button: the person must look, then click.
        dontMatchButton.keyEquivalent = ""
        matchButton.keyEquivalent = ""
        let buttons = NSStackView(views: [dontMatchButton, matchButton])
        buttons.orientation = .horizontal
        buttons.spacing = Pairing.decisionButtonGap
        buttons.alignment = .centerY

        pendingFootnote.font = AgentStatusDesign.Font.caption
        pendingFootnote.textColor = AgentStatusDesign.Color.inkQuaternary
        pendingFootnote.alignment = .center

        pendingStack.setViews([titleRow, pendingSubtitle, sasRow, sasHint, buttons, pendingFootnote], in: .center)
        pendingStack.orientation = .vertical
        pendingStack.alignment = .centerX
        pendingStack.spacing = Pairing.pendingGap
        pendingStack.setCustomSpacing(6, after: titleRow)

        resultTitle.font = .design(Pairing.pendingTitle)
        resultTitle.textColor = AgentStatusDesign.Color.inkPrimary
        resultTitle.alignment = .center
        resultBody.font = .design(Pairing.resultBody)
        resultBody.textColor = .tertiaryLabelColor
        resultBody.alignment = .center
        resultBody.maximumNumberOfLines = 3
        resultStack.setViews([resultMark, resultTitle, resultBody], in: .center)
        resultStack.orientation = .vertical
        resultStack.alignment = .centerX
        resultStack.spacing = 10
        resultStack.isHidden = true

        let content = NSStackView(views: [pendingStack, resultStack])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 0
        content.edgeInsets = NSEdgeInsets(
            top: Pairing.pendingTopPadding, left: Pairing.cardPadding, bottom: Pairing.pendingBottomPadding, right: Pairing.cardPadding
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        pendingCard.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: pendingCard.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pendingCard.trailingAnchor),
            content.topAnchor.constraint(equalTo: pendingCard.topAnchor),
            content.bottomAnchor.constraint(equalTo: pendingCard.bottomAnchor),
            pendingTitle.widthAnchor.constraint(lessThanOrEqualToConstant: Pairing.columnMinimumWidth - 2 * Pairing.cardPadding - 30),
            sasHint.widthAnchor.constraint(lessThanOrEqualToConstant: Pairing.sasHintMaxWidth),
            resultBody.widthAnchor.constraint(lessThanOrEqualToConstant: Pairing.sasHintMaxWidth),
            dontMatchButton.heightAnchor.constraint(equalToConstant: Pairing.decisionButtonHeight),
            matchButton.heightAnchor.constraint(equalToConstant: Pairing.decisionButtonHeight),
            resultMark.widthAnchor.constraint(equalToConstant: Pairing.resultMark),
            resultMark.heightAnchor.constraint(equalToConstant: Pairing.resultMark),
        ])
    }

    private func configureDevicesColumn() {
        let recordsTitle = NSTextField(labelWithString: "Paired iPhones")
        recordsTitle.font = AgentStatusDesign.Font.section
        devicesCountChip.text = "0"
        let titleRow = NSStackView(views: [recordsTitle, devicesCountChip])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        deviceStack.orientation = .vertical
        deviceStack.alignment = .leading
        deviceStack.spacing = 0
        deviceStack.translatesAutoresizingMaskIntoConstraints = false
        devicesCard.addSubview(deviceStack)
        NSLayoutConstraint.activate([
            deviceStack.leadingAnchor.constraint(equalTo: devicesCard.leadingAnchor),
            deviceStack.trailingAnchor.constraint(equalTo: devicesCard.trailingAnchor),
            deviceStack.topAnchor.constraint(equalTo: devicesCard.topAnchor),
            deviceStack.bottomAnchor.constraint(equalTo: devicesCard.bottomAnchor),
        ])

        let recordsHelp = NSTextField(wrappingLabelWithString: "配对码 5 分钟有效、只能用一次。Device token 只在这台 Mac 点 Match 之后才签发；Relay 全程拿不到能冒充任何一端的材料。撤销设备会关闭该 iPhone 的通道，历史 Session 仍保留在本机。")
        recordsHelp.font = AgentStatusDesign.Font.caption
        recordsHelp.textColor = .tertiaryLabelColor
        recordsHelp.maximumNumberOfLines = 4
        recordsHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        recordsColumn.setViews([titleRow, devicesCard, recordsHelp], in: .leading)
        recordsColumn.orientation = .vertical
        recordsColumn.alignment = .leading
        recordsColumn.spacing = 12
        recordsColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        // The two columns are top-aligned and independent in height: the
        // devices card is exactly as tall as its rows, never stretched to
        // match the code card.
        recordsColumn.setHuggingPriority(.required, for: .vertical)
        devicesCard.setContentHuggingPriority(.required, for: .vertical)
        deviceStack.setHuggingPriority(.required, for: .vertical)
        // The devices column wants 360 but yields to the code card: a long
        // Relay host widens the card (its content is required), and inside
        // the 900pt content cap the list gives the difference up.
        let devicesMinimum = recordsColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        devicesMinimum.priority = .defaultHigh
        NSLayoutConstraint.activate([
            devicesCard.widthAnchor.constraint(equalTo: recordsColumn.widthAnchor),
            recordsHelp.widthAnchor.constraint(lessThanOrEqualTo: recordsColumn.widthAnchor),
            devicesMinimum,
        ])
    }

    private static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .design(DesignSystem.Pairing.label)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func updateContentLayout() {
        let availableWidth = max(
            view.bounds.width - (AgentStatusDetailLayout.horizontalInset * 2),
            AgentStatusDetailLayout.minimumContentWidth
        )
        let compact = Self.usesCompactContentLayout(availableWidth: availableWidth)
        guard usesCompactLayout != compact else { return }
        usesCompactLayout = compact
        contentStack.orientation = compact ? .vertical : .horizontal
        contentStack.alignment = compact ? .leading : .top
        contentStack.spacing = compact ? 24 : Pairing.columnGap
        compactRecordsWidthConstraint?.isActive = compact
    }

    static func usesCompactContentLayout(availableWidth: CGFloat) -> Bool {
        availableWidth < minimumHorizontalContentWidth
    }

    // MARK: State

    private func reload() {
        guard isViewLoaded else { return }
        if relayHost.isConnected {
            relayPill.configure(tone: .green, text: "Relay connected")
        } else {
            relayPill.configure(tone: .gray, text: "Relay unavailable")
        }
        var hint = "在 iPhone 上输入这 6 位配对码，或直接扫二维码。每台 iPhone 是一条独立的加密通道，撤销其中一台不影响其他设备。"
        if !relayHost.isConnected, let error = relayHost.lastError {
            hint = error
        }
        subtitleLabel.stringValue = hint
        renderCode()
        renderPending()
        reloadDevices()
        newCodeButton.isEnabled = canGenerateCode
        if view.window != nil { ensureLiveCode() }
    }

    /// A code is on screen whenever the page is up and the Relay is there.
    private func ensureLiveCode() {
        guard view.window != nil, relayHost.isConnected, !isStarting, shownOutcome == nil else { return }
        if let pairing = relayHost.pairing {
            guard pairing.expiresAt <= Date() || pairing.outcome != nil else { return }
        }
        // A failed start retries on a slow clock (or via `New code`), never
        // once a second — and never as a modal alert.
        if startFailure != nil, let lastStartAttempt, Date().timeIntervalSince(lastStartAttempt) < 30 { return }
        startPairing()
    }

    private func startPairing() {
        guard relayHost.isConnected, !isStarting else { return }
        isStarting = true
        lastStartAttempt = Date()
        recentlyPairedDeviceName = nil
        outcomeDismissTask?.cancel()
        outcomeDismissTask = nil
        shownOutcome = nil
        newCodeButton.isEnabled = false
        Task {
            defer {
                isStarting = false
                reload()
            }
            do {
                _ = try await relayHost.startPairing()
                startFailure = nil
            } catch {
                NSLog("agent-status pairing: start failed: %@", String(describing: error))
                startFailure = error.localizedDescription
            }
        }
    }

    private func renderCode() {
        if let startFailure {
            qrImageView.image = nil
            codeLabel.attributedStringValue = Self.codeText("···-···")
            relayHostLabel.stringValue = "—"
            expiryValueLabel.stringValue = "—"
            countdownBar.progress = 0
            codeHelpLabel.stringValue = "拿不到配对码：\(startFailure)\n每 30 秒自动重试，或点 New code。"
            return
        }
        codeHelpLabel.stringValue = "到点自动换一个新码，旧码立刻作废。二维码里只有 Relay 地址和这 6 位。"
        guard let pairing = relayHost.pairing, relayHost.isConnected else {
            qrImageView.image = nil
            codeLabel.attributedStringValue = Self.codeText("···-···")
            relayHostLabel.stringValue = relayHost.isConnected ? "—" : "Relay unavailable"
            expiryValueLabel.stringValue = "—"
            countdownBar.progress = 0
            return
        }
        codeLabel.attributedStringValue = Self.codeText(PairingCode.display(pairing.code).replacingOccurrences(of: " ", with: "-"))
        relayHostLabel.stringValue = RelayURLValidation.displayHost(pairing.relayURL)
        let link = PairingLink(relayURL: pairing.relayURL, code: pairing.code)
        if qrImageView.toolTip != link.url.absoluteString {
            qrImageView.image = Self.qrImage(text: link.url.absoluteString)
            qrImageView.toolTip = link.url.absoluteString
        }
        renderCountdown()
    }

    private func renderCountdown() {
        guard let pairing = relayHost.pairing else { return }
        let remaining = max(0, pairing.expiresAt.timeIntervalSinceNow)
        expiryValueLabel.stringValue = Self.clock(remaining)
        let lifetime = max(1, pairing.expiresAt.timeIntervalSince(pairing.expiresAt.addingTimeInterval(-5 * 60)))
        countdownBar.progress = remaining / lifetime
        if let pending = pairing.pending, shownOutcome == nil {
            let left = max(0, 60 - Date().timeIntervalSince(pending.receivedAt))
            pendingFootnote.stringValue = "默认焦点在 Don't match，Return 不绑定任何一个 · \(Self.clock(left)) 后自动拒绝"
            pendingSubtitle.stringValue = "\(RelayURLValidation.displayHost(pairing.relayURL)) · \(Self.relative(pending.receivedAt))"
        }
    }

    private func renderPending() {
        let pairing = relayHost.pairing
        if let outcome = pairing?.outcome, outcome != shownOutcome {
            shownOutcome = outcome
            outcomeDismissTask?.cancel()
            outcomeDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Pairing.resultDwell))
                guard !Task.isCancelled, let self else { return }
                self.shownOutcome = nil
                self.setPendingCard(visible: false)
                self.ensureLiveCode()
            }
        }
        if let outcome = shownOutcome {
            pendingStack.isHidden = true
            resultStack.isHidden = false
            switch outcome.kind {
            case .approved:
                resultMark.configure(success: true)
                resultTitle.stringValue = "Paired"
                resultBody.stringValue = "Device token 已签发、通道已建立。卡片 2 秒后收起，新设备落到右侧列表第一行。"
                recentlyPairedDeviceName = outcome.deviceName
            case .rejected:
                resultMark.configure(success: false)
                resultTitle.stringValue = "Pairing declined"
                resultBody.stringValue = "已告诉 iPhone 这次配对被拒绝，配对码同时作废；出码卡换上一个新码。"
            }
            pendingCard.setPending(false)
            setPendingCard(visible: true)
            return
        }
        guard let pending = pairing?.pending else {
            setPendingCard(visible: false)
            return
        }
        pendingStack.isHidden = false
        resultStack.isHidden = true
        pendingTitle.stringValue = "“\(pending.deviceName)” wants to pair"
        let halves = PairingCode.displaySAS(pending.sas).split(separator: " ")
        sasFirstHalf.stringValue = halves.first.map(String.init) ?? pending.sas
        sasSecondHalf.stringValue = halves.count > 1 ? String(halves[1]) : ""
        sasHint.stringValue = "Compare with the number on the iPhone. 上面的 \(PairingCode.display(pairing?.code ?? "").replacingOccurrences(of: " ", with: "-")) 是配对码，不是要比对的数字。"
        dontMatchButton.isEnabled = !isDeciding
        matchButton.isEnabled = !isDeciding
        pendingCard.setPending(true)
        renderCountdown()
        let wasVisible = pendingCardVisible
        setPendingCard(visible: true)
        if !wasVisible { view.window?.makeFirstResponder(dontMatchButton) }
    }

    private func setPendingCard(visible: Bool) {
        guard pendingCardVisible != visible else { return }
        pendingCardVisible = visible
        if visible {
            pendingCard.alphaValue = 0
            leftColumn.addArrangedSubview(pendingCard)
            if pendingCardWidthConstraint == nil {
                pendingCardWidthConstraint = pendingCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor)
            }
            pendingCardWidthConstraint?.isActive = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Pairing.entranceDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pendingCard.animator().alphaValue = 1
            }
        } else {
            pendingCardWidthConstraint?.isActive = false
            leftColumn.removeArrangedSubview(pendingCard)
            pendingCard.removeFromSuperview()
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.renderCountdown()
                self.ensureLiveCode()
            }
        }
    }

    @objc private func newCodeFromCard() {
        startFailure = nil
        startPairing()
    }

    @objc private func match() {
        decide(approved: true)
    }

    @objc private func dontMatch() {
        decide(approved: false)
    }

    private func decide(approved: Bool) {
        guard !isDeciding, relayHost.pairing?.pending != nil else { return }
        isDeciding = true
        dontMatchButton.isEnabled = false
        matchButton.isEnabled = false
        Task {
            defer {
                isDeciding = false
                reload()
            }
            do {
                _ = try await relayHost.decidePairing(approved: approved)
            } catch {
                NSLog("agent-status pairing: decision failed: %@", String(describing: error))
                pendingFootnote.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func revokeDevice(_ sender: NSButton) {
        guard let device = device(for: sender) else { return }
        confirm(
            title: "Revoke “\(device.name)”?",
            message: "Only this device channel is closed; other iPhones stay connected. Session history stays on this Mac.",
            button: "Revoke"
        ) { [weak self] in
            await self?.relayHost.revoke(deviceID: device.id)
        }
    }

    @objc private func removeDevice(_ sender: NSButton) {
        guard let device = device(for: sender) else { return }
        confirm(
            title: "Remove “\(device.name)”?",
            message: "The revoked record is deleted from this Mac's pairing list. The iPhone can pair again with a new code.",
            button: "Remove"
        ) { [weak self] in
            await self?.relayHost.remove(deviceID: device.id)
        }
    }

    private func device(for sender: NSButton) -> PairedDevice? {
        guard let value = sender.identifier?.rawValue else { return nil }
        return relayHost.devices.first { $0.id.rawValue == value }
    }

    private func confirm(title: String, message: String, button: String, then action: @escaping () async -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let proceed: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await action() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    private func reloadDevices() {
        deviceStack.arrangedSubviews.forEach {
            deviceStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let devices = relayHost.devices.sorted(by: { $0.pairedAt > $1.pairedAt })
        devicesCountChip.text = "\(devices.filter { $0.revokedAt == nil && $0.keyVerified }.count)"
        guard !devices.isEmpty else {
            let label = NSTextField(labelWithString: "No iPhone has been paired with this Mac.")
            label.font = AgentStatusDesign.Font.body
            label.textColor = .secondaryLabelColor
            let row = NSStackView(views: [label])
            row.edgeInsets = NSEdgeInsets(top: 0, left: Pairing.deviceRowInset, bottom: 0, right: Pairing.deviceRowInset)
            row.heightAnchor.constraint(equalToConstant: Pairing.deviceRowHeight).isActive = true
            deviceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: deviceStack.widthAnchor).isActive = true
            return
        }

        for (index, device) in devices.enumerated() {
            let row = makeDeviceRow(device)
            deviceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: deviceStack.widthAnchor).isActive = true
            if index < devices.count - 1 {
                let hairline = makeHairline()
                deviceStack.addArrangedSubview(hairline)
                hairline.widthAnchor.constraint(equalTo: deviceStack.widthAnchor).isActive = true
            }
        }
    }

    /// `[iPhone] name [Active tag]` / `relay host` … `Revoke` | `Remove`.
    private func makeDeviceRow(_ device: PairedDevice) -> NSView {
        let isActive = device.revokedAt == nil
        // Listed at the Relay but not a key this Mac approved (a row from
        // another life, or a key the Relay swapped): the daemon sends it
        // nothing until it pairs again.
        let isUnverified = isActive && !device.keyVerified
        let icon = NSImageView(image: NSImage(systemSymbolName: "iphone", accessibilityDescription: "iPhone") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Pairing.deviceIcon - 2, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: Pairing.deviceIcon + 8).isActive = true

        let name = NSTextField(labelWithString: device.name)
        name.font = AgentStatusDesign.Font.rowTitle
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tag = StateTagView()
        tag.configure(isUnverified ? .unverified : (isActive ? .active : .revoked))
        let mainRow = NSStackView(views: [name, tag])
        mainRow.orientation = .horizontal
        mainRow.alignment = .centerY
        mainRow.spacing = Pairing.deviceTagGap

        let relayHostText = relayHost.pairing.map { RelayURLValidation.displayHost($0.relayURL) } ?? "—"
        let subtitle = NSTextField(labelWithString: isUnverified ? "Key not verified · pair this iPhone again" : relayHostText)
        subtitle.font = isUnverified ? AgentStatusDesign.Font.caption : .design(Pairing.deviceSubtitle)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [mainRow, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: Pairing.deviceRowInset, bottom: 0, right: Pairing.deviceRowInset)
        row.heightAnchor.constraint(equalToConstant: Pairing.deviceRowHeight).isActive = true

        // One plain-text action per row: Revoke closes an Active channel,
        // Remove deletes a Revoked record.
        let action = NSButton(title: "", target: self, action: isActive ? #selector(revokeDevice(_:)) : #selector(removeDevice(_:)))
        action.isBordered = false
        action.attributedTitle = NSAttributedString(
            string: isActive ? "Revoke" : "Remove",
            attributes: [.foregroundColor: AgentStatusDesign.Color.destructiveText, .font: NSFont.design(Pairing.deviceAction)]
        )
        action.heightAnchor.constraint(equalToConstant: Pairing.deviceActionHeight).isActive = true
        action.setContentHuggingPriority(.required, for: .horizontal)
        action.identifier = NSUserInterfaceItemIdentifier(device.id.rawValue)
        row.addArrangedSubview(action)

        let isRecentlyPaired = isActive && device.name == recentlyPairedDeviceName
        if isRecentlyPaired {
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor(Pairing.newRowTint).cgColor
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.2
                row.animator().layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        return row
    }

    private static func qrImage(text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    /// `7KF-3QP` as one run: the hyphen greyed so the halves read as a pair,
    /// the rest in the code style's tracking.
    private static func codeText(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.design(Pairing.code),
            .kern: Pairing.code.tracking,
            .foregroundColor: AgentStatusDesign.Color.inkPrimary,
        ])
        if let hyphen = text.range(of: "-") {
            result.addAttribute(.foregroundColor, value: NSColor(Pairing.codeHyphen), range: NSRange(hyphen, in: text))
        }
        return result
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Views

/// Paired-list state tag: 18pt capsule, 11 / Semibold. Active is the green
/// L2 tint; Revoked / Unverified the hairline-ringed L1.
@MainActor
private final class StateTagView: NSView {
    enum Kind { case active, revoked, unverified }
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Pairing.tagHeight / 2
        layer?.borderWidth = 0.5
        label.font = .design(DesignSystem.Pairing.tag)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignSystem.Pairing.tagHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Pairing.tagHorizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Pairing.tagHorizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ kind: Kind) {
        switch kind {
        case .active:
            label.stringValue = "Active"
            label.textColor = NSColor(DesignSystem.Pairing.tagActiveText)
            layer?.backgroundColor = NSColor(DesignSystem.Pairing.tagActiveFill).cgColor
            layer?.borderColor = NSColor(DesignSystem.Pairing.tagActiveRing).cgColor
        case .revoked, .unverified:
            label.stringValue = kind == .revoked ? "Revoked" : "Unverified"
            label.textColor = NSColor(DesignSystem.Pairing.tagMutedText)
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor(DesignSystem.Pairing.tagMutedRing).cgColor
        }
    }
}

/// Code lifetime bar: 3pt capsule, accent fill over a grey track.
@MainActor
private final class CountdownBarView: NSView {
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint?

    var progress: Double = 0 {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Pairing.countdownHeight / 2
        layer?.backgroundColor = NSColor(DesignSystem.Pairing.countdownTrack).cgColor
        fill.wantsLayer = true
        fill.layer?.cornerRadius = DesignSystem.Pairing.countdownHeight / 2
        fill.layer?.backgroundColor = NSColor(DesignSystem.Semantic.accent).cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        let width = fill.widthAnchor.constraint(equalToConstant: 0)
        fillWidth = width
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        fillWidth?.constant = bounds.width * min(1, max(0, progress))
    }
}

/// The pending / result card: a plain card that gains the accent ring while
/// an iPhone is waiting for Match.
@MainActor
private final class PendingCardView: NSView {
    private let ring = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Pairing.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -12)
        ring.cornerCurve = .continuous
        ring.borderWidth = DesignSystem.Pairing.pendingRingOuterWidth
        layer?.addSublayer(ring)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setPending(_ pending: Bool) {
        ring.isHidden = !pending
        layer?.borderWidth = pending ? 1 : 0.5
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        let outer = DesignSystem.Pairing.pendingRingOuterWidth
        ring.frame = bounds.insetBy(dx: -outer, dy: -outer)
        ring.cornerRadius = DesignSystem.Pairing.cardRadius + outer
    }

    private func applyColors() {
        layer?.backgroundColor = NSColor(AdaptiveDesignColor(light: DesignSystem.Surface.card, dark: DesignSystem.SurfaceDark.card)).cgColor
        layer?.borderColor = (ring.isHidden ? AgentStatusDesign.Color.cardStroke : NSColor(DesignSystem.Pairing.pendingRingInner)).cgColor
        ring.borderColor = NSColor(DesignSystem.Pairing.pendingRingOuter).cgColor
    }
}

/// 34pt circle with ✓ (green) or ✕ (grey).
@MainActor
private final class ResultMarkView: NSView {
    private let glyph = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Pairing.resultMark / 2
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentTintColor = .white
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        configure(success: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(success: Bool) {
        layer?.backgroundColor = (success ? NSColor(DesignSystem.Semantic.connected) : NSColor(DesignSystem.Ink.quaternary)).cgColor
        glyph.image = NSImage(systemSymbolName: success ? "checkmark" : "xmark", accessibilityDescription: success ? "Paired" : "Declined")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    }
}
