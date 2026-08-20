import CryptoKit
import Foundation

/// Content fingerprint of an executable, used to detect a running daemon whose
/// on-disk binary has since been replaced by an app update. Both sides hash the
/// same file (the daemon runs in place from the app bundle), so equal hashes
/// mean the running process is the current build.
public enum ExecutableFingerprint {
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func currentExecutable() throws -> String {
        guard let executable = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try sha256Hex(fileAt: executable.resolvingSymlinksInPath())
    }
}
