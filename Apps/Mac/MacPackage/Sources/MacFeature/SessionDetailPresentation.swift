import Foundation

// Session detail presentation (metrics, Info groups, Activity rows, display
// names, time formatters) is shared with the iPhone in
// `Core/SessionPresentation.swift`. Only Mac-specific UI state
// remains here.

/// Activity timeline density: three lanes or one line.
enum ActivityTimelineMode: String, Equatable, Sendable {
    case lanes
    case single

    var toggled: ActivityTimelineMode { self == .lanes ? .single : .lanes }
}
