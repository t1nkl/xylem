//
//  LastPromptReader.swift
//  Xylem
//
//  Pulls the most recent user prompt and the session's name from a Claude
//  session jsonl. Used by the tab card and the overview sheet to show what
//  the user last typed and what the session is about without forcing the
//  caller to know the jsonl shape.
//
//  The name is Claude Code's own: a `custom-title` line (`/rename`) wins
//  over the `ai-title` lines it writes as the conversation goes (both
//  last-wins, 2.1.332). Claude Code passes the same name to the status line
//  as `session_name`.
//
//  Folded incrementally (IncrementalJSONLCache): repeated reads of a
//  growing file parse only the appended lines.
//

import Foundation

nonisolated enum LastPromptReader {
    private static let cache = IncrementalJSONLCache<LastPromptState>()

    /// What a tab shows of its transcript.
    struct Preview: Equatable, Sendable {
        /// The latest thing the user typed, at most 120 characters.
        var prompt: String?
        /// The session's name; nil until Claude Code has named it.
        var title: String?
    }

    /// Returns the *latest* thing the user typed (see UserPromptExtractor
    /// for what is filtered out). Filtering happens while folding, so a
    /// slash-command echo or hook message after a real prompt does not hide
    /// it. Truncated to 120 chars with an ellipsis.
    static func read(from url: URL) -> String? {
        preview(from: url)?.prompt
    }

    /// The prompt and the session's name in one read.
    static func preview(from url: URL) -> Preview? {
        cache.withState(for: url) { state in
            Preview(prompt: state.prompt.map(truncated), title: state.title)
        }
    }

    static let titleLimit = 200

    private static func truncated(_ prompt: String) -> String {
        prompt.count > 120 ? String(prompt.prefix(120)) + "…" : prompt
    }
}

nonisolated struct LastPromptState: JSONLFoldState {
    private(set) var prompt: String?
    private var customTitle: String?
    private var aiTitle: String?

    init() {}

    /// A name the user gave (`/rename`) over the one Claude Code made up.
    var title: String? { customTitle ?? aiTitle }

    /// The newest thing the user typed, including `/goal <task>`; settings
    /// commands (`/model opus`) are filtered out by UserPromptExtractor.
    mutating func consume(_ root: [String: Any]) {
        switch root["type"] as? String {
        case "custom-title":
            if let name = Self.name(root["customTitle"]) { customTitle = name }
        case "ai-title":
            if let name = Self.name(root["aiTitle"]) { aiTitle = name }
        default:
            if let typed = UserPromptExtractor.prompt(from: root) {
                prompt = typed
            }
        }
    }

    /// One line, trimmed and capped; nil when empty.
    private static func name(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > LastPromptReader.titleLimit ? String(trimmed.prefix(LastPromptReader.titleLimit)) : trimmed
    }
}
