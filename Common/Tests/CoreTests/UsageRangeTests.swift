import Core
import Transport
import Foundation
import Testing

/// Gregorian UTC with Sunday as the locale's first weekday — the Usage
/// presets must still start weeks on Monday.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()

/// Saturday 2026-09-05 14:00 UTC.
private let now = Date(timeIntervalSince1970: 1_788_616_800)

@Test func presetsFollowTheCalendarWithMondayWeeks() {
    let today = UsageDay(year: 2026, month: 9, day: 5)
    #expect(UsageRange.preset(.today, now: now, calendar: utc) == UsageRange(kind: .today, since: today, until: today))
    #expect(UsageRange.preset(.thisWeek, now: now, calendar: utc) == UsageRange(kind: .thisWeek, since: UsageDay(year: 2026, month: 8, day: 31), until: today))
    #expect(UsageRange.preset(.thisMonth, now: now, calendar: utc) == UsageRange(kind: .thisMonth, since: UsageDay(year: 2026, month: 9, day: 1), until: today))
    // A Monday's week is itself; a Sunday's week started six days earlier.
    let monday = Date(timeIntervalSince1970: 1_788_616_800 + 2 * 86_400)
    #expect(UsageRange.preset(.thisWeek, now: monday, calendar: utc).since == UsageDay(year: 2026, month: 9, day: 7))
    let sunday = Date(timeIntervalSince1970: 1_788_616_800 + 86_400)
    #expect(UsageRange.preset(.thisWeek, now: sunday, calendar: utc).since == UsageDay(year: 2026, month: 8, day: 31))
}

@Test func customRangesAreClampedToTodayAndOrdered() {
    let today = UsageDay(year: 2026, month: 9, day: 5)
    let future = UsageDay(year: 2026, month: 12, day: 31)
    let past = UsageDay(year: 2026, month: 8, day: 1)
    #expect(UsageRange.custom(since: past, until: future, now: now, calendar: utc) == UsageRange(kind: .custom, since: past, until: today))
    #expect(UsageRange.custom(since: today, until: past, now: now, calendar: utc) == UsageRange(kind: .custom, since: past, until: past))
    #expect(UsageRange.custom(since: future, until: future, now: now, calendar: utc) == UsageRange(kind: .custom, since: today, until: today))
}

@Test func comparisonPeriodsMatchTheRangeKind() {
    let today = UsageDay(year: 2026, month: 9, day: 5)
    // Today → yesterday.
    let day = UsageRange.preset(.today, now: now, calendar: utc)
    #expect(day.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 9, day: 4), until: UsageDay(year: 2026, month: 9, day: 4)))
    #expect(day.comparisonLabel(calendar: utc) == "yesterday")
    // This week (Mon 31 – Sat 5) → the same days last week.
    let week = UsageRange.preset(.thisWeek, now: now, calendar: utc)
    #expect(week.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 8, day: 24), until: UsageDay(year: 2026, month: 8, day: 29)))
    #expect(week.comparisonLabel(calendar: utc) == "last week")
    // This month (Sep 1 – 5) → Aug 1 – 5.
    let month = UsageRange.preset(.thisMonth, now: now, calendar: utc)
    #expect(month.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 8, day: 1), until: UsageDay(year: 2026, month: 8, day: 5)))
    #expect(month.comparisonLabel(calendar: utc) == "last month")
    // A whole 31-day month compared with a 30-day one stops at its end.
    let october = UsageRange(kind: .thisMonth, since: UsageDay(year: 2026, month: 10, day: 1), until: UsageDay(year: 2026, month: 10, day: 31))
    #expect(october.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 9, day: 1), until: UsageDay(year: 2026, month: 9, day: 30)))
    // Custom N days → the N days before.
    let custom = UsageRange.custom(since: UsageDay(year: 2026, month: 8, day: 7), until: today, now: now, calendar: utc)
    #expect(custom.dayCount(calendar: utc) == 30)
    #expect(custom.comparison(calendar: utc) == UsageRange(kind: .custom, since: UsageDay(year: 2026, month: 7, day: 8), until: UsageDay(year: 2026, month: 8, day: 6)))
    #expect(custom.comparisonLabel(calendar: utc) == "previous 30 days")
    let single = UsageRange.custom(since: today, until: today, now: now, calendar: utc)
    #expect(single.comparisonLabel(calendar: utc) == "previous day")
}
