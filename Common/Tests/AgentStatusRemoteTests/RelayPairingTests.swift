import AgentStatusRemote
import AgentStatusTransport
import Foundation
import Testing

@Test func pairingCodesNormaliseWhatPeopleType() {
    #expect(PairingCode.normalize("7KF 3QP") == "7KF3QP")
    #expect(PairingCode.normalize("7kf-3qp") == "7KF3QP")
    #expect(PairingCode.normalize(" 7KF3QP\n") == "7KF3QP")
    // Look-alikes the alphabet left out map to their digit / letter.
    #expect(PairingCode.normalize("oil u2x") == "011V2X")
    #expect(PairingCode.normalize("OIL-U2X") == "011V2X")
    // Wrong length or characters outside the alphabet: not a code.
    #expect(PairingCode.normalize("7KF3Q") == nil)
    #expect(PairingCode.normalize("7KF3QPX") == nil)
    #expect(PairingCode.normalize("7KF3Q?") == nil)
    #expect(PairingCode.normalize("") == nil)
    #expect(PairingCode.alphabet.count == 32)
    for excluded in ["I", "L", "O", "U"] {
        #expect(!PairingCode.alphabet.contains(Character(excluded)))
    }
    #expect(PairingCode.display("7KF3QP") == "7KF 3QP")
    // While typing / after a paste: keep what fits, drop the rest.
    #expect(PairingCode.sanitize("7k") == "7K")
    #expect(PairingCode.sanitize("7KF-3QP-XYZ") == "7KF3QP")
    #expect(PairingCode.sanitize("o?i!") == "01")
    #expect(PairingCode.sanitize("") == "")
}

@Test func relayURLsAreHTTPSHostsOnly() {
    #expect(RelayURLValidation.normalize("https://Agent-Status-Relay.afuture.workers.dev/")?.absoluteString == "https://agent-status-relay.afuture.workers.dev")
    #expect(RelayURLValidation.normalize("  https://relay.example.com  ")?.absoluteString == "https://relay.example.com")
    #expect(RelayURLValidation.normalize("https://relay.example.com/base/")?.absoluteString == "https://relay.example.com/base")
    #expect(RelayURLValidation.normalize("http://relay.example.com") == nil)
    #expect(RelayURLValidation.normalize("https://user:pw@relay.example.com") == nil)
    #expect(RelayURLValidation.normalize("https://relay.example.com/?x=1") == nil)
    #expect(RelayURLValidation.normalize("https://relay.example.com/#frag") == nil)
    #expect(RelayURLValidation.normalize("relay.example.com") == nil)
    #expect(RelayURLValidation.normalize("https://") == nil)
    #expect(RelayURLValidation.normalize("https://" + String(repeating: "a", count: 260) + ".com") == nil)
    // `wrangler dev` only when the build says so.
    #expect(RelayURLValidation.normalize("http://localhost:8787") == nil)
    #expect(RelayURLValidation.normalize("http://localhost:8787", allowInsecureLocalhost: true)?.absoluteString == "http://localhost:8787")
    #expect(RelayURLValidation.normalize("http://127.0.0.1:8787", allowInsecureLocalhost: true)?.absoluteString == "http://127.0.0.1:8787")
    #expect(RelayURLValidation.normalize("http://evil.example.com", allowInsecureLocalhost: true) == nil)
    #expect(RelayURLValidation.displayHost(URL(string: "https://agent-status-relay.afuture.workers.dev")!) == "agent-status-relay.afuture.workers.dev")
}

@Test func pairingLinksRoundTripAndRejectStrangers() throws {
    let relay = URL(string: "https://agent-status-relay.afuture.workers.dev")!
    let link = PairingLink(relayURL: relay, code: "7KF3QP")
    let url = link.url
    #expect(url.scheme == "lumi")
    #expect(url.host == "pair")
    #expect(url.absoluteString == "lumi://pair?relay=https%3A%2F%2Fagent%2Dstatus%2Drelay%2Eafuture%2Eworkers%2Edev&code=7KF3QP")
    #expect(PairingLink(url: url) == link)

    // What a person might paste: un-encoded relay, lowercase code, hyphen.
    let loose = try #require(URL(string: "lumi://pair?relay=https://relay.example.com/&code=7kf-3qp"))
    #expect(PairingLink(url: loose) == PairingLink(relayURL: URL(string: "https://relay.example.com")!, code: "7KF3QP"))

    // Not ours / incomplete / insecure relay.
    #expect(PairingLink(url: URL(string: "https://example.com/pair?relay=https://r.example.com&code=7KF3QP")!) == nil)
    #expect(PairingLink(url: URL(string: "lumi://other?relay=https://r.example.com&code=7KF3QP")!) == nil)
    #expect(PairingLink(url: URL(string: "lumi://pair?code=7KF3QP")!) == nil)
    #expect(PairingLink(url: URL(string: "lumi://pair?relay=https://r.example.com")!) == nil)
    #expect(PairingLink(url: URL(string: "lumi://pair?relay=http://r.example.com&code=7KF3QP")!) == nil)
    #expect(PairingLink(url: URL(string: "lumi://pair?relay=https://r.example.com&code=7KF3Q")!) == nil)
}
