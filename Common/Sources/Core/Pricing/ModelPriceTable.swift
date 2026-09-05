import Transport
import Foundation

/// One set of rates, USD per million tokens.
public struct ModelRates: Hashable, Sendable {
    public var input: Double
    public var output: Double
    /// Missing on providers that publish no cache rates; billed as `input`.
    public var cacheRead: Double?
    public var cacheWrite: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// A long-context band: a request whose context (everything but the
/// output) exceeds `size` tokens is billed entirely at these rates.
public struct ModelPriceTier: Hashable, Sendable {
    public var size: Int64
    public var rates: ModelRates

    public init(size: Int64, rates: ModelRates) {
        self.size = size
        self.rates = rates
    }
}

/// Published rates for one model: the base band plus any long-context
/// bands (ascending by size). Batch / flex / speed tiers are ignored on
/// purpose: transcripts do not record which service tier served a request.
public struct ModelPrice: Hashable, Sendable {
    public var input: Double
    public var output: Double
    /// Missing on providers that publish no cache rates; billed as `input`.
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var contextWindow: Int64?
    public var tiers: [ModelPriceTier]

    public init(
        input: Double,
        output: Double,
        cacheRead: Double? = nil,
        cacheWrite: Double? = nil,
        contextWindow: Int64? = nil,
        tiers: [ModelPriceTier] = []
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.contextWindow = contextWindow
        self.tiers = tiers.sorted { $0.size < $1.size }
    }

    public var baseRates: ModelRates {
        ModelRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    /// 0 for the base band, else the highest band the context exceeds.
    public func tier(forContext context: Int64) -> Int {
        tiers.lastIndex { context > $0.size }.map { $0 + 1 } ?? 0
    }

    /// Rates of band `tier` (0 = base). A band the table no longer has —
    /// the bucket was classified under an older table — falls back to the
    /// highest band there is; a band's unpublished field to the base rate.
    public func rates(atTier tier: Int) -> ModelRates {
        guard tier > 0, !tiers.isEmpty else { return baseRates }
        let band = tiers[min(tier, tiers.count) - 1].rates
        return ModelRates(
            input: band.input,
            output: band.output,
            cacheRead: band.cacheRead ?? cacheRead,
            cacheWrite: band.cacheWrite ?? cacheWrite
        )
    }
}

/// The models.dev catalog reduced to prices: provider id → model id → rate.
/// Built from the live `api.json` (or the daemon's cached copy of it) and,
/// failing both, from the snapshot compiled into the binary.
public struct ModelPriceTable: Sendable {
    public let providers: [String: [String: ModelPrice]]
    public let modelCount: Int

    public init(providers: [String: [String: ModelPrice]]) {
        self.providers = providers
        modelCount = providers.values.reduce(0) { $0 + $1.count }
    }

    /// Parses the api.json shape: `{ provider: { "models": { id: { "cost":
    /// { input, output, cache_read?, cache_write? }, "limit": { context? } } } } }`.
    /// Models without both an input and an output rate are dropped — a
    /// half-priced model would under-report silently, which is worse than
    /// reporting it as unpriced.
    public init(modelsDevJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelPriceTableError.notAnObject
        }
        var providers: [String: [String: ModelPrice]] = [:]
        for (providerID, providerValue) in root {
            guard let provider = providerValue as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            var prices: [String: ModelPrice] = [:]
            for (modelID, modelValue) in models {
                guard let model = modelValue as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = Self.finite(cost["input"]),
                      let output = Self.finite(cost["output"]) else { continue }
                let context = (model["limit"] as? [String: Any])?["context"] as? NSNumber
                prices[modelID] = ModelPrice(
                    input: input,
                    output: output,
                    cacheRead: Self.finite(cost["cache_read"]),
                    cacheWrite: Self.finite(cost["cache_write"]),
                    contextWindow: context?.int64Value,
                    tiers: Self.tiers(in: cost)
                )
            }
            if !prices.isEmpty { providers[providerID] = prices }
        }
        guard !providers.isEmpty else { throw ModelPriceTableError.noPricedModels }
        self.init(providers: providers)
    }

    /// The snapshot compiled into the binary (`scripts/models-dev-snapshot.sh`).
    public static let builtin: ModelPriceTable = {
        do {
            return try ModelPriceTable(modelsDevJSON: Data(ModelPricingSnapshot.json.utf8))
        } catch {
            fatalError("built-in models.dev snapshot is unreadable: \(error)")
        }
    }()

    /// models.dev provider that publishes the agent's first-party rates.
    public static func provider(for agent: AgentProvider) -> String {
        switch agent {
        case .claude: "anthropic"
        case .codex: "openai"
        }
    }

    /// Ids that name no billable model: locally synthesized messages and bare
    /// family names that are ambiguous across generations.
    public static let unpriceableModels: Set<String> = [
        "", "<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable",
    ]

    /// Ids agents report under a name the catalog spells differently.
    public static let aliases: [String: String] = [
        "gpt-5.6": "gpt-5.6-sol",
        "gpt-5.3-spark": "gpt-5.3-codex-spark",
    ]

    /// The rate for a model as an agent reported it. Lookup order: the
    /// agent's own provider by exact id, then with a trailing release date
    /// stripped, then through the alias table; then the same candidates on
    /// every other provider (sorted, deterministic). `nil` means unpriced.
    public func price(for model: String, agent: AgentProvider) -> ModelPrice? {
        let candidates = Self.candidates(for: model)
        guard !candidates.isEmpty else { return nil }
        let preferred = Self.provider(for: agent)
        if let prices = providers[preferred] {
            for candidate in candidates {
                if let price = prices[candidate] { return price }
            }
        }
        for providerID in providers.keys.sorted() where providerID != preferred {
            let prices = providers[providerID]!
            for candidate in candidates {
                if let price = prices[candidate] { return price }
            }
        }
        return nil
    }

    /// The band the context falls in for a model, 0 when the model is
    /// unpriced or has no bands. Decided once, when the call is stored.
    public func tier(for model: String, agent: AgentProvider, context: Int64) -> Int {
        price(for: model, agent: agent)?.tier(forContext: context) ?? 0
    }

    /// models.dev `cost.tiers` (context-sized bands only), else the legacy
    /// `context_over_200k` block as one band at 200K. Bands without both an
    /// input and an output rate are dropped.
    private static func tiers(in cost: [String: Any]) -> [ModelPriceTier] {
        if let raw = cost["tiers"] as? [[String: Any]] {
            return raw.compactMap { band -> ModelPriceTier? in
                guard let bound = band["tier"] as? [String: Any],
                      (bound["type"] as? String ?? "context") == "context",
                      let size = bound["size"] as? NSNumber, CFGetTypeID(size as CFTypeRef) != CFBooleanGetTypeID(),
                      let input = finite(band["input"]), let output = finite(band["output"]) else { return nil }
                return ModelPriceTier(size: size.int64Value, rates: ModelRates(
                    input: input, output: output, cacheRead: finite(band["cache_read"]), cacheWrite: finite(band["cache_write"])
                ))
            }
        }
        if let legacy = cost["context_over_200k"] as? [String: Any],
           let input = finite(legacy["input"]), let output = finite(legacy["output"]) {
            return [ModelPriceTier(size: 200_000, rates: ModelRates(
                input: input, output: output, cacheRead: finite(legacy["cache_read"]), cacheWrite: finite(legacy["cache_write"])
            ))]
        }
        return []
    }

    /// Lookup keys in priority order; empty for an unpriceable id.
    static func candidates(for model: String) -> [String] {
        var normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = normalized.lastIndex(of: "/") {
            normalized = String(normalized[normalized.index(after: slash)...])
        }
        guard !Self.unpriceableModels.contains(normalized) else { return [] }
        var candidates = [normalized]
        let undated = Self.withoutDateSuffix(normalized)
        if undated != normalized { candidates.append(undated) }
        for candidate in candidates {
            if let alias = Self.aliases[candidate], !candidates.contains(alias) {
                candidates.append(alias)
            }
        }
        return candidates
    }

    /// Strips `-YYYYMMDD` (Anthropic) or `-YYYY-MM-DD` (OpenAI) release
    /// suffixes so a date-pinned id shares its base model's rate.
    static func withoutDateSuffix(_ model: String) -> String {
        let scalars = Array(model.utf8)
        func digits(_ range: Range<Int>) -> Bool {
            range.allSatisfy { scalars[$0] >= 0x30 && scalars[$0] <= 0x39 }
        }
        if scalars.count > 11 {
            let start = scalars.count - 11
            if scalars[start] == 0x2D, digits(start + 1..<start + 5),
               scalars[start + 5] == 0x2D, digits(start + 6..<start + 8),
               scalars[start + 8] == 0x2D, digits(start + 9..<scalars.count) {
                return String(decoding: scalars[..<start], as: UTF8.self)
            }
        }
        if scalars.count > 9 {
            let start = scalars.count - 9
            if scalars[start] == 0x2D, digits(start + 1..<scalars.count) {
                return String(decoding: scalars[..<start], as: UTF8.self)
            }
        }
        return model
    }

    /// A JSON number (never a JSON boolean — `NSNumber(0)`/`(1)` bridge to
    /// `Bool`, so the CF type is the only reliable tell) that is finite.
    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

public enum ModelPriceTableError: Error, Hashable, Sendable {
    case notAnObject
    case noPricedModels
}

/// Cost of a token bundle at a published rate. Cache reads and writes fall
/// back to the input rate when the provider publishes none; the 1-hour
/// cache write tier is billed at twice the input rate (Anthropic's
/// published multiplier, which models.dev does not carry).
public enum UsageCost {
    public static let cacheWrite1hInputMultiplier = 2.0

    /// `tier` picks the long-context band the calls were stored under.
    public static func usd(tokens: UsageTokens, price: ModelPrice, tier: Int = 0) -> Double {
        let rates = price.rates(atTier: tier)
        let perMillion = Double(tokens.input) * rates.input
            + Double(tokens.cacheRead) * (rates.cacheRead ?? rates.input)
            + Double(tokens.cacheWrite5m) * (rates.cacheWrite ?? rates.input)
            + Double(tokens.cacheWrite1h) * rates.input * cacheWrite1hInputMultiplier
            + Double(tokens.output) * rates.output
        return perMillion / 1_000_000
    }
}

public extension UsageTokens {
    /// What the model had to read for the call: everything but the output.
    /// Decides the long-context band.
    var context: Int64 { input + cacheRead + cacheWrite5m + cacheWrite1h }
}
