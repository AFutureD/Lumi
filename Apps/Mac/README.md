# Agent Status for macOS

The macOS client targets macOS 15. Its Mail-style main window is AppKit; its OpenNook surface and the Notch settings detail are SwiftUI hosted inside the same application. UI and controller logic live in `MacPackage`; the Xcode app target is only the application shell and packaging configuration.

Open `Lumi.xcworkspace` at the repository root. A Release build embeds Universal 2 copies of Lumen and Spark and registers the daemon as a per-user LaunchAgent through `SMAppService`.

OpenNook is resolved from `https://github.com/twinkling-reality/opennook.git` at the revision pinned in `MacPackage/Package.resolved`.
