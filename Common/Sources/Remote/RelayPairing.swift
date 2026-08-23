import Transport
import Foundation

/// The six-character pairing code a person reads off the Mac and types on
/// the iPhone: Crockford Base32 (no `I`, `L`, `O`, `U`), 30 bits. The Relay
/// generates it; both ends normalise what people type the same way.
public enum PairingCode {
    public static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 6

    /// Uppercases, drops spaces and hyphens, maps the look-alikes the
    /// alphabet left out (`O→0`, `I→1`, `L→1`, `U→V`); `nil` unless the
    /// result is exactly six alphabet characters.
    public static func normalize(_ input: String) -> String? {
        let output = sanitize(input, limit: nil)
        guard output.count == length, output.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return output
    }

    /// What a code field keeps while a person is still typing or just pasted:
    /// the same mapping as `normalize`, characters outside the alphabet
    /// dropped, cut to `limit` (the six cells).
    public static func sanitize(_ input: String, limit: Int? = length) -> String {
        var output = ""
        for character in input.uppercased() {
            if let limit, output.count >= limit { break }
            if character.isWhitespace || character.isNewline { continue }
            switch character {
            case "-", "\u{2011}", "\u{2013}", "\u{2014}": continue
            case "O": output.append("0")
            case "I", "L": output.append("1")
            case "U": output.append("V")
            default:
                if limit == nil || alphabet.contains(character) { output.append(character) }
            }
        }
        return output
    }

    /// `7KF3QP` → `7KF 3QP`.
    public static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        let half = code.index(code.startIndex, offsetBy: length / 2)
        return "\(code[..<half]) \(code[half...])"
    }

    /// `482913` → `482 913` (the SAS uses the same split).
    public static func displaySAS(_ sas: String) -> String { display(sas) }
}

/// Relay URLs people type or scan: `https` only (plus `http://localhost` /
/// `http://127.0.0.1` in DEBUG builds for `wrangler dev`), a host, nothing
/// else — no credentials, query or fragment; host lowercased, trailing `/`
/// dropped, ≤ 256 characters.
public enum RelayURLValidation {
    public static let maximumLength = 256

    public static func normalize(_ input: String, allowInsecureLocalhost: Bool = false) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        switch scheme {
        case "https":
            break
        case "http":
            guard allowInsecureLocalhost, host == "localhost" || host == "127.0.0.1" else { return nil }
        default:
            return nil
        }
        components.scheme = scheme
        components.host = host
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    /// What the screens show for a Relay: its host (`relay.lumi.huanan.app`).
    public static func displayHost(_ url: URL) -> String {
        url.host ?? url.absoluteString
    }
}

/// What the Mac's QR code carries and what the system camera hands the app:
/// `lumi://pair?relay=<https URL>&code=<6 chars>`. Nothing secret
/// beyond the code itself — the link only fills two fields for the person.
public struct PairingLink: Hashable, Sendable {
    public static let scheme = "lumi"
    public static let host = "pair"

    public let relayURL: URL
    public let code: String

    public init(relayURL: URL, code: String) {
        self.relayURL = relayURL
        self.code = code
    }

    /// Parses a scanned or opened URL; the Relay URL is validated and the
    /// code normalised, so a `nil` means "not a Lumi pairing link".
    public init?(url: URL, allowInsecureLocalhost: Bool = false) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let relay = items.first(where: { $0.name == "relay" })?.value,
              let rawCode = items.first(where: { $0.name == "code" })?.value,
              let relayURL = RelayURLValidation.normalize(relay, allowInsecureLocalhost: allowInsecureLocalhost),
              let code = PairingCode.normalize(rawCode) else { return nil }
        self.relayURL = relayURL
        self.code = code
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "relay", value: relayURL.absoluteString),
            URLQueryItem(name: "code", value: code),
        ]
        // The link goes into a QR code and a system URL handler: the Relay
        // URL is percent-encoded in full so `://` and `/` never confuse either.
        components.percentEncodedQuery = "relay=\(Self.percentEncode(relayURL.absoluteString))&code=\(code)"
        return components.url!
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
