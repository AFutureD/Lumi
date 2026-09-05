import Foundation

/// Gregorian UTC with Sunday as the locale's first weekday — the Usage
/// presets must still start weeks on Monday.
let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()
