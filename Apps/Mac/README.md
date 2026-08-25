# Lumi for macOS

The macOS client targets macOS 26. Its Mail-style main window is AppKit; its OpenNook surface and the Notch settings detail are SwiftUI hosted inside the same application. UI and controller logic live in `MacPackage`; the Xcode app target is only the application shell and packaging configuration.

Open `Lumi.xcworkspace` at the repository root. A Release build embeds arm64 copies of Lumen and Spark and registers the daemon as a per-user LaunchAgent through `SMAppService`.

Sparkle 2.9.6 provides the Stable update channel. The App menu and Settings > About share one updater; Settings > General controls automatic checks. Updates use a signed GitHub Release appcast and a Developer ID signed, notarized DMG.

OpenNook and Sparkle are resolved at the revisions pinned in `MacPackage/Package.resolved`.
