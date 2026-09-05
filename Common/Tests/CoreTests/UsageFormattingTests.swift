import Transport
import Foundation
import Testing
@testable import Core

@Test func usageCostFormatsDollarsAndTheSubCentCase() {
    #expect(UsageFormatting.cost(nil) == "—")
    #expect(UsageFormatting.cost(0) == "$0.00")
    #expect(UsageFormatting.cost(0.004) == "<$0.01")
    #expect(UsageFormatting.cost(0.005) == "$0.01")
    #expect(UsageFormatting.cost(1.234) == "$1.23")
    #expect(UsageFormatting.cost(1234.5) == "$1,234.50")
    #expect(UsageFormatting.cost(98.372076) == "$98.37")
}

@Test func usageTokensUseTheDesignsCompactUnits() {
    #expect(UsageFormatting.tokens(0) == "0")
    #expect(UsageFormatting.tokens(804) == "804")
    #expect(UsageFormatting.tokens(999) == "999")
    #expect(UsageFormatting.tokens(1_000) == "1.0K")
    #expect(UsageFormatting.tokens(12_345) == "12.3K")
    #expect(UsageFormatting.tokens(12_400) == "12.4K")
    #expect(UsageFormatting.tokens(804_000) == "804.0K")
    #expect(UsageFormatting.tokens(999_950) == "1.0M")
    #expect(UsageFormatting.tokens(1_200_000) == "1.2M")
    #expect(UsageFormatting.tokens(795_300_000) == "795.3M")
    #expect(UsageFormatting.tokens(1_100_000_000) == "1.10B")
    #expect(UsageFormatting.tokens(19_900_000_000) == "19.90B")
    #expect(UsageFormatting.exactTokens(41_791_377) == "41,791,377")
    #expect(UsageFormatting.count(1_704) == "1,704")
}

@Test func usageDeltaComparesAgainstThePreviousPeriod() {
    #expect(UsageFormatting.delta(current: 112, previous: 100, against: "yesterday") == "↑ 12% vs yesterday")
    #expect(UsageFormatting.delta(current: 75, previous: 100, against: "last week") == "↓ 25% vs last week")
    #expect(UsageFormatting.delta(current: 100, previous: 100, against: "last month") == "↑ 0% vs last month")
    #expect(UsageFormatting.delta(current: 5, previous: 0, against: "previous 30 days") == "no comparable previous period")
    #expect(UsageFormatting.delta(current: nil, previous: 3, against: "yesterday") == "no comparable previous period")
    #expect(UsageFormatting.delta(current: 5, previous: nil, against: "yesterday") == "no comparable previous period")
}

@Test func usageDateLabelsFollowTheDesign() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let saturday = UsageDay(year: 2026, month: 9, day: 5)
    #expect(UsageFormatting.weekday(saturday, calendar: calendar) == "Sat")
    #expect(UsageFormatting.dayLabel(saturday, calendar: calendar) == "Sat, Sep 5")
    #expect(UsageFormatting.monthDay(UsageDay(year: 2026, month: 8, day: 7)) == "8/7")
    #expect(saturday.startOfWeek(in: calendar) == UsageDay(year: 2026, month: 8, day: 31))
    #expect(UsageDay(year: 2026, month: 8, day: 31).startOfWeek(in: calendar) == UsageDay(year: 2026, month: 8, day: 31))
    #expect(UsageDay(year: 2026, month: 9, day: 6).startOfWeek(in: calendar) == UsageDay(year: 2026, month: 8, day: 31))
    #expect(UsageFormatting.weekLabel(UsageDay(year: 2026, month: 8, day: 31), calendar: calendar) == "Aug 31 – Sep 6")
    #expect(UsageFormatting.monthLabel(saturday) == "September 2026")
    #expect(saturday.endOfMonth(in: calendar) == UsageDay(year: 2026, month: 9, day: 30))
    #expect(UsageFormatting.hourLabel(9) == "09:00")
    #expect(UsageFormatting.periodLabel(UsagePeriod(unit: .hour, start: saturday, hour: 9), calendar: calendar) == "9/5 09:00")
    #expect(UsageFormatting.periodLabel(UsagePeriod(unit: .week, start: UsageDay(year: 2026, month: 8, day: 31)), calendar: calendar) == "Aug 31 – Sep 6")
    #expect(UsageFormatting.periodLabel(UsagePeriod(unit: .month, start: saturday), calendar: calendar) == "September 2026")
    #expect(UsagePeriod(unit: .week, start: UsageDay(year: 2026, month: 8, day: 31)).end(in: calendar) == UsageDay(year: 2026, month: 9, day: 6))
    #expect(UsagePeriod(unit: .month, start: saturday, hour: nil).end(in: calendar) == UsageDay(year: 2026, month: 9, day: 30))
}

@Test func usageProjectNamesComeFromTheLastPathComponent() {
    #expect(UsageFormatting.projectName("/Users/me/Developer/lumi") == "lumi")
    #expect(UsageFormatting.projectName("/Users/me/Developer/lumi/") == "lumi")
    #expect(UsageFormatting.projectName("") == "Unknown project")
    #expect(UsageFormatting.projectName("/") == "/")
    #expect(UsageFormatting.projectPath("/Users/me/Developer/lumi", home: "/Users/me") == "~/Developer/lumi")
    #expect(UsageFormatting.projectPath("", home: "/Users/me") == nil)
}

@Test func usagePercentKeepsOneDecimalAndMarksSliversAndNothing() {
    #expect(UsageFormatting.percent(0, of: 0) == "—")
    #expect(UsageFormatting.percent(0, of: 100) == "0.0%")
    #expect(UsageFormatting.percent(1, of: 10_000) == "<0.1%")
    #expect(UsageFormatting.percent(5, of: 1_000) == "0.5%")
    #expect(UsageFormatting.percent(834, of: 1_000) == "83.4%")
    #expect(UsageFormatting.percent(886, of: 1_000) == "88.6%")
    #expect(UsageFormatting.percent(1_000, of: 1_000) == "100.0%")
    #expect(UsageFormatting.cacheRatio(UsageTokens(input: 100, cacheRead: 800, cacheWrite5m: 50, cacheWrite1h: 0, output: 50)) == "80.0%")
}
