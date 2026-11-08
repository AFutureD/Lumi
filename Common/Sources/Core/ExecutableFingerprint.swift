import CryptoKit
import Foundation

/// Content fingerprint of an executable, used to detect a running daemon whose
/// on-disk binary has since been replaced by an app update. Both sides hash the
/// same file (the daemon runs in place from the app bundle), so equal hashes
/// mean the running process is the current build.
public enum ExecutableFingerprint {
    public static func sha256Hex(fileAt url: URL) throws -> String {
        try Data(contentsOf: url, options: .mappedIfSafe).sha256Hex
    }

    /// The running process's executable with symlinks resolved: the file the
    /// fingerprint hashes, and the path the daemon reports as its identity.
    public static func currentExecutableURL() throws -> URL {
        guard let executable = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable.resolvingSymlinksInPath()
    }

    public static func currentExecutable() throws -> String {
        try sha256Hex(fileAt: currentExecutableURL())
    }
}

public extension Data {
    /// Lowercase hex SHA-256 of the bytes.
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
