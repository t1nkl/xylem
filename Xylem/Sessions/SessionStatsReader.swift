//
//  SessionStatsReader.swift
//  Xylem
//
//  Parses a Claude Code session jsonl and produces a StatsSnapshot.
//  Cost comes from ModelPricingCatalog (published per-million-token rates);
//  it is an approximation for display, not billing-accurate.
//
//  The file is folded incrementally (IncrementalJSONLCache): a poll parses
//  only the lines appended since the previous one, and nothing at all when
//  the file is unchanged.
//

import Foundation

nonisolated protocol SessionStatsReading {
    func readStats(from url: URL) -> StatsSnapshot?
}

nonisolated struct SessionStatsReader: SessionStatsReading {
    private static let cache = IncrementalJSONLCache<SessionStatsAccumulator>()

    func readStats(from url: URL) -> StatsSnapshot? {
        Self.cache.withState(for: url) { $0.snapshot() } ?? nil
    }
}

/// Running totals for one session file, updated line by line.
nonisolated struct SessionStatsAccumulator: JSONLFoldState {
    /// The model Claude Code names on the error message it writes after a
    /// failed request.
    static let syntheticModel = "<synthetic>"

    private var totalTokens = 0
    private var cost: Double = 0
    private var lastModel: String?
    private var lastEffort: String?
    private var latestMessageTokens = 0
    private var firstTimestamp: Date?
    private var lastTimestamp: Date?
    /// Raw text of the newest timestamp in the current batch; parsed once
    /// per batch instead of once per line.
    private var pendingLastTimestamp: String?
    /// Same, for the newest assistant message (the line that names the
    /// model). A model picked in the UI is compared against this, not
    /// against any line: the user's next prompt lands before the reply.
    private var lastAssistantTimestamp: Date?
    private var pendingAssistantTimestamp: String?
    /// Newest line the human typed (not tool results or command echoes).
    private var lastPromptTimestamp: Date?
    private var pendingPromptTimestamp: String?
    private var processedAnything = false
    private var countedMessageIDs = Set<String>()

    init() {}

    mutating func consume(_ root: [String: Any]) {
        if let timestamp = root["timestamp"] as? String {
            if firstTimestamp == nil {
                firstTimestamp = TimestampParser.parse(timestamp)
            }
            pendingLastTimestamp = timestamp
        }

        if root["type"] as? String == "user",
           let timestamp = root["timestamp"] as? String,
           UserPromptExtractor.prompt(from: root) != nil {
            pendingPromptTimestamp = timestamp
        }

        guard root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        // Claude Code writes one line per content block, each repeating the
        // message's usage; count every message id once.
        if let id = message["id"] as? String, !countedMessageIDs.insert(id).inserted {
            return
        }
        // The error text Claude Code writes after a failed request: no
        // tokens, and not a model the session runs.
        if message["model"] as? String == Self.syntheticModel { return }

        processedAnything = true
        if let model = message["model"] as? String { lastModel = model }
        if let effort = root["effort"] as? String, !effort.isEmpty { lastEffort = effort }
        if let timestamp = root["timestamp"] as? String { pendingAssistantTimestamp = timestamp }

        // Priced per message: rates depend on that message's model, its
        // speed and (Haiku 5.5) its prompt length.
        let tokens = MessageTokenUsage(usage: usage)
        cost += ModelPricingCatalog.cost(tokens, model: lastModel ?? "")
        totalTokens += tokens.totalTokens
        latestMessageTokens = tokens.totalTokens
    }

    mutating func finishBatch() {
        if let raw = pendingLastTimestamp, let date = TimestampParser.parse(raw) {
            lastTimestamp = date
        }
        pendingLastTimestamp = nil
        if let raw = pendingAssistantTimestamp, let date = TimestampParser.parse(raw) {
            lastAssistantTimestamp = date
        }
        pendingAssistantTimestamp = nil
        if let raw = pendingPromptTimestamp, let date = TimestampParser.parse(raw) {
            lastPromptTimestamp = date
        }
        pendingPromptTimestamp = nil
    }

    func snapshot() -> StatsSnapshot? {
        guard processedAnything else { return nil }

        let duration = (firstTimestamp != nil && lastTimestamp != nil)
            ? lastTimestamp!.timeIntervalSince(firstTimestamp!)
            : 0

        return StatsSnapshot(
            contextUsed: latestMessageTokens,
            contextLimit: ModelPricingCatalog.pricing(for: lastModel ?? "").contextLimit,
            costUSD: cost,
            model: lastModel.map(ModelNameFormatter.display) ?? "-",
            modelID: lastModel ?? "",
            effort: lastEffort,
            lastAssistantAt: lastAssistantTimestamp,
            lastPromptAt: lastPromptTimestamp,
            tokens: totalTokens,
            duration: duration,
            projectPath: ""
        )
    }
}
