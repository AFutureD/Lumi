import CryptoKit
import Foundation

/// Claude Code on macOS keeps its sign-in in the login Keychain rather than
/// `~/.claude/.credentials.json`: a generic password whose service is
/// `Claude Code-credentials` (suffixed with a hash of `CLAUDE_CONFIG_DIR`
/// when that is set) and whose account is the user name (older items have
/// none). The value is the same JSON the file would hold, so it feeds
/// `ClaudeCredentials(fileData:)` unchanged.
///
/// Read through `/usr/bin/security`, not `SecItemCopyMatching`: Claude Code
/// writes the item with that same tool, which therefore sits in the item's
/// ACL — so the read never raises the Keychain prompt and never depends on
/// Lumen being allowed, whatever the user answered before. Claude Desktop's
/// own item (`Claude Safe Storage`) is deliberately not read.
public enum ClaudeKeychainCredentials {
    public static let baseService = "Claude Code-credentials"
    static let securityTool = "/usr/bin/security"
    /// `security`'s exit status for `errSecItemNotFound`.
    static let notFoundExitStatus: Int32 = 44

    public enum Outcome: Hashable, Sendable {
        case found(Data)
        case notFound
        /// `security` could not run, or answered with an error.
        case failed(String)
    }

    /// The services to try, most specific first: Claude Code hashes the
    /// config directory into the name so two homes never share a sign-in.
    public static func serviceCandidates(configDirectory: String?) -> [String] {
        guard let configDirectory, !configDirectory.isEmpty else { return [baseService] }
        let digest = SHA256.hash(data: Data(configDirectory.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return ["\(baseService)-\(suffix)", baseService]
    }

    /// The first item found across the services, trying the current user's
    /// account before the account-less legacy item.
    public static func read(services: [String], account: String = NSUserName()) -> Outcome {
        var lastFailure: Outcome?
        for service in services {
            for accountFilter in [account, nil] {
                switch read(service: service, account: accountFilter) {
                case let .found(data): return .found(data)
                case .notFound: continue
                case let failure: lastFailure = failure
                }
            }
        }
        return lastFailure ?? .notFound
    }

    static func read(service: String, account: String?) -> Outcome {
        var arguments = ["find-generic-password", "-s", service, "-w"]
        if let account { arguments.insert(contentsOf: ["-a", account], at: 1) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityTool)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failed("\(securityTool) could not be run: \(error.localizedDescription)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0:
            guard let data = decodeSecurityOutput(output) else { return .failed("the Keychain item is not readable text") }
            return .found(data)
        case notFoundExitStatus:
            return .notFound
        default:
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "security exited with status \(process.terminationStatus)" : message)
        }
    }

    /// `security -w` prints the value as text, or as hex when it holds
    /// bytes it will not print; either way the bytes are the credentials JSON.
    static func decodeSecurityOutput(_ output: Data) -> Data? {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "{" { return Data(text.utf8) }
        var hex = Substring(text)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = hex.dropFirst(2) }
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return Data(text.utf8) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
