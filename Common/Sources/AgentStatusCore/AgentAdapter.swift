import AgentStatusTransport
import Foundation

public struct RolloutRecordContext: Hashable, Sendable {
    public let path: String
    public let byteOffset: UInt64
    public let sessionID: SessionID?

    public init(path: String, byteOffset: UInt64, sessionID: SessionID? = nil) {
        self.path = path
        self.byteOffset = byteOffset
        self.sessionID = sessionID
    }
}

public protocol AgentAdapter: Sendable {
    var agentKind: AgentKind { get }

    func events(fromHookData data: Data) throws -> [AgentIngressEvent]
    func events(fromRolloutLine data: Data, context: RolloutRecordContext) throws -> [AgentIngressEvent]
}

public enum AgentAdapterError: Error, Equatable, Sendable {
    case malformedJSON
    case missingSessionID
    case unsupportedEvent(String)
}
