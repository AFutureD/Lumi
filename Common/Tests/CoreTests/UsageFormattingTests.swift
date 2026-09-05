import Transport
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

@Test func usageTokensKeepThreeSignificantFigures() {
    #expect(UsageFormatting.tokens(0) == "0")
    #expect(UsageFormatting.tokens(804) == "804")
    #expect(UsageFormatting.tokens(999) == "999")
    #expect(UsageFormatting.tokens(1_000) == "1.00K")
    #expect(UsageFormatting.tokens(9_994) == "9.99K")
    #expect(UsageFormatting.tokens(12_345) == "12.3K")
    #expect(UsageFormatting.tokens(804_000) == "804K")
    #expect(UsageFormatting.tokens(999_950) == "1.00M")
    #expect(UsageFormatting.tokens(1_200_000) == "1.20M")
    #expect(UsageFormatting.tokens(41_791_377) == "41.8M")
    #expect(UsageFormatting.tokens(19_900_000_000) == "19.9B")
    #expect(UsageFormatting.exactTokens(41_791_377) == "41,791,377")
    #expect(UsageFormatting.count(1_704) == "1,704")
}

@Test func usageProjectNamesComeFromTheLastPathComponent() {
    #expect(UsageFormatting.projectName("/Users/me/Developer/lumi") == "lumi")
    #expect(UsageFormatting.projectName("/Users/me/Developer/lumi/") == "lumi")
    #expect(UsageFormatting.projectName("") == "Unknown project")
    #expect(UsageFormatting.projectName("/") == "/")
    #expect(UsageFormatting.projectPath("/Users/me/Developer/lumi", home: "/Users/me") == "~/Developer/lumi")
    #expect(UsageFormatting.projectPath("", home: "/Users/me") == nil)
}

@Test func usagePercentRoundsAndMarksSliversAndNothing() {
    #expect(UsageFormatting.percent(0, of: 0) == "—")
    #expect(UsageFormatting.percent(0, of: 100) == "0%")
    #expect(UsageFormatting.percent(1, of: 1_000) == "<1%")
    #expect(UsageFormatting.percent(5, of: 1_000) == "1%")
    #expect(UsageFormatting.percent(834, of: 1_000) == "83%")
    #expect(UsageFormatting.percent(1_000, of: 1_000) == "100%")
    #expect(UsageFormatting.cacheRatio(UsageTokens(input: 100, cacheRead: 800, cacheWrite5m: 50, cacheWrite1h: 0, output: 50)) == "80%")
}
