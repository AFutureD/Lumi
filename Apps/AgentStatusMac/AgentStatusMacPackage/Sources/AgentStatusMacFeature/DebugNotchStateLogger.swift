import Combine
import Foundation
import NookApp

/// Debug-only: when launched with `-AgentStatusNotchStateLog <path>`, appends a
/// timestamped line for every Notch surface visibility flip and every turn
/// event the controller acts on. This is how expand/collapse behavior is
/// verified headlessly — the Notch window is a fixed full-width panel, so
/// window geometry alone cannot show whether the chrome is expanded.
@MainActor
final class DebugNotchStateLogger {
    private let url: URL
    private var cancellables: Set<AnyCancellable> = []

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init?(appState: AppState) {
        guard let path = UserDefaults.standard.string(forKey: "AgentStatusNotchStateLog") else { return nil }
        url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
        appState.$isNookVisible
            .removeDuplicates()
            .sink { [weak self] visible in self?.log("visible=\(visible)") }
            .store(in: &cancellables)
    }

    func log(_ message: String) {
        let line = "\(Self.timestamp.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
