import Transport
import Foundation
import Testing
@testable import Core

private let table = ModelPriceTable(providers: [
    "anthropic": [
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, contextWindow: 1_000_000),
        "claude-sonnet-4-5": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
    ],
    "openai": [
        "gpt-5.6-sol": ModelPrice(input: 2, output: 12, cacheRead: 0.2),
        "gpt-5.5": ModelPrice(input: 1.75, output: 14, cacheRead: 0.175),
        "gpt-5.5-2026-04-23": ModelPrice(input: 1, output: 4),
    ],
    "moonshotai": ["kimi-k3": ModelPrice(input: 0.5, output: 2)],
    "aihubmix": ["claude-fable-5": ModelPrice(input: 99, output: 99)],
])

@Test func priceLookupPrefersTheAgentsOwnProviderThenFallsBack() {
    // Own provider wins over a reseller carrying the same id.
    #expect(table.price(for: "claude-fable-5", agent: .claude)?.input == 10)
    // A model the own provider lacks resolves through the sorted others.
    #expect(table.price(for: "kimi-k3", agent: .codex)?.input == 0.5)
    // Case and a provider/ prefix are not identity.
    #expect(table.price(for: "Anthropic/Claude-Fable-5", agent: .claude)?.input == 10)
}

@Test func priceLookupStripsReleaseDatesAndAppliesAliases() {
    #expect(table.price(for: "claude-sonnet-4-5-20250929", agent: .claude)?.input == 3)
    #expect(table.price(for: "gpt-5.6", agent: .codex)?.input == 2)
    // The dated id itself is still an exact key when the catalog spells it that way.
    #expect(table.price(for: "gpt-5.5-2026-04-23", agent: .codex)?.input == 1)
    #expect(ModelPriceTable.withoutDateSuffix("gpt-5.5-2026-04-23") == "gpt-5.5")
    #expect(ModelPriceTable.withoutDateSuffix("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
    #expect(ModelPriceTable.withoutDateSuffix("gpt-5.4-mini") == "gpt-5.4-mini")
    #expect(ModelPriceTable.candidates(for: "claude-sonnet-4-5-20250929") == ["claude-sonnet-4-5-20250929", "claude-sonnet-4-5"])
}

@Test func unpriceableIDsNeverResolve() {
    for model in ["<synthetic>", "synthetic", "sonnet", "haiku", "opus", "fable", "", "  "] {
        #expect(table.price(for: model, agent: .claude) == nil, Comment(rawValue: model))
    }
    #expect(table.price(for: "codex-auto-review", agent: .codex) == nil)
}

@Test func costBillsCacheTiersAtPublishedRatesAndOneHourWritesAtTwiceInput() throws {
    let price = try #require(table.price(for: "claude-fable-5", agent: .claude))
    let tokens = UsageTokens(input: 2, cacheRead: 37_690, cacheWrite5m: 1_000, cacheWrite1h: 21_292, output: 496)
    let expected = (2 * 10.0 + 37_690 * 1.0 + 1_000 * 12.5 + 21_292 * 20.0 + 496 * 50.0) / 1_000_000
    #expect(abs(UsageCost.usd(tokens: tokens, price: price) - expected) < 1e-12)
    // No published cache rates: cached input bills as plain input, not as free.
    let openai = try #require(table.price(for: "gpt-5.5", agent: .codex))
    let codexTokens = UsageTokens(input: 100, cacheRead: 900, cacheWrite5m: 50, output: 10)
    #expect(abs(UsageCost.usd(tokens: codexTokens, price: openai) - (100 * 1.75 + 900 * 0.175 + 50 * 1.75 + 10 * 14.0) / 1_000_000) < 1e-12)
    let dated = try #require(table.price(for: "gpt-5.5-2026-04-23", agent: .codex))
    #expect(abs(UsageCost.usd(tokens: codexTokens, price: dated) - (100 * 1.0 + 900 * 1.0 + 50 * 1.0 + 10 * 4.0) / 1_000_000) < 1e-12)
}

@Test func modelsDevJSONParsesAndDropsHalfPricedModels() throws {
    let json = """
    {
      "anthropic": {"id": "anthropic", "models": {
        "claude-opus-5": {"cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}, "limit": {"context": 1000000, "output": 128000}},
        "claude-broken": {"cost": {"input": 5}},
        "claude-free": {"cost": {"input": 0, "output": 0}}
      }},
      "empty": {"id": "empty", "models": {}},
      "openai": {"models": {"gpt-5.5": {"cost": {"input": 1.75, "output": 14, "cache_read": 0.175}}}}
    }
    """
    let parsed = try ModelPriceTable(modelsDevJSON: Data(json.utf8))
    #expect(parsed.modelCount == 3)
    #expect(parsed.providers["anthropic"]?["claude-opus-5"] == ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, contextWindow: 1_000_000))
    #expect(parsed.providers["anthropic"]?["claude-broken"] == nil)
    #expect(parsed.providers["openai"]?["gpt-5.5"]?.cacheWrite == nil)
    #expect(throws: ModelPriceTableError.self) { try ModelPriceTable(modelsDevJSON: Data("[]".utf8)) }
    #expect(throws: ModelPriceTableError.self) { try ModelPriceTable(modelsDevJSON: Data(#"{"x":{"models":{}}}"#.utf8)) }
}

@Test func builtinSnapshotPricesTheModelsSeenOnThisMac() throws {
    let builtin = ModelPriceTable.builtin
    #expect(builtin.modelCount == ModelPricingSnapshot.modelCount)
    #expect(builtin.providers.count == ModelPricingSnapshot.providerCount)
    let fable = try #require(builtin.price(for: "claude-fable-5", agent: .claude))
    #expect(fable == ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, contextWindow: 1_000_000))
    #expect(builtin.price(for: "claude-haiku-4-5-20251001", agent: .claude)?.input == 1)
    #expect(builtin.price(for: "gpt-5.3-codex", agent: .codex)?.output == 14)
    #expect(builtin.price(for: "<synthetic>", agent: .claude) == nil)
}

@Test func longContextBandsParseAndPickTheHighestExceededBand() throws {
    let json = """
    {
      "openai": {"models": {
        "gpt-5.6-sol": {"cost": {"input": 4, "output": 20, "cache_read": 0.4, "cache_write": 5,
          "tiers": [{"input": 8, "output": 30, "cache_read": 0.8, "cache_write": 10, "tier": {"type": "context", "size": 272000}}],
          "context_over_200k": {"input": 8, "output": 30}}},
        "gpt-5.4": {"cost": {"input": 2.5, "output": 15, "cache_read": 0.25,
          "tiers": [{"input": 5, "output": 22.5, "cache_read": 0.5, "tier": {"type": "context", "size": 272000}}]}},
        "legacy": {"cost": {"input": 1, "output": 2, "context_over_200k": {"input": 2, "output": 4}}},
        "odd": {"cost": {"input": 1, "output": 2, "tiers": [
          {"input": 9, "output": 9, "tier": {"type": "audio", "size": 1}},
          {"output": 9, "tier": {"type": "context", "size": 100}},
          {"input": 3, "output": 6, "tier": {"type": "context", "size": 500000}},
          {"input": 2, "output": 4, "tier": {"type": "context", "size": 200000}}]}}
      }}
    }
    """
    let table = try ModelPriceTable(modelsDevJSON: Data(json.utf8))
    let sol = try #require(table.price(for: "gpt-5.6-sol", agent: .codex))
    #expect(sol.tiers == [ModelPriceTier(size: 272_000, rates: ModelRates(input: 8, output: 30, cacheRead: 0.8, cacheWrite: 10))])
    #expect(sol.tier(forContext: 272_000) == 0)
    #expect(sol.tier(forContext: 272_001) == 1)
    #expect(table.tier(for: "gpt-5.6-sol", agent: .codex, context: 300_000) == 1)
    #expect(table.tier(for: "<synthetic>", agent: .claude, context: 900_000) == 0)
    // A band's unpublished cache rates fall back to the base band's.
    let gpt54 = try #require(table.price(for: "gpt-5.4", agent: .codex))
    #expect(gpt54.rates(atTier: 1) == ModelRates(input: 5, output: 22.5, cacheRead: 0.5, cacheWrite: nil))
    // Legacy block alone is one band at 200K.
    let legacy = try #require(table.price(for: "legacy", agent: .codex))
    #expect(legacy.tiers.map(\.size) == [200_000])
    // Non-context and half-priced bands are dropped; bands sort ascending; a
    // stale band index clamps to the highest band there is.
    let odd = try #require(table.price(for: "odd", agent: .codex))
    #expect(odd.tiers.map(\.size) == [200_000, 500_000])
    #expect(odd.tier(forContext: 600_000) == 2)
    #expect(odd.rates(atTier: 7).input == 3)
    #expect(odd.rates(atTier: 0).input == 1)
}

@Test func costUsesTheBandRatesForTheStoredTier() throws {
    let price = ModelPrice(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5, tiers: [
        ModelPriceTier(size: 272_000, rates: ModelRates(input: 8, output: 30, cacheRead: 0.8, cacheWrite: 10)),
    ])
    let tokens = UsageTokens(input: 100_000, cacheRead: 200_000, cacheWrite5m: 10_000, output: 1_000)
    #expect(tokens.context == 310_000)
    let base = (100_000 * 4.0 + 200_000 * 0.4 + 10_000 * 5.0 + 1_000 * 20.0) / 1_000_000
    let band = (100_000 * 8.0 + 200_000 * 0.8 + 10_000 * 10.0 + 1_000 * 30.0) / 1_000_000
    #expect(abs(UsageCost.usd(tokens: tokens, price: price) - base) < 1e-12)
    #expect(abs(UsageCost.usd(tokens: tokens, price: price, tier: 1) - band) < 1e-12)
}

@Test func builtinSnapshotCarriesOpenAILongContextBands() throws {
    let sol = try #require(ModelPriceTable.builtin.price(for: "gpt-5.6-sol", agent: .codex))
    #expect(sol.tiers.map(\.size) == [272_000])
    #expect(sol.rates(atTier: 1).input == 2 * sol.input)
    let fable = try #require(ModelPriceTable.builtin.price(for: "claude-fable-5-1", agent: .claude))
    #expect(fable.tiers.isEmpty)
}
