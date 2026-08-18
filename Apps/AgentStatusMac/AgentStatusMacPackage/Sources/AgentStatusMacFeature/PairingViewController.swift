import AgentStatusRemote
import AgentStatusTransport
import AppKit
import CoreImage

/// Pair iPhone: subheader (Relay pill · hint) → QR card (320) | paired-devices card.
/// The title and `Generate new code` live in the toolbar.
@MainActor
final class PairingViewController: NSViewController {
    static let minimumHorizontalContentWidth: CGFloat = 708

    private let relayHost: RelayHostController
    private let subheader = DetailSubheaderView(horizontalInset: AgentStatusDetailLayout.horizontalInset)
    private let relayPill = StatusPillView()
    private let qrCard = CardView(cornerRadius: 20, shadow: true)
    private let qrImageView = NSImageView()
    private let qrHelpLabel = NSTextField(labelWithString: "A one-time pairing code will appear here.")
    private let expiryLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy pairing payload", target: nil, action: nil)
    private let regenerateButton = NSButton(
        image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Generate new code") ?? NSImage(),
        target: nil,
        action: nil
    )
    private let devicesCountChip = CapsuleChipView()
    private let devicesCard = CardView()
    private let deviceStack = NSStackView()
    private let recordsColumn = NSStackView()
    private let contentStack = NSStackView()
    private var compactRecordsWidthConstraint: NSLayoutConstraint?
    private var usesCompactLayout: Bool?
    private var pairingPayload: String?
    private var isGenerating = false

    /// Fires whenever `canGenerateCode` may have changed; the toolbar re-validates.
    var onStateChange: (() -> Void)?

    var canGenerateCode: Bool {
        relayHost.isConnected && !isGenerating
    }

    init(relayHost: RelayHostController) {
        self.relayHost = relayHost
        super.init(nibName: nil, bundle: nil)
        relayHost.observe { [weak self] in
            guard let self else { return }
            self.reload()
            if self.relayHost.isConnected, self.pairingPayload == nil {
                self.generatePairingCode()
            }
        }
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
        Task { await relayHost.refreshDevices() }
        if relayHost.isConnected, pairingPayload == nil { generatePairingCode() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContentLayout()
    }

    /// Toolbar action.
    func generateNewCode() {
        generatePairingCode()
    }

    // MARK: UI

    private func configureUI() {
        // QR card
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.backgroundColor = NSColor.white.cgColor
        qrImageView.layer?.cornerRadius = 14
        qrImageView.layer?.cornerCurve = .continuous
        qrImageView.layer?.borderWidth = 0.5
        qrImageView.layer?.borderColor = AgentStatusDesign.Color.cardStroke.cgColor
        qrHelpLabel.font = AgentStatusDesign.Font.rowTitle
        qrHelpLabel.alignment = .center
        qrHelpLabel.maximumNumberOfLines = 2
        expiryLabel.font = AgentStatusDesign.Font.caption
        expiryLabel.textColor = .tertiaryLabelColor
        expiryLabel.alignment = .center
        copyButton.target = self
        copyButton.action = #selector(copyPairingPayload)
        copyButton.isEnabled = false
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerateFromCard)
        regenerateButton.bezelStyle = .rounded
        regenerateButton.imagePosition = .imageOnly
        regenerateButton.toolTip = "Generate new code"
        regenerateButton.setAccessibilityLabel("Generate new code")
        regenerateButton.isEnabled = false

        let qrTexts = NSStackView(views: [qrHelpLabel, expiryLabel])
        qrTexts.orientation = .vertical
        qrTexts.alignment = .centerX
        qrTexts.spacing = 3
        let qrButtons = NSStackView(views: [copyButton, regenerateButton])
        qrButtons.orientation = .horizontal
        qrButtons.alignment = .centerY
        qrButtons.spacing = 8
        let qrColumn = NSStackView(views: [qrImageView, qrTexts, qrButtons])
        qrColumn.orientation = .vertical
        qrColumn.alignment = .centerX
        qrColumn.spacing = 14
        qrColumn.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        qrColumn.translatesAutoresizingMaskIntoConstraints = false
        qrCard.addSubview(qrColumn)
        NSLayoutConstraint.activate([
            qrImageView.widthAnchor.constraint(equalToConstant: 280),
            qrImageView.heightAnchor.constraint(equalToConstant: 280),
            qrColumn.leadingAnchor.constraint(equalTo: qrCard.leadingAnchor),
            qrColumn.trailingAnchor.constraint(equalTo: qrCard.trailingAnchor),
            qrColumn.topAnchor.constraint(equalTo: qrCard.topAnchor),
            qrColumn.bottomAnchor.constraint(equalTo: qrCard.bottomAnchor),
            qrCard.widthAnchor.constraint(equalToConstant: 320),
        ])

        // Devices column
        let recordsTitle = NSTextField(labelWithString: "Paired devices")
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

        let recordsHelp = NSTextField(wrappingLabelWithString: "Pairing codes are single-use and expire after scanning. Revoking a device closes that iPhone's channel; Session history stays on this Mac.")
        recordsHelp.font = AgentStatusDesign.Font.caption
        recordsHelp.textColor = .tertiaryLabelColor
        recordsHelp.maximumNumberOfLines = 3
        recordsHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        recordsColumn.setViews([titleRow, devicesCard, recordsHelp], in: .leading)
        recordsColumn.orientation = .vertical
        recordsColumn.alignment = .leading
        recordsColumn.spacing = 12
        recordsColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            devicesCard.widthAnchor.constraint(equalTo: recordsColumn.widthAnchor),
            recordsHelp.widthAnchor.constraint(lessThanOrEqualTo: recordsColumn.widthAnchor),
            recordsColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])

        contentStack.addArrangedSubview(qrCard)
        contentStack.addArrangedSubview(recordsColumn)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable body under the subheader
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        scroll.documentView = document

        [subheader, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        compactRecordsWidthConstraint = recordsColumn.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        NSLayoutConstraint.activate([
            subheader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subheader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subheader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: subheader.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: AgentStatusDetailLayout.topInset),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -AgentStatusDetailLayout.bottomInset),
        ] + AgentStatusDetailLayout.adaptiveWidthConstraints(for: contentStack, in: document))
        updateContentLayout()
    }

    private func updateContentLayout() {
        let availableWidth = min(
            max(
                view.bounds.width - (AgentStatusDetailLayout.horizontalInset * 2),
                AgentStatusDetailLayout.minimumContentWidth
            ),
            AgentStatusDetailLayout.maximumContentWidth
        )
        let compact = Self.usesCompactContentLayout(availableWidth: availableWidth)
        guard usesCompactLayout != compact else { return }
        usesCompactLayout = compact
        contentStack.orientation = compact ? .vertical : .horizontal
        contentStack.alignment = compact ? .leading : .top
        contentStack.spacing = compact ? 24 : 28
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
        var hint = "Open Agent Status on iPhone and scan this one-time code. Each iPhone is an independent encrypted channel to this Mac."
        if !relayHost.isConnected, let error = relayHost.lastError {
            hint = error
        }
        subheader.setLeadingViews([relayPill], trailingText: hint)
        copyButton.isEnabled = pairingPayload != nil
        regenerateButton.isEnabled = canGenerateCode
        reloadDevices()
        onStateChange?()
    }

    private func generatePairingCode() {
        guard relayHost.isConnected, !isGenerating else { return }
        isGenerating = true
        regenerateButton.isEnabled = false
        onStateChange?()
        qrHelpLabel.stringValue = "Generating one-time code…"
        Task {
            defer {
                isGenerating = false
                reload()
            }
            do {
                let offer = try await relayHost.createPairingOffer()
                let data = try TransportCoding.makeEncoder().encode(offer)
                guard let image = Self.qrImage(data: data),
                      let payload = String(data: data, encoding: .utf8) else {
                    throw PairingViewError.qrGenerationFailed
                }
                qrImageView.image = image
                pairingPayload = payload
                copyButton.isEnabled = true
                qrHelpLabel.stringValue = "Scan with Agent Status on iPhone"
                expiryLabel.stringValue = "Expires \(Self.dateFormatter.string(from: offer.expiresAt))"
            } catch {
                qrImageView.image = nil
                pairingPayload = nil
                copyButton.isEnabled = false
                qrHelpLabel.stringValue = "Unable to generate a pairing code."
                expiryLabel.stringValue = ""
                showError(error)
            }
        }
    }

    @objc private func regenerateFromCard() {
        generatePairingCode()
    }

    @objc private func copyPairingPayload() {
        guard let pairingPayload else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingPayload, forType: .string)
    }

    @objc private func revokeDevice(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue,
              let device = relayHost.devices.first(where: { $0.id.rawValue == value }) else { return }
        let alert = NSAlert()
        alert.messageText = "Revoke “\(device.name)”?"
        alert.informativeText = "Only this device channel is closed; other iPhones stay connected. Session history stays on this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revoke")
        alert.addButton(withTitle: "Cancel")
        let deviceID = device.id
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.relayHost.revoke(deviceID: deviceID) }
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
        devicesCountChip.text = "\(devices.filter { $0.revokedAt == nil }.count)"
        guard !devices.isEmpty else {
            let label = NSTextField(labelWithString: "No iPhone has been paired with this Mac.")
            label.font = AgentStatusDesign.Font.body
            label.textColor = .secondaryLabelColor
            let row = NSStackView(views: [label])
            row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            row.heightAnchor.constraint(equalToConstant: 60).isActive = true
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

    private func makeDeviceRow(_ device: RelayDeviceRecord) -> NSView {
        let isActive = device.revokedAt == nil
        let icon = NSImageView(image: NSImage(systemSymbolName: "iphone", accessibilityDescription: "iPhone") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let name = NSTextField(labelWithString: device.name)
        name.font = AgentStatusDesign.Font.rowTitle
        name.lineBreakMode = .byTruncatingTail
        let state = isActive ? "Paired" : "Revoked"
        let detail = NSTextField(labelWithString: "\(state) · \(Self.dateFormatter.string(from: device.pairedAt))")
        detail.textColor = .tertiaryLabelColor
        detail.font = AgentStatusDesign.Font.caption
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (isActive ? AgentStatusDesign.Color.connected : NSColor.quaternaryLabelColor).cgColor
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        let stateLabel = NSTextField(labelWithString: isActive ? "Active" : "Revoked")
        stateLabel.font = AgentStatusDesign.Font.caption
        stateLabel.textColor = .tertiaryLabelColor
        stateLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let row = NSStackView(views: [icon, labels, dot, stateLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        row.heightAnchor.constraint(equalToConstant: 60).isActive = true
        if isActive {
            let button = NSButton(title: "Revoke", target: self, action: #selector(revokeDevice(_:)))
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.contentTintColor = AgentStatusDesign.Color.destructiveText
            button.identifier = NSUserInterfaceItemIdentifier(device.id.rawValue)
            row.addArrangedSubview(button)
        }
        return row
    }

    private func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private static func qrImage(data: Data) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum PairingViewError: LocalizedError {
    case qrGenerationFailed

    var errorDescription: String? { "The pairing QR code could not be generated." }
}
