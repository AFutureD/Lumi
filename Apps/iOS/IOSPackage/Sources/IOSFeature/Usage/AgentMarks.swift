import DesignSystem
import Transport
import os
import UIKit

private let log = os.Logger(subsystem: "app.huanan.lumi", category: "usage.marks")

/// The Claude Code / Codex brand marks for the Plan cards, drawn the way the
/// Mac's `AgentIcons.image` draws them: the mark on a white rounded tile
/// with a hairline ring, the Claude mark set deeper in its tile than the
/// Codex one (as the two brands draw them).
///
/// The SVGs in `Resources/AgentMarks.xcassets` are copies of
/// `Apps/Mac/MacPackage/Sources/MacFeature/Resources/{claude,codex}.svg` —
/// UIKit cannot decode an SVG file directly, so the iPhone goes through an
/// asset catalog (`preserves-vector-representation`). Keep the two in step.
enum AgentMarks {
    static func image(for provider: AgentProvider, pointSize: CGFloat) -> UIImage {
        let size = CGSize(width: pointSize, height: pointSize)
        let radius = pointSize * 0.28
        let inset = pointSize * (provider == .claude ? 0.18 : 0.1)
        let source = mark(for: provider)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            let tile = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            UIColor.white.setFill()
            tile.fill()
            if let source {
                source.draw(in: rect.insetBy(dx: inset, dy: inset))
            } else {
                let symbol = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize - 2, weight: .medium))
                symbol?.withTintColor(.inkSecondary).draw(in: rect.insetBy(dx: inset, dy: inset))
            }
            let ring = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius)
            ring.lineWidth = 1
            UIColor(IOSDS.Color.rowSeparator).setStroke()
            ring.stroke()
            _ = context
        }.withRenderingMode(.alwaysOriginal)
    }

    private static func mark(for provider: AgentProvider) -> UIImage? {
        let name = provider == .claude ? "claude" : "codex"
        guard let image = UIImage(named: name, in: Bundle.module, compatibleWith: nil) else {
            log.error("agent_mark_missing provider=\(name, privacy: .public)")
            return nil
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
