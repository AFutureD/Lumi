@preconcurrency import AVFoundation
import AgentStatusDesignSystem
import AgentStatusRemote
import UIKit

/// Scan Code: full-screen camera with a 252pt viewfinder, caption and a
/// torch toggle. The first `lumi://pair?relay=…&code=…` QR is handed
/// to `onLink`; the Add Mac screen fills its two fields from it.
@MainActor
final class PairingScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onLink: ((PairingLink) -> Void)?

    private let captureSession = AVCaptureSession()
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    private let gradient = CAGradientLayer()
    private let dimLayer = CAShapeLayer()
    private let cornersLayer = CAShapeLayer()
    private let viewfinder = UIView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .large)
    private let torchButton = UIButton(type: .system)
    private var camera: AVCaptureDevice?
    private var consumed = false

    private let defaultCaption = "在 Mac 的 Lumi 里打开 Pair an iPhone，把二维码放进取景框。"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scan Code"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(IOSDS.Color.scannerBackground)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.tintColor = .white
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.design(IOSDS.Typography.sheetTitle)]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        gradient.colors = [UIColor(IOSDS.Color.scannerGradientStart).cgColor, UIColor(IOSDS.Color.scannerGradientEnd).cgColor]
        gradient.startPoint = CGPoint(x: 0.15, y: 0)
        gradient.endPoint = CGPoint(x: 0.85, y: 1)
        view.layer.addSublayer(gradient)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor(IOSDS.Color.scannerDim).cgColor
        view.layer.addSublayer(dimLayer)
        cornersLayer.strokeColor = UIColor.white.cgColor
        cornersLayer.fillColor = UIColor.clear.cgColor
        cornersLayer.lineWidth = IOSDS.Scanner.stroke
        cornersLayer.lineCap = .round
        view.layer.addSublayer(cornersLayer)

        let s = IOSDS.Scanner.self
        viewfinder.backgroundColor = UIColor(IOSDS.Color.scannerViewfinderFill)
        viewfinder.layer.cornerRadius = s.radius
        viewfinder.layer.cornerCurve = .continuous
        viewfinder.translatesAutoresizingMaskIntoConstraints = false
        activity.color = .white
        activity.translatesAutoresizingMaskIntoConstraints = false
        viewfinder.addSubview(activity)

        titleLabel.setText("对准 Mac 上的配对码", style: IOSDS.Typography.scannerTitle, color: .white)
        titleLabel.textAlignment = .center
        captionLabel.numberOfLines = 0
        captionLabel.textAlignment = .center
        setCaption(defaultCaption)
        let caption = UIStackView(arrangedSubviews: [titleLabel, captionLabel])
        caption.axis = .vertical
        caption.alignment = .center
        caption.spacing = s.captionLineGap
        caption.translatesAutoresizingMaskIntoConstraints = false

        var torch = UIButton.Configuration.plain()
        torch.image = UIImage(systemName: "flashlight.off.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        torch.title = "Torch"
        torch.imagePadding = s.torchGap
        torch.baseForegroundColor = .white
        torch.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: s.torchHorizontalPadding, bottom: 0, trailing: s.torchHorizontalPadding)
        torch.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.design(IOSDS.Typography.actionEmphasized)
            return attributes
        }
        torchButton.configuration = torch
        torchButton.backgroundColor = UIColor(IOSDS.Color.torchFill)
        torchButton.layer.cornerRadius = s.torchHeight / 2
        torchButton.clipsToBounds = true
        torchButton.translatesAutoresizingMaskIntoConstraints = false
        torchButton.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.isUserInteractionEnabled = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        torchButton.insertSubview(blur, at: 0)

        view.addSubview(viewfinder)
        view.addSubview(caption)
        view.addSubview(torchButton)
        NSLayoutConstraint.activate([
            viewfinder.widthAnchor.constraint(equalToConstant: s.viewfinder),
            viewfinder.heightAnchor.constraint(equalToConstant: s.viewfinder),
            viewfinder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            viewfinder.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -s.captionGap * 1.5),
            activity.centerXAnchor.constraint(equalTo: viewfinder.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: viewfinder.centerYAnchor),
            caption.topAnchor.constraint(equalTo: viewfinder.bottomAnchor, constant: s.captionGap),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: s.captionInset),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -s.captionInset),
            torchButton.heightAnchor.constraint(equalToConstant: s.torchHeight),
            torchButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            torchButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -s.torchBottom),
            blur.topAnchor.constraint(equalTo: torchButton.topAnchor),
            blur.bottomAnchor.constraint(equalTo: torchButton.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: torchButton.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: torchButton.trailingAnchor),
        ])
        requestCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = view.bounds
        previewLayer.frame = view.bounds
        let s = IOSDS.Scanner.self
        let frame = viewfinder.frame
        let cutout = UIBezierPath(roundedRect: frame, cornerRadius: s.radius)
        let dim = UIBezierPath(rect: view.bounds)
        dim.append(cutout)
        dimLayer.path = dim.cgPath
        cornersLayer.path = Self.cornerMarks(in: frame, radius: s.radius, arm: s.corner).cgPath
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            Task.detached { [captureSession] in captureSession.stopRunning() }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - State

    func setBusy(_ busy: Bool) {
        busy ? activity.startAnimating() : activity.stopAnimating()
        if busy { setCaption("Pairing…") } else { consumed = false }
    }

    func show(error: Error) {
        setCaption(error.localizedDescription)
    }

    private func setCaption(_ text: String) {
        captionLabel.setText(text, style: IOSDS.Typography.caption, color: UIColor(IOSDS.Color.scannerCaption))
        captionLabel.textAlignment = .center
    }

    // MARK: - Camera

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        Task { @MainActor in self.consume(value) }
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
            self.camera = camera
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
            torchButton.isHidden = !camera.hasTorch
            Task.detached { [captureSession] in captureSession.startRunning() }
        } catch {
            torchButton.isHidden = true
            show(error: error)
        }
    }

    private func consume(_ value: String) {
        guard !consumed else { return }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = PairingLink(url: url, allowInsecureLocalhost: AddMacViewController.allowsInsecureLocalhost) else {
            setCaption("这不是 Lumi 的配对码。")
            return
        }
        consumed = true
        onLink?(link)
    }

    private func showCameraDenied() {
        torchButton.isHidden = true
        setCaption("相机不可用。在 iOS 设置里允许 Lumi 使用相机后重试。")
    }

    @objc private func toggleTorch() {
        guard let camera, camera.hasTorch else { return }
        do {
            try camera.lockForConfiguration()
            camera.torchMode = camera.torchMode == .on ? .off : .on
            camera.unlockForConfiguration()
            let name = camera.torchMode == .on ? "flashlight.on.fill" : "flashlight.off.fill"
            torchButton.configuration?.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        } catch {
            show(error: error)
        }
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    /// Four L-shaped marks following the viewfinder's rounded corners.
    private static func cornerMarks(in rect: CGRect, radius: CGFloat, arm: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let straight = arm - radius
        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + radius + straight, y: rect.minY))
        // Top-right
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: 1.5 * .pi, endAngle: 2 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius + straight))
        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(withCenter: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 0, endAngle: 0.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX - radius - straight, y: rect.maxY))
        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(withCenter: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius - straight))
        return path
    }
}

private enum ScannerError: LocalizedError {
    case cameraUnavailable

    var errorDescription: String? { "相机不可用。" }
}
