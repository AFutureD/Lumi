import Remote
import Foundation

enum RelayBuildConfiguration {
    static let url: URL = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "LumiRelayURL") as? String,
           let url = URL(string: value),
           url.scheme == "https" {
            return url
        }
        // SwiftPM tests do not run inside the application bundle. The shipped
        // app overrides this fallback through LUMI_RELAY_URL.
        return URL(string: "https://relay.lumi.huanan.app")!
    }()

    /// Which APNs endpoint this build's push tokens belong to. Debug builds
    /// carry the `development` aps-environment entitlement (sandbox); App
    /// Store re-signing flips it to `production` — this mirrors that flip.
    static let apnsEnvironment: RelayPushEnvironment = {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }()
}
