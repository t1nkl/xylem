//
//  ClaudeEffortChoice.swift
//  Xylem
//
//  The effort levels the toolbar's effort menu offers, and how a pick
//  reaches Claude Code: its `/effort` picker, set for this session only
//  (see `ModelSwitchController.switchEffort`; Claude Code 2.1.328 levels:
//  low, medium, high, xhigh, max).
//
//  What a session runs at is read from its transcript: every assistant line
//  carries the level its request was sent with (`"effort":"medium"`), and
//  "auto" is written as the level it resolved to. The settings can't tell:
//  with `"effortLevel": "xhigh"` in settings.json, Claude Code 2.1.328 ran
//  new sessions at auto (medium); `CLAUDE_CODE_EFFORT_LEVEL` and an
//  organization cap override both.
//
//  `/effort <level>` typed with an argument would also save the level as
//  the default for new sessions of that model
//  (`modelSettings.<model>.effortLevel` in ~/.claude/settings.json); the
//  picker's "s" keeps it to the session. "auto" has no place on the picker's
//  slider, so the menu doesn't offer it.
//

import Foundation

nonisolated struct ClaudeEffortChoice: Identifiable, Hashable, Sendable {
    /// `/effort` argument, also the value in the transcript.
    let level: String
    let title: String

    var id: String { level }

    /// Lowest to highest. A model with a lower cap gets the cap instead
    /// (Claude Code says so in the terminal; the next reply shows it here).
    static let levels: [ClaudeEffortChoice] = [
        ClaudeEffortChoice(level: "low", title: "Low"),
        ClaudeEffortChoice(level: "medium", title: "Medium"),
        ClaudeEffortChoice(level: "high", title: "High"),
        ClaudeEffortChoice(level: "xhigh", title: "Extra High"),
        ClaudeEffortChoice(level: "max", title: "Max")
    ]

    /// The choice for a transcript's level, if it is a known one.
    static func matching(level: String?) -> ClaudeEffortChoice? {
        guard let level = level?.lowercased() else { return nil }
        return levels.first { $0.level == level }
    }
}

/// Claude Code's `/effort` picker as it appears on screen (2.1.328):
/// "←/→ to adjust · s to use this session only · Enter to save · Esc to
/// cancel", then "Set effort level to high (this session only): …".
/// Matching ignores whitespace and case: the terminal may wrap or pad it.
nonisolated enum EffortPicker {
    static let left = "\u{1B}[D"
    static let right = "\u{1B}[C"
    static let thisSessionOnly = "s"
    static let cancel = "\u{1B}"

    static func isOpen(onScreen screen: String) -> Bool {
        let text = normalized(screen)
        return text.contains("stousethissessiononly") && text.contains("esctocancel")
    }

    /// The levels of the "this session only" confirmations on screen, top
    /// to bottom.
    static func confirmations(onScreen screen: String) -> [String] {
        normalized(screen).matches(of: /seteffortlevelto([a-z]+)\(thissessiononly\)/).map { String($0.1) }
    }

    /// The slider's stops, left to right, from its label row ("low medium
    /// high xhigh max"; a model with a lower cap has fewer). Read with the
    /// whitespace gone, so a row split or padded by the terminal still
    /// matches. Nil when no such row is on screen.
    static func stops(onScreen screen: String) -> [String]? {
        guard let row = normalized(screen).firstMatch(of: /lowmedium(high)?(xhigh)?(max)?/) else { return nil }
        return ["low", "medium"] + [row.1, row.2, row.3].compactMap { $0.map(String.init) }
    }

    private static func normalized(_ screen: String) -> String {
        String(screen.lowercased().unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
    }
}
