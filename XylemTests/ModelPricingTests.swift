//
//  ModelPricingTests.swift
//  XylemTests
//
//  Rate lookup by model ID prefix, TTL-split cache writes, fast mode and the
//  Haiku 5.5 long-prompt rate card. Usage objects are decoded from jsonl-shaped
//  dictionaries so the parsing path is the same one the readers use.
//

import Testing
import Foundation

struct ModelPricingTests {

    private func usage(_ json: String) throws -> MessageTokenUsage {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return MessageTokenUsage(usage: object)
    }

    @Test func longestPrefixWinsOverShorterVersion() {
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-5-5").inputPerMillion == 4)
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-5").inputPerMillion == 5)
        #expect(ModelPricingCatalog.pricing(for: "claude-sonnet-5-5").cacheReadPerMillion == 0.10)
        #expect(ModelPricingCatalog.pricing(for: "claude-sonnet-5").cacheReadPerMillion == 0.20)
    }

    @Test func olderModelsKeepTheirOwnRates() {
        #expect(ModelPricingCatalog.pricing(for: "claude-sonnet-4-5-20250929").inputPerMillion == 3)
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-4-1-20250805").outputPerMillion == 75)
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-4-20250514").inputPerMillion == 15)
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-4-5").inputPerMillion == 5)
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-4-8").inputPerMillion == 5)
    }

    @Test func suffixesAndProviderPrefixesAreIgnored() {
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-5-5[1m]").inputPerMillion == 4)
        #expect(ModelPricingCatalog.pricing(for: "+bedrock/claude-fable-5-2").inputPerMillion == 8)
        #expect(ModelPricingCatalog.pricing(for: "claude-haiku-4-5-20251001").contextLimit == 200_000)
    }

    @Test func unknownVersionFallsBackToCurrentFamilyModel() {
        #expect(ModelPricingCatalog.pricing(for: "claude-opus-9-9") == ModelPricingCatalog.pricing(for: "claude-opus-5-5"))
        #expect(ModelPricingCatalog.pricing(for: "something-else") == ModelPricingCatalog.pricing(for: "claude-sonnet-5-5"))
    }

    @Test func oneHourCacheWritesCostTwiceInput() throws {
        let tokens = try usage(#"""
        {"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,
         "cache_creation_input_tokens":1000000,
         "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}
        """#)
        #expect(tokens.cacheWrite1h == 1_000_000)
        #expect(ModelPricingCatalog.cost(tokens, model: "claude-opus-5-5") == 8)
    }

    @Test func totalWithoutSplitIsPricedAsFiveMinuteWrites() throws {
        let tokens = try usage(#"{"cache_creation_input_tokens":1000000}"#)
        #expect(tokens.cacheWrite5m == 1_000_000)
        #expect(ModelPricingCatalog.cost(tokens, model: "claude-opus-5-5") == 5)
    }

    @Test func fastModeDoublesTheRate() throws {
        let tokens = try usage(#"{"input_tokens":1000000,"output_tokens":1000000,"speed":"fast"}"#)
        #expect(ModelPricingCatalog.cost(tokens, model: "claude-opus-5-5") == 48)
    }

    @Test func haikuLongPromptUsesTheHigherRateCard() {
        let short = MessageTokenUsage(input: 100_000, output: 1_000_000)
        let long = MessageTokenUsage(input: 100_001, output: 1_000_000)
        #expect(abs(ModelPricingCatalog.cost(short, model: "claude-haiku-5-5") - 0.51) < 1e-9)
        #expect(abs(ModelPricingCatalog.cost(long, model: "claude-haiku-5-5") - (0.100_001 * 0.10 * 5 + 2.5)) < 1e-9)
    }

    @Test func displayNamesCoverCurrentFamilies() {
        #expect(ModelNameFormatter.display("claude-fable-5-2") == "Fable 5.2")
        #expect(ModelNameFormatter.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelNameFormatter.display("claude-opus-5") == "Opus 5")
    }

    @Test func onlyModelsInTheTableHaveAListedPrice() {
        #expect(ModelPricingCatalog.hasListedPrice("claude-opus-5-5"))
        #expect(ModelPricingCatalog.hasListedPrice("claude-opus-5-5[1m]"))
        #expect(ModelPricingCatalog.hasListedPrice("+provider/claude-haiku-4-5-20251001"))
        // A newer version prices like its family, so it is only an estimate.
        #expect(!ModelPricingCatalog.hasListedPrice("claude-opus-6"))
        #expect(!ModelPricingCatalog.hasListedPrice("some-other-model"))
    }

    @Test func costOfUnlistedModelsIsMarkedEstimated() {
        func file(_ model: String, path: String) -> FileUsageAggregate {
            var bucket = UsageBucket(key: .init(day: nil, model: model, isFast: false, isLongPrompt: false))
            bucket.add(MessageTokenUsage(input: 1_000_000))
            return FileUsageAggregate(
                path: path, stamp: FileStamp(size: 0, mtimeSeconds: 0, mtimeNanoseconds: 0, inode: 0), sessionID: path, projectPath: "/tmp/p", model: model,
                firstDate: nil, buckets: [bucket], parsedBytes: 0, tailMessageIDs: [], tailBytes: Data(),
                classificationVersion: ModelPricingCatalog.classificationVersion
            )
        }
        let dataset = UsageAggregator.combine(
            files: [file("claude-opus-5-5", path: "a"), file("claude-opus-6", path: "b")],
            cutoff: nil
        )
        // claude-opus-6 falls back to Opus 5.5's $4 input rate.
        #expect(abs(dataset.totals.estimatedCostUSD - 4) < 1e-9)
        #expect(abs(dataset.totals.totalCostUSD - 8) < 1e-9)
        let rows = Dictionary(uniqueKeysWithValues: dataset.byModel.map { ($0.model, $0.hasEstimatedCost) })
        #expect(rows["claude-opus-6"] == .some(true))
        #expect(rows["claude-opus-5-5"] == .some(nil))
        #expect(UsageFormatting.costCaption(dataset.totals) == "$4.00 estimated")
    }
}
