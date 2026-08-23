import AgentStatusRemote
import Foundation

/// Where the daemon keeps its Relay host registration (host id, host secret,
/// key pair). The production store is the login Keychain; the item is created
/// by the daemon itself so the daemon is in the item's ACL and later reads
/// never prompt.
public protocol RelayHostCredentialStoring: Sendable {
    func load() throws -> RelayHostCredentials?
    func save(_ credentials: RelayHostCredentials) throws
}

public struct KeychainRelayHostCredentialStore: RelayHostCredentialStoring {
    public static let defaultService = "app.huanan.lumi.daemon.relay"
    public static let defaultAccount = "host-credentials-v2"

    private let store: SecureStore
    private let account: String

    public init(service: String = defaultService, account: String = defaultAccount) {
        store = SecureStore(service: service)
        self.account = account
    }

    public func load() throws -> RelayHostCredentials? {
        try store.load(RelayHostCredentials.self, account: account)
    }

    public func save(_ credentials: RelayHostCredentials) throws {
        try store.save(credentials, account: account)
    }
}

/// Tests and smoke runs: credentials live only in this process.
public final class InMemoryRelayHostCredentialStore: RelayHostCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: RelayHostCredentials?

    public init(credentials: RelayHostCredentials? = nil) {
        self.credentials = credentials
    }

    public func load() throws -> RelayHostCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }

    public func save(_ credentials: RelayHostCredentials) throws {
        lock.lock()
        self.credentials = credentials
        lock.unlock()
    }
}
