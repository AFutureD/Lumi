import Foundation

/// Pacing for the daemon event stream's reconnects. The first retry is quick
/// — a daemon restart drops the stream for well under a second — and the
/// series doubles up to a 30 s ceiling, so a daemon that is gone for the day
/// costs the log a line every half minute instead of every two seconds. A
/// health frame ends the series.
struct DaemonReconnectBackoff: Equatable {
    static let initialDelay: Duration = .seconds(2)
    static let maximumDelay: Duration = .seconds(30)
    /// Disconnects logged at warning before the series goes quiet (debug).
    /// The transition itself is announced once, at warning.
    static let loudDisconnects = 3

    /// Consecutive disconnects since the daemon last answered.
    private(set) var consecutiveFailures = 0

    /// The wait before the next attempt, for the disconnect just recorded.
    var delay: Duration {
        let doublings = max(0, consecutiveFailures - 1)
        // Capped before shifting so a long outage never overflows.
        guard doublings < 4 else { return Self.maximumDelay }
        return min(Self.initialDelay * (1 << doublings), Self.maximumDelay)
    }

    /// Whether this disconnect still earns a warning line of its own.
    var isLoud: Bool { consecutiveFailures <= Self.loudDisconnects }

    /// True exactly once per outage: the disconnect that takes the log quiet.
    var isGoingQuiet: Bool { consecutiveFailures == Self.loudDisconnects + 1 }

    mutating func recordDisconnect() {
        consecutiveFailures += 1
    }

    /// The daemon answered: the next outage starts the series over.
    /// Returns how many attempts the outage took, `0` when there was none.
    @discardableResult
    mutating func recordConnected() -> Int {
        defer { consecutiveFailures = 0 }
        return consecutiveFailures
    }
}
