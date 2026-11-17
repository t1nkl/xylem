//
//  ModelPricing.swift
//  Xylem
//
//  Single source of per-model rates and context windows, shared by the top
//  stats bar (SessionStatsReader) and the Usage Dashboard (UsageAggregator).
//  Rates are Anthropic first-party list prices per million tokens; the result
//  is an API-equivalent estimate, not a subscription bill.
//
//  Cache writes are priced by TTL: 5-minute writes at 1.25x input, 1-hour
//  writes at 2x input. Claude Code writes almost all of its cache with the
//  1-hour TTL, so the split in `usage.cache_creation` matters.
//

import Foundation

nonisolated struct ModelPricing: Equatable {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheReadPerMillion: Double
    let contextLimit: Int
    /// Prompts above this many tokens use a long-prompt rate card (Haiku 5.5).
    let longPromptThreshold: Int?
    /// Multiplier applied to every rate above `longPromptThreshold`.
    let longPromptMultiplier: Double

    init(
        input: Double,
        output: Double,
        cacheRead: Double,
        contextLimit: Int = 1_000_000,
        longPromptThreshold: Int? = nil,
        longPromptMultiplier: Double = 1
    ) {
        self.inputPerMillion = input
        self.outputPerMillion = output
        self.cacheReadPerMillion = cacheRead
        self.contextLimit = contextLimit
        self.longPromptThreshold = longPromptThreshold
        self.longPromptMultiplier = longPromptMultiplier
    }

    var cacheWrite5mPerMillion: Double { inputPerMillion * 1.25 }
    var cacheWrite1hPerMillion: Double { inputPerMillion * 2 }
}

/// Token counts of one assistant message, read from its jsonl `usage` object.
nonisolated struct MessageTokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var isFast = false

    init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
         cacheRead: Int = 0, isFast: Bool = false) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.isFast = isFast
    }

    init(usage: [String: Any]) {
        input = (usage["input_tokens"] as? Int) ?? 0
        output = (usage["output_tokens"] as? Int) ?? 0
        cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let totalWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        if let split = usage["cache_creation"] as? [String: Any] {
            cacheWrite5m = (split["ephemeral_5m_input_tokens"] as? Int) ?? 0
            cacheWrite1h = (split["ephemeral_1h_input_tokens"] as? Int) ?? 0
            // Older entries carry only the total; the remainder is priced as 5-minute writes.
            let unsplit = totalWrite - cacheWrite5m - cacheWrite1h
            if unsplit > 0 { cacheWrite5m += unsplit }
        } else {
            cacheWrite5m = totalWrite
        }
        isFast = (usage["speed"] as? String) == "fast"
    }

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var promptTokens: Int { input + cacheWrite + cacheRead }
    var totalTokens: Int { promptTokens + output }
}

nonisolated enum ModelPricingCatalog {
    /// Bump when rates change. Per-file caches store token counts, not
    /// money, so nothing is re-parsed: costs are recomputed from the cached
    /// tokens, and only the per-range dataset cache (keyed by this) rebuilds.
    static let version = 4

    /// Bump when the way a message is classified for pricing changes - today
    /// that is only the long-prompt threshold: changing one, or adding a row
    /// for a model that so far fell back to a family member WITH a threshold
    /// (its messages were classified with the fallback's). Per-file caches
    /// keep tokens per class (model, fast, long prompt), so this forces one
    /// full re-parse.
    static let classificationVersion = 1

    /// Keyed by model ID prefix; the longest matching key wins, so
    /// "claude-opus-5-5" is not priced as "claude-opus-5".
    private static let table: [String: ModelPricing] = [
        "claude-fable-5-2": ModelPricing(input: 8, output: 40, cacheRead: 0.20),
        "claude-mythos-5-2": ModelPricing(input: 8, output: 40, cacheRead: 0.20),
        "claude-fable-5-1": ModelPricing(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": ModelPricing(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": ModelPricing(input: 10, output: 50, cacheRead: 1.0),
        "claude-mythos-5": ModelPricing(input: 10, output: 50, cacheRead: 1.0),
        "claude-opus-5-5": ModelPricing(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": ModelPricing(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-8": ModelPricing(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-7": ModelPricing(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-6": ModelPricing(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-5": ModelPricing(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-1": ModelPricing(input: 15, output: 75, cacheRead: 1.50),
        "claude-opus-4": ModelPricing(input: 15, output: 75, cacheRead: 1.50),
        "claude-sonnet-5-5": ModelPricing(input: 2, output: 10, cacheRead: 0.10),
        "claude-sonnet-5": ModelPricing(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-4-6": ModelPricing(input: 3, output: 15, cacheRead: 0.30),
        "claude-sonnet-4-5": ModelPricing(input: 3, output: 15, cacheRead: 0.30),
        "claude-sonnet-4": ModelPricing(input: 3, output: 15, cacheRead: 0.30),
        "claude-haiku-5-5": ModelPricing(input: 0.10, output: 0.50, cacheRead: 0.01,
                                         longPromptThreshold: 100_000, longPromptMultiplier: 5),
        "claude-haiku-4-5": ModelPricing(input: 1, output: 5, cacheRead: 0.10, contextLimit: 200_000)
    ]

    private static let keysLongestFirst = table.keys.sorted { $0.count > $1.count }

    /// Unknown versions fall back to the current model of their family.
    private static let familyFallback: [(family: String, key: String)] = [
        ("fable", "claude-fable-5-2"),
        ("mythos", "claude-mythos-5-2"),
        ("opus", "claude-opus-5-5"),
        ("sonnet", "claude-sonnet-5-5"),
        ("haiku", "claude-haiku-5-5")
    ]

    static func pricing(for model: String) -> ModelPricing {
        let id = normalizedID(model)
        if let key = listedKey(for: id) {
            return table[key]!
        }
        if let fallback = familyFallback.first(where: { id.contains($0.family) }) {
            return table[fallback.key]!
        }
        return table["claude-sonnet-5-5"]!
    }

    /// Whether `model` has its own row in the table. A model that doesn't
    /// (released after this build, or not Anthropic's) is priced by its
    /// family's current model, so its cost is only an estimate.
    static func hasListedPrice(_ model: String) -> Bool {
        listedKey(for: normalizedID(model)) != nil
    }

    private static func listedKey(for id: String) -> String? {
        keysLongestFirst.first { id == $0 || id.hasPrefix($0 + "-") || id.hasPrefix($0 + "[") }
    }

    static func cost(_ usage: MessageTokenUsage, model: String) -> Double {
        cost(usage, model: model, longPrompt: isLongPrompt(usage, model: model))
    }

    /// Whether one message's prompt is above its model's long-prompt
    /// threshold. Decided per message, so token counts of many messages can
    /// be summed per class and priced later.
    static func isLongPrompt(_ usage: MessageTokenUsage, model: String) -> Bool {
        guard let threshold = pricing(for: model).longPromptThreshold else { return false }
        return usage.promptTokens > threshold
    }

    /// Price of `usage` - one message, or the summed tokens of messages of
    /// the same class (model, fast, long prompt): every term is linear.
    static func cost(_ usage: MessageTokenUsage, model: String, longPrompt: Bool) -> Double {
        let rates = pricing(for: model)
        var multiplier = usage.isFast ? 2.0 : 1.0
        if longPrompt {
            multiplier *= rates.longPromptMultiplier
        }
        let perMillion = Double(usage.input) * rates.inputPerMillion
            + Double(usage.output) * rates.outputPerMillion
            + Double(usage.cacheWrite5m) * rates.cacheWrite5mPerMillion
            + Double(usage.cacheWrite1h) * rates.cacheWrite1hPerMillion
            + Double(usage.cacheRead) * rates.cacheReadPerMillion
        return perMillion / 1_000_000 * multiplier
    }

    /// "+provider/claude-opus-5-5[1m]" -> "claude-opus-5-5[1m]", lowercased.
    private static func normalizedID(_ raw: String) -> String {
        let lowered = raw.lowercased()
        guard let slash = lowered.lastIndex(of: "/") else { return lowered }
        return String(lowered[lowered.index(after: slash)...])
    }
}
