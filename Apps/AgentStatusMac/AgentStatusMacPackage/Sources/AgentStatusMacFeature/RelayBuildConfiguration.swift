import Foundation

enum RelayBuildConfiguration {
    static let url: URL = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "AgentStatusRelayURL") as? String,
           let url = URL(string: value),
           url.scheme == "https" {
            return url
        }
        // SwiftPM tests do not run inside the application bundle. The shipped
        // app overrides this fallback through AGENT_STATUS_RELAY_URL.
        return URL(string: "https://agent-status-relay.afuture.workers.dev")!
    }()
}
