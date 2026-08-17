# Agent Status for iOS

The iOS client is a UIKit application targeting iOS 18. Its UI and controller logic live in `AgentStatusIOSPackage`; the Xcode app target supplies the application delegate, signing, entitlements, and generated Info.plist settings.

Open `AgentStatus.xcworkspace` at the repository root. The client stores pairing credentials in Keychain but keeps received Session data in memory only.

The project intentionally does not use SwiftUI.
