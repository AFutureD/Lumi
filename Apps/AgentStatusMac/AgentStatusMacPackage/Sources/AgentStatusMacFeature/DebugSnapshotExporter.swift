import AppKit

/// Debug-only: when launched with `-AgentStatusSnapshotDirectory <dir>`, waits
/// for the UI to settle and writes a PNG of every visible window (main window,
/// Notch panel in list / detail / turn-complete routes) into `dir`, then
/// quits. Rendering goes through `NSView.cacheDisplay`, so it needs no
/// screen-recording permission — this is how design passes are verified
/// against the handoff screenshots.
@MainActor
enum DebugSnapshotExporter {
    static var directory: URL? {
        UserDefaults.standard.string(forKey: "AgentStatusSnapshotDirectory").map { URL(fileURLWithPath: $0) }
    }

    static func run(notch: AgentStatusNookController) {
        guard let directory else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(6))
            snapshotWindows(prefix: "01-main")
            notch.showNook()
            try? await Task.sleep(for: .seconds(2))
            snapshotWindows(prefix: "02-notch-list")
            if notch.debugShowDetailOfFirstSession() {
                try? await Task.sleep(for: .seconds(1))
                snapshotWindows(prefix: "03-notch-detail")
            }
            if notch.debugShowTurnEndedCardOfFirstSession() {
                try? await Task.sleep(for: .seconds(1))
                snapshotWindows(prefix: "04-notch-turn-ended")
            }
            if notch.debugShowTurnStartedCardOfFirstSession() {
                try? await Task.sleep(for: .seconds(1))
                snapshotWindows(prefix: "05-notch-turn-started")
            }
            NSApp.terminate(nil)
            // The coordinator's async shutdown can outlive a headless run; don't linger.
            try? await Task.sleep(for: .seconds(5))
            exit(0)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    private static func snapshotWindows(prefix: String) {
        guard let directory else { return }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0 else { continue }
            let name = "\(prefix)-\(index)-\(Int(view.bounds.width))x\(Int(view.bounds.height))"
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appendingPathComponent(name + "-cache.png"))
                }
            }
            // Scroll views composite through surfaces `cacheDisplay` cannot read:
            // render each document view on its own (visible part, up to 2000pt).
            for (scrollIndex, scrollView) in scrollViews(in: view).enumerated() {
                guard let document = scrollView.documentView else { continue }
                var rect = document.visibleRect
                rect.size.height = min(rect.height, 2000)
                guard rect.width > 0, rect.height > 0,
                      let rep = document.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                document.cacheDisplay(in: rect, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appendingPathComponent(name + "-scroll\(scrollIndex)-\(Int(rect.width))x\(Int(rect.height)).png"))
                }
            }
            // Layer-tree render: reaches layer-hosted content `cacheDisplay` skips.
            if let layer = view.layer {
                let scale = window.backingScaleFactor
                let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
                if let context = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    context.scaleBy(x: scale, y: scale)
                    if !view.isFlipped {
                        context.translateBy(x: 0, y: view.bounds.height)
                        context.scaleBy(x: 1, y: -1)
                    }
                    layer.render(in: context)
                    if let image = context.makeImage() {
                        let rep = NSBitmapImageRep(cgImage: image)
                        if let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent(name + "-layer.png"))
                        }
                    }
                }
            }
        }
    }
}
