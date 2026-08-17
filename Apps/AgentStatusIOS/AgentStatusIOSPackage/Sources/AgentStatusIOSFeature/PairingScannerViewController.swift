@preconcurrency import AVFoundation
import AgentStatusTransport
import UIKit

@MainActor
final class PairingScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onOffer: ((PairingOffer) -> Void)?
    private let captureSession = AVCaptureSession()
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .large)
    private var consumed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scan Mac pairing code"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Paste", style: .plain, target: self, action: #selector(pasteCode))
        configureOverlay()
        requestCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            Task.detached { [captureSession] in captureSession.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        Task { @MainActor in self.consume(value) }
    }

    func setBusy(_ busy: Bool) {
        busy ? activity.startAnimating() : activity.stopAnimating()
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        if !busy { consumed = false }
    }

    func show(error: Error) {
        statusLabel.text = "Pairing failed: \(error)"
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func pasteCode() {
        guard let value = UIPasteboard.general.string else {
            statusLabel.text = "Clipboard does not contain a pairing code."
            return
        }
        consume(value)
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                Task { @MainActor in
                    allowed ? self?.configureCapture() : self?.showCameraDenied()
                }
            }
        default: showCameraDenied()
        }
    }

    private func configureCapture() {
        do {
            guard let camera = AVCaptureDevice.default(for: .video) else { throw ScannerError.cameraUnavailable }
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureMetadataOutput()
            captureSession.beginConfiguration()
            guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
                captureSession.commitConfiguration()
                throw ScannerError.cameraUnavailable
            }
            captureSession.addInput(input)
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            captureSession.commitConfiguration()
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(previewLayer, at: 0)
            Task.detached { [captureSession] in captureSession.startRunning() }
        } catch {
            show(error: error)
        }
    }

    private func configureOverlay() {
        statusLabel.text = "Point the camera at the QR code in Agent Status on your Mac."
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.layer.cornerRadius = 12
        statusLabel.layer.masksToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        activity.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        view.addSubview(activity)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func consume(_ value: String) {
        guard !consumed else { return }
        do {
            let offer = try TransportCoding.makeDecoder().decode(PairingOffer.self, from: Data(value.utf8))
            consumed = true
            onOffer?(offer)
        } catch {
            statusLabel.text = "This is not a valid Agent Status pairing code."
        }
    }

    private func showCameraDenied() {
        statusLabel.text = "Camera access is unavailable. Use Paste after copying the pairing payload from your Mac."
    }
}

private enum ScannerError: Error {
    case cameraUnavailable
}
