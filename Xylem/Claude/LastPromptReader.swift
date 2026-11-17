//
//  LastPromptReader.swift
//  Xylem
//
//  Pulls the most recent user prompt from a Claude session jsonl. Used by
//  the tab card and the overview sheet to show what the user last typed
//  without forcing the caller to know the jsonl shape.
//
//  Folded incrementally (IncrementalJSONLCache): repeated reads of a
//  growing file parse only the appended lines.
//

import Foundation

nonisolated enum LastPromptReader {
    private static let cache = IncrementalJSONLCache<LastPromptState>()

    /// Returns the *latest* thing the user typed (see UserPromptExtractor
    /// for what is filtered out). Filtering happens while folding, so a
    /// slash-command echo or hook message after a real prompt does not hide
    /// it. Truncated to 120 chars with an ellipsis.
    static func read(from url: URL) -> String? {
        guard let prompt = cache.withState(for: url, { $0.prompt }) ?? nil else { return nil }
        return prompt.count > 120 ? String(prompt.prefix(120)) + "…" : prompt
    }
}

nonisolated struct LastPromptState: JSONLFoldState {
    private(set) var prompt: String?

    init() {}

    /// The newest thing the user typed, including `/goal <task>`; settings
    /// commands (`/model opus`) are filtered out by UserPromptExtractor.
    mutating func consume(_ root: [String: Any]) {
        if let typed = UserPromptExtractor.prompt(from: root) {
            prompt = typed
        }
    }
}
