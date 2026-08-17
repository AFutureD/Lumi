import AgentStatusRemote
import AgentStatusTransport
import AppKit
import CoreImage

@MainActor
final class PairingViewController: NSViewController {
    private let relayHost: RelayHostController
    private let statusLabel = NSTextField(labelWithString: "Connecting to Relay…")
    private let qrImageView = NSImageView()
    private let qrHelpLabel = NSTextField(wrappingLabelWithString: "A one-time pairing code will appear here.")
    private let expiryLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy pairing payload", target: nil, action: nil)
    private let generateButton = NSButton(title: "Generate new code", target: nil, action: nil)
    private let deviceStack = NSStackView()
    private var pairingPayload: String?
    private var isGenerating = false

    init(relayHost: RelayHostController) {
        self.relayHost = relayHost
        super.init(nibName: nil, bundle: nil)
        relayHost.onChange = { [weak self] in
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

    private func configureUI() {
        let title = NSTextField(labelWithString: "Pair iPhone")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let introduction = NSTextField(wrappingLabelWithString: "Open Agent Status on iPhone and scan this one-time code. Each iPhone is an independent encrypted channel to this Mac.")
        introduction.textColor = .secondaryLabelColor
        introduction.maximumNumberOfLines = 3

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        qrImageView.layer?.cornerRadius = 12
        qrImageView.widthAnchor.constraint(equalToConstant: 270).isActive = true
        qrImageView.heightAnchor.constraint(equalToConstant: 270).isActive = true
        qrHelpLabel.alignment = .center
        qrHelpLabel.textColor = .secondaryLabelColor
        qrHelpLabel.maximumNumberOfLines = 2
        expiryLabel.textColor = .secondaryLabelColor
        expiryLabel.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyPairingPayload)
        copyButton.isEnabled = false
        generateButton.target = self
        generateButton.action = #selector(regeneratePairingCode)
        let qrButtons = NSStackView(views: [generateButton, copyButton])
        qrButtons.orientation = .horizontal
        qrButtons.spacing = 8
        let qrColumn = NSStackView(views: [qrImageView, qrHelpLabel, expiryLabel, qrButtons])
        qrColumn.orientation = .vertical
        qrColumn.alignment = .centerX
        qrColumn.spacing = 10

        let recordsTitle = NSTextField(labelWithString: "Pairing records")
        recordsTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let recordsHelp = NSTextField(wrappingLabelWithString: "Revoking one iPhone closes only that device channel. Other iPhones remain connected.")
        recordsHelp.textColor = .secondaryLabelColor
        recordsHelp.maximumNumberOfLines = 3
        deviceStack.orientation = .vertical
        deviceStack.alignment = .leading
        deviceStack.spacing = 10
        let recordsColumn = NSStackView(views: [recordsTitle, recordsHelp, deviceStack])
        recordsColumn.orientation = .vertical
        recordsColumn.alignment = .leading
        recordsColumn.spacing = 12
        recordsColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        let content = NSStackView(views: [qrColumn, recordsColumn])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 44
        let root = NSStackView(views: [title, introduction, statusLabel, content])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 32, right: 32)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            introduction.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
        ])
    }

    private func reload() {
        statusLabel.stringValue = relayHost.isConnected
            ? "Relay connected"
            : "Relay unavailable\(relayHost.lastError.map { ": \($0)" } ?? "")"
        statusLabel.textColor = relayHost.isConnected ? .systemGreen : .secondaryLabelColor
        generateButton.isEnabled = relayHost.isConnected && !isGenerating
        copyButton.isEnabled = pairingPayload != nil
        reloadDevices()
    }

    @objc private func regeneratePairingCode() {
        generatePairingCode()
    }

    private func generatePairingCode() {
        guard relayHost.isConnected, !isGenerating else { return }
        isGenerating = true
        generateButton.isEnabled = false
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

    @objc private func copyPairingPayload() {
        guard let pairingPayload else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingPayload, forType: .string)
    }

    @objc private func revokeDevice(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        Task { await relayHost.revoke(deviceID: DeviceID(value)) }
    }

    private func reloadDevices() {
        deviceStack.arrangedSubviews.forEach {
            deviceStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !relayHost.devices.isEmpty else {
            let label = NSTextField(labelWithString: "No iPhone has been paired with this Mac.")
            label.textColor = .secondaryLabelColor
            deviceStack.addArrangedSubview(label)
            return
        }

        for device in relayHost.devices.sorted(by: { $0.pairedAt > $1.pairedAt }) {
            let name = NSTextField(labelWithString: device.name)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            let state = device.revokedAt == nil ? "Paired" : "Revoked"
            let detail = NSTextField(labelWithString: "\(state) · \(Self.dateFormatter.string(from: device.pairedAt))")
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 11)
            let labels = NSStackView(views: [name, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 2
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.addArrangedSubview(labels)
            if device.revokedAt == nil {
                let button = NSButton(title: "Revoke", target: self, action: #selector(revokeDevice(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(device.id.rawValue)
                row.addArrangedSubview(button)
            }
            deviceStack.addArrangedSubview(row)
        }
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
