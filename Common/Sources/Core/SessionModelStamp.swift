import Transport
import Foundation

/// The latest CLI-reported model identity of a session — the raw `model` id
/// (`claude-sonnet-4-5`, `gpt-5-codex`) and, when the CLI reported one, the
/// raw `reasoningEffort`. Values are shown as reported, unmapped; each field
/// resolves to the newest non-nil value across the session's
/// model-configuration items (the same rule as the Inspector's Model group).
public struct SessionModelStamp: Hashable, Sendable {
    public let model: String?
    public let reasoningEffort: String?

    public init(model: String? = nil, reasoningEffort: String? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public var isEmpty: Bool { model == nil && reasoningEffort == nil }

    /// Folds a newer configuration on top: reported fields win, unreported
    /// fields keep the value already known.
    public func updating(with payload: ModelConfigurationTimelinePayload) -> SessionModelStamp {
        SessionModelStamp(
            model: payload.model ?? model,
            reasoningEffort: payload.reasoningEffort ?? reasoningEffort
        )
    }
}
